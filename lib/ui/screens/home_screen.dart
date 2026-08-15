import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../animations/pulse_animation.dart';
import '../widgets/device_card.dart';
import '../../core/models/device.dart';
import '../../core/providers/device_provider.dart';
import '../../core/providers/transfer_provider.dart';
import '../../core/services/transfer_service.dart';
import 'file_picker_screen.dart';
import 'browser_share_screen.dart';
import 'browser_receive_screen.dart';
import 'home_screen_strings.dart';
import '../../core/utils/byte_formatter.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  bool _isRefreshing = false;
  bool _isShowingRequestSheet = false;

  ProviderSubscription<AsyncValue<List<PendingTransferRequest>>>?
      _pendingRequestsSubscription;
  
  // FIX (Bug #6): Store timer reference for cancellation on dispose
  Timer? _pendingRequestTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenForIncomingRequests();
  }

  // FIX (Bug #3): Ensure all subscriptions are properly cancelled
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    
    // FIX (Bug #6): Cancel pending request timer
    _pendingRequestTimer?.cancel();
    _pendingRequestTimer = null;
    
    // Cancel subscription with try-catch
    try {
      _pendingRequestsSubscription?.close();
      _pendingRequestsSubscription = null;
    } catch (e) {
      debugPrint('Error closing pending requests subscription: $e');
    }
    
    debugPrint('🧹 HomeScreen disposed');
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      _refreshDevices();
    }
  }

  void _listenForIncomingRequests() {
    // Create subscription directly in initState to avoid race condition
    // with addPostFrameCallback and fast dispose scenarios
    try {
      _pendingRequestsSubscription =
          ref.listenManual<AsyncValue<List<PendingTransferRequest>>>(
        pendingTransferRequestsProvider,
        (previous, next) {
          // Check mounted state synchronously before any async operations
          if (!mounted || _isShowingRequestSheet) return;
          
          next.whenData((requests) {
            // Check again inside whenData callback
            if (requests.isNotEmpty && mounted && !_isShowingRequestSheet) {
              _showTransferRequestSheet(requests.first);
            }
          });
        },
      );
    } catch (e) {
      debugPrint('⚠️ Error creating pending requests subscription: $e');
    }
  }

  void _showTransferRequestSheet(PendingTransferRequest request) {
    if (_isShowingRequestSheet || !mounted) return;
    setState(() => _isShowingRequestSheet = true);

    final scaffoldMessenger = ScaffoldMessenger.of(context);

    try {
      showModalBottomSheet(
        context: context,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (bottomSheetContext) {
          return _TransferRequestSheetContent(
            request: request,
            onAccept: () async {
              if (!mounted) return;
              Navigator.of(bottomSheetContext).pop();
              if (!mounted) return;
              await Future.delayed(const Duration(milliseconds: 100));
              if (!mounted) return;

              try {
                final transferService = ref.read(transferServiceProvider);
                await transferService.approveTransfer(request.requestId);

                if (!mounted) return;
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text(HomeScreenStrings.transferAccepted),
                    backgroundColor: AppTheme.successColor,
                  ),
                );
              } catch (e) {
                debugPrint('Error accepting transfer: $e');
                if (!mounted) return;
                scaffoldMessenger.showSnackBar(
                  SnackBar(
                    content: Text(HomeScreenStrings.failedToAccept(e.toString())),
                    backgroundColor: AppTheme.errorColor,
                  ),
                );
              }
            },
            onReject: () async {
              if (!mounted) return;
              Navigator.of(bottomSheetContext).pop();
              if (!mounted) return;
              await Future.delayed(const Duration(milliseconds: 100));
              if (!mounted) return;

              try {
                final transferService = ref.read(transferServiceProvider);
                transferService.rejectTransfer(request.requestId);

                if (!mounted) return;
                scaffoldMessenger.showSnackBar(
                  const SnackBar(
                    content: Text(HomeScreenStrings.transferRejected),
                    backgroundColor: AppTheme.warningColor,
                  ),
                );
              } catch (e) {
                debugPrint('Error rejecting transfer: $e');
              }
            },
          );
        },
      ).whenComplete(() {
        if (!mounted) return;
        setState(() => _isShowingRequestSheet = false);

        try {
          if (!mounted) return;
          final pendingRequests =
              ref.read(transferServiceProvider).pendingRequests;
          if (pendingRequests.isNotEmpty) {
            // FIX (Bug #6): Store timer reference for cancellation on dispose
            _pendingRequestTimer?.cancel();
            _pendingRequestTimer = Timer(const Duration(milliseconds: 300), () {
              if (mounted && !_isShowingRequestSheet) {
                _showTransferRequestSheet(pendingRequests.first);
              }
            });
          }
        } catch (e) {
          debugPrint('Error checking pending requests: $e');
        }
      });
    } catch (e) {
      debugPrint('⚠️ Error showing transfer request sheet: $e');
      // FIXED (Bug #4): Reset flag if sheet fails to show
      if (mounted) {
        setState(() => _isShowingRequestSheet = false);
      }
    }
  }

  Future<void> _refreshDevices() async {
    if (_isRefreshing || !mounted) return;
    setState(() => _isRefreshing = true);

    try {
      final service = ref.read(deviceDiscoveryServiceProvider);
      await service.refreshDevices();
    } catch (e) {
      debugPrint('Refresh error: $e');
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
  }

  bool _isMobile() {
    return Platform.isAndroid;
  }

  // FIX (Bug #13): Ensure loading dialog is always dismissed
  void _showLoadingDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.6),
      builder: (dialogContext) => PopScope(
        canPop: false,
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.xxxl,
              vertical: AppSpacing.xxl,
            ),
            decoration: BoxDecoration(
              color: AppTheme.surfaceContainerHigh,
              borderRadius: AppRadius.xlAll,
              border: Border.all(color: AppTheme.outlineVariant, width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.3),
                  blurRadius: 20,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(
                  color: AppTheme.primaryColor,
                ),
                SizedBox(height: AppSpacing.xl),
                Text(
                  'Preparing files...',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
                SizedBox(height: AppSpacing.sm),
                Text(
                  'This may take a moment for large files',
                  style: TextStyle(
                    color: AppTheme.textTertiary,
                    fontSize: 12,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // FIX (Bug #13 & #14): Safe dialog dismissal helper
  void _dismissLoadingDialog() {
    if (mounted && context.mounted) {
      try {
        // Use root navigator to ensure we dismiss the right dialog
        Navigator.of(context, rootNavigator: true).pop();
      } catch (e) {
        debugPrint('Error dismissing dialog: $e');
      }
    }
  }

  void _showShareModeDialog() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius:
              BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40,
              height: 4,
              decoration: const BoxDecoration(
                color: AppTheme.borderColor,
                borderRadius: AppRadius.pillAll,
              ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            Text(
              'Browser Share',
              style: Theme.of(sheetContext).textTheme.titleLarge,
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Share files without installing an app',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Connect to the same WiFi network or create a Hotspot',
              style: Theme.of(sheetContext).textTheme.bodySmall?.copyWith(
                    color: AppTheme.warningColor,
                  ),
            ),
            const SizedBox(height: AppSpacing.xxl),
            _buildShareOption(
              context: sheetContext,
              icon: Icons.photo_library,
              title: 'Share Media',
              subtitle: 'Photos and videos from gallery',
              color: AppTheme.secondaryColor,
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndShareMedia();
              },
            ),
            const SizedBox(height: AppSpacing.md),
            _buildShareOption(
              context: sheetContext,
              icon: Icons.upload_file,
              title: 'Send Files',
              subtitle: 'Share files via browser link',
              color: AppTheme.primaryColor,
              onTap: () {
                Navigator.pop(sheetContext);
                _pickAndShareFiles();
              },
            ),
            const SizedBox(height: AppSpacing.md),
            _buildShareOption(
              context: sheetContext,
              icon: Icons.download,
              title: 'Receive Files',
              subtitle: 'Get files from any device',
              color: AppTheme.accentColor,
              onTap: () {
                Navigator.pop(sheetContext);
                _openReceiveScreen();
              },
            ),
            const SizedBox(height: AppSpacing.lg),
          ],
        ),
      ),
    );
  }

  Widget _buildShareOption({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.lgAll,
        child: Container(
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.1),
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: color.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(AppSpacing.md),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.2),
                  borderRadius: AppRadius.mdAll,
                ),
                child: Icon(
                  icon,
                  color: color,
                  size: 28,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                    ),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                color: AppTheme.textTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ============================================
  // FIXED: _pickAndShareMedia with loading dialog
  // ============================================
  Future<void> _pickAndShareMedia() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.media,
    );

    if (result != null && result.files.isNotEmpty && mounted) {
      // Calculate total size for large file warning
      double totalSize = 0;
      for (final file in result.files) {
        totalSize += file.size;
      }
      
      // Show warning for large files (> 2GB)
      const double largeFileThreshold = 2 * 1024 * 1024 * 1024;
      if (totalSize > largeFileThreshold) {
        final shouldProceed = await _showLargeFileWarningDialog(totalSize);
        if (!shouldProceed) return;
      }

      _showLoadingDialog();

      try {
        await Future.delayed(const Duration(milliseconds: 100));

        final files = result.files
            .where((f) => f.path != null)
            .map((f) => File(f.path!))
            .toList();

        _dismissLoadingDialog();

        if (files.isNotEmpty && mounted) {
          _openBrowserShareScreen(files, ShareMode.media);
        }
      } catch (e) {
        debugPrint('Error processing media files: $e');
        _dismissLoadingDialog();
        
        // FIX (Bug #18): Show error feedback to user
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error processing files: $e'),
              backgroundColor: AppTheme.errorColor,
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Retry',
                textColor: Colors.white,
                onPressed: _pickAndShareMedia,
              ),
            ),
          );
        }
      }
    }
  }

  Future<void> _pickAndShareFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.any,
    );

    if (result != null && result.files.isNotEmpty && mounted) {
      // Calculate total size for large file warning
      double totalSize = 0;
      for (final file in result.files) {
        totalSize += file.size;
      }
      
      // Show warning for large files (> 2GB)
      const double largeFileThreshold = 2 * 1024 * 1024 * 1024;
      if (totalSize > largeFileThreshold) {
        final shouldProceed = await _showLargeFileWarningDialog(totalSize);
        if (!shouldProceed) return;
      }

      _showLoadingDialog();

      try {
        await Future.delayed(const Duration(milliseconds: 100));

        final files = result.files
            .where((f) => f.path != null)
            .map((f) => File(f.path!))
            .toList();

        _dismissLoadingDialog();

        if (files.isNotEmpty && mounted) {
          _openBrowserShareScreen(files, ShareMode.files);
        }
      } catch (e) {
        debugPrint('Error processing files: $e');
        _dismissLoadingDialog();
        
        // FIX (Bug #18): Show error feedback to user
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error processing files: $e'),
              backgroundColor: AppTheme.errorColor,
              behavior: SnackBarBehavior.floating,
              action: SnackBarAction(
                label: 'Retry',
                textColor: Colors.white,
                onPressed: _pickAndShareFiles,
              ),
            ),
          );
        }
      }
    }
  }
  
  /// Show warning dialog for large file transfers
  /// Returns true if user wants to proceed, false otherwise
  Future<bool> _showLargeFileWarningDialog(num totalSize) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surfaceContainerHigh,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.xlAll,
          side: BorderSide(
            color: AppTheme.warningColor.withValues(alpha: 0.3),
          ),
        ),
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: AppTheme.warningColor),
            SizedBox(width: AppSpacing.md),
            Text('Large File Warning'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'You are about to share ${ByteFormatter.format(totalSize.toInt())}.',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: AppSpacing.lg),
            const Text(
              'Large files may take longer to prepare and could cause '
              'browser performance issues during download.',
            ),
            const SizedBox(height: AppSpacing.md),
            Container(
              padding: const EdgeInsets.all(AppSpacing.md),
              decoration: BoxDecoration(
                color: AppTheme.primaryContainer,
                borderRadius: AppRadius.smAll,
                border: Border.all(
                  color: AppTheme.primaryColor.withValues(alpha: 0.2),
                ),
              ),
              child: const Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      color: AppTheme.onPrimaryContainer, size: 20),
                  SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: Text(
                      'Tip: For better performance with large files, '
                      'use direct device-to-device transfer instead.',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.onPrimaryContainer),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Continue with Browser Share'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
  


  void _openBrowserShareScreen(List<File> files, ShareMode shareMode) {
    if (!mounted) return;

    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      showDialog(
        context: context,
        builder: (dialogContext) => Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.all(AppSpacing.xxl),
          child: ClipRRect(
            borderRadius: AppRadius.lgAll,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                maxWidth: 450,
                maxHeight: 650,
              ),
              child: BrowserShareScreen(
                files: files,
                shareMode: shareMode,
              ),
            ),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (routeContext) => BrowserShareScreen(
            files: files,
            shareMode: shareMode,
          ),
        ),
      );
    }
  }

  void _openReceiveScreen() {
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => const BrowserReceiveScreen(),
      ),
    );
  }

  Widget _buildCurrentDeviceCard(BuildContext context, dynamic currentDevice) {
    // Get custom nickname if available
    final customNickname = ref.watch(currentDeviceNicknameProvider);
    final displayName = customNickname ?? currentDevice.name;

    return AppCard(
      child: Row(
        children: [
          const GradientIconTile(
            icon: Icons.devices,
            size: 52,
            radius: AppRadius.lg,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'This Device',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    const StatusBadge(
                      label: 'Online',
                      variant: BadgeVariant.success,
                      showDot: true,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  displayName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    const Icon(
                      Icons.wifi_rounded,
                      size: 14,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      currentDevice.ipAddress,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final currentDevice = ref.watch(currentDeviceProvider);
    final discoveredDevicesAsync = ref.watch(discoveredDevicesProvider);
    final selectedDevice = ref.watch(selectedDeviceProvider);
    final isInitialized = ref.watch(isDeviceServiceInitializedProvider);

    final bottomPadding = _isMobile() ? 120.0 : 0.0;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GradientIconTile(
              icon: Icons.share,
              size: 36,
              iconSize: 20,
              radius: AppRadius.sm,
              glow: false,
            ),
            SizedBox(width: AppSpacing.md),
            Text('Syndro'),
          ],
        ),
        actions: const [],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: _buildCurrentDeviceCard(context, currentDevice),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: AppSpacing.md,
                    vertical: AppSpacing.sm,
                  ),
                  child: SectionHeader(
                    title: 'Nearby Devices',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildDeviceCountBadge(discoveredDevicesAsync),
                        if (_isRefreshing) ...[
                          const SizedBox(width: AppSpacing.md),
                          const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppTheme.primaryColor,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm),
                          Text(
                            'Scanning...',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: AppTheme.textTertiary),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                Expanded(
                  child: Padding(
                    padding: EdgeInsets.only(bottom: bottomPadding),
                    child: _buildDeviceList(
                      discoveredDevicesAsync,
                      isInitialized,
                      selectedDevice,
                    ),
                  ),
                ),
              ],
            ),

            // Browser Share FAB
            Positioned(
              right: AppSpacing.xl,
              bottom: _isMobile() ? 110 : 20,
              child: FloatingActionButton(
                heroTag: null,
                onPressed: _showShareModeDialog,
                backgroundColor: AppTheme.surfaceContainerHigh,
                foregroundColor: AppTheme.primaryColor,
                shape: const CircleBorder(),
                child: const Icon(Icons.language, size: 30),
              ),
            ),

            // Send Files FAB (when device selected)
            if (selectedDevice != null)
              Positioned(
                right: AppSpacing.xl,
                bottom: _isMobile() ? 190 : 80, // Raised from 20 to 80 for desktop
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (routeContext) => FilePickerScreen(
                          recipientDevice: selectedDevice,
                        ),
                      ),
                    );
                  },
                  backgroundColor: AppTheme.surfaceContainerHigh,
                  foregroundColor: AppTheme.primaryColor,
                  icon: const Icon(Icons.send, size: 24),
                  label: const Text('Send Files'),
                ),
              ),

            // Multi-select Send FAB (when multiple devices selected)
            if (ref.watch(selectedDevicesProvider).isNotEmpty)
              Positioned(
                right: AppSpacing.xl,
                bottom: _isMobile() ? 190 : 80,
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () {
                    final selectedDevices = ref.read(selectedDevicesProvider);
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (routeContext) => FilePickerScreen(
                          recipientDevices: selectedDevices.toList(),
                        ),
                      ),
                    );
                  },
                  icon: const Icon(Icons.send, size: 24),
                  label: Text('Send to ${ref.watch(selectedDevicesProvider).length}'),
                ),
              ),

            // Multi-select cancel button
            if (ref.watch(selectedDevicesProvider).isNotEmpty)
              Positioned(
                left: AppSpacing.xl,
                bottom: _isMobile() ? 190 : 80,
                child: FloatingActionButton(
                  heroTag: null,
                  onPressed: () {
                    ref.read(selectedDevicesProvider.notifier).state = {};
                  },
                  backgroundColor: AppTheme.errorContainer,
                  foregroundColor: AppTheme.onErrorContainer,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.close, size: 24),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCountBadge(AsyncValue<List<dynamic>> devicesAsync) {
    return devicesAsync.when(
      data: (devices) => StatusBadge(
        label: '${devices.length}',
        variant: BadgeVariant.primary,
      ),
      loading: () => const StatusBadge(
        label: '...',
        variant: BadgeVariant.neutral,
      ),
      error: (_, __) => const StatusBadge(
        label: '!',
        variant: BadgeVariant.error,
      ),
    );
  }

  Widget _buildDeviceList(
    AsyncValue<List<Device>> devicesAsync,
    bool isInitialized,
    Device? selectedDevice,
  ) {
    if (!isInitialized) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: AppSpacing.lg),
            Text(HomeScreenStrings.initializing),
          ],
        ),
      );
    }

    return devicesAsync.when(
      data: (devices) {
        // Filter to only show devices on the same subnet
        final localIps = ref.watch(localIpsProvider);
        final sameSubnetDevices = devices.where((device) {
          // Allow current device to always show
          if (device.id == ref.read(currentDeviceProvider).id) return true;
          // Check if device is on same subnet as any of our local IPs
          for (final localIp in localIps) {
            if (device.isOnSameSubnetAs(localIp)) {
              return true;
            }
          }
          return false;
        }).toList();

        if (sameSubnetDevices.isEmpty) {
          return RefreshIndicator(
            onRefresh: _refreshDevices,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final screenHeight = MediaQuery.of(context).size.height;
                final isSmallScreen = screenHeight < 600;
                final emptyStateHeight = isSmallScreen
                    ? (screenHeight * 0.6).clamp(300.0, 500.0)
                    : (screenHeight * 0.4).clamp(350.0, 600.0);

                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: emptyStateHeight,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PulseAnimation(
                            child: Icon(
                              Icons.radar,
                              size: 72,
                              color: AppTheme.primaryColor.withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxl),
                          Text(
                            'Scanning for devices...',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Make sure other devices are on the\nsame Wi-Fi network and have Syndro open.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: AppTheme.textTertiary,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.xxxl),
                          OutlinedButton.icon(
                            onPressed: _isRefreshing ? null : _refreshDevices,
                            icon: const Icon(Icons.refresh),
                            label: const Text(HomeScreenStrings.scanAgain),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: _refreshDevices,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            itemCount: sameSubnetDevices.length,
            itemBuilder: (context, index) {
              final device = sameSubnetDevices[index];
              final selectedDevices = ref.watch(selectedDevicesProvider);
              final isMultiSelectMode = selectedDevices.isNotEmpty;
              final isSelected = selectedDevices.any((d) => d.id == device.id) || 
                                 (!isMultiSelectMode && selectedDevice?.id == device.id);
              
              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: DeviceCard(
                  device: device,
                  isSelected: isSelected,
                  onTap: () {
                    if (isMultiSelectMode) {
                      // Multi-select mode: toggle device in selection
                      final currentSelection = Set<Device>.from(selectedDevices);
                      if (currentSelection.any((d) => d.id == device.id)) {
                        currentSelection.removeWhere((d) => d.id == device.id);
                      } else {
                        currentSelection.add(device);
                      }
                      ref.read(selectedDevicesProvider.notifier).state = currentSelection;
                      // Clear single selection when in multi-select mode
                      ref.read(selectedDeviceProvider.notifier).state = null;
                    } else {
                      // Single-select mode
                      ref.read(selectedDeviceProvider.notifier).state = device;
                    }
                  },
                  onLongPress: () {
                    // Enter multi-select mode on long press
                    if (!isMultiSelectMode) {
                      ref.read(selectedDevicesProvider.notifier).state = {device};
                      ref.read(selectedDeviceProvider.notifier).state = null;
                    }
                  },
                ),
              );
            },
          ),
        );
      },
      loading: () => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.devices,
              size: 64,
              color: AppTheme.textTertiary,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              HomeScreenStrings.scanningForDevices,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            const CircularProgressIndicator(),
          ],
        ),
      ),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: AppTheme.errorColor,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              HomeScreenStrings.errorDiscoveringDevices,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
              child: Text(
                error.toString(),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              onPressed: _refreshDevices,
              icon: const Icon(Icons.refresh),
              label: const Text(HomeScreenStrings.retry),
            ),
          ],
        ),
      ),
    );
  }
}

class _TransferRequestSheetContent extends StatelessWidget {
  final PendingTransferRequest request;
  final VoidCallback onAccept;
  final VoidCallback onReject;

  const _TransferRequestSheetContent({
    required this.request,
    required this.onAccept,
    required this.onReject,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: const BoxDecoration(
              color: AppTheme.borderColor,
              borderRadius: AppRadius.pillAll,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          const GradientIconTile(
            icon: Icons.file_download_rounded,
            size: 64,
            radius: AppRadius.lg,
          ),
          const SizedBox(height: AppSpacing.lg),
          Text(
            'Incoming Transfer',
            style: Theme.of(context).textTheme.headlineMedium,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            'From: ${request.senderName}',
            style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            '${request.fileCount} file(s) • ${_formatSize(request.totalSize)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textTertiary,
                ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: onReject,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.errorColor,
                    side: const BorderSide(color: AppTheme.errorColor),
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  ),
                  child: const Text('REJECT'),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: FilledButton(
                  onPressed: onAccept,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.successColor,
                    foregroundColor: Colors.white,
                    padding:
                        const EdgeInsets.symmetric(vertical: AppSpacing.lg),
                  ),
                  child: const Text('ACCEPT'),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.lg),
        ],
      ),
    );
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(1)} GB';
  }
}
