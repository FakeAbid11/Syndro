import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/models/transfer_checkpoint.dart';
import 'package:syndro/core/services/checkpoint_manager.dart';

/// Resume must survive an interrupted send.
///
/// The checkpoint was previously written under the per-attempt transfer id
/// while `loadCheckpoint` looked it up under a content-derived key, so the load
/// always missed: `startIndex` was always 0, the resume branch was unreachable,
/// and a completed send cleared a file that had never been written. Every retry
/// therefore re-sent every file and leaked an orphan checkpoint.
///
/// This pins the three properties that make resume work:
///
///  1. a checkpoint saved under `resumeKey` is found again by that key,
///  2. it reports a non-zero `currentFileIndex`, so the send loop skips the
///     files that already got through, and
///  3. clearing by the same key actually removes it, so a later unrelated send
///     of the same files does not resume from stale state.
///
/// The key derivation itself lives on TransferService and is exercised through
/// the end-to-end acceptance suites; here we pin the persistence contract that
/// the bug actually broke.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late CheckpointManager manager;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('syndro-resume-test');
    manager = CheckpointManager(checkpointsDirectoryOverride: dir.path);
  });

  tearDown(() async {
    if (await dir.exists()) await dir.delete(recursive: true);
  });

  /// Mirrors what TransferService does: the key is derived from the two peers
  /// plus the item list, not from the transfer id.
  String checkpointKey(String sender, String receiver, List<String> names) {
    final digest = _sha256Hex('$sender->$receiver:${names.join('|')}');
    return 'ckpt_${digest.substring(0, 16)}';
  }

  test('a checkpoint saved under a resumeKey is found again by that key',
      () async {
    final key = checkpointKey('alice', 'bob', ['a.txt', 'b.txt', 'c.txt']);

    // First attempt: dies after two files.
    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'attempt-1-uuid',
      resumeKey: key,
      fileId: 'b.txt',
      bytesTransferred: 200,
      timestamp: DateTime.now(),
      currentFileIndex: 2,
      totalFiles: 3,
    ));

    // Second attempt: a brand new transfer id, same content key.
    final loaded = await manager.loadCheckpoint(key);

    expect(loaded, isNotNull,
        reason: 'the checkpoint must be reachable by its resumeKey');
    expect(loaded!.currentFileIndex, 2,
        reason: 'resume must know two files already got through');
    expect(loaded.bytesTransferred, 200);
    expect(loaded.transferId, 'attempt-1-uuid',
        reason: 'the original attempt id is recorded for diagnostics only');
  });

  test('the resume loop skips exactly the completed files', () async {
    // The observable the send loop depends on: given a checkpoint at index 2
    // of 4 items, the loop must start at 2 and not resend 0 or 1.
    const items = ['a.bin', 'b.bin', 'c.bin', 'd.bin'];
    final key = checkpointKey('alice', 'bob', items);

    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'uuid-a',
      resumeKey: key,
      fileId: items[1],
      bytesTransferred: 1024,
      timestamp: DateTime.now(),
      currentFileIndex: 2,
      totalFiles: items.length,
    ));

    final startIndex =
        (await manager.loadCheckpoint(key))?.currentFileIndex ?? 0;
    final remaining = items.sublist(startIndex);

    expect(startIndex, 2);
    expect(remaining, ['c.bin', 'd.bin']);
  });

  test('clearing by the resume key removes the checkpoint', () async {
    final key = checkpointKey('alice', 'bob', ['x.txt']);
    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'uuid-a',
      resumeKey: key,
      fileId: 'x.txt',
      bytesTransferred: 5,
      timestamp: DateTime.now(),
      currentFileIndex: 1,
      totalFiles: 1,
    ));
    expect(await manager.loadCheckpoint(key), isNotNull);

    await manager.clearCheckpoint(key);

    expect(await manager.loadCheckpoint(key), isNull,
        reason: 'a completed transfer must not leave a resumable checkpoint');
  });

  test('two sends of different content do not share a checkpoint', () async {
    // The key includes the item list, so sending different files to the same
    // peer must not resume from an unrelated checkpoint.
    final keyA = checkpointKey('alice', 'bob', ['a.txt']);
    final keyB = checkpointKey('alice', 'bob', ['b.txt']);
    expect(keyA, isNot(keyB));

    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'uuid-a',
      resumeKey: keyA,
      fileId: 'a.txt',
      bytesTransferred: 1,
      timestamp: DateTime.now(),
      currentFileIndex: 1,
      totalFiles: 1,
    ));

    expect(await manager.loadCheckpoint(keyB), isNull);
    expect(await manager.loadCheckpoint(keyA), isNotNull);
  });

  test('an expired checkpoint is discarded rather than resumed', () async {
    // Older than the 24h validity window.
    final key = checkpointKey('alice', 'bob', ['old.txt']);
    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'uuid-old',
      resumeKey: key,
      fileId: 'old.txt',
      bytesTransferred: 1,
      timestamp: DateTime.now().subtract(const Duration(hours: 25)),
      currentFileIndex: 1,
      totalFiles: 1,
    ));

    final loaded = await manager.loadCheckpoint(key);
    expect(loaded, isNull,
        reason: 'a checkpoint from over a day ago must not be trusted');
  });

  test('checkpoint writes do not throw when the directory is unusable',
      () async {
    // Checkpointing is telemetry for resuming, never load-bearing for the
    // transfer. A write that fails must not abort a send whose bytes already
    // went across the wire.
    final broken = CheckpointManager(
      checkpointsDirectoryOverride: p.join(dir.path, 'nested', 'deep'),
    );
    await manager.saveCheckpoint(TransferCheckpoint(
      transferId: 'uuid-a',
      resumeKey: 'ckpt_ok',
      fileId: 'a.txt',
      bytesTransferred: 1,
      timestamp: DateTime.now(),
      currentFileIndex: 1,
      totalFiles: 1,
    ));

    // A directory path that cannot be created (a file sits where the directory
    // would go) makes _getCheckpointsDirectory throw.
    final blocker = File(p.join(dir.path, 'blocked'));
    await blocker.writeAsString('not a directory');
    final hostile = CheckpointManager(
      checkpointsDirectoryOverride: p.join(blocker.path, 'checkpoints'),
    );

    await expectLater(
      hostile.saveCheckpoint(TransferCheckpoint(
        transferId: 'uuid-a',
        resumeKey: 'ckpt_x',
        fileId: 'a.txt',
        bytesTransferred: 1,
        timestamp: DateTime.now(),
        currentFileIndex: 1,
        totalFiles: 1,
      )),
      completes,
      reason: 'a checkpoint write failure must not propagate to the sender',
    );
    await expectLater(hostile.clearCheckpoint('ckpt_x'), completes);

    // The usable manager is unaffected.
    expect(await broken.getAllCheckpoints(), isNotNull);
  });
}

/// Minimal SHA-256 hex, mirroring TransferService._generateCheckpointKey.
String _sha256Hex(String input) =>
    crypto.sha256.convert(utf8.encode(input)).toString();
