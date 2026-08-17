import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/services/app_settings_service.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';
import 'package:syndro/core/services/transfer_service/models.dart';

/// Proves the text-message transfer pipeline against the real
/// `TransferService.startServer` HTTP server on loopback:
///   1. A text POST from an unknown sender is queued for approval.
///   2. Approving the request delivers the message: a .txt note is saved
///      under the download dir (Syndro Notes), the transfer completes and
///      the message is streamed to the UI.
///   3. A trusted sender with auto-accept enabled is delivered immediately
///      (no approval prompt, no pending request).
///   4. Malformed/oversized payloads are rejected.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Stub flutter_secure_storage so identity/token/trust persistence are
  // in-memory no-ops in the VM (same pattern as the other service tests).
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
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

  group('Text transfer', () {
    late TransferService service;
    late int port;
    final List<File> createdFiles = [];

    setUp(() async {
      service = TransferService(FileService());
      await service.initialize();
      port = 18767;
      await service.startServer(port);
    });

    tearDown(() async {
      await service.dispose();
      // Remove notes created during the tests.
      for (final file in createdFiles) {
        try {
          if (await file.exists()) await file.delete();
        } catch (_) {}
      }
      createdFiles.clear();
      final downloadDir = await FileService().getDownloadDirectory();
      final notesDir =
          Directory('$downloadDir${Platform.pathSeparator}Syndro Notes');
      try {
        if (await notesDir.exists() &&
            await notesDir.list().isEmpty) {
          await notesDir.delete();
        }
      } catch (_) {}
    });

    /// Sends a raw HTTP POST and returns the full response text.
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

    String textBody(String requestId, String senderId, String token,
            {String text = 'Hello from test'}) =>
        jsonEncode({
          'id': requestId,
          'senderId': senderId,
          'senderName': 'Test Sender',
          'senderToken': token,
          'text': text,
        });

    Future<String> sendText(
            String requestId, String senderId, String token,
            {String text = 'Hello from test'}) =>
        rawPostFull('/transfer/text', {
          'Content-Type': 'application/json',
          'x-device-id': senderId,
        }, textBody(requestId, senderId, token, text: text));

    test('unknown sender is queued for approval with the text attached',
        () async {
      final response = await sendText('txt-unknown-1', 'sender-unknown', 'tok');

      expect(response, contains('pending_approval'));
      expect(service.pendingRequests, hasLength(1));

      final pending = service.pendingRequests.first;
      expect(pending.isText, isTrue);
      expect(pending.textContent, 'Hello from test');
      expect(pending.fileCount, 0);
      expect(pending.totalSize, 0);
    });

    test('approving a text request delivers the message as a saved note',
        () async {
      final messages = <ReceivedTextMessage>[];
      final sub =
          service.receivedTextStream.listen(messages.add);

      final response = await sendText('txt-approve-1', 'sender-appr', 'tok');
      expect(response, contains('pending_approval'));

      await service.approveTransfer('txt-approve-1');

      expect(messages, hasLength(1));
      final message = messages.first;
      expect(message.senderId, 'sender-appr');
      expect(message.senderName, 'Test Sender');
      expect(message.text, 'Hello from test');
      expect(message.filePath, endsWith('.txt'));
      expect(message.filePath, contains('Syndro Notes'));

      final saved = File(message.filePath);
      expect(await saved.exists(), isTrue);
      expect(await saved.readAsString(), 'Hello from test');
      createdFiles.add(saved);

      final active = service.activeTransfers
          .where((t) => t.id == 'txt-approve-1')
          .toList();
      expect(active, hasLength(1));
      expect(active.first.status.name, 'completed');
      expect(active.first.items.single.name, endsWith('.txt'));

      await sub.cancel();
    });

    test('approval poll reports accepted once the text is delivered',
        () async {
      await sendText('txt-poll-1', 'sender-poll', 'tok');
      await service.approveTransfer('txt-poll-1');

      final socket = await Socket.connect('127.0.0.1', port);
      socket.write('GET /transfer/approval/txt-poll-1 HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Connection: close\r\n'
          '\r\n');
      final poll =
          await socket.cast<List<int>>().transform(utf8.decoder).join();
      await socket.close();

      expect(poll, contains('"status":"approved"'));
      expect(poll, contains('"transferId":"txt-poll-1"'));
    });

    test('trusted sender with auto-accept is delivered without a prompt',
        () async {
      await AppSettingsService().setAutoAcceptTrusted(true);

      // First contact: queued, then accepted + trusted.
      final first = await sendText('txt-trust-1', 'sender-trusted', 'tok-t');
      expect(first, contains('pending_approval'));
      await service.approveTransfer('txt-trust-1', trustSender: true);
      expect(service.trustedDevices, hasLength(1));

      // Second contact: delivered immediately.
      final messages = <ReceivedTextMessage>[];
      final sub = service.receivedTextStream.listen(messages.add);

      final second =
          await sendText('txt-trust-2', 'sender-trusted', 'tok-t',
              text: 'Second message');
      expect(second, contains('"status":"accepted"'));
      expect(second, isNot(contains('pending_approval')));
      expect(service.pendingRequests, isEmpty);

      await Future.delayed(const Duration(milliseconds: 100));
      expect(messages, hasLength(1));
      expect(messages.first.text, 'Second message');
      createdFiles.add(File(messages.first.filePath));

      await sub.cancel();
    });

    test('empty text is rejected with 400', () async {
      final response =
          await sendText('txt-empty-1', 'sender-empty', 'tok', text: '   ');
      expect(response, contains('400'));
      expect(service.pendingRequests, isEmpty);
    });

    test('oversized text is rejected with 400', () async {
      final bigText = 'a' * (64 * 1024 + 1);
      final response =
          await sendText('txt-big-1', 'sender-big', 'tok', text: bigText);
      expect(response, contains('400'));
      expect(service.pendingRequests, isEmpty);
    });

    test('retried text request is not queued twice', () async {
      final first = await sendText('txt-retry-1', 'sender-retry', 'tok');
      expect(first, contains('pending_approval'));

      final second = await sendText('txt-retry-1', 'sender-retry', 'tok');
      expect(second, contains('pending_approval'));
      expect(service.pendingRequests, hasLength(1));
    });
  });
}