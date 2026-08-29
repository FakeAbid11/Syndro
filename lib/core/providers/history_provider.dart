import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../database/database_helper.dart';
import '../models/transfer_history_entry.dart';

import '../utils/app_logger.dart';
/// Immutable UI state for the history screen.
class HistoryState {
  final List<TransferHistoryEntry> entries;
  final Map<String, int> statistics;
  final bool isLoading;

  const HistoryState({
    this.entries = const [],
    this.statistics = const {},
    this.isLoading = true,
  });

  HistoryState copyWith({
    List<TransferHistoryEntry>? entries,
    Map<String, int>? statistics,
    bool? isLoading,
  }) {
    return HistoryState(
      entries: entries ?? this.entries,
      statistics: statistics ?? this.statistics,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

/// Loads, deletes and clears transfer history via [DatabaseHelper].
///
/// Extracted from [HistoryScreen], which previously queried the database
/// directly in initState and managed rows as raw maps with setState.
class HistoryNotifier extends StateNotifier<HistoryState> {
  HistoryNotifier() : super(const HistoryState());

  Future<void> load() async {
    state = state.copyWith(isLoading: true);
    try {
      final db = DatabaseHelper.instance;
      final entries = await db.getHistoryEntries(limit: 100);
      final stats = await db.getStatistics();
      state = HistoryState(
        entries: entries,
        statistics: stats,
        isLoading: false,
      );
    } catch (e) {
      AppLogger.info('History load error: $e');
      state = state.copyWith(isLoading: false);
    }
  }

  /// Removes an entry from the state immediately (so a [Dismissible] row
  /// leaves the tree at once) and deletes it from the database in the
  /// background, refreshing statistics afterwards.
  Future<void> delete(String transferId) async {
    state = state.copyWith(
      entries: state.entries.where((e) => e.id != transferId).toList(),
    );
    try {
      await DatabaseHelper.instance.deleteTransfer(transferId);
      final stats = await DatabaseHelper.instance.getStatistics();
      state = state.copyWith(statistics: stats);
    } catch (e) {
      AppLogger.info('History delete error: $e');
    }
  }

  /// Clears every history record. Returns `true` on success.
  Future<bool> clearAll() async {
    try {
      await DatabaseHelper.instance.clearHistory();
      final stats = await DatabaseHelper.instance.getStatistics();
      state = state.copyWith(entries: const [], statistics: stats);
      return true;
    } catch (e) {
      AppLogger.info('History clear error: $e');
      return false;
    }
  }
}

final historyProvider =
    StateNotifierProvider<HistoryNotifier, HistoryState>((ref) {
  return HistoryNotifier();
});
