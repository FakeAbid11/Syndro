@Tags(<String>['acceptance'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-05 — gate item #4: a parallel transfer must report the same outcome on
/// both ends.
///
/// The original hypothesis was the 10 s completion-ack timeout in
/// `parallel_transfer_service.dart:547` racing a whole-file hash on the
/// receiver. Running this exposed a much earlier and size-independent cause:
/// `approveTransfer` removes the pending request at
/// `transfer_service_impl.dart:1908` and only registers `_activeTransfers[id]`
/// at `:1980`, with `await`s in between (key exchange, and
/// `handleInitiate`'s file pre-allocation). `_handleApprovalCheck` (`:1855-1875`)
/// answers `rejected` when neither exists, and the sender's 500 ms poll
/// (`parallel_transfer_service.dart:576-608`) treats `rejected` as terminal.
/// So every parallel transfer is exposed to a window in which approving it
/// makes the sender abort.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  group('FA-05 parallel single-file transfer', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('a 12 MB file completes on both ends with matching bytes', () async {
      final payload =
          await writePayload(h.sender.workDir, 'big.bin', 12 * 1024 * 1024);
      final sourceHash = await sha256OfFile(payload.path);

      final started = DateTime.now();
      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: [itemFor(payload)],
        encrypted: false,
      );
      await h.approveNextPending();
      try {
        await sendFuture;
      } on Object catch (e) {
        fail('gate #4: the sender aborted a parallel transfer it should have '
            'completed. Approved at the receiver, then rejected by the '
            'approval poll — see the header of this file for the '
            'transfer_service_impl.dart:1908/1980 window. Error was: $e');
      }
      final senderDoneAt = DateTime.now().difference(started);

      // The receiver's own record must reach completed too — a sender-only
      // success is exactly the gate #4 mismatch.
      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        timeout: const Duration(seconds: 45),
        reason: 'receiver marks the parallel transfer completed',
      );

      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.completed,
          reason: 'sender must agree; it took $senderDoneAt');

      final landed = h.receiver.downloaded('big.bin');
      expect(await landed.exists(), isTrue,
          reason: 'parallel receive produced no file; dir holds '
              '${await h.receiver.downloadedNames()}');
      expect(await landed.length(), 12 * 1024 * 1024);
      expect(await sha256OfFile(landed.path), sourceHash,
          reason: 'reassembled chunks do not reproduce the source');

      // Evidence for the gate #4 timing analysis: how long the end-to-end
      // parallel send takes at this size, against the 10 s ack budget.
      print('FA-05 12MB parallel end-to-end: $senderDoneAt');
    });
  });

  group('FA-05b encrypted parallel transfer', () {
    late TwoNodeHarness h;

    setUp(() async {
      // Encryption must be enabled on the node, not just requested per call:
      // sendFiles computes `shouldEncrypt && encryptionEnabled`, so asking for
      // encryption on a node with the flag off falls through to plaintext.
      h = await TwoNodeHarness.start();
    });

    tearDown(() => h.dispose());

    test('a 12 MB file also completes through the encrypted parallel path',
        () async {
      final payload =
          await writePayload(h.sender.workDir, 'big.enc', 12 * 1024 * 1024);
      final sourceHash = await sha256OfFile(payload.path);

      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: [itemFor(payload)],
        encrypted: true,
      );
      await h.approveNextPending();
      await sendFuture;

      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        timeout: const Duration(seconds: 45),
        reason: 'encrypted parallel receive completes',
      );

      final landed = h.receiver.downloaded('big.enc');
      expect(await landed.exists(), isTrue);
      expect(await sha256OfFile(landed.path), sourceHash);
    });
  });
}
