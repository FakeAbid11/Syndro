import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-01 — the product's core promise: pick files on one device, end up with
/// the same files on another.
///
/// This is the first test in the repository to move a real payload from a real
/// sender into the real receiver and check the bytes that land on disk.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  group('FA-01 sequential plaintext device to device', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    Future<void> sendOne(File payload, {String? asName}) async {
      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: [itemFor(payload, name: asName)],
        encrypted: false,
      );
      await h.approveNextPending();
      await sendFuture;
      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        reason: 'receiver marks the transfer completed',
      );
    }

    test('a 256 KB file arrives byte-identical under the same name', () async {
      final payload = await writePayload(h.sender.workDir, 'report.bin', 256*1024);
      final sourceHash = await sha256OfFile(payload.path);

      await sendOne(payload);

      final landed = h.receiver.downloaded('report.bin');
      expect(await landed.exists(), isTrue,
          reason: 'received file missing; downloads dir holds '
              '${await h.receiver.downloadedNames()}');
      expect(await landed.length(), 256 * 1024);
      expect(await sha256OfFile(landed.path), sourceHash,
          reason: 'payload altered in transit');
      expect(h.senderTransfer(h.receiver.deviceId)?.status,
          TransferStatus.completed,
          reason: 'sender must agree the transfer finished');
    });

    test('spaces and mixed case in the name survive the round trip', () async {
      final payload = await writePayload(h.sender.workDir, 'Q3 Budget FY.pdf', 4096);
      final sourceHash = await sha256OfFile(payload.path);

      await sendOne(payload);

      final landed = h.receiver.downloaded('Q3 Budget FY.pdf');
      expect(await landed.exists(), isTrue,
          reason: 'names must be preserved exactly, got '
              '${await h.receiver.downloadedNames()}');
      expect(await sha256OfFile(landed.path), sourceHash);
    });

    test('no scratch file is left behind in the receiver downloads dir',
        () async {
      final payload = await writePayload(h.sender.workDir, 'clean.bin', 8192);

      await sendOne(payload);

      final strays = (await h.receiver.downloadedNames())
          .where((n) => n != 'clean.bin')
          .toList();
      expect(strays, isEmpty,
          reason: 'temp/checkpoint residue leaked into the downloads dir');
    });

    test('five files in one send all arrive', () async {
      final items = <TransferItem>[];
      final hashes = <String, String>{};
      for (var i = 0; i < 5; i++) {
        final name = 'part-$i.dat';
        final file = await writePayload(h.sender.workDir, name, 128 * 1024);
        items.add(itemFor(file));
        hashes[name] = await sha256OfFile(file.path);
      }

      final sendFuture = h.sender.service.sendFiles(
        sender: h.sender.asDevice(),
        receiver: h.receiver.asDevice(),
        items: items,
        encrypted: false,
      );
      await h.approveNextPending();
      await sendFuture;
      await waitUntil(
        () => h.receiverTransfer(h.sender.deviceId)?.status ==
            TransferStatus.completed,
        reason: 'receiver completes a five-file send',
      );

      for (final entry in hashes.entries) {
        final landed = h.receiver.downloaded(entry.key);
        expect(await landed.exists(), isTrue, reason: 'missing ${entry.key}');
        expect(await sha256OfFile(landed.path), entry.value,
            reason: 'corrupt ${entry.key}');
      }
      expect(
        p.basename(h.receiver.downloadDir.path), isNotEmpty,
        reason: 'sanity: the receiver dir is a temp path, not Downloads',
      );
    });
  });
}
