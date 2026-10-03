import 'dart:io';
import 'dart:convert';
import 'dart:async';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;

import '../models/transfer_checkpoint.dart';
import '../utils/app_logger.dart';

/// Manages transfer checkpoints (save/load/clear) for resume-on-failure.
///
/// Concurrency is provided by a per-key future queue ([_queues]), which gives
/// every operation a real exclusive critical section. The earlier
/// exists()-then-write sequence was a TOCTOU race even within a single isolate.
///
/// Every method is best-effort: checkpoint I/O never throws, because a
/// transfer that already streamed its files must not be reported as failed just
/// because the resume metadata could not be written.
class CheckpointManager {
  static const String _checkpointsDir = 'checkpoints';

  // A future queue gives every operation a real exclusive critical section.
  // The old exists()->write sequence was a TOCTOU race even within one isolate.
  final Map<String, Future<void>> _queues = {};

  Future<T> _exclusive<T>(String key, Future<T> Function() operation) {
    final previous = _queues[key] ?? Future<void>.value();
    final done = Completer<void>();
    _queues[key] = done.future;
    return previous.then((_) => operation()).whenComplete(() async {
      done.complete();
      if (identical(_queues[key], done.future)) _queues.remove(key);
    });
  }

  // Save checkpoint to disk.
  //
  // Checkpointing is best-effort telemetry for resuming an interrupted send; it
  // is never load-bearing for the transfer itself. A failure here (no writable
  // documents directory, a full disk, a revoked permission) must therefore not
  // propagate: the caller has already streamed the file, and letting this throw
  // would discard a completed send.
  Future<void> saveCheckpoint(TransferCheckpoint checkpoint) async {
    try {
      await _exclusive(checkpoint.resumeKey ?? checkpoint.transferId, () async {
        final dir = await _getCheckpointsDirectory();
        final key = checkpoint.resumeKey ?? checkpoint.transferId;
        final file = File(path.join(dir.path, '$key.json'));
        final temp = File(
            '${file.path}.${DateTime.now().microsecondsSinceEpoch}.tmp');
        final json = jsonEncode(checkpoint.toJson());
        await temp.writeAsString(json, flush: true);
        try {
          await temp.rename(file.path);
        } on FileSystemException {
          // Windows does not replace an existing destination on rename. Delete
          // only the checkpoint (never user data), then complete the atomic move.
          if (await file.exists()) await file.delete();
          await temp.rename(file.path);
        }
      });
    } catch (e) {
      AppLogger.error('Error saving checkpoint: $e');
    }
  }

  // Load checkpoint from disk
  Future<TransferCheckpoint?> loadCheckpoint(String transferId) async {
    return _exclusive(transferId, () async {
      final dir = await _getCheckpointsDirectory();
      final file = File(path.join(dir.path, '$transferId.json'));

      if (!await file.exists()) {
        return null;
      }

      final contents = await file.readAsString();
      final json = jsonDecode(contents) as Map<String, dynamic>;
      final checkpoint = TransferCheckpoint.fromJson(json);

      // Check if checkpoint is still valid
      if (!checkpoint.isValid) {
        await file.delete();
        return null;
      }

      return checkpoint;
    }).catchError((e) {
      AppLogger.error('Error loading checkpoint: $e');
      return null;
    });
  }

  // Clear checkpoint after transfer completion.
  //
  // Like [saveCheckpoint], a failure here is logged and swallowed: leaving a
  // stale checkpoint behind is recoverable, failing a completed transfer is not.
  Future<void> clearCheckpoint(String transferId) async {
    try {
      await _exclusive(transferId, () async {
        final dir = await _getCheckpointsDirectory();
        final file = File(path.join(dir.path, '$transferId.json'));

        if (await file.exists()) {
          await file.delete();
        }
      });
    } catch (e) {
      AppLogger.error('Error clearing checkpoint: $e');
    }
  }

  // FIX (Bug #19): Get checkpoints with pagination to avoid memory spike
  Future<List<TransferCheckpoint>> getAllCheckpoints({
    int? limit,
    int offset = 0,
  }) async {
    try {
      final dir = await _getCheckpointsDirectory();

      if (!await dir.exists()) {
        return [];
      }

      final files = dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json')) // Skip .lock files
          .toList();

      // Sort by modification time (newest first).
      //
      // Stat each file exactly once up front. Sorting with a comparator that
      // calls statSync() performs two blocking stat() calls per comparison,
      // which is O(n log n) synchronous filesystem I/O on the UI isolate.
      final datedFiles = <MapEntry<File, DateTime>>[];
      for (final file in files) {
        try {
          datedFiles.add(MapEntry(file, file.statSync().modified));
        } on FileSystemException {
          // A checkpoint file that vanished mid-listing is simply skipped.
        }
      }
      datedFiles.sort((a, b) => b.value.compareTo(a.value));
      final sortedFiles = datedFiles.map((e) => e.key).toList();

      // Apply pagination
      final startIndex = offset;
      final endIndex = limit != null ? (offset + limit).clamp(0, sortedFiles.length) : sortedFiles.length;
      final paginatedFiles = sortedFiles.sublist(
        startIndex.clamp(0, sortedFiles.length),
        endIndex,
      );

      final checkpoints = <TransferCheckpoint>[];

      for (final file in paginatedFiles) {
        try {
          final contents = await file.readAsString();
          final json = jsonDecode(contents) as Map<String, dynamic>;
          final checkpoint = TransferCheckpoint.fromJson(json);

          if (checkpoint.isValid) {
            checkpoints.add(checkpoint);
          } else {
            // Delete invalid checkpoint
            await file.delete();
          }
        } catch (e) {
          // FIX: Use debugPrint instead of print
          AppLogger.error('Error reading checkpoint file: $e');
        }
      }

      return checkpoints;
    } catch (e) {
      // FIX: Use debugPrint instead of print
      AppLogger.error('Error getting checkpoints: $e');
      return [];
    }
  }

  // Get total checkpoint count (for pagination)
  Future<int> getCheckpointCount() async {
    try {
      final dir = await _getCheckpointsDirectory();
      if (!await dir.exists()) return 0;

      return dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.json'))
          .length;
    } catch (e) {
      AppLogger.error('Error getting checkpoint count: $e');
      return 0;
    }
  }

  // Clear all checkpoints
  Future<void> clearAllCheckpoints() async {
    try {
      final dir = await _getCheckpointsDirectory();

      if (await dir.exists()) {
        await dir.delete(recursive: true);
      }
    } catch (e) {
      // FIX: Use debugPrint instead of print
      AppLogger.error('Error clearing all checkpoints: $e');
    }
  }

  Future<Directory> _getCheckpointsDirectory() async {
    final appDir = await getApplicationDocumentsDirectory();
    final checkpointsDir = Directory(path.join(appDir.path, _checkpointsDir));

    if (!await checkpointsDir.exists()) {
      await checkpointsDir.create(recursive: true);
    }

    return checkpointsDir;
  }
}
