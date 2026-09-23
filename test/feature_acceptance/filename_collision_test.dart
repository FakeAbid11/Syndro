@Tags(<String>['acceptance'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-04 — gate item #3: receiving a file whose name already exists must not
/// destroy what the user already had.
///
/// The parallel writer has always de-duplicated (`chunk_writer_service.dart`,
/// `_resolveUniqueFinalPath`). The sequential receive path used to delete the
/// existing file and rename over it; it now routes through
/// `FileService.moveFileIntoPlace`, so the whole group should stay green.
///
/// FA-04b still fails, but for a different reason: parallel transfers never get
/// this far because of the approval-window race documented in
/// `parallel_completion_test.dart`.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  const originalUserBytes = 'THE USER OWNED THIS FILE BEFORE THE TRANSFER';

  Future<void> seedExisting(SyndroNode receiver, String name) =>
      receiver.downloaded(name).writeAsString(originalUserBytes, flush: true);

  Future<void> sendTo(
    TwoNodeHarness h,
    String name,
    int size, {
    bool encrypted = false,
  }) async {
    final payload = await writePayload(h.sender.workDir, name, size);
    final sendFuture = h.sender.service.sendFiles(
      sender: h.sender.asDevice(),
      receiver: h.receiver.asDevice(),
      items: [itemFor(payload)],
      encrypted: encrypted,
    );
    await h.approveNextPending();
    await sendFuture;
    await waitUntil(
      () {
        final status = h.receiverTransfer(h.sender.deviceId)?.status;
        return status == TransferStatus.completed ||
            status == TransferStatus.failed;
      },
      reason: 'colliding transfer reaches a terminal state',
    );
  }

  /// 12 MB in one item crosses `parallel_config`'s threshold — the same size
  /// `phase1_correctness_test.dart:280` uses to force the parallel path.
  const parallelSize = 12 * 1024 * 1024;

  group('FA-04 sequential receive onto an existing filename', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('the user file must survive a same-name receive', () async {
      await seedExisting(h.receiver, 'photo.jpg');
      await sendTo(h, 'photo.jpg', 8192);

      expect(h.receiverTransfer(h.sender.deviceId)?.status,
          TransferStatus.completed,
          reason: 'sanity: the transfer itself must succeed');

      final survivor = await h.receiver.downloaded('photo.jpg').readAsBytes();
      expect(survivor, utf8.encode(originalUserBytes),
          reason: 'gate #3: the sequential receive deletes the existing file '
              'and renames over it, so an incoming "photo.jpg" destroys the '
              'user\'s own "photo.jpg"');
    });

    test('records today\'s behaviour: the incoming file is de-duplicated',
        () async {
      await seedExisting(h.receiver, 'photo.jpg');
      await sendTo(h, 'photo.jpg', 8192);

      // P0-2 changed this from "the incoming file wins outright": the original
      // must survive AND the incoming copy must exist alongside it.
      final originals = await h.receiver.downloaded('photo.jpg').readAsBytes();
      expect(originals, utf8.encode(originalUserBytes),
          reason: 'the pre-existing file is still the user\'s own');
      final names = await h.receiver.downloadedNames();
      expect(names, contains('photo (1).jpg'),
          reason: 'the received copy should land as photo (1).jpg; dir holds '
              '$names');
      expect(await File(p.join(h.receiver.downloadDir.path, 'photo (1).jpg'))
          .length(), 8192);
    });

    test('the same overwrites through the encrypted path too', () async {
      await seedExisting(h.receiver, 'secure.txt');
      await sendTo(h, 'secure.txt', 8192, encrypted: true);

      expect(
          await h.receiver.downloaded('secure.txt').readAsBytes(),
          utf8.encode(originalUserBytes),
          reason: 'gate #3 (encrypted branch, transfer_service_impl.dart'
              ':2338-2341)');
    });
  });

  group('FA-04b parallel receive onto an existing filename', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('the parallel writer de-duplicates instead of clobbering', () async {
      await seedExisting(h.receiver, 'photo.jpg');
      await sendTo(h, 'photo.jpg', parallelSize);

      final receiver = h.receiverTransfer(h.sender.deviceId);
      expect(receiver?.status, TransferStatus.completed,
          reason: 'the parallel receive must complete before its bookkeeping '
              'is judged');

      expect(await h.receiver.downloaded('photo.jpg').readAsBytes(),
          utf8.encode(originalUserBytes),
          reason: 'the user file must be untouched');
      final names = await h.receiver.downloadedNames();
      expect(names, contains('photo (1).jpg'),
          reason: 'the incoming copy should be de-duplicated; dir holds '
              '$names');
    });

    test('names recorded for a transfer must describe a file that exists',
        () async {
      await seedExisting(h.receiver, 'photo.jpg');
      await sendTo(h, 'photo.jpg', parallelSize);

      final transferId = h.receiverTransfer(h.sender.deviceId)!.id;
      final items = await recordedItems(transferId);
      expect(items, isNotEmpty, reason: 'the receive wrote no history items');

      for (final item in items) {
        final recorded = item['file_path'] as String?;
        expect(recorded, isNotNull,
            reason: 'a receive has to record where the file went');
        // Both nodes share one filesystem here, so "the path exists" proves
        // nothing. Assert the recorded path is inside the RECEIVER's directory.
        final recordedDir = p.dirname(File(recorded!).absolute.path);
        expect(
          p.equals(recordedDir, h.receiver.downloadDir.absolute.path),
          isTrue,
          reason: 'gate #3-b: the receiver recorded "$recorded", which is not '
              'inside its own downloads dir '
              '"${h.receiver.downloadDir.path}" — the de-duplicated save name '
              'never reaches the transfer record',
        );
      }
    });
  });
}
