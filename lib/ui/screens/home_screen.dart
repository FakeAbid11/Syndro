import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:animations/animations.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/device_provider.dart';
import '../../core/providers/transfer_provider.dart';
import '../../core/services/transfer_service.dart';
import '../../core/services/background_transfer_service.dart';
import 'file_picker_screen.dart';
import 'browser_share_screen.dart';
import 'browser_receive_screen.dart';
import 'transfer_progress_screen.dart';
import 'home/home_mobile.dart';
import 'home/home_desktop.dart';
import 'home_screen_strings.dart';
import '../../core/utils/byte_formatter.dart';

import '../../core/utils/app_logger.dart';
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

  StreamSubscription<ReceivedTextMessage>? _receivedTextSubscription;

  // FIX (Bug #6): Store timer reference for cancellation on dispose
  Timer? _pendingRequestTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenForIncomingRequests();
    _listenForReceivedText();
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
      AppLogger.info('Error closing pending requests subscription: $e');
    }

    try {
      _receivedTextSubscription?.cancel();
      _receivedTextSubscription = null;
    } catch (e) {
      AppLogger.info('Error closing received text subscription: $e');
    }
    
    AppLogger.info('ðŸ§¹ HomeScreen disposed');
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
      AppLogger.warn('âš ï¸ Error creating pending requests subscription: $e');
    }
  }

  void _listenForReceivedText() {
    try {
      _receivedTextSubscription =
          ref.read(transferServiceProvider).receivedTextStream.listen((msg) {
        if (!mounted) return;
        _showReceivedTextSheet(msg);
      });
    } catch (e) {
      AppLogger.warn('âš ï¸ Error creating received text subscription: $e');
    }
  }

  /// PLATFORM: Android/iOS keep bottom sheets; Windows/Linux/macOS use
  /// centered dialogs — a drag-handle sheet doesn't suit mouse-driven windows.
  bool get _isMobilePlatform => Platform.isAndroid || Platform.isIOS;

  void _showReceivedTextSheet(ReceivedTextMessage message) {
    if (!mounted) return;

    if (_isMobilePlatform) {
      _showReceivedTextBottomSheet(message);
    } else {
      _showReceivedTextDialog(message);
    }
  }

  void _showReceivedTextBottomSheet(ReceivedTextMessage message) {
    if (!mounted) return;

    showModalBottomSheet(
      context: context,
      isDismissible: true,
      backgroundColor: Colors.transparent,
      builder: (bottomSheetContext) {
        return Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor,
            borderRadius:
                const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 4,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: AppTheme.borderColor,
                  borderRadius: AppRadius.pillAll,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              _buildReceivedTextContent(bottomSheetContext, message),
            ],
          ),
        );
      },
    );
  }

  /// Message body shared by the mobile bottom sheet and the desktop dialog.
  /// [overlayContext] is the sheet's or the dialog's own context: actions
  /// pop it and show snackbars through it.
  Widget _buildReceivedTextContent(
    BuildContext overlayContext,
    ReceivedTextMessage message,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const GradientIconTile(
              icon: Icons.chat_bubble_rounded,
              size: 48,
              radius: AppRadius.lg,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Message from ${message.senderName}',
                    style: Theme.of(overlayContext).textTheme.titleLarge,
                  ),
                  const SizedBox(height: AppSpacing.xs),
                  Text(
                    'Saved to Downloads/Syndro Notes',
                    style: Theme.of(overlayContext)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textTertiary),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.lg),
        Container(
          width: double.infinity,
          constraints: const BoxConstraints(maxHeight: 280),
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: AppTheme.surfaceContainerHigh,
            borderRadius: AppRadius.lgAll,
            border: Border.all(
              color: AppTheme.outlineVariant,
              width: 1,
            ),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              message.text,
              style: Theme.of(overlayContext).textTheme.bodyLarge,
            ),
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: message.text),
                  );
                  if (!overlayContext.mounted) return;
                  ScaffoldMessenger.of(overlayContext).showSnackBar(
                    const SnackBar(
                      content: Text('Copied to clipboard'),
                      backgroundColor: AppTheme.successColor,
                    ),
                  );
                },
                icon: const Icon(Icons.copy, size: 20),
                label: const Text('Copy'),
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: FilledButton.icon(
                onPressed: () {
                  Navigator.of(overlayContext).pop();
                  BackgroundTransferService.openFileLocation(
                    message.filePath,
                  );
                },
                icon: const Icon(Icons.folder_open, size: 20),
                label: const Text('Open file'),
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.md),
        SizedBox(
          width: double.infinity,
          child: TextButton(
            onPressed: () => Navigator.of(overlayContext).pop(),
            child: const Text('Close'),
          ),
        ),
        const SizedBox(height: AppSpacing.sm),
      ],
    );
  }

  /// WINDOWS/LINUX/MACOS: the received-text view in a centered dialog.
  void _showReceivedTextDialog(ReceivedTextMessage message) {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xxl),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: _buildReceivedTextContent(dialogContext, message),
          ),
        ),
      ),
    );
  }

  void _showTransferRequestSheet(PendingTransferRequest request) {
    // PLATFORM: Android keeps the non-dismissable bottom sheet; desktop
    // gets an equally modal centered dialog.
    if (_isMobilePlatform) {
      _showTransferRequestBottomSheet(request);
    } else {
      _showTransferRequestDialog(request);
    }
  }

  void _showTransferRequestBottomSheet(PendingTransferRequest request) {
    if (_isShowingRequestSheet || !mounted) return;
    setState(() => _isShowingRequestSheet = true);

    try {
      showModalBottomSheet(
        context: context,
        isDismissible: false,
        enableDrag: false,
        backgroundColor: Colors.transparent,
        builder: (bottomSheetContext) {
          return _TransferRequestSheetContent(
            request: request,
            onAccept: (bool trustSender) => _resolveTransferRequest(
                  bottomSheetContext,
                  request,
                  accepted: true,
                  trustSender: trustSender,
                ),
            onReject: () => _resolveTransferRequest(
                  bottomSheetContext,
                  request,
                  accepted: false,
                ),
          );
        },
      ).whenComplete(_scheduleNextPendingRequestCheck);
    } catch (e) {
      AppLogger.warn('âš ï¸ Error showing transfer request sheet: $e');
      // FIXED (Bug #4): Reset flag if sheet fails to show
      if (mounted) {
        setState(() => _isShowingRequestSheet = false);
      }
    }
  }

  /// WINDOWS/LINUX/MACOS: the same approval flow in a centered, equally
  /// non-dismissable dialog.
  void _showTransferRequestDialog(PendingTransferRequest request) {
    if (_isShowingRequestSheet || !mounted) return;
    setState(() => _isShowingRequestSheet = true);

    try {
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) {
          return _TransferRequestSheetContent(
            request: request,
            onAccept: (bool trustSender) => _resolveTransferRequest(
                  dialogContext,
                  request,
                  accepted: true,
                  trustSender: trustSender,
                ),
            onReject: () => _resolveTransferRequest(
                  dialogContext,
                  request,
                  accepted: false,
                ),
          );
        },
      ).whenComplete(_scheduleNextPendingRequestCheck);
    } catch (e) {
      AppLogger.warn('Error showing transfer request dialog: $e');
      if (mounted) {
        setState(() => _isShowingRequestSheet = false);
      }
    }
  }

  /// Pops [routeContext] (the sheet or the dialog) and applies the user's
  /// decision. Shared by both presentations; preserves the original
  /// per-branch behavior (accept failures surface a snackbar, reject
  /// failures only log).
  Future<void> _resolveTransferRequest(
    BuildContext routeContext,
    PendingTransferRequest request, {
    required bool accepted,
    bool trustSender = false,
  }) async {
    final scaffoldMessenger = ScaffoldMessenger.of(context);
    if (!mounted) return;
    Navigator.of(routeContext).pop();
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;

    try {
      final transferService = ref.read(transferServiceProvider);
      if (accepted) {
        await transferService.approveTransfer(
          request.requestId,
          trustSender: trustSender,
        );

        if (!mounted) return;
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text(HomeScreenStrings.transferAccepted),
            backgroundColor: AppTheme.successColor,
          ),
        );
      } else {
        transferService.rejectTransfer(request.requestId);

        if (!mounted) return;
        scaffoldMessenger.showSnackBar(
          const SnackBar(
            content: Text(HomeScreenStrings.transferRejected),
            backgroundColor: AppTheme.warningColor,
          ),
        );
      }
    } catch (e) {
      if (accepted) {
        AppLogger.info('Error accepting transfer: $e');
        if (!mounted) return;
        scaffoldMessenger.showSnackBar(
          SnackBar(
            content: Text(HomeScreenStrings.failedToAccept(e.toString())),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      } else {
        AppLogger.info('Error rejecting transfer: $e');
      }
    }
  }

  /// Common tail of both presentations: reset the guard and re-show the next
  /// pending request after a beat. FIX (Bug #6): timer stored for disposal;
  /// the pending list is re-read INSIDE the timer because the snapshot taken
  /// at dismissal time may still contain the request just handled.
  void _scheduleNextPendingRequestCheck() {
    if (!mounted) return;
    setState(() => _isShowingRequestSheet = false);

    try {
      if (!mounted) return;
      _pendingRequestTimer?.cancel();
      _pendingRequestTimer = Timer(const Duration(milliseconds: 300), () {
        if (!mounted || _isShowingRequestSheet) return;
        final pendingRequests =
            ref.read(transferServiceProvider).pendingRequests;
        if (pendingRequests.isNotEmpty) {
          _showTransferRequestSheet(pendingRequests.first);
        }
      });
    } catch (e) {
      AppLogger.info('Error checking pending requests: $e');
    }
  }

  Future<void> _refreshDevices() async {
    if (_isRefreshing || !mounted) return;
    setState(() => _isRefreshing = true);

    try {
      final service = ref.read(deviceDiscoveryServiceProvider);
      await service.refreshDevices();
    } catch (e) {
      AppLogger.info('Refresh error: $e');
    } finally {
      if (mounted) {
        setState(() => _isRefreshing = false);
      }
    }
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(height: AppSpacing.xl),
                Text(
                  'Preparing files...',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
const SizedBox(height: AppSpacing.sm),
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
        AppLogger.info('Error dismissing dialog: $e');
      }
    }
  }

  void _showShareModeDialog() {
    // PLATFORM: Android keeps the bottom sheet; desktop gets a centered
    // dialog.
    if (_isMobilePlatform) {
      _showShareModeBottomSheet();
    } else {
      _showShareModeCenteredDialog();
    }
  }

  /// ANDROID: drag-handle bottom sheet with the three share options.
  void _showShareModeBottomSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        decoration: BoxDecoration(
          color: AppTheme.surfaceColor,
          borderRadius:
              const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
        padding: EdgeInsets.only(
          left: AppSpacing.xxl,
          right: AppSpacing.xxl,
          top: AppSpacing.xxl,
          bottom: AppSpacing.xxl + MediaQuery.of(sheetContext).padding.bottom,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.borderColor,
                  borderRadius: AppRadius.pillAll,
                ),
              ),
              const SizedBox(height: AppSpacing.xxl),
              _buildShareModeContent(sheetContext),
            ],
          ),
        ),
      ),
    );
  }

  /// WINDOWS/LINUX/MACOS: the same options in a centered dialog.
  void _showShareModeCenteredDialog() {
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.xxl),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 460),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(AppSpacing.xxl),
            child: _buildShareModeContent(dialogContext),
          ),
        ),
      ),
    );
  }

  /// Header + three options, shared by the mobile sheet and the desktop
  /// dialog. Pops [routeContext] (whichever presentation is showing) before
  /// acting.
  Widget _buildShareModeContent(BuildContext routeContext) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Browser Share',
          style: Theme.of(routeContext).textTheme.titleLarge,
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Share files without installing an app',
          style: Theme.of(routeContext).textTheme.bodySmall?.copyWith(
                color: AppTheme.textTertiary,
              ),
        ),
        const SizedBox(height: AppSpacing.sm),
        Text(
          'Connect to the same WiFi network or create a Hotspot',
          style: Theme.of(routeContext).textTheme.bodySmall?.copyWith(
                color: AppTheme.warningColor,
              ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        _buildShareOption(
          context: routeContext,
          icon: Icons.photo_library,
          title: 'Share Media',
          subtitle: 'Photos and videos from gallery',
          color: AppTheme.secondaryColor,
          onTap: () {
            Navigator.pop(routeContext);
            _pickAndShareMedia();
          },
        ),
        const SizedBox(height: AppSpacing.md),
        _buildShareOption(
          context: routeContext,
          icon: Icons.upload_file,
          title: 'Send Files',
          subtitle: 'Share files via browser link',
          color: AppTheme.primaryColor,
          onTap: () {
            Navigator.pop(routeContext);
            _pickAndShareFiles();
          },
        ),
        const SizedBox(height: AppSpacing.md),
        _buildShareOption(
          context: routeContext,
          icon: Icons.download,
          title: 'Receive Files',
          subtitle: 'Get files from any device',
          color: AppTheme.accentColor,
          onTap: () {
            Navigator.pop(routeContext);
            _openReceiveScreen();
          },
        ),
        const SizedBox(height: AppSpacing.lg),
      ],
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
              Icon(
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
        AppLogger.info('Error processing media files: $e');
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
        AppLogger.info('Error processing files: $e');
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
              child: Row(
                children: [
                  Icon(Icons.lightbulb_outline,
                      color: AppTheme.onPrimaryContainer, size: 20),
const SizedBox(width: AppSpacing.sm),
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

Future<void> _showTextComposeDialog(Device device) async {
    if (!mounted) return;
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();

    final text = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.xlAll,
        ),
        title: Text('Send to ${device.name}'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            maxLines: 6,
            minLines: 3,
            maxLength: 64000,
            decoration: const InputDecoration(
              hintText: 'Type a message, note or link...',
              border: OutlineInputBorder(),
            ),
            validator: (value) {
              if (value == null || value.trim().isEmpty) {
                return 'Message cannot be empty';
              }
              return null;
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text.trim());
              }
            },
            child: const Text('Send'),
          ),
        ],
      ),
    );

    if (text == null || text.isEmpty || !mounted) return;
    await _sendTextMessage(device, text);
  }

  Future<void> _sendTextMessage(Device device, String text) async {
    if (!mounted) return;
    final transferService = ref.read(transferServiceProvider);

    // Pre-compute the transfer id so the progress screen can attach to the
    // transfer immediately; sendText publishes it synchronously afterwards.
    final transferId =
        'text-${DateTime.now().microsecondsSinceEpoch}-${device.id}';

    try {
      final sendFuture = transferService.sendText(
        device,
        text,
        transferId: transferId,
      );
      if (!mounted) return;

      Navigator.of(context).push(
        PageRouteBuilder(
          pageBuilder: (context, animation, secondaryAnimation) =>
              TransferProgressScreen(
            transferId: transferId,
            remoteDevice: device,
            isSender: true,
            items: const [
              TransferItem(
                name: 'Message',
                path: '',
                size: 0,
              ),
            ],
          ),
          transitionsBuilder:
              (context, animation, secondaryAnimation, child) {
            return FadeThroughTransition(
              animation: animation,
              secondaryAnimation: secondaryAnimation,
              child: child,
            );
          },
          transitionDuration: AppMotion.slow,
        ),
      );

      await sendFuture;
    } catch (e) {
      AppLogger.info('Error sending text: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Message failed: $e'),
          backgroundColor: AppTheme.errorColor,
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

  @override
  Widget build(BuildContext context) {
    final currentDevice = ref.watch(currentDeviceProvider);
    final discoveredDevicesAsync = ref.watch(discoveredDevicesProvider);
    final selectedDevice = ref.watch(selectedDeviceProvider);
    final isInitialized = ref.watch(isDeviceServiceInitializedProvider);
    final selectedDevices = ref.watch(selectedDevicesProvider);

    // PLATFORM: Android always renders the mobile layout; Windows/Linux/
    // macOS always render the desktop layout. Each family evolves in its
    // own file (home/home_mobile.dart, home/home_desktop.dart); shared
    // logic lives in this facade, shared views in home_device_views.dart.
    if (Platform.isAndroid || Platform.isIOS) {
      return HomeMobileLayout(
        currentDevice: currentDevice,
        discoveredDevicesAsync: discoveredDevicesAsync,
        selectedDevice: selectedDevice,
        isInitialized: isInitialized,
        isRefreshing: _isRefreshing,
        selectedDevices: selectedDevices,
        onRefresh: _refreshDevices,
        onOpenShareDialog: _showShareModeDialog,
        onTextCompose: _showTextComposeDialog,
        onSendFiles: _openFilePickerForDevice,
        onSendToMultiple: _openFilePickerForDevices,
        onClearMultiSelect: _clearMultiSelect,
      );
    }
    return HomeDesktopLayout(
      currentDevice: currentDevice,
      discoveredDevicesAsync: discoveredDevicesAsync,
      selectedDevice: selectedDevice,
      isInitialized: isInitialized,
      isRefreshing: _isRefreshing,
      selectedDevices: selectedDevices,
      onRefresh: _refreshDevices,
      onOpenShareDialog: _showShareModeDialog,
      onSendText: _sendTextToSelected,
      onOpenPicker: _openDesktopPicker,
      onSendFilesTo: _openFilePickerForDevice,
      onFilesDropped: _handleDesktopFilesDropped,
      onSendToMultiple: _openFilePickerForDevices,
      onClearMultiSelect: _clearMultiSelect,
    );
  }

  /// ANDROID: open the picker for a single selected device.
  void _openFilePickerForDevice(Device device) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => FilePickerScreen(recipientDevice: device),
      ),
    );
  }

  /// ANDROID (multi-select): open the picker for several devices at once.
  void _openFilePickerForDevices(List<Device> devices) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => FilePickerScreen(recipientDevices: devices),
      ),
    );
  }

  void _clearMultiSelect() {
    ref.read(selectedDevicesProvider.notifier).state = {};
  }

  /// WINDOWS: compose text to the selected device (validates selection).
  void _sendTextToSelected() {
    final selected = ref.read(selectedDeviceProvider);
    if (selected == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device first to send text')),
      );
      return;
    }
    _showTextComposeDialog(selected);
  }

  /// Opens the file picker for the current desktop selection.
  void _openDesktopPicker() {
    final selectedDevices = ref.read(selectedDevicesProvider);
    final selectedDevice = ref.read(selectedDeviceProvider);
    if (selectedDevice == null && selectedDevices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Select a device on the left first')),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => FilePickerScreen(
          recipientDevice: selectedDevice,
          recipientDevices:
              selectedDevices.isNotEmpty ? selectedDevices.toList() : null,
        ),
      ),
    );
  }

  /// Handles files/folders dropped onto the desktop send pane.
  void _handleDesktopFilesDropped(List<TransferItem> items) {
    if (items.isEmpty) return;
    final selectedDevices = ref.read(selectedDevicesProvider);
    final selectedDevice = ref.read(selectedDeviceProvider);
    if (selectedDevice == null && selectedDevices.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Select a device first, then drop files to send'),
          backgroundColor: AppTheme.warningColor,
        ),
      );
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (routeContext) => FilePickerScreen(
          recipientDevice: selectedDevice,
          recipientDevices:
              selectedDevices.isNotEmpty ? selectedDevices.toList() : null,
          preselectedFiles: items,
        ),
      ),
    );
  }
}

class _TransferRequestSheetContent extends StatefulWidget {
  final PendingTransferRequest request;
  final ValueChanged<bool> onAccept;
  final VoidCallback onReject;

  const _TransferRequestSheetContent({
    required this.request,
    required this.onAccept,
    required this.onReject,
  });

  @override
  State<_TransferRequestSheetContent> createState() =>
      _TransferRequestSheetContentState();
}

class _TransferRequestSheetContentState
    extends State<_TransferRequestSheetContent> {
  bool _trustSender = false;

  @override
  Widget build(BuildContext context) {
    final request = widget.request;
    return Container(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius:
            const BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
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
            request.isText ? 'Incoming Message' : 'Incoming Transfer',
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
          if (request.isText)
            Text(
              '1 message',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
            )
          else
            Text(
              '${request.fileCount} file(s) â€¢ ${_formatSize(request.totalSize)}',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
            ),
          if (request.isText) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(AppSpacing.lg),
              decoration: BoxDecoration(
                color: AppTheme.surfaceContainerHigh,
                borderRadius: AppRadius.lgAll,
                border: Border.all(color: AppTheme.outlineVariant, width: 1),
              ),
              child: Text(
                request.textContent!,
                maxLines: 6,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.lg),
          if (request.isTrusted)
            _TrustedDeviceBadge()
          else
            CheckboxListTile(
              value: _trustSender,
              onChanged: (value) =>
                  setState(() => _trustSender = value ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              activeColor: AppTheme.primaryColor,
              checkColor: Colors.white,
              side: BorderSide(color: AppTheme.borderColor),
              title: Text(
                'Trust this device',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              subtitle: Text(
                'Future transfers from this device will auto-accept',
                style: TextStyle(
                  color: AppTheme.textTertiary,
                  fontSize: 12,
                ),
              ),
            ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: widget.onReject,
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
                  onPressed: () => widget.onAccept(_trustSender),
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

class _TrustedDeviceBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        const Icon(
          Icons.verified_user_rounded,
          size: 16,
          color: AppTheme.successColor,
        ),
        const SizedBox(width: AppSpacing.xs),
        Text(
          'Trusted device â€” transfers auto-accept',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: AppTheme.successColor,
                fontWeight: FontWeight.w500,
              ),
        ),
      ],
    );
  }
}
