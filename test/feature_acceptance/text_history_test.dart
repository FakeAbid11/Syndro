@Tags(<String>['acceptance'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/database/database_helper.dart';
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-07 and FA-09 — text sharing through the real sender, and the history rows
/// both devices persist afterwards.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  /// Text shares go through the same approval handshake as files
  /// (`approveTransfer` routes `pending.isText` to `_deliverText`).
  ///
  /// Returns the sender's error, if any: the rejection is converted to a value
  /// here so it cannot escape the test as an unhandled async error before the
  /// receiver-side assertions have had a chance to run.
  Future<Object?> sendTextCapturingError(
    TwoNodeHarness h,
    String text,
  ) async {
    Object? failure;
    final future = h.sender.service
        .sendText(h.receiver.asDevice(), text)
        .catchError((Object e) {
      failure = e;
      return '';
    });
    await h.approveNextPending();
    await future;
    return failure;
  }

  group('FA-07 text share', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('an approved text must not be reported to the sender as rejected',
        () async {
      const payload = 'hello from the acceptance test';
      final received = <String>[];
      final sub =
          h.receiver.service.receivedTextStream.listen((m) => received.add(m.text));

      final senderError = await sendTextCapturingError(h, payload);

      await waitUntil(
        () => received.isNotEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'the receiver should still stream the text it accepted',
      );
      expect(received.first, payload, reason: 'content must arrive intact');
      await sub.cancel();

      // The delivery above proves the receiver accepted and saved the note; if
      // the sender still errors, the handshake is misreporting a success.
      // approveTransfer removes the pending request
      // (transfer_service_impl.dart:1908) and only registers
      // _activeTransfers[requestId] inside _deliverText after writing the note
      // file, so the sender's first poll lands in a window where the receiver
      // answers "rejected" for a request it has just approved.
      expect(senderError, isNull,
          reason: 'the receiver delivered the note but told the sender it was '
              'rejected: $senderError');
    });

    test('unicode text survives the round trip', () async {
      const payload = 'Ünïcödé ✓ 日本語 — ok';
      final received = <String>[];
      final sub =
          h.receiver.service.receivedTextStream.listen((m) => received.add(m.text));

      final senderError = await sendTextCapturingError(h, payload);

      await waitUntil(
        () => received.isNotEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'unicode text should still arrive',
      );
      expect(received.first, payload);
      expect(senderError, isNull, reason: '$senderError');
      await sub.cancel();
    });
  });

  group('FA-09 history rows', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('both ends persist a completed row for a successful send', () async {
      final payload = await writePayload(h.sender.workDir, 'logged.bin', 64 * 1024);

      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: [itemFor(payload)],
        encrypted: false,
      );
      final requestId = await h.approveNextPending();
      await sendFuture;
      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        reason: 'receiver completes before history is judged',
      );

      final senderTransfer = h.senderTransfer(h.receiver.deviceId)!;
      final senderRow =
          await DatabaseHelper.instance.getTransferById(senderTransfer.id);
      expect(senderRow, isNotNull, reason: 'sender wrote no history row');
      expect(senderRow!['status'], 'completed');
      expect(senderRow['file_count'], 1);
      expect(senderRow['total_bytes'], 64 * 1024);

      // The receiver keys its row by the request id it was given.
      final receiverRow =
          await DatabaseHelper.instance.getTransferById(requestId);
      expect(receiverRow, isNotNull,
          reason: 'receiver wrote no history row for the receive');
      expect(receiverRow!['status'], 'completed');

      final senderItems = await recordedItems(senderTransfer.id);
      expect(senderItems, hasLength(1));
      expect(senderItems.single['file_path'], payload.path,
          reason: 'the sender must record the file it actually sent');
    });
  });
}
