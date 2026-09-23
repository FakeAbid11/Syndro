@Tags(<String>['acceptance'])
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:syndro/core/services/web_share/servers/receive_server.dart';

import 'harness.dart';

/// Browser-to-app receive mode.
///
/// `web_share/` had no tests at all before this file: the only `web_share`
/// import anywhere under `test/` was the multipart parser. The first group
/// drives the real server over real HTTP so it runs in CI; the second group is
/// driven by a real browser and is opt-in, because it needs an external driver
/// and must never hang a build.
///
/// Enable the browser group with:
///   FA_BROWSER_HARNESS=1 flutter test test/feature_acceptance/web_receive_test.dart
/// It then publishes a handshake file and waits for a human or agent to open
/// the URL and upload `upload-me.bin`.
void main() {
  setUpAll(installAcceptanceBootstrap);
  tearDownAll(uninstallAcceptanceBootstrap);

  const browserFlagVar = 'FA_BROWSER_HARNESS';

  late Directory receiveDir;
  late ReceiveServer server;

  setUp(() async {
    receiveDir = await Directory.systemTemp.createTemp('syndro-web-receive');
    server = ReceiveServer();
  });

  tearDown(() async {
    await server.stop();
    if (await receiveDir.exists()) {
      await receiveDir.delete(recursive: true);
    }
  });

  group('receive server over HTTP', () {
    test('a browser-style multipart upload lands on disk with its bytes',
        () async {
      var confirmations = 0;
      // `UploadPendingConfirmation` carries no id field, so the only way for an
      // outside caller to approve is the emitted instance itself — the same one
      // the server's approval poll re-reads from its map.
      server.uploadConfirmationRequestStream.listen((confirmation) {
        confirmations++;
        confirmation.confirmed = true;
      });

      final url = await server.startReceiving(receiveDir.path);
      expect(url, isNotNull, reason: 'the receive server must report its URL');

      const fileName = 'browser-upload.bin';
      final body = List<int>.generate(4096, (i) => i % 251);
      final boundary = '----syndrofa${DateTime.now().microsecondsSinceEpoch}';

      final status = await _postMultipart(
        Uri.parse(url!),
        boundary: boundary,
        fileName: fileName,
        field: 'files[]',
        bytes: body,
      );

      expect(status, 200, reason: 'the upload was not accepted (got $status)');

      // The committed file is the observable that matters; where the server
      // stages it first (pending list vs straight to the receive directory) is
      // an implementation detail, so accept either.
      await waitUntil(
        () => File(p.join(receiveDir.path, fileName)).existsSync() ||
            server.pendingFilesManager.pendingFiles.isNotEmpty,
        timeout: const Duration(seconds: 15),
        reason: 'the confirmed upload should reach the server; receiveDir '
            'holds ${(await receiveDir.list(recursive: true).toList())
                .map((e) => e.path)}',
      );

      final staged = server.pendingFilesManager.pendingFiles;
      if (staged.isNotEmpty) {
        final received = staged.first;
        expect(received.name, fileName);
        expect(received.size, body.length);
        expect(await File(received.tempPath).readAsBytes(), body,
            reason: 'uploaded bytes must be preserved through the parser');
        expect(await server.pendingFilesManager.saveFile(received), isTrue,
            reason: 'saveFile must commit a pending upload');
        expect(received.finalPath, isNotNull,
            reason: 'a saved file must record where it went');
        expect(await File(received.finalPath!).readAsBytes(), body);
      } else {
        final landed = File(p.join(receiveDir.path, fileName));
        expect(await landed.readAsBytes(), body,
            reason: 'the upload written straight to the receive directory '
                'must be byte-identical');
      }
      expect(confirmations, greaterThan(0),
          reason: 'an upload confirmation should have been requested');
    });

    test('an upload filename cannot escape the receive directory', () async {
      server.uploadConfirmationRequestStream
          .listen((c) => c.confirmed = true);
      final url = await server.startReceiving(receiveDir.path);

      const traversal = '../../../evil.txt';
      final status = await _postMultipart(
        Uri.parse(url!),
        boundary: '----syndrofa-traversal',
        fileName: traversal,
        field: 'files[]',
        bytes: utf8.encode('escaped'),
      );
      expect(status, anyOf(200, 400), reason: 'a rejection is fine too');

      // Whatever it accepted, nothing may land outside the receive directory.
      final escaped = File(p.join(receiveDir.path, '..', '..', 'evil.txt'));
      expect(await escaped.exists(), isFalse,
          reason: 'a traversal filename wrote outside the receive dir');
      for (final entity in await receiveDir.list(recursive: true).toList()) {
        expect(
          p.basename(entity.path),
          isNot(contains('..')),
          reason: 'traversal sequence survived into ${entity.path}',
        );
      }
    });

    test(
        'an upload that is never confirmed must not reach the disk '
        '(fail-closed check)', () async {
      // `isUploadAllowed` returns true when no confirmation entry exists
      // (receive_server.dart:130-134) — the sibling share server was fixed to
      // fail closed and documents why at share_server.dart:181-193. This checks
      // whether that latent branch is actually reachable from the network: no
      // listener approves anything here.
      final url = await server.startReceiving(receiveDir.path);

      // Fire and forget: the handler parks polling for approval for up to two
      // minutes, so awaiting it would just time the test out.
      unawaited(_postMultipart(
        Uri.parse(url!),
        boundary: '----syndrofa-noconfirm',
        fileName: 'unconfirmed.bin',
        field: 'files[]',
        bytes: utf8.encode('never approved'),
      ).catchError((Object _) => -1));

      await Future<void>.delayed(const Duration(seconds: 5));
      final landed = (await receiveDir.list(recursive: true).toList())
          .whereType<File>()
          .where((f) => p.basename(f.path).contains('unconfirmed'))
          .toList();
      expect(landed, isEmpty,
          reason: 'an unapproved upload was written to disk anyway');
      expect(server.pendingFilesManager.pendingFiles, isEmpty,
          reason: 'an unapproved upload should not be staged either');
    }, timeout: const Timeout(Duration(seconds: 45)));
  });

  group('receive server driven by a real browser', () {
    test('a human-driven upload through the served page arrives intact',
        () async {
      // Skipped unless the flag is set, so CI can never hang on the handshake.
      // bool.fromEnvironment is compile-time; use the process env for a
      // run-time opt-in instead.
      if (!Platform.environment.containsKey(browserFlagVar)) {
        markTestSkipped('set $browserFlagVar=1 to drive a real browser');
        return;
      }

      server.uploadConfirmationRequestStream
          .listen((c) => c.confirmed = true);
      final url = await server.startReceiving(receiveDir.path);
      expect(url, isNotNull);

      final handshake = File(p.join(
          Directory.systemTemp.path, 'syndro-browser-harness.json'));
      final payload = jsonEncode(<String, String>{
        'url': url!,
        'expect': 'upload-me.bin',
      });
      await handshake.writeAsString('$payload\n', flush: true);

      // The browser is the thing that satisfies this: it opens the page, picks
      // upload-me.bin and submits. 4 minutes, then it fails rather than hangs.
      await waitUntil(
        () => server.pendingFilesManager.pendingFiles.isNotEmpty,
        timeout: const Duration(minutes: 4),
        reason: 'no upload arrived from the browser',
      );

      final received = server.pendingFilesManager.pendingFiles.first;
      final bytes = await File(received.tempPath).readAsBytes();
      expect(bytes, isNotEmpty, reason: 'the browser uploaded an empty file');
      expect(received.name, isNotEmpty);
      print('BROWSER UPLOAD received: ${received.name} ${received.size} bytes '
          '-> ${received.tempPath}');
      await handshake.delete();
    }, timeout: const Timeout(Duration(minutes: 6)));
  });
}

/// POSTs a single-file multipart/form-data body to [path] over a raw socket and
/// returns the response status code.
Future<int> _postMultipart(
  Uri base, {
  String path = '/upload',
  required String boundary,
  required String fileName,
  required String field,
  required List<int> bytes,
}) async {
  final header = '--$boundary\r\n'
      'Content-Disposition: form-data; name="$field"; filename="$fileName"\r\n'
      'Content-Type: application/octet-stream\r\n\r\n';
  final trailer = '\r\n--$boundary--\r\n';
  final body = <int>[
    ...utf8.encode(header),
    ...bytes,
    ...utf8.encode(trailer),
  ];

  final socket = await Socket.connect(base.host, base.port);
  try {
    socket.write('POST $path HTTP/1.1\r\n'
        'Host: ${base.host}:${base.port}\r\n'
        'Content-Type: multipart/form-data; boundary=$boundary\r\n'
        'Content-Length: ${body.length}\r\n'
        'Connection: close\r\n\r\n');
    socket.add(body);
    await socket.flush();

    final response = <int>[];
    await for (final chunk in socket.timeout(const Duration(seconds: 30))) {
      response.addAll(chunk);
    }
    final first = utf8.decode(response, allowMalformed: true)
        .split('\r\n')
        .first;
    return int.tryParse(first.split(' ').elementAtOrNull(1) ?? '') ?? -1;
  } finally {
    socket.destroy();
  }
}
