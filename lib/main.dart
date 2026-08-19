import 'dart:async';
import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:window_manager/window_manager.dart';

import 'core/utils/window_listener_adapter.dart';
import 'core/config/app_config.dart';
import 'core/database/database_helper.dart';
import 'core/models/transfer.dart';
import 'core/providers/device_provider.dart';
import 'core/providers/transfer_provider.dart';
import 'core/providers/incoming_files_provider.dart';
import 'core/providers/theme_provider.dart';
import 'core/services/single_instance_service.dart';
import 'core/services/startup_logger.dart';
import 'core/services/system_tray_service.dart';
import 'core/services/share_intent_service.dart';
import 'core/services/desktop_notification_service.dart';
import 'core/services/window_bounds_validator.dart';
import 'core/services/window_settings_service.dart';
import 'ui/screens/main_navigation_screen.dart';
import 'ui/screens/onboarding_screen.dart';
import 'ui/screens/quick_send_screen.dart';
import 'ui/screens/browser_share_screen.dart';
import 'ui/screens/text_share_screen.dart';
import 'ui/theme/app_theme.dart';

/// Held for the process lifetime so the single-instance listener stays bound.
SingleInstanceGuard? _instanceGuard;

void main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize SQLite for desktop platforms
  if (Platform.isWindows || Platform.isLinux) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  // Check onboarding status
  final prefs = await SharedPreferences.getInstance();
  final onboardingComplete = prefs.getBool('onboarding_complete') ?? false;

  // Parse incoming file arguments (for right-click send)
  List<String>? incomingFiles;
  if (args.isNotEmpty) {
    incomingFiles = args.where((arg) {
      // Filter out Flutter/Dart internal arguments
      if (arg.startsWith('--') || arg.startsWith('-')) {
        return false;
      }
      // Check if path exists
      return File(arg).existsSync() || Directory(arg).existsSync();
    }).toList();

    if (incomingFiles.isNotEmpty) {
      debugPrint('📥 Received ${incomingFiles.length} file(s) from command line');
      for (final file in incomingFiles) {
        debugPrint('  - $file');
      }
    }
  }

  // Initialize window manager for desktop
  if (Platform.isWindows || Platform.isLinux) {
    try {
      await windowManager.ensureInitialized();

      // Single-instance guard: a second launch asks the running instance to
      // show its window instead of starting a conflicting duplicate process.
      final guard = SingleInstanceGuard(AppConfig.singleInstancePort);
      final role = await guard.start(
        onShowWindow: () async {
          try {
            if (SystemTrayService.isInitialized) {
              await SystemTrayService.showWindow();
            } else {
              await windowManager.show();
              await windowManager.focus();
            }
            await StartupLogger.log('Second instance signaled window show');
          } catch (e) {
            debugPrint('⚠️ Failed to show window on signal: $e');
          }
        },
      );
      if (role == SingleInstanceRole.secondary) {
        debugPrint('⚠️ Another Syndro instance is already running — exiting.');
        await StartupLogger.log('Secondary instance — exiting');
        exit(0);
      }
      _instanceGuard = guard;
      await StartupLogger.log('Single-instance listener bound on port '
          '${AppConfig.singleInstancePort}');

      // Load saved window settings
      await WindowSettingsService.initialize();
      var savedBounds = await WindowSettingsService.loadWindowBounds();

      // Never restore an off-screen or degenerate saved position: validate
      // against the current display layout (Windows only — the platform that
      // persists window geometry).
      if (Platform.isWindows) {
        savedBounds = await _sanitizeSavedBounds(savedBounds);
      }

      // Configure window options
      final windowSize = savedBounds != null
          ? Size(savedBounds.width, savedBounds.height)
          : WindowSettingsService.getDefaultSize();
      final windowOptions = WindowOptions(
        size: windowSize,
        minimumSize: WindowSettingsService.getMinimumSize(),
        center: savedBounds == null ||
            savedBounds.x == null ||
            savedBounds.y == null,
        backgroundColor: const Color(0xFF0A0A0F),
        skipTaskbar: false,
        titleBarStyle: TitleBarStyle.normal,
        title: 'Syndro',
      );

      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        // Apply saved maximized state, or restore the saved position.
        // Each call is individually guarded so show() + focus() always run.
        if (savedBounds?.maximized == true) {
          await _safeWindowCall('maximize', () => windowManager.maximize());
        } else if (savedBounds?.x != null && savedBounds?.y != null) {
          await _safeWindowCall(
            'setPosition',
            () => windowManager.setPosition(
              Offset(savedBounds!.x!, savedBounds.y!),
            ),
          );
        }

        await windowManager.show();
        await windowManager.focus();
        await StartupLogger.log(
          'Window shown — size ${windowSize.width.toInt()}x'
          '${windowSize.height.toInt()}, position '
          '${savedBounds?.x?.toInt() ?? 'centered'},'
          '${savedBounds?.y?.toInt() ?? 'centered'}, maximized '
          '${savedBounds?.maximized ?? false}',
        );
      });

      // Window events handled by _SyndroAppState.onWindowClose()

      // Initialize desktop notification service
      await DesktopNotificationService.initialize();
      debugPrint('✅ Desktop notification service initialized');
      await StartupLogger.log('Desktop notification service initialized');
    } catch (e) {
      debugPrint('⚠️ Window manager initialization failed: $e');
      await StartupLogger.log('Window manager initialization failed: $e');
      // Continue without window manager - app will still work
    }
  }

  // Create the ProviderContainer to pre-initialize services
  final container = ProviderContainer();

  // PRE-INITIALIZE device discovery service BEFORE app loads
  debugPrint('🚀 Pre-initializing device discovery...');

  try {
    final deviceService = container.read(deviceDiscoveryServiceProvider);
    await deviceService.initialize();
    debugPrint('✅ Device discovery initialized!');
  } catch (e) {
    debugPrint('❌ Device discovery initialization failed: $e');
    // Continue anyway - the app can retry later
  }

  // Global error handlers: uncaught async errors previously crashed the
  // engine/isolate silently in release builds. Log (and never crash) instead.
  runZonedGuarded(() {
    PlatformDispatcher.instance.onError = (error, stack) {
      debugPrint('❌ Platform error: $error');
      debugPrint('$stack');
      return true;
    };

    FlutterError.onError = (details) {
      FlutterError.presentError(details);
      debugPrint('❌ Flutter error: ${details.exception}');
      debugPrint('${details.stack}');
    };

    runApp(
      UncontrolledProviderScope(
        container: container,
        child: SyndroApp(
          showOnboarding: !onboardingComplete,
          incomingFiles: incomingFiles,
        ),
      ),
    );
  }, (error, stack) {
    debugPrint('❌ Uncaught zone error: $error');
    debugPrint('$stack');
  });
}

/// Convert screen_retriever displays into logical-pixel [Rect]s (falling back
/// to the full size/zero origin when the visible area is unavailable).
List<Rect> displayBounds(List<Display> displays) {
  return displays.map((display) {
    final position = display.visiblePosition ?? Offset.zero;
    final size = display.visibleSize ?? display.size;
    return Rect.fromLTWH(
      position.dx,
      position.dy,
      size.width,
      size.height,
    );
  }).toList();
}

/// Validate saved window bounds against the current display layout so the
/// window can never be restored off-screen or with a degenerate size.
Future<WindowBounds?> _sanitizeSavedBounds(WindowBounds? saved) async {
  if (saved == null) return null;
  try {
    final displays = await ScreenRetriever.instance.getAllDisplays();
    final result = WindowBoundsValidator.sanitize(
      saved,
      displayBounds(displays),
    );
    await StartupLogger.log(
      result == null
          ? 'Saved window bounds rejected (off-screen or degenerate): $saved'
          : 'Saved window bounds accepted: $result',
    );
    return result;
  } catch (e) {
    debugPrint('⚠️ Could not validate window bounds: $e');
    await StartupLogger.log('Could not validate window bounds: $e');
    return saved;
  }
}

/// Run a window-manager call but never let a failure stop the window from
/// being shown.
Future<void> _safeWindowCall(
  String name,
  Future<void> Function() action,
) async {
  try {
    await action();
  } catch (e) {
    debugPrint('⚠️ Window call "$name" failed: $e');
  }
}

class SyndroApp extends ConsumerStatefulWidget {
  final bool showOnboarding;
  final List<String>? incomingFiles;

  const SyndroApp({
    super.key,
    required this.showOnboarding,
    this.incomingFiles,
  });

  @override
  ConsumerState<SyndroApp> createState() => _SyndroAppState();
}

class _SyndroAppState extends ConsumerState<SyndroApp>
    with WidgetsBindingObserver, WindowListenerAdapter {
  bool _initialized = false;
  String? _initError;
  bool _windowListenerAdded = false;

  // Share intent state
  List<SharedFile>? _sharedFilesFromIntent;
  List<File>? _browserShareFiles;
  String? _sharedTextFromIntent;
  bool _hasShareIntent = false;
  AndroidShareMode _shareMode = AndroidShareMode.appToApp;
  StreamSubscription<List<SharedFile>>? _sharedFilesSubscription;
  StreamSubscription<AndroidShareMode>? _shareModeSubscription;
  StreamSubscription<String>? _sharedTextSubscription;
  bool _shareIntentHandled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Add window listener for desktop
    if (Platform.isWindows || Platform.isLinux) {
      try {
        windowManager.addListener(this);
        _windowListenerAdded = true;
      } catch (e) {
        debugPrint('⚠️ Could not add window listener: $e');
      }
    }

    _initializeApp();

    // Self-heal: if the window did not become visible for any reason, force
    // it after the first frame so the app can never end up icon-only.
    if (Platform.isWindows || Platform.isLinux) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _ensureWindowVisible();
      });
    }
  }

  /// Force the window visible if it somehow ended up hidden.
  Future<void> _ensureWindowVisible() async {
    try {
      final visible = await windowManager.isVisible();
      if (!visible) {
        debugPrint('⚠️ Window not visible after first frame — forcing show');
        await windowManager.show();
        await windowManager.focus();
        await StartupLogger.log('Window not visible after first frame — '
            'forced show');
      }
    } catch (e) {
      debugPrint('⚠️ Could not verify window visibility: $e');
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);

    // Cancel share intent stream subscriptions
    _sharedFilesSubscription?.cancel();
    _shareModeSubscription?.cancel();
    _sharedTextSubscription?.cancel();

    // Only remove listener if we added it
    if (_windowListenerAdded) {
      try {
        windowManager.removeListener(this);
      } catch (e) {
        debugPrint('⚠️ Could not remove window listener: $e');
      }
    }

    // Prevent double dispose — fire-and-forget is correct for sync dispose()
    SystemTrayService.dispose().timeout(
      const Duration(seconds: 3),
      onTimeout: () => debugPrint('⚠️ SystemTrayService disposal timed out'),
    ).catchError((e) => debugPrint('⚠️ SystemTrayService disposal error: $e'));
    super.dispose();
  }

  Future<void> _initializeApp() async {
    // Initialize system tray for desktop
    if (Platform.isWindows || Platform.isLinux) {
      try {
        await SystemTrayService.initialize(
          onShowWindow: () {
            debugPrint('Window shown from tray');
          },
          onToggleServer: () {
            debugPrint('Toggle server from tray');
          },
          onExit: () {
            debugPrint('Exit from tray');
          },
        );
      } catch (e) {
        debugPrint('⚠️ System tray initialization failed: $e');
        // Continue without system tray
      }
    }

    // Initialize share intent service (Android)
    if (Platform.isAndroid) {
      try {
        final shareIntentService = ShareIntentService();
        await shareIntentService.initialize();
        
        // Listen for share intents
        _sharedFilesSubscription = shareIntentService.sharedFilesStream.listen((files) {
          if (files.isNotEmpty && mounted) {
            debugPrint('📥 Received ${files.length} file(s) from share intent');
            // Get the share mode from the service
            final mode = shareIntentService.lastShareMode;
            debugPrint('📱 Share mode: $mode');
            
            setState(() {
              _sharedFilesFromIntent = files;
              _hasShareIntent = true;
              _shareMode = mode;
            });
          }
        });
        
        // Also listen for share mode changes
        _shareModeSubscription = shareIntentService.shareModeStream.listen((mode) {
          if (mounted) {
            debugPrint('📱 Share mode changed to: $mode');
            setState(() {
              _shareMode = mode;
            });
          }
        });

        // Listen for shared text (text/plain share intents)
        _sharedTextSubscription =
            shareIntentService.sharedTextStream.listen((text) {
          if (text.isNotEmpty && mounted) {
            debugPrint('📝 Received shared text');
            setState(() {
              _sharedTextFromIntent = text;
              _hasShareIntent = true;
              _shareMode = AndroidShareMode.textShare;
            });
          }
        });
      } catch (e) {
        debugPrint('⚠️ Share intent service initialization failed: $e');
      }
    }

    // Handle incoming files from command line
    if (widget.incomingFiles != null && widget.incomingFiles!.isNotEmpty) {
      try {
        await ref
            .read(incomingFilesProvider.notifier)
            .setFilesFromPaths(widget.incomingFiles!);
      } catch (e) {
        debugPrint('⚠️ Error setting incoming files: $e');
      }
    }

    // Initialize transfer server for discovery
    try {
      debugPrint('🚀 Starting transfer server...');
      final transferService = ref.read(transferServiceProvider);

      // Initialize encryption and trusted devices before starting server
      await transferService.initialize();

      try {
        await transferService.startServer(AppConfig.defaultTransferPort);
        debugPrint('✅ Transfer server started');
      } catch (e) {
        debugPrint('❌ Failed to start transfer server: $e');
        _initError = 'Could not start transfer server';
      }
    } catch (e) {
      debugPrint('❌ Failed to initialize transfer service: $e');
      _initError = 'Transfer service error: $e';
    }

    if (mounted) {
      setState(() => _initialized = true);
    }
    await StartupLogger.log(
      _initError == null
          ? 'App initialization complete'
          : 'App initialization complete with error: $_initError',
    );
  }

  /// One-time notification so users know the app kept running in the tray
  /// instead of closing (previously this was silent and looked like a crash).
  static bool _trayMinimizeNotified = false;

  Future<void> _notifyMinimizedToTray() async {
    if (_trayMinimizeNotified) return;
    _trayMinimizeNotified = true;
    try {
      await DesktopNotificationService.show(
        title: 'Syndro is still running',
        body: 'The app is in the system tray — click the tray icon to reopen it.',
      );
    } catch (e) {
      debugPrint('⚠️ Tray minimize notification failed: $e');
    }
  }

  @override
  void onWindowClose() async {
    try {
      // Save window bounds before handling close
      try {
        final size = await windowManager.getSize();
        final position = await windowManager.getPosition();
        final maximized = await windowManager.isMaximized();
        await WindowSettingsService.saveWindowBounds(
          size: size,
          position: position,
          maximized: maximized,
        );
      } catch (e) {
        debugPrint('⚠️ Error saving window bounds: $e');
      }

      final isPreventClose = await windowManager.isPreventClose();

      if (isPreventClose && SystemTrayService.isInitialized) {
        await SystemTrayService.minimizeToTray();
        await _notifyMinimizedToTray();
      } else {
        // FIXED: Properly dispose resources before exiting
        debugPrint('🧹 Cleaning up resources before exit...');
        
        // FIX (Bug #8): Close database before exiting
        try {
          await DatabaseHelper.instance.close();
          debugPrint('✅ Database closed');
        } catch (e) {
          debugPrint('⚠️ Error closing database: $e');
        }
        
        // Dispose system tray
        await SystemTrayService.dispose();
        
        // Give services time to cleanup
        await Future.delayed(const Duration(milliseconds: 500));

        // Release the single-instance listener before destroying the window
        await _instanceGuard?.dispose();

        // Now destroy window
        await windowManager.destroy();
      }
    } catch (e) {
      debugPrint('⚠️ Error handling window close: $e');
      // Try graceful cleanup before fallback
      try {
        await DatabaseHelper.instance.close();
        debugPrint('✅ Database closed in fallback');
      } catch (dbError) {
        debugPrint('⚠️ Database close error in fallback: $dbError');
      }
      try {
        await SystemTrayService.dispose();
        debugPrint('✅ System tray disposed in fallback');
      } catch (trayError) {
        debugPrint('⚠️ System tray dispose error in fallback: $trayError');
      }
      // Give a brief moment for cleanup to complete
      await Future.delayed(const Duration(milliseconds: 100));
      // Use windowManager.destroy() instead of exit(0) for proper Flutter lifecycle
      try {
        await windowManager.destroy();
      } catch (destroyError) {
        debugPrint('⚠️ Error destroying window: $destroyError');
        // Only use exit(0) as absolute last resort when window manager is unavailable
        // This ensures the app still terminates even if window manager is corrupted
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final incomingFilesState = ref.watch(incomingFilesProvider);
    final themeMode = ref.watch(themeModeProvider);

    // Sync the legacy hardcoded AppTheme.* palette with the selected mode
    // before any widget builds, so light mode renders light colors.
    AppTheme.applyMode(themeMode);

    return MaterialApp(
      title: 'Syndro',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      darkTheme: AppTheme.darkTheme,
      themeMode: themeMode,
      home: _buildHome(incomingFilesState),
    );
  }

  Widget _buildHome(IncomingFilesState incomingFilesState) {
    // Show loading screen while initializing
    if (!_initialized) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: AppTheme.backgroundGradient,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 24),
                Text(
                  'Starting Syndro...',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // Show error if initialization failed critically
    if (_initError != null) {
      return Scaffold(
        body: Container(
          decoration: BoxDecoration(
            gradient: AppTheme.backgroundGradient,
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: AppTheme.errorColor,
                  size: 64,
                ),
                const SizedBox(height: 24),
                Text(
                  'Initialization Error',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 32),
                  child: Text(
                    _initError!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ),
                const SizedBox(height: 24),
                ElevatedButton(
                  onPressed: () {
                    setState(() {
                      _initError = null;
                      _initialized = false;
                    });
                    _initializeApp();
                  },
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    }

    // If we have incoming files, show quick send screen
    if (incomingFilesState.hasFiles && _initialized) {
      return QuickSendScreen(
        files: incomingFilesState.files,
        onComplete: () {
          ref.read(incomingFilesProvider.notifier).clear();
        },
      );
    }

    // If we have browser share files, show browser share screen
    if (_browserShareFiles != null && _browserShareFiles!.isNotEmpty && _initialized) {
      final files = _browserShareFiles!;
      // Defer state mutation to post-frame callback (build must be pure)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _browserShareFiles = null;
          });
        }
      });
      return BrowserShareScreen(
        files: files,
      );
    }

    // Show share intent dialog if app was opened from another app
    if (_hasShareIntent && _sharedFilesFromIntent != null && _initialized && !_shareIntentHandled) {
      _shareIntentHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          if (_shareMode == AndroidShareMode.browserShare) {
            _handleBrowserShare();
          } else if (_shareMode == AndroidShareMode.textShare) {
            _handleTextShare();
          } else {
            _handleAppToAppShare();
          }
        }
      });
      return _buildShareIntentScreen();
    }

    // Show text share picker if a text/plain intent was received
    if (_hasShareIntent &&
        _shareMode == AndroidShareMode.textShare &&
        _sharedTextFromIntent != null &&
        _initialized &&
        !_shareIntentHandled) {
      _shareIntentHandled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _handleTextShare();
        }
      });
      return _buildShareIntentScreen();
    }

    // Normal app flow
    if (widget.showOnboarding) {
      return const OnboardingScreen();
    }

    return const MainNavigationScreen();
  }

  // Build screen for handling share intents from other apps
  // On Android, directly navigates based on share mode (no dialog)
  Widget _buildShareIntentScreen() {
    // Show loading while processing
    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 24),
              Text(
                'Preparing share...',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _handleAppToAppShare() async {
    debugPrint('App to App share selected with ${_sharedFilesFromIntent?.length ?? 0} files');
    
    if (_sharedFilesFromIntent == null || _sharedFilesFromIntent!.isEmpty) {
      setState(() {
        _hasShareIntent = false;
      });
      return;
    }

    // On Android, content:// URIs need to be copied to actual files
    // Use the copyContentUri method from ShareIntentService via platform channel
    final items = <TransferItem>[];
    
    for (final sharedFile in _sharedFilesFromIntent!) {
      final uri = sharedFile.uri;
      
      if (uri.startsWith('content://')) {
        // Copy content URI to temp file
        try {
          final tempDir = await getTemporaryDirectory();
          final result = await ShareIntentService().copyContentUri(
            uri: uri,
            tempDir: tempDir.path,
            fileName: sharedFile.name,
          );
          
          if (result != null) {
            // Use the original name from the share intent, not the temp file name
            final fileName = sharedFile.name ?? result.split('/').last;
            items.add(TransferItem(
              name: fileName,
              path: result,
              size: sharedFile.size,
              isDirectory: false,
            ));
            debugPrint('✅ Copied content URI to: $result (name: $fileName, size: ${sharedFile.size})');
          } else {
            debugPrint('⚠️ Failed to copy content URI: $uri');
          }
        } catch (e) {
          debugPrint('❌ Error copying content URI: $e');
        }
      } else {
        // Regular file path - use the name from share intent
        final fileName = sharedFile.name ?? uri.split('/').last;
        items.add(TransferItem(
          name: fileName,
          path: uri,
          size: sharedFile.size,
          isDirectory: false,
        ));
      }
    }
    
    debugPrint('Processed ${items.length} files:');
    for (final item in items) {
      debugPrint('  - ${item.name} (${item.size} bytes)');
    }
    
    // Set the files directly - this triggers the state to show QuickSendScreen
    if (items.isNotEmpty) {
      ref.read(incomingFilesProvider.notifier).setFiles(items);
      debugPrint('Set ${items.length} files for QuickSendScreen');
    }

    // Clear the share intent from Android
    ShareIntentService().clearSharedFiles();
    
    // NOW change state to close dialog and trigger rebuild
    // The rebuild will see incomingFilesState.hasFiles is true and show QuickSendScreen
    if (mounted) {
      setState(() {
        _hasShareIntent = false;
      });
    }
  }

  void _handleTextShare() {
    debugPrint('📝 Text share selected');
    final text = _sharedTextFromIntent;
    if (text == null || text.trim().isEmpty) {
      if (mounted) {
        setState(() {
          _hasShareIntent = false;
          _shareIntentHandled = false;
        });
      }
      return;
    }

    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => TextShareScreen(
          text: text,
          onComplete: () async {
            ShareIntentService().clearSharedFiles();
            if (mounted) {
              setState(() {
                _hasShareIntent = false;
                _sharedTextFromIntent = null;
              });
            }
            Navigator.of(context).popUntil((route) => route.isFirst);
          },
        ),
      ),
    );
  }

  void _handleBrowserShare() async {
    debugPrint('Browser share selected with ${_sharedFilesFromIntent?.length ?? 0} files');
    
    if (_sharedFilesFromIntent == null || _sharedFilesFromIntent!.isEmpty) {
      setState(() {
        _hasShareIntent = false;
      });
      return;
    }

    // On Android, content:// URIs need to be copied to actual files
    // Same as _handleAppToAppShare - we need proper file paths for thumbnails and file info
    final files = <File>[];
    
    for (final sharedFile in _sharedFilesFromIntent!) {
      final uri = sharedFile.uri;
      
      if (uri.startsWith('content://')) {
        // Copy content URI to temp file
        try {
          final tempDir = await getTemporaryDirectory();
          final result = await ShareIntentService().copyContentUri(
            uri: uri,
            tempDir: tempDir.path,
            fileName: sharedFile.name,
          );
          
          if (result != null) {
            files.add(File(result));
            debugPrint('✅ Copied content URI to: $result (name: ${sharedFile.name}, size: ${sharedFile.size})');
          } else {
            debugPrint('⚠️ Failed to copy content URI: $uri');
          }
        } catch (e) {
          debugPrint('❌ Error copying content URI: $e');
        }
      } else {
        // Regular file path
        files.add(File(uri));
      }
    }

    // Clear share intent and set browser share files
    ShareIntentService().clearSharedFiles();

    // The content-URI copies above are async — the widget may be gone by now.
    if (!mounted) return;
    setState(() {
      _hasShareIntent = false;
      _browserShareFiles = files;
    });
  }
}
