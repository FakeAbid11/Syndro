import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/transfer_provider.dart';

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

class _TransferProgressScreenState extends ConsumerState<TransferProgressScreen>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
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

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);

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
      if (_pulseController.isAnimating) {
        _pulseController.stop();
      }
      _pulseController.dispose();
    } catch (e) {
      debugPrint('Error disposing pulse controller: $e');
    }
    
    try {
      _transferSubscription?.cancel();
      _transferSubscription = null;
    } catch (e) {
      debugPrint('Error cancelling transfer subscription: $e');
    }
    
    try {
      _speedTimer?.cancel();
      _speedTimer = null;
    } catch (e) {
      debugPrint('Error cancelling speed timer: $e');
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
            status == TransferStatus.pending) {
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
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () async {
              final status = _currentTransfer?.status;
              
              if (status == TransferStatus.completed ||
                  status == TransferStatus.failed ||
                  status == TransferStatus.cancelled) {
                Navigator.of(context).pop();
              } else {
                // Show confirmation for active transfers
                final shouldCancel = await showDialog<bool>(
                  context: context,
                  builder: (dialogContext) => AlertDialog(
                    backgroundColor: AppTheme.surfaceColor,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
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
          ),
        ),
        body: Container(
          // FIX: Removed const - AppTheme.backgroundGradient is not a compile-time constant
          decoration: BoxDecoration(
            gradient: AppTheme.backgroundGradient,
          ),
          child: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              child: Column(
                children: [
                  _buildDeviceCard(),
                  const SizedBox(height: AppSpacing.xxxl),
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
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Row(
        children: [
          GradientIconTile(
            icon:
                widget.isSender ? Icons.upload_rounded : Icons.download_rounded,
            size: 56,
            radius: AppRadius.lg,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [accent, accent.withValues(alpha: 0.7)],
            ),
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.isSender ? 'Sending to' : 'Receiving from',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  widget.remoteDevice?.name ?? 'Unknown Device',
                  style: Theme.of(context).textTheme.titleLarge,
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
      case TransferStatus.completed:
        return _buildCompletedState();
      case TransferStatus.failed:
        return _buildFailedState();
      case TransferStatus.cancelled:
        return _buildCancelledState();
    }
  }

  Widget _buildWaitingState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        AnimatedBuilder(
          animation: _pulseController,
          builder: (context, child) {
            return Container(
              padding: const EdgeInsets.all(AppSpacing.xxl),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor
                    .withValues(alpha: 0.1 + _pulseController.value * 0.1),
                shape: BoxShape.circle,
              ),
              child: Icon(
                widget.isSender ? Icons.upload_rounded : Icons.download_rounded,
                size: 64,
                color: AppTheme.primaryColor,
              ),
            );
          },
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

    final currentFile = _currentFileIndex < widget.items.length
        ? widget.items[_currentFileIndex]
        : widget.items.last;

    return Column(
      children: [
        AppCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  GradientIconTile(
                    icon: _getFileIcon(currentFile.name),
                    size: 44,
                    radius: AppRadius.md,
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          currentFile.name,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'File ${_currentFileIndex + 1} of ${widget.items.length}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: AppSpacing.lg),
              ClipRRect(
                borderRadius: AppRadius.smAll,
                child: LinearProgressIndicator(
                  value: percentage / 100,
                  minHeight: 12,
                ),
              ),
              const SizedBox(height: AppSpacing.md),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    '${_formatSize(bytesTransferred)} / ${_formatSize(totalBytes)}',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  Text(
                    '${percentage.toStringAsFixed(1)}%',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: AppTheme.primaryColor,
                        ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: AppSpacing.xxl),
        Row(
          children: [
            Expanded(
              child: _buildStatCard(
                icon: Icons.speed,
                label: 'Speed',
                value: _getSpeedDisplay(),
                color: AppTheme.accentColor,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: _buildStatCard(
                icon: Icons.timer_outlined,
                label: 'Remaining',
                value: _calculateRemainingTime(),
                color: AppTheme.secondaryColor,
              ),
            ),
          ],
        ),
        const SizedBox(height: AppSpacing.xxl),
        Expanded(child: _buildFileList()),
      ],
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required Color color,
  }) {
    return AppCard(
      child: Column(
        children: [
          Icon(icon, color: color, size: 24),
          const SizedBox(height: AppSpacing.sm),
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: AppSpacing.xs),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
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

  Widget _buildCompletedState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
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
      ],
    );
  }

  Widget _buildFailedState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
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
      ],
    );
  }

  Widget _buildCancelledState() {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.xxl),
          decoration: BoxDecoration(
            color: AppTheme.textTertiary.withValues(alpha: 0.2),
            shape: BoxShape.circle,
          ),
          child: const Icon(
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
    return '${_formatSize(_speed.toInt())}/s';
  }

  String _formatSize(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}
