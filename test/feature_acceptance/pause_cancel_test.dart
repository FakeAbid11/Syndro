@Tags(<String>['acceptance'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-06 / FA-08 — pause, resume and cancel against a real receiver.
///
/// Pause is only honoured on the sequential path
/// (`transfer_service_impl.dart:3811-3825` returns early for
/// `isParallel == true`), and a single item over ~10 MB is routed to parallel,
/// so these use two 8 MB files: large enough to still be streaming when the
/// control lands, sequential by construction.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  const chunkSize = 8 * 1024 * 1024;

  Future<List<TransferItem>> twoPayloads(TwoNodeHarness h) async {
    final a = await writePayload(h.sender.workDir, 'bulk-a.bin', chunkSize);
    final b = await writePayload(h.sender.workDir, 'bulk-b.bin', chunkSize);
    return [itemFor(a), itemFor(b)];
  }

  group('FA-06 pause and resume', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('a paused transfer stops advancing and resumes to correct bytes',
        () async {
      final items = await twoPayloads(h);
      final expected = <String, String>{};
      for (final item in items) {
        expected[item.name] = await sha256OfFile(item.path);
      }

      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: items,
        encrypted: false,
      );
      await h.approveNextPending();

      final transferId = h.senderTransfer(h.receiver.deviceId)?.id;
      expect(transferId, isNotNull, reason: 'sender must register the transfer');

      h.sender.service.pauseTransfer(transferId!);
      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.paused,
          reason: 'pauseTransfer must move a sequential transfer to paused');

      final frozenBytes =
          h.senderTransfer(h.receiver.deviceId)!.progress.bytesTransferred;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        h.senderTransfer(h.receiver.deviceId)!.progress.bytesTransferred,
        frozenBytes,
        reason: 'progress must not advance while paused',
      );

      h.sender.service.resumeTransfer(transferId);

      // Bound this so an orphaned pause gate reports itself instead of
      // surfacing as an opaque test-level timeout. `resumeTransfer` completes the
      // gate recorded in `_pauseGates`; if that entry has gone, the sender is
      // left parked on `await gate.future` and the send never settles. That has
      // reproduced roughly one run in three; naming it here makes the failure
      // legible rather than a bare "test timed out after 90 seconds".
      await sendFuture.timeout(
        const Duration(seconds: 25),
        onTimeout: () => fail(
          'the send never settled after resumeTransfer. The transfer was '
          'paused at ${h.senderTransfer(h.receiver.deviceId)?.status} with '
          '$frozenBytes bytes sent, which points at the pause gate being '
          'orphaned rather than at the resume not being requested.',
        ),
      );

      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.completed,
          reason: 'the resumed send should finish, not stall mid-transfer');

      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        timeout: const Duration(seconds: 60),
        reason: 'receiver completes after a pause/resume cycle',
      );

      for (final entry in expected.entries) {
        final landed = h.receiver.downloaded(entry.key);
        expect(await landed.exists(), isTrue, reason: 'missing ${entry.key}');
        expect(await sha256OfFile(landed.path), entry.value,
            reason: '${entry.key} corrupted across pause/resume');
      }
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('pausing a completed or unknown transfer is a no-op, not a crash',
        () async {
      h.sender.service.pauseTransfer('does-not-exist');
      h.sender.service.resumeTransfer('does-not-exist');
      h.sender.service.cancelTransfer('does-not-exist');
      // Reaching here without an exception is the assertion.
      expect(h.sender.service.activeTransfers, isEmpty);
    });
  });

  group('FA-08 cancel mid-transfer', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
        // Short window so the abandoned-receive watchdog is exercised promptly.
        // Production uses 90s, chosen to outlast any plausible user pause;
        // that is far too slow to wait on here.
        receiverSilenceTimeout: const Duration(seconds: 3),
      );
    });

    tearDown(() => h.dispose());

    test('a cancel aborts the sender and leaves no completed file', () async {
      final items = await twoPayloads(h);

      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: items,
        encrypted: false,
      );
      await h.approveNextPending();

      final transferId = h.senderTransfer(h.receiver.deviceId)!.id;
      // Pause first, then cancel. Loopback can finish 16 MB in well under a
      // second, and cancelTransfer returns early on a terminal transfer — so
      // without the pause this test would race the thing it is checking.
      // cancelTransfer releases the gate (:3759) and the send loop then throws
      // CANCELLED at the next chunk boundary.
      h.sender.service.pauseTransfer(transferId);
      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.paused,
          reason: 'the transfer must be held before it can be cancelled '
              'deterministically — increase the fixture if this fails');

      // Prove we are genuinely mid-flight, not already done: progress must be
      // frozen for a window, exactly as FA-06 asserts.
      final frozenBytes =
          h.senderTransfer(h.receiver.deviceId)!.progress.bytesTransferred;
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(
        h.senderTransfer(h.receiver.deviceId)!.progress.bytesTransferred,
        frozenBytes,
        reason: 'progress must not advance while paused',
      );

      h.sender.service.cancelTransfer(transferId);

      Object? error;
      try {
        await sendFuture.timeout(const Duration(seconds: 60));
      } on Object catch (e) {
        error = e;
      }
      expect(error, isNotNull,
          reason: 'a cancelled send must not resolve as success');

      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.cancelled,
          reason: 'the user cancel must survive the abort path');

      // The receiver sees an abandoned upload: no bytes ever arrive, so its
      // silence watchdog fails the transfer. 20s is the product timeout; allow
      // generous headroom for a loaded machine, and give the test itself a real
      // budget rather than the 30s default which this wait can exceed.
      await waitUntil(
        () {
          final status = h.receiverTransfer(h.sender.deviceId)?.status;
          return status == TransferStatus.failed ||
              status == TransferStatus.cancelled ||
              status == null;
        },
        timeout: const Duration(seconds: 45),
        reason: 'receiver reaches a terminal state after the sender cancels',
      );
      print('FA-08 receiver terminal status after cancel: '
          '${h.receiverTransfer(h.sender.deviceId)?.status}');

      final residue = (await h.receiver.downloadedNames())
          .where((n) => n.endsWith('.bin'))
          .toList();
      expect(residue, isEmpty,
          reason: 'a cancelled transfer must not leave finished files');
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
