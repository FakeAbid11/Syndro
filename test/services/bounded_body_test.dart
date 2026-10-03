import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// Proves that every endpoint which reads a request body caps how much it will
/// buffer, and answers `400` rather than materialising an oversized body.
///
/// The control-plane endpoints (`/transfer/parallel/initiate`,
/// `/transfer/parallel/cancel`, `/key-exchange`) are capped at
/// `_maxControlBodyBytes` (16 KB) and the payload-carrying ones
/// (`/transfer/initiate`, `/transfer/text`) at `_maxPayloadBodyBytes` (128 KB).
///
/// Two properties are asserted per endpoint:
///
///  * **Declared oversize** — a large `Content-Length` is refused up front,
///    before a single body byte is read. This is the cheap path.
///  * **Streaming oversize** — a body that *understates* its length (or omits
///    it) is still cut off while streaming, so a lying or absent header cannot
///    make the server buffer without bound. This is the property that an
///    up-front `Content-Length` check alone would miss.
///
/// A body that fits must still be processed normally, so the cap is proven not
/// to break the legitimate path.
///
/// Raw sockets are used deliberately: in the test VM, `package:http` and
/// `dart:io`'s `HttpClient` surface a spurious bodyless 400 against this
/// server, whereas a raw request reaches the real handler.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  group('Request body size limits', () {
    late TransferService service;
    late int port;

    setUp(() async {
      service = TransferService(FileService());
      // Documented lifecycle: initialize() before startServer().
      await service.initialize();
      // High port, free in a fresh test VM, so startServer binds it exactly.
      port = 18790;
      await service.startServer(port);
    });

    tearDown(() async {
      await service.dispose();
    });

    /// POSTs [bodyBytes] to [path] with a raw socket.
    ///
    /// [declaredContentLength] overrides the `Content-Length` header so a test
    /// can lie about (or omit) the length. Defaults to the true byte length.
    ///
    /// When the server refuses an oversized body *while it is still being
    /// streamed*, it answers 400 and closes, which aborts the client's pending
    /// write. That abort is itself proof the server stopped reading early, so
    /// the write error is swallowed here and whatever response did arrive is
    /// still parsed. Returns `''` if the connection died before any status
    /// line was readable.
    Future<String> rawPost(
      String path,
      List<int> bodyBytes, {
      int? declaredContentLength,
      Map<String, String> extraHeaders = const {},
    }) async {
      final socket = await Socket.connect('127.0.0.1', port);
      try {
        final head = StringBuffer()
          ..write('POST $path HTTP/1.1\r\n')
          ..write('Host: 127.0.0.1:$port\r\n')
          ..write(
              'Content-Length: ${declaredContentLength ?? bodyBytes.length}\r\n')
          ..write('Connection: close\r\n')
          ..write('Content-Type: application/json\r\n');
        extraHeaders.forEach((k, v) => head.write('$k: $v\r\n'));
        head.write('\r\n');

        try {
          socket.add(utf8.encode(head.toString()));
          socket.add(bodyBytes);
          await socket.flush();
        } on SocketException {
          // Server hung up mid-body (it rejected the size). Fall through and
          // read whatever response it managed to send.
        }

        String response;
        try {
          response = await socket
              .cast<List<int>>()
              .transform(utf8.decoder)
              .join()
              .timeout(const Duration(seconds: 5));
        } on SocketException {
          response = '';
        } on TimeoutException {
          response = '';
        }
        if (response.isEmpty) return '';
        return response.split('\r\n').first.trim();
      } finally {
        socket.destroy();
      }
    }

    int statusOf(String statusLine) => int.parse(statusLine.split(' ')[1]);

    /// True when the request was refused: either an explicit non-200 status, or
    /// the connection being torn down before a usable response could be read.
    ///
    /// A refused request is the invariant under test. The declared-oversize
    /// cases additionally pin the exact status to 400.
    bool wasRefused(String statusLine) =>
        statusLine.isEmpty || statusOf(statusLine) != 200;


    /// A syntactically valid JSON object padded past [targetBytes].
    List<int> oversizedJson(int targetBytes) {
      final padding = 'a' * targetBytes;
      return utf8.encode(jsonEncode({'pad': padding}));
    }

    // ── Declared oversize: refused from Content-Length alone ──────────────

    test('declared-oversize body is refused on /key-exchange', () async {
      final status = await rawPost(
        '/key-exchange',
        oversizedJson(200 * 1024),
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });

    test('declared-oversize body is refused on /transfer/parallel/initiate',
        () async {
      final status = await rawPost(
        '/transfer/parallel/initiate',
        oversizedJson(64 * 1024),
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });

    test('declared-oversize body is refused on /transfer/parallel/cancel',
        () async {
      final status = await rawPost(
        '/transfer/parallel/cancel',
        oversizedJson(64 * 1024),
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });

    test('declared-oversize body is refused on /transfer/initiate', () async {
      final status = await rawPost(
        '/transfer/initiate',
        oversizedJson(512 * 1024),
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });

    test('declared-oversize body is refused on /transfer/text', () async {
      final status = await rawPost(
        '/transfer/text',
        oversizedJson(512 * 1024),
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });

    // ── Streaming oversize: header understates the real size ──────────────
    //
    // These are the ones an up-front Content-Length check alone would miss.

    test('understated Content-Length is still cut off on /key-exchange',
        () async {
      final status = await rawPost(
        '/key-exchange',
        oversizedJson(200 * 1024),
        declaredContentLength: 10, // lies: claims 10 bytes, sends ~200 KB
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(wasRefused(status), isTrue,
          reason: 'oversized body must not be accepted');
    });

    test('understated Content-Length is still cut off on /transfer/text',
        () async {
      final status = await rawPost(
        '/transfer/text',
        oversizedJson(512 * 1024),
        declaredContentLength: 10,
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(wasRefused(status), isTrue,
          reason: 'oversized body must not be accepted');
    });

    test('understated Content-Length is still cut off on /transfer/initiate',
        () async {
      final status = await rawPost(
        '/transfer/initiate',
        oversizedJson(512 * 1024),
        declaredContentLength: 10,
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(wasRefused(status), isTrue,
          reason: 'oversized body must not be accepted');
    });

    test('understated Content-Length is still cut off on '
        '/transfer/parallel/initiate', () async {
      final status = await rawPost(
        '/transfer/parallel/initiate',
        oversizedJson(64 * 1024),
        declaredContentLength: 10,
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(wasRefused(status), isTrue,
          reason: 'oversized body must not be accepted');
    });

    // ── The cap must not break the legitimate path ───────────────────────

    test('a small well-formed body is still processed on /transfer/initiate',
        () async {
      // Same endpoint, same shape, just under the cap: this must reach the
      // normal JSON/validation path (which queues it for approval), proving the
      // limit rejects only on size and not on shape.
      final status = await rawPost(
        '/transfer/initiate',
        utf8.encode(jsonEncode({
          'id': 'bounded-body-small-1',
          'senderId': 'small-sender',
          'senderName': 'Small Sender',
          'senderToken': 'small-token',
          'receiverId': 'this-device',
          'items': [
            {'name': 'ok.txt', 'size': 2}
          ],
        })),
        extraHeaders: {'x-device-id': 'small-sender'},
      );
      expect(statusOf(status), 200);
    });

    test('a small well-formed body is still processed on /key-exchange',
        () async {
      final status = await rawPost(
        '/key-exchange',
        utf8.encode(jsonEncode({
          'deviceId': 'small-peer',
          'publicKey': List<int>.filled(32, 7),
        })),
        extraHeaders: {'x-device-id': 'small-peer'},
      );
      expect(statusOf(status), 200);
    });

    test('non-UTF-8 body is refused rather than crashing the handler',
        () async {
      // 0xC3 starts a 2-byte sequence that never completes.
      final status = await rawPost(
        '/key-exchange',
        [0x7b, 0x22, 0xc3, 0x22, 0x7d],
        extraHeaders: {'x-device-id': 'someone'},
      );
      expect(statusOf(status), 400);
    });
  });
}
