@Tags(<String>['acceptance'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-02 — the encrypted device-to-device path: X25519 key exchange, AES-256-GCM
/// chunk encryption, and an integrity check performed by the receiver.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  group('FA-02 encrypted device to device', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start();
    });

    tearDown(() => h.dispose());

    test('a 256 KB file arrives intact through the encrypted path', () async {
      final payload = await writePayload(h.sender.workDir, 'secret.bin', 256*1024);
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
        reason: 'receiver completes an encrypted transfer',
      );

      final landed = h.receiver.downloaded('secret.bin');
      expect(await landed.exists(), isTrue,
          reason: 'encrypted receive saved nothing; dir holds '
              '${await h.receiver.downloadedNames()}');
      expect(await sha256OfFile(landed.path), sourceHash,
          reason: 'decrypted bytes differ from the source');
    });

    test('no scratch file survives an encrypted receive', () async {
      final payload = await writePayload(h.sender.workDir, 'clean.enc', 32 * 1024);

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
        reason: 'encrypted transfer completes',
      );

      final residue = (await h.receiver.downloadedNames())
          .where((n) => n.contains('.tmp'))
          .toList();
      expect(residue, isEmpty, reason: 'temp scratch left in downloads dir');
    });
  });
}
