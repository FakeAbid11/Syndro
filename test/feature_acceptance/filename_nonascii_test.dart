@Tags(<String>['acceptance'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/transfer.dart';

import 'harness.dart';

/// FA-03 — gate item #2: non-ASCII filenames.
///
/// `dart:io`'s `HttpHeaders` rejects code units >= 128, so a name like
/// `café.jpg` used to abort the whole send with a FormatException. The fix in
/// flight percent-encodes the real name into `x-file-name-enc` and keeps an
/// ASCII rendering in the legacy header.
///
/// Run against `HEAD` (without `http_header_codec.dart` and the
/// `transfer_service_impl.dart` change) these must go red — that is the proof
/// the codec is what makes them pass.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  Future<void> sendAndAwaitName(
    TwoNodeHarness h,
    String name,
    int size,
  ) async {
    final payload = await writePayload(h.sender.workDir, name, size);

    final sendFuture = h.sender.service.sendFiles(
      sender: h.sender.asDevice(),
      receiver: h.receiver.asDevice(),
      items: [itemFor(payload)],
      encrypted: false,
    );
    await h.approveNextPending();
    await sendFuture;

    await waitUntil(
      () => h.receiverTransfer(h.sender.deviceId)?.status ==
          TransferStatus.completed,
      reason: 'receiver completes the send of "$name"',
    );

    final landed = h.receiver.downloaded(name);
    expect(await landed.exists(), isTrue,
        reason: 'the received file is not named "$name" on disk; the '
            'downloads dir actually holds '
            '${await h.receiver.downloadedNames()}');
    expect(await sha256OfFile(landed.path), await sha256OfFile(payload.path),
        reason: 'payload changed while crossing the wire for "$name"');
  }

  group('FA-03 non-ASCII filenames', () {
    late TwoNodeHarness h;

    setUp(() async {
      h = await TwoNodeHarness.start(
        senderEncryption: false,
        receiverEncryption: false,
      );
    });

    tearDown(() => h.dispose());

    test('an accented name survives end to end', () async {
      await sendAndAwaitName(h, 'café.jpg', 4096);
    });

    test('a CJK name survives end to end', () async {
      await sendAndAwaitName(h, '日本語.txt', 4096);
    });

    test('a mixed script and space name survives end to end', () async {
      await sendAndAwaitName(h, 'Ñoño — résumé PDF.docx', 4096);
    });

    test('the wire header itself stays ASCII-only', () async {
      // The legacy header must never carry a code unit >= 128, because that is
      // what threw before the codec existed. Assert the rendering the sender
      // produces rather than trusting the transfer to imply it.
      const name = 'café.jpg';
      final rendered = asciiRenderedFileName(name);
      expect(rendered.codeUnits.every((u) => u < 128), isTrue,
          reason: 'ASCII fallback header must be pure ASCII');
      expect(rendered.length, name.length,
          reason: 'the fallback keeps the name shape so a legacy peer can '
              'still recognise it');
    });

    test('an emoji name survives end to end', () async {
      // Emoji are non-BMP: two UTF-16 code units per character. If the encoder
      // or the sanitizer splits a surrogate pair the name comes back wrong.
      await sendAndAwaitName(h, 'party🎉.png', 2048);
    });
  });
}
