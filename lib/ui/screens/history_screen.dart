import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/database/database_helper.dart';
import '../../core/utils/byte_formatter.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  List<Map<String, dynamic>> _transfers = [];
  bool _isLoading = true;
  Map<String, int> _statistics = {};

  @override
  void initState() {
    super.initState();
    _loadHistory();
  }

  Future<void> _loadHistory() async {
    // FIXED (Bug #23): Add mounted check before setState
    if (!mounted) return;
    
    setState(() {
      _isLoading = true;
    });

    try {
      final db = DatabaseHelper.instance;
      final transfers = await db.getTransferHistory(limit: 100);
      final stats = await db.getStatistics();

      // FIXED (Bug #23): Add mounted check before setState
      if (mounted) {
        setState(() {
          _transfers = transfers;
          _statistics = stats;
          _isLoading = false;
        });
      }
    } catch (e) {
      // FIXED (Bug #23): Add mounted check before setState
      if (mounted) {
        setState(() {
          _isLoading = false;
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error loading history: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _deleteTransfer(String transferId) async {
    try {
      await DatabaseHelper.instance.deleteTransfer(transferId);
      await _loadHistory();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Transfer removed from history'),
            backgroundColor: AppTheme.successColor,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error deleting transfer: $e'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  Future<void> _clearAllHistory() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear All History?'),
        content: const Text(
          'This will permanently delete all transfer records. This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
            ),
            child: const Text('Clear All'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await DatabaseHelper.instance.clearHistory();
        await _loadHistory();

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('History cleared'),
              backgroundColor: AppTheme.successColor,
            ),
          );
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Error clearing history: $e'),
              backgroundColor: AppTheme.errorColor,
            ),
          );
        }
      }
    }
  }

  String _formatTimestamp(int milliseconds) {
    final dateTime = DateTime.fromMillisecondsSinceEpoch(milliseconds);
    final now = DateTime.now();
    final difference = now.difference(dateTime);

    if (difference.inDays == 0) {
      return 'Today ${_formatTime(dateTime)}';
    } else if (difference.inDays == 1) {
      return 'Yesterday ${_formatTime(dateTime)}';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${dateTime.day}/${dateTime.month}/${dateTime.year}';
    }
  }

  String _formatTime(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }

  Color _getStatusColor(String status) {
    switch (status) {
      case 'completed':
        return AppTheme.successColor;
      case 'failed':
      case 'cancelled':
        return AppTheme.errorColor;
      default:
        return AppTheme.textTertiary;
    }
  }

  IconData _getStatusIcon(String status) {
    switch (status) {
      case 'completed':
        return Icons.check_circle;
      case 'failed':
        return Icons.error;
      case 'cancelled':
        return Icons.cancel;
      default:
        return Icons.sync;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GradientIconTile(
              icon: Icons.history,
              size: 36,
              iconSize: 20,
              radius: AppRadius.sm,
            ),
            SizedBox(width: AppSpacing.md),
            Text('Transfer History'),
          ],
        ),
        actions: [
          if (_transfers.isNotEmpty)
            IconButton(
              icon: Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: AppTheme.errorColor.withValues(alpha: 0.15),
                  borderRadius: AppRadius.smAll,
                ),
                child: const Icon(
                  Icons.delete_sweep,
                  color: AppTheme.errorColor,
                  size: 20,
                ),
              ),
              onPressed: _clearAllHistory,
              tooltip: 'Clear All',
            ),
        ],
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _transfers.isEmpty
                ? _buildEmptyState()
                : Column(
                    children: [
                      _buildStatistics(),
                      Expanded(child: _buildHistoryList()),
                    ],
                  ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return const EmptyState(
      icon: Icons.history,
      title: 'No transfer history',
      message: 'Your completed transfers will appear here',
    );
  }

  Widget _buildStatistics() {
    if (_statistics.isEmpty) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.all(AppSpacing.lg),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceAround,
          children: [
            _buildStatItem(
              'Total',
              _statistics['totalTransfers']?.toString() ?? '0',
              Icons.swap_horiz,
            ),
            _buildStatItem(
              'Completed',
              _statistics['completedTransfers']?.toString() ?? '0',
              Icons.check_circle,
              color: AppTheme.successColor,
            ),
            _buildStatItem(
              'Data',
              ByteFormatter.format(_statistics['totalBytes'] ?? 0),
              Icons.data_usage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatItem(String label, String value, IconData icon,
      {Color? color}) {
    return Column(
      children: [
        Container(
          padding: const EdgeInsets.all(AppSpacing.md),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                (color ?? AppTheme.primaryColor).withValues(alpha: 0.2),
                (color ?? AppTheme.primaryColor).withValues(alpha: 0.1),
              ],
            ),
            borderRadius: AppRadius.mdAll,
            border: Border.all(
              color: (color ?? AppTheme.primaryColor).withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Icon(
            icon,
            color: color ?? AppTheme.primaryColor,
            size: 26,
          ),
        ),
        const SizedBox(height: AppSpacing.md),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
                fontWeight: FontWeight.bold,
              ),
        ),
        const SizedBox(height: AppSpacing.xs + 2),
        Text(
          label,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppTheme.textTertiary,
              ),
        ),
      ],
    );
  }

  Widget _buildHistoryList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      itemCount: _transfers.length,
      itemBuilder: (context, index) {
        final transfer = _transfers[index];

        // FIX (Bug #33, #39): Safe type casting with defaults
        final transferId = transfer['id'] as String? ?? '';
        final status = transfer['status'] as String? ?? 'unknown';
        final receiverName = transfer['receiver_name'] as String? ?? 'Unknown Device';
        final fileCount = transfer['file_count'] as int? ?? 0;
        final totalBytes = transfer['total_bytes'] as int? ?? 0;
        final createdAt = transfer['created_at'] as int? ?? 0;

        return Dismissible(
          key: Key(transferId),
          direction: DismissDirection.endToStart,
          background: Container(
            alignment: Alignment.centerRight,
            padding: const EdgeInsets.only(right: AppSpacing.xl),
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            decoration: const BoxDecoration(
              color: AppTheme.errorColor,
              borderRadius: AppRadius.lgAll,
            ),
            child: const Icon(Icons.delete, color: Colors.white),
          ),
          onDismissed: (_) {
            // Remove synchronously — Dismissible requires the item to leave
            // the tree immediately, or the widget errors and the row stays.
            setState(() {
              _transfers.removeWhere((t) => t['id'] == transferId);
            });
            // DB delete + snackbar happen in the background.
            _deleteTransfer(transferId);
          },
          child: Container(
            margin: const EdgeInsets.only(bottom: AppSpacing.md),
            child: AppCard(
              onTap: () {},
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.md),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [
                          _getStatusColor(status)
                              .withValues(alpha: 0.2),
                          _getStatusColor(status)
                              .withValues(alpha: 0.1),
                        ],
                      ),
                      borderRadius: AppRadius.mdAll,
                      border: Border.all(
                        color: _getStatusColor(status)
                            .withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Icon(
                      _getStatusIcon(status),
                      color: _getStatusColor(status),
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          receiverName,
                          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                        const SizedBox(height: AppSpacing.xs + 2),
                        Row(
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceColor.withValues(alpha: 0.5),
                                borderRadius: AppRadius.smAll,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    _getFileTypeIcon(fileCount),
                                    size: 12,
                                    color: AppTheme.textTertiary,
                                  ),
                                  const SizedBox(width: AppSpacing.xs),
                                  Text(
                                    '$fileCount file(s)',
                                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: AppTheme.textTertiary,
                                        ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: AppSpacing.sm),
                            Text(
                              ByteFormatter.format(totalBytes),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.primaryColor,
                                    fontWeight: FontWeight.w600,
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: AppSpacing.xs + 2),
                        Row(
                          children: [
                            const Icon(
                              Icons.access_time_rounded,
                              size: 12,
                              color: AppTheme.textTertiary,
                            ),
                            const SizedBox(width: AppSpacing.xs),
                            Text(
                              _formatTimestamp(createdAt),
                              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: AppTheme.textTertiary,
                                  ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceColor.withValues(alpha: 0.5),
                      borderRadius: AppRadius.smAll,
                    ),
                    child: const Icon(
                      Icons.chevron_right,
                      color: AppTheme.textTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _getFileTypeIcon(int fileCount) {
    if (fileCount > 1) return Icons.folder;
    return Icons.insert_drive_file_rounded;
  }
}
