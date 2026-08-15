import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// Proves the B2 authorization gate: an upload to the real TransferService
/// HTTP server is rejected unless it carries valid, transfer-scoped auth
/// backed by an established encryption session.
///
/// This boots the actual `TransferService.startServer` on a loopback port and
/// hits `/transfer/upload` and `/transfer/chunk` with raw HTTP sockets, so it
/// exercises the production request handler (route gate + transfer-scoped
/// token check) rather than a reimplementation of it.
///
/// Raw sockets are used deliberately instead of package:http / dart:io
/// HttpClient: in the test VM those clients surface a spurious bodyless 400
/// against this server, whereas a raw request reaches the real handler and
/// observes its genuine 401 responses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Stub flutter_secure_storage so identity load/persist is a no-op in the VM.
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      // read/readAll → null/empty; write/delete → void.
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  group('Upload authorization (B2)', () {
    late TransferService service;
    late int port;

    setUp(() async {
      service = TransferService(FileService());
      // Match the documented lifecycle: initialize() before startServer().
      // (startServer only re-inits encryption/parallel handlers when the key
      // pair is still null, so initializing first avoids a double-init.)
      await service.initialize();
      // Fresh test VM: this high port is free, so startServer binds it exactly.
      port = 18765;
      await service.startServer(port);
    });

    tearDown(() async {
      await service.dispose();
    });

    /// Sends a raw HTTP POST and returns the parsed status line, e.g.
    /// `HTTP/1.1 401 Unauthorized`.
    Future<String> rawPost(
        String path, Map<String, String> headers, String body) async {
      final socket = await Socket.connect('127.0.0.1', port);
      final req = StringBuffer()
        ..write('POST $path HTTP/1.1\r\n')
        ..write('Host: 127.0.0.1:$port\r\n')
        ..write('Content-Length: ${utf8.encode(body).length}\r\n')
        ..write('Connection: close\r\n');
      headers.forEach((k, v) => req.write('$k: $v\r\n'));
      req
        ..write('\r\n')
        ..write(body);
      socket.write(req.toString());
      final response =
          await socket.cast<List<int>>().transform(utf8.decoder).join();
      await socket.close();
      return response.split('\r\n').first.trim();
    }

    int statusOf(String statusLine) =>
        int.parse(statusLine.split(' ')[1]);

    /// Sends a raw HTTP POST and returns the full response (status line +
    /// headers + body), for tests that need to assert on the response body.
    Future<String> rawPostFull(
        String path, Map<String, String> headers, String body) async {
      final socket = await Socket.connect('127.0.0.1', port);
      final req = StringBuffer()
        ..write('POST $path HTTP/1.1\r\n')
        ..write('Host: 127.0.0.1:$port\r\n')
        ..write('Content-Length: ${utf8.encode(body).length}\r\n')
        ..write('Connection: close\r\n');
      headers.forEach((k, v) => req.write('$k: $v\r\n'));
      req
        ..write('\r\n')
        ..write(body);
      socket.write(req.toString());
      final response =
          await socket.cast<List<int>>().transform(utf8.decoder).join();
      await socket.close();
      return response;
    }

    test('upload for an unapproved transfer is rejected (never 200)',
        () async {
      // With the per-handler authorization model there is no blanket route
      // gate: the upload handler itself rejects the request. A missing sender
      // token is a bad request (400); the invariant that matters is that an
      // unauthorized upload is NEVER accepted.
      final status = await rawPost('/transfer/upload', {
        'x-transfer-id': 'no-such-transfer',
        'x-file-name': 'evil.txt',
        'x-sender-id': 'attacker',
        // deliberately no x-sender-token
      }, 'malicious');

      expect(statusOf(status), isNot(200));
      expect(statusOf(status), 400);
    });

    test('transfer initiate is NOT blocked by a session gate (200, handshake)',
        () async {
      // Regression: a blanket "encryption session must already exist" route
      // gate used to 401 /transfer/initiate — the very request that ESTABLISHES
      // the session — deadlocking first contact so devices could never connect.
      // A fresh sender's initiate must be accepted into the pending-approval
      // handshake, not rejected.
      final response = await rawPostFull('/transfer/initiate', {
        'Content-Type': 'application/json',
        'x-device-id': 'brand-new-sender',
      }, jsonEncode({
        'id': 'handshake-transfer-1',
        'senderId': 'brand-new-sender',
        'senderName': 'Test Sender',
        'senderToken': 'first-contact-token',
        'receiverId': 'this-device',
        'items': [
          {'name': 'hello.txt', 'size': 5}
        ],
      }));

      final statusLine = response.split('\r\n').first.trim();
      expect(statusOf(statusLine), 200);
      // The receiver queues it for approval rather than auto-accepting an
      // unknown sender.
      expect(response, contains('pending_approval'));
    });

    test('upload with a forged session/token for an unapproved transfer is rejected (401)',
        () async {
      // A device id that was never key-exchanged plus a forged sender token
      // must not be accepted for an unknown transfer.
      final status = await rawPost('/transfer/upload', {
        'x-device-id': 'ghost-device',
        'x-transfer-id': 'no-such-transfer',
        'x-file-name': 'evil.txt',
        'x-file-size': '9',
        'x-sender-id': 'attacker',
        'x-sender-token': 'forged-token',
      }, 'malicious');

      expect(statusOf(status), 401);
    });

    test('a chunk upload without valid transfer-scoped auth is rejected (401)',
        () async {
      final status = await rawPost('/transfer/chunk', {
        'X-Device-Id': 'ghost-device',
        'X-Transfer-Id': 'no-such-transfer',
        'X-Chunk-Index': '0',
        'X-Sender-Id': 'attacker',
        'X-Sender-Token': 'forged-token',
      }, 'chunkdata');

      // Must never be accepted (200); the gate returns 401.
      expect(statusOf(status), isNot(200));
      expect(statusOf(status), 401);
    });
  });
}
