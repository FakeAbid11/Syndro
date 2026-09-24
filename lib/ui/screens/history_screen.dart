import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../widgets/shimmer_loading.dart';
import '../../core/models/transfer_history_entry.dart';
import '../../core/providers/history_provider.dart';
import '../../core/utils/byte_formatter.dart';

class HistoryScreen extends ConsumerStatefulWidget {
  const HistoryScreen({super.key});

  @override
  ConsumerState<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends ConsumerState<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    // Load through [historyProvider] (providers must not be mutated during
    // the build phase, hence the microtask).
    Future.microtask(() {
      if (mounted) ref.read(historyProvider.notifier).load();
    });
  }

  // Backed by the history provider — previously local setState state fed by
  // raw sqflite maps.
  List<TransferHistoryEntry> get _transfers =>
      ref.watch(historyProvider).entries;
  Map<String, int> get _statistics => ref.watch(historyProvider).statistics;
  bool get _isLoading => ref.watch(historyProvider).isLoading;

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
      final cleared = await ref.read(historyProvider.notifier).clearAll();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content:
                Text(cleared ? 'History cleared' : 'Error clearing history'),
            backgroundColor:
                cleared ? AppTheme.successColor : AppTheme.errorColor,
          ),
        );
      }
    }
  }

  /// Status colour, paired with an icon and a word everywhere it is used.
  Color _statusColor(String status) {
    switch (status) {
      case 'completed':
        return AppTheme.successColor;
      case 'failed':
        return AppTheme.errorColor;
      case 'cancelled':
        return AppTheme.warningColor;
      default:
        return AppTheme.textTertiary;
    }
  }

  IconData _statusIcon(String status) {
    switch (status) {
      case 'completed':
        return Icons.check_circle_outline;
      case 'failed':
        return Icons.error_outline;
      case 'cancelled':
        return Icons.cancel_outlined;
      default:
        return Icons.sync;
    }
  }

  String _statusLabel(String status) => switch (status) {
        'completed' => 'Completed',
        'failed' => 'Failed',
        'cancelled' => 'Cancelled',
        _ => 'In progress',
      };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: const Text('Transfer History'),
        actions: [
          if (_transfers.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              color: AppTheme.errorColor,
              onPressed: _clearAllHistory,
              tooltip: 'Clear All',
            ),
          const SizedBox(width: AppSpacing.sm),
        ],
      ),
      body: _isLoading
          ? const Padding(
              padding: EdgeInsets.all(AppSpacing.lg),
              child: Column(
                children: [
                  HistoryItemSkeleton(),
                  SizedBox(height: AppSpacing.md),
                  HistoryItemSkeleton(),
                  SizedBox(height: AppSpacing.md),
                  HistoryItemSkeleton(),
                  SizedBox(height: AppSpacing.md),
                  HistoryItemSkeleton(),
                ],
              ),
            )
          : _transfers.isEmpty
              ? const EmptyState(
                  icon: Icons.history,
                  title: 'No transfer history',
                  message: 'Your completed transfers will appear here',
                )
              : ResponsiveCenter(
                  maxWidth: 860,
                  child: CustomScrollView(
                    slivers: [
                      SliverToBoxAdapter(
                        child: _buildStatistics(),
                      ),
                      for (final section in _sections(_transfers)) ...[
                        SliverToBoxAdapter(
                          child: _SectionHeading(label: section.label),
                        ),
                        SliverList.separated(
                          itemCount: section.entries.length,
                          separatorBuilder: (_, __) =>
                              const SizedBox(height: AppSpacing.sm),
                          itemBuilder: (context, index) =>
                              _buildRow(section.entries[index]),
                        ),
                      ],
                      const SliverToBoxAdapter(
                        child: SizedBox(height: AppSpacing.xxl),
                      ),
                    ],
                  ),
                ),
    );
  }

  /// Groups rows by calendar day, newest first, as the provider returns them.
  ///
  /// The list is already ordered by `created_at DESC` in SQL, so one pass over
  /// it is enough; a device that has been used for months gets a heading per
  /// day rather than one undifferentiated wall.
  List<({String label, List<TransferHistoryEntry> entries})> _sections(
    List<TransferHistoryEntry> entries,
  ) {
    final today = DateTime.now();
    DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
    final result =
        <({String label, List<TransferHistoryEntry> entries})>[];

    for (final entry in entries) {
      final day = dayOf(entry.createdAt);
      final difference = dayOf(today).difference(day).inDays;
      final label = switch (difference) {
        0 => 'Today',
        1 => 'Yesterday',
        _ when difference < 0 => 'Upcoming',
        _ => '${day.day} ${_months[day.month - 1]}'
            '${day.year == today.year ? '' : ' ${day.year}'}',
      };
      if (result.isNotEmpty && result.last.label == label) {
        result.last.entries.add(entry);
      } else {
        result.add((label: label, entries: [entry]));
      }
    }
    return result;
  }

  static const _months = [
    'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', //
    'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
  ];

  Widget _buildStatistics() {
    if (_statistics.isEmpty) return const SizedBox.shrink();

    final total = _statistics['totalTransfers'] ?? 0;
    final completed = _statistics['completedTransfers'] ?? 0;
    final bytes = _statistics['totalBytes'] ?? 0;

    return Container(
      margin: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.lg,
        vertical: AppSpacing.md,
      ),
      decoration: BoxDecoration(
        color: AppTheme.surfaceContainer,
        borderRadius: AppRadius.lgAll,
        border: Border.all(color: AppTheme.outlineVariant, width: 1),
      ),
      child: Row(
        children: [
          _Stat(label: 'Transfers', value: '$total'),
          const _StatDivider(),
          _Stat(label: 'Completed', value: '$completed'),
          const _StatDivider(),
          _Stat(label: 'Data moved', value: ByteFormatter.format(bytes)),
        ],
      ),
    );
  }

  Widget _buildRow(TransferHistoryEntry transfer) {
    final status = transfer.status;
    final color = _statusColor(status);
    final fileCount = transfer.fileCount;

    return Dismissible(
      key: Key(transfer.id),
      direction: DismissDirection.endToStart,
      // A swipe is irreversible from the user's point of view, so it asks
      // first; the record itself is only removed once the answer is yes.
      confirmDismiss: (_) => _confirmDelete(transfer),
      onDismissed: (_) {
        // Provider state updates synchronously so the row leaves the
        // tree immediately (Dismissible requirement); the DB delete and
        // statistics refresh happen in the background.
        ref.read(historyProvider.notifier).delete(transfer.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Transfer removed from history'),
              backgroundColor: AppTheme.successColor,
            ),
          );
        }
      },
      background: const _DismissBackground(),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.md,
          vertical: AppSpacing.md,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surfaceContainer,
          borderRadius: AppRadius.mdAll,
          border: Border.all(color: AppTheme.outlineVariant, width: 1),
        ),
        child: Row(
          children: [
            Icon(_statusIcon(status), color: color, size: 20),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    transfer.displayName,
                    style: Theme.of(context).textTheme.titleSmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${fileCount == 1 ? '1 file' : '$fileCount files'}'
                    ' • ${transfer.totalBytesFormatted}',
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  _time(transfer.createdAt),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                const SizedBox(height: 2),
                Text(
                  _statusLabel(status),
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// The row's own confirmation, so a swipe cannot silently delete a record.
  Future<bool> _confirmDelete(TransferHistoryEntry transfer) async {
    if (!mounted) return false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove from history?'),
        content: Text(
          'The record for ${transfer.displayName} will be deleted. '
          'Files already transferred are not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.errorColor,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  String _time(DateTime dateTime) {
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    return '$hour:$minute';
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.sm,
      ),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: AppTheme.textTertiary,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            value,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            label,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _StatDivider extends StatelessWidget {
  const _StatDivider();

  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
        color: AppTheme.outlineVariant,
      );
}

/// Swipe-to-delete affordance.
///
/// The bin sits at the leading edge because `DismissDirection.endToStart`
/// reveals whatever is behind it from right to left; the old centred-right
/// icon ended up off-screen as the row slid away.
class _DismissBackground extends StatelessWidget {
  const _DismissBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      alignment: Alignment.centerLeft,
      margin: const EdgeInsets.only(bottom: AppSpacing.sm),
      padding: const EdgeInsets.only(left: AppSpacing.xl),
      decoration: BoxDecoration(
        color: AppTheme.errorContainer,
        borderRadius: AppRadius.mdAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.delete_outline, color: AppTheme.onErrorContainer),
          const SizedBox(width: AppSpacing.sm),
          Text(
            'Remove',
            style: TextStyle(color: AppTheme.onErrorContainer),
          ),
        ],
      ),
    );
  }
}
