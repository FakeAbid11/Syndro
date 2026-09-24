import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/transfer_provider.dart';
import '../../core/services/background_transfer_service.dart';
import '../../core/utils/byte_formatter.dart';

import '../../core/utils/app_logger.dart';
class TransferProgressScreen extends ConsumerStatefulWidget {
  final String transferId;
  final Device? remoteDevice;
  final bool isSender;
  final List<TransferItem> items;

  const TransferProgressScreen({
    super.key,
    required this.transferId,
    this.remoteDevice,
    required this.isSender,
    required this.items,
  });

  @override
  ConsumerState<TransferProgressScreen> createState() =>
      _TransferProgressScreenState();
}

class _TransferProgressScreenState extends ConsumerState<TransferProgressScreen> {
  StreamSubscription<Transfer>? _transferSubscription;
  Transfer? _currentTransfer;
  int _currentFileIndex = 0;
  int _lastBytes = 0;
  double _speed = 0;
  Timer? _speedTimer;
  DateTime? _transferStartTime;
  static const int _calculatingDurationSeconds = 2;

  @override
  void initState() {
    super.initState();

    // Record transfer start time for speed calculation
    _transferStartTime = DateTime.now();

    _listenToTransfer();

    _speedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _calculateSpeed();
    });
  }

  void _listenToTransfer() {
    final transferService = ref.read(transferServiceProvider);

    _transferSubscription = transferService.transferStream.listen((transfer) {
      if (transfer.id == widget.transferId && mounted) {
        setState(() {
          _currentTransfer = transfer;

          int totalSize = 0;
          for (int i = 0; i < widget.items.length; i++) {
            totalSize += widget.items[i].size;
            if (transfer.progress.bytesTransferred < totalSize) {
              _currentFileIndex = i;
              break;
            }
            if (i == widget.items.length - 1) {
              _currentFileIndex = i;
            }
          }
        });

        if (transfer.status == TransferStatus.completed) {
          _onTransferComplete();
        }
      }
    });
  }

  // FIXED (Bug #6): Prevent speed overflow by clamping to safe int range  
  void _calculateSpeed() {
    if (_currentTransfer == null || !mounted) return;

    final currentBytes = _currentTransfer!.progress.bytesTransferred;
    final bytesPerSecond = (currentBytes - _lastBytes).clamp(0, double.maxFinite);
    _lastBytes = currentBytes;

    if (mounted) {
      setState(() {
        // FIXED: Clamp speed to prevent overflow (max ~2GB/s which is realistic)
        _speed = bytesPerSecond.toDouble().clamp(0, 2147483647);
      });
    }
  }

  void _onTransferComplete() {
    _speedTimer?.cancel();
    // Show completion message
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            widget.items.length == 1
                ? 'Transfer complete: ${widget.items.first.name}'
                : 'Transfer complete: ${widget.items.length} files',
          ),
          backgroundColor: AppTheme.successColor,
          duration: const Duration(seconds: 3),
        ),
      );
    }
    
    // FIXED (Bug #7): Enhanced auto-pop with dual mounted checks
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && context.mounted) {
        Navigator.of(context).pop(true);
      }
    });
  }

  void _cancelTransfer() {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppTheme.surfaceColor,
        title: const Text('Cancel transfer?'),
        content: const Text(
            'The file transfer is in progress. Cancelling will discard any progress.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Keep transferring'),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              final transferService = ref.read(transferServiceProvider);
              transferService.cancelTransfer(widget.transferId);
              Navigator.of(context).pop(false);
            },
            style: TextButton.styleFrom(foregroundColor: AppTheme.errorColor),
            child: const Text('Cancel transfer'),
          ),
        ],
      ),
    );
  }

  // FIXED (Bug #3, #5, #6): Ensure all resources are properly disposed with try-catch
  @override
  void dispose() {
    // FIXED (Bug #5): Stop animation BEFORE disposing
    try {
      _transferSubscription?.cancel();
      _transferSubscription = null;
    } catch (e) {
      AppLogger.info('Error cancelling transfer subscription: $e');
    }
    
    try {
      _speedTimer?.cancel();
      _speedTimer = null;
    } catch (e) {
      AppLogger.info('Error cancelling speed timer: $e');
    }
    
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // FIX (Bug #17): Improved PopScope with proper state handling
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        
        final status = _currentTransfer?.status;
        
        // Allow immediate pop for completed/failed/cancelled transfers
        if (status == TransferStatus.completed ||
            status == TransferStatus.failed ||
            status == TransferStatus.cancelled) {
          if (context.mounted) {
            Navigator.of(context).pop();
          }
          return;
        }
        
        // For active transfers, show confirmation dialog
        if (status == TransferStatus.transferring ||
            status == TransferStatus.connecting ||
            status == TransferStatus.pending ||
            status == TransferStatus.paused) {
          final shouldCancel = await showDialog<bool>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              backgroundColor: AppTheme.surfaceColor,
              shape: const RoundedRectangleBorder(
                borderRadius: AppRadius.xlAll,
              ),
              title: const Text('Cancel Transfer?'),
              content: const Text(
                  'The transfer is still in progress. Going back will cancel it. Are you sure?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.primaryColor,
                  ),
                  child: const Text('Keep Transferring'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, true),
                  style: TextButton.styleFrom(
                    foregroundColor: AppTheme.errorColor,
                  ),
                  child: const Text('Cancel Transfer'),
                ),
              ],
            ),
          );
          
          if (shouldCancel == true && context.mounted) {
            final transferService = ref.read(transferServiceProvider);
            transferService.cancelTransfer(widget.transferId);
            Navigator.of(context).pop(false);
          }
        }
      },
      child: Scaffold(
        backgroundColor: AppTheme.backgroundColor,
        appBar: AppBar(
          title: Text(widget.isSender ? 'Sending Files' : 'Receiving Files'),
          backgroundColor: AppTheme.backgroundColor,
          // PopScope handles back navigation; leading triggers same path
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).maybePop(),
            tooltip: 'Close',
          ),
        ),
        body: SafeArea(
          child: ResponsiveCenter(
            maxWidth: 720,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: Column(
                children: [
                  _buildDeviceCard(),
                  const SizedBox(height: AppSpacing.lg),
                  Expanded(child: _buildProgressSection()),
                  _buildActionButton(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDeviceCard() {
    final accent =
        widget.isSender ? AppTheme.primaryColor : AppTheme.successColor;
    return AppCard(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      child: Row(
        children: [
          Container(
            width: 34,
            height: 34,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.12),
              borderRadius: AppRadius.smAll,
            ),
            child: Icon(
              widget.isSender ? Icons.upload_rounded : Icons.download_rounded,
              size: 18,
              color: accent,
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.isSender ? 'Sending to' : 'Receiving from',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                Text(
                  widget.remoteDevice?.name ?? 'Unknown Device',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: AppSpacing.sm),
          _buildStatusBadge(),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    final status = _currentTransfer?.status ?? TransferStatus.connecting;

    BadgeVariant variant;
    String text;

    switch (status) {
      case TransferStatus.connecting:
        variant = BadgeVariant.warning;
        text = 'Connecting';
        break;
      case TransferStatus.pending:
        variant = BadgeVariant.warning;
        text = 'Waiting';
        break;
      case TransferStatus.transferring:
        variant = BadgeVariant.primary;
        text = 'Transferring';
        break;
      case TransferStatus.paused:
        variant = BadgeVariant.warning;
        text = 'Paused';
        break;
      case TransferStatus.completed:
        variant = BadgeVariant.success;
        text = 'Completed';
        break;
      case TransferStatus.failed:
        variant = BadgeVariant.error;
        text = 'Failed';
        break;
      case TransferStatus.cancelled:
        variant = BadgeVariant.neutral;
        text = 'Cancelled';
        break;
    }

    return StatusBadge(label: text, variant: variant);
  }

  Widget _buildProgressSection() {
    final status = _currentTransfer?.status ?? TransferStatus.connecting;

    switch (status) {
      case TransferStatus.connecting:
      case TransferStatus.pending:
        return _buildWaitingState();
      case TransferStatus.transferring:
        return _buildTransferringState();
      case TransferStatus.paused:
        return _buildPausedState();
      case TransferStatus.completed:
        return _buildCompletedState();
      case TransferStatus.failed:
        return _buildFailedState();
      case TransferStatus.cancelled:
        return _buildCancelledState();
    }
  }

  Widget _buildWaitingState() {
    return _StatusColumn(
      children: [
        // A static disc. This used to breathe on a 1500ms loop until a 30s
        // timer stopped it, which is the opposite of what a screen the user is
        // waiting on should do.
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.primaryColor.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(
            widget.isSender ? Icons.upload_rounded : Icons.download_rounded,
            size: 64,
            color: AppTheme.primaryColor,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          _currentTransfer?.status == TransferStatus.pending
              ? 'Waiting for approval...'
              : 'Connecting...',
          style: Theme.of(context).textTheme.headlineMedium,
        ),
        const SizedBox(height: AppSpacing.xxxl),
        const CircularProgressIndicator(),
      ],
    );
  }

  Widget _buildTransferringState() {
    final progress = _currentTransfer?.progress;
    final percentage = progress?.percentage ?? 0;
    final bytesTransferred = progress?.bytesTransferred ?? 0;
    final totalBytes = progress?.totalBytes ?? 1;

    final currentFile = widget.items.isNotEmpty
        ? (_currentFileIndex < widget.items.length
            ? widget.items[_currentFileIndex]
            : widget.items.last)
        : const TransferItem(
            name: 'File',
            path: '',
            size: 0,
          );

    return Column(
      children: [
        // One compact card: what is moving, how far it has got, and the three
        // numbers that matter. This used to be a file card plus two stat cards
        // plus a list, which read as a dashboard rather than a progress bar.
        AppCard(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: AppTheme.primaryColor.withValues(alpha: 0.12),
                      borderRadius: AppRadius.smAll,
                    ),
                    child: Icon(
                      _getFileIcon(currentFile.name),
                      size: 18,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          currentFile.name,
                          style: Theme.of(context).textTheme.titleSmall?.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Text(
                          'File ${_currentFileIndex + 1} of ${widget.items.length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Text(
                    '${percentage.toStringAsFixed(0)}%',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.md),
              ClipRRect(
                borderRadius: AppRadius.smAll,
                child: LinearProgressIndicator(
                  value: percentage / 100,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Wrap(
                spacing: AppSpacing.xl,
                runSpacing: AppSpacing.xs,
                children: [
                  _StatChip(
                    icon: Icons.swap_vert,
                    label: '${ByteFormatter.format(bytesTransferred)} / '
                        '${ByteFormatter.format(totalBytes)}',
                  ),
                  // Both report honestly: speed shows "Calculating…" until the
                  // sample window fills, and the estimate is "--:--" while the
                  // speed is still zero.
                  _StatChip(
                    icon: Icons.speed,
                    label: _getSpeedDisplay(),
                  ),
                  _StatChip(
                    icon: Icons.timer_outlined,
                    label: _calculateRemainingTime(),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.lg),
        Expanded(child: _buildFileList()),
      ],
    );
  }

  Widget _buildFileList() {
    return AppCard(
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: widget.items.length,
        separatorBuilder: (_, __) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final item = widget.items[index];
          final isCompleted = index < _currentFileIndex;
          final isCurrent = index == _currentFileIndex;

          final Color tileColor = isCompleted
              ? AppTheme.successColor.withValues(alpha: 0.2)
              : isCurrent
                  ? AppTheme.primaryColor.withValues(alpha: 0.2)
                  : AppTheme.surfaceContainerHigh;
          final Color iconColor = isCompleted
              ? AppTheme.successColor
              : isCurrent
                  ? AppTheme.primaryColor
                  : AppTheme.textTertiary;

          return ListTile(
            contentPadding:
                const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
            leading: Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: tileColor,
                borderRadius: AppRadius.smAll,
              ),
              child: Icon(
                isCompleted ? Icons.check_circle : _getFileIcon(item.name),
                color: iconColor,
                size: 20,
              ),
            ),
            title: Text(
              item.name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: isCompleted || isCurrent
                        ? AppTheme.textPrimary
                        : AppTheme.textTertiary,
                  ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            trailing: Text(
              item.sizeFormatted,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          );
        },
      ),
    );
  }

  Widget _buildPausedState() {
    _speed = 0;
    _lastBytes = _currentTransfer?.progress.bytesTransferred ?? 0;
    return _StatusColumn(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.warningColor.withValues(alpha: 0.15),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.pause_circle_outline,
            size: 80,
            color: AppTheme.warningColor,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          'Transfer Paused',
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          'The transfer will resume where it left off.',
          style: Theme.of(context).textTheme.bodyLarge,
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: AppSpacing.xxl),
        SizedBox(
          width: 120,
          child: LinearProgressIndicator(
            minHeight: 8,
            backgroundColor: AppTheme.outlineVariant,
          ),
        ),
      ],
    );
  }

  void _pauseTransfer() {
    ref.read(transferServiceProvider).pauseTransfer(widget.transferId);
  }

  void _resumeTransfer() {
    ref.read(transferServiceProvider).resumeTransfer(widget.transferId);
  }

  Widget _buildCompletedState() {
    return _StatusColumn(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.successColor.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.check_circle,
            size: 80,
            color: AppTheme.successColor,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          'Transfer Complete!',
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          '${widget.items.length} file${widget.items.length == 1 ? '' : 's'} ${widget.isSender ? 'sent' : 'received'} successfully',
          style: Theme.of(context).textTheme.bodyLarge,
        ),
        if (!widget.isSender && widget.items.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.xl),
          OutlinedButton.icon(
            onPressed: () {
              final filePath = widget.items.first.path;
              if (filePath.isNotEmpty) {
                BackgroundTransferService.openFileLocation(filePath);
              }
            },
            icon: const Icon(Icons.folder_open, size: 20),
            label: const Text('Open in Folder'),
          ),
        ],
      ],
    );
  }

  Widget _buildFailedState() {
    return _StatusColumn(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.errorColor.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.error_outline,
            size: 80,
            color: AppTheme.errorColor,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          'Transfer Failed',
          style: Theme.of(context).textTheme.displaySmall,
        ),
        const SizedBox(height: AppSpacing.md),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
          child: Text(
            _currentTransfer?.errorMessage ?? 'An unknown error occurred',
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: AppSpacing.xl),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).pop('retry'),
          icon: const Icon(Icons.refresh, size: 20),
          label: const Text('Retry'),
        ),
      ],
    );
  }

  Widget _buildCancelledState() {
    return _StatusColumn(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.textTertiary.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: Icon(
            Icons.cancel_outlined,
            size: 80,
            color: AppTheme.textTertiary,
          ),
        ),
        const SizedBox(height: AppSpacing.xxxl),
        Text(
          'Transfer Cancelled',
          style: Theme.of(context).textTheme.displaySmall,
        ),
      ],
    );
  }

  Widget _buildActionButton() {
    final status = _currentTransfer?.status ?? TransferStatus.connecting;
    final isParallel = _currentTransfer?.isParallel ?? false;

    if (status == TransferStatus.completed) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.successColor,
          ),
          child: const Text('Done'),
        ),
      );
    }

    if (status == TransferStatus.failed ||
        status == TransferStatus.cancelled) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.tonal(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Close'),
        ),
      );
    }

    // Pause/Resume only applies to sequential transfers; the parallel
    // pipeline has no checkpoint support, so the control is hidden there.
    if (status == TransferStatus.transferring && !isParallel) {
      return Row(
        children: [
          Expanded(
            child: FilledButton.tonalIcon(
              onPressed: _pauseTransfer,
              icon: const Icon(Icons.pause, size: 20),
              label: const Text('Pause'),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: OutlinedButton(
              onPressed: _cancelTransfer,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                side: const BorderSide(color: AppTheme.errorColor),
              ),
              child: const Text('Cancel Transfer'),
            ),
          ),
        ],
      );
    }

    if (status == TransferStatus.paused) {
      return Row(
        children: [
          Expanded(
            child: FilledButton.icon(
              onPressed: _resumeTransfer,
              icon: const Icon(Icons.play_arrow, size: 20),
              label: const Text('Resume'),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: OutlinedButton(
              onPressed: _cancelTransfer,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.errorColor,
                side: const BorderSide(color: AppTheme.errorColor),
              ),
              child: const Text('Cancel Transfer'),
            ),
          ),
        ],
      );
    }

    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        onPressed: _cancelTransfer,
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.errorColor,
          side: const BorderSide(color: AppTheme.errorColor),
        ),
        child: const Text('Cancel Transfer'),
      ),
    );
  }

  String _calculateRemainingTime() {
    if (_speed <= 0) return '--:--';

    final progress = _currentTransfer?.progress;
    if (progress == null) return '--:--';

    final remainingBytes = progress.totalBytes - progress.bytesTransferred;
    final seconds = remainingBytes / _speed;

    if (seconds.isInfinite || seconds.isNaN) return '--:--';

    final duration = Duration(seconds: seconds.toInt());

    if (duration.inHours > 0) {
      return '${duration.inHours}h ${duration.inMinutes.remainder(60)}m';
    } else if (duration.inMinutes > 0) {
      return '${duration.inMinutes}m ${duration.inSeconds.remainder(60)}s';
    } else {
      return '${duration.inSeconds}s';
    }
  }

  IconData _getFileIcon(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();

    const imageExts = ['jpg', 'jpeg', 'png', 'gif', 'webp', 'bmp'];
    const videoExts = ['mp4', 'mov', 'avi', 'mkv', 'webm'];
    const audioExts = ['mp3', 'wav', 'flac', 'aac', 'ogg'];
    const docExts = ['pdf', 'doc', 'docx', 'txt', 'rtf'];
    const archiveExts = ['zip', 'rar', '7z', 'tar', 'gz'];

    if (imageExts.contains(ext)) return Icons.image;
    if (videoExts.contains(ext)) return Icons.video_file;
    if (audioExts.contains(ext)) return Icons.audio_file;
    if (docExts.contains(ext)) return Icons.description;
    if (archiveExts.contains(ext)) return Icons.folder_zip;

    return Icons.insert_drive_file;
  }

  /// Get the speed display text, showing "Calculating..." for the first 2 seconds
  String _getSpeedDisplay() {
    if (_transferStartTime == null) {
      return 'Calculating...';
    }
    final elapsed = DateTime.now().difference(_transferStartTime!);
    if (elapsed.inSeconds < _calculatingDurationSeconds) {
      return 'Calculating...';
    }
    return '${ByteFormatter.format(_speed.toInt())}/s';
  }
}

/// One figure on the progress line: an icon, a value.
///
/// The icon is not decoration — the three figures are bytes, rate and estimate,
/// and without a marker each is guessable from its shape alone.
class _StatChip extends StatelessWidget {
  const _StatChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: AppTheme.textTertiary),
        const SizedBox(width: AppSpacing.sm - 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}

/// A status message that stays readable in a window that is shorter than it.
///
/// Centres itself when the viewport has room, and gains a scroll axis when it
/// does not. The plain `Column(mainAxisAlignment: center)` these states used to
/// return overflowed by ~50px on a 915x412 landscape window.
class _StatusColumn extends StatelessWidget {
  const _StatusColumn({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: children,
            ),
          ),
        );
      },
    );
  }
}
