import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syndro/core/services/app_settings_service.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// Proves the trusted-device auto-accept flow end-to-end against the real
/// `TransferService.startServer` HTTP server on loopback:
///   1. An unknown sender is queued for manual approval, never auto-accepted.
///   2. After the receiver approves with `trustSender: true`, a later
///      initiate from the same device (same token) is auto-accepted without
///      a prompt and without creating a pending request.
///   3. Auto-accept is gated by the settings toggle.
///   4. A token mismatch from a trusted id is NOT auto-accepted.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Stub flutter_secure_storage so identity/token/trust persistence are
  // in-memory no-ops in the VM (same pattern as upload_auth_rejection_test).
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
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

  group('Trusted-device auto-accept', () {
    late TransferService service;
    late int port;

    setUp(() async {
      service = TransferService(FileService());
      await service.initialize();
      port = 18766;
      await service.startServer(port);
    });

    tearDown(() async {
      await service.dispose();
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

    String initiateBody(String requestId, String senderId, String token) =>
        jsonEncode({
          'id': requestId,
          'senderId': senderId,
          'senderName': 'Test Sender',
          'senderToken': token,
          'receiverId': 'this-device',
          'items': [
            {'name': 'hello.txt', 'size': 5}
          ],
        });

    Future<String> initiate(
            String requestId, String senderId, String token) =>
        rawPostFull('/transfer/initiate', {
          'Content-Type': 'application/json',
          'x-device-id': senderId,
        }, initiateBody(requestId, senderId, token));

    test('unknown sender is queued for approval, not auto-accepted', () async {
      await AppSettingsService().setAutoAcceptTrusted(true);

      final response = await initiate('t-unknown-1', 'sender-unknown', 'tok-1');

      expect(response, contains('pending_approval'));
      expect(response, isNot(contains('authorized')));
      expect(service.trustedDevices, isEmpty);
    });

    test('approved-with-trust sender is auto-accepted on next initiate',
        () async {
      await AppSettingsService().setAutoAcceptTrusted(true);

      // First contact: queued for approval, then accepted + trusted.
      final first = await initiate('t-trust-1', 'sender-trusted', 'tok-trusted');
      expect(first, contains('pending_approval'));
      await service.approveTransfer('t-trust-1', trustSender: true);

      expect(service.trustedDevices, hasLength(1));
      expect(service.trustedDevices.first.senderId, 'sender-trusted');
      expect(service.trustedDevices.first.token, 'tok-trusted');

      // Second contact from the same device with the same token: no prompt.
      final second =
          await initiate('t-trust-2', 'sender-trusted', 'tok-trusted');
      expect(second, contains('"status":"accepted"'));
      expect(second, contains('"authorized":true'));
      expect(second, isNot(contains('pending_approval')));
      expect(service.pendingRequests, isEmpty);
    });

    test('trusted sender is NOT auto-accepted when the toggle is off',
        () async {
      await AppSettingsService().setAutoAcceptTrusted(false);

      final first = await initiate('t-off-1', 'sender-toggled', 'tok-a');
      expect(first, contains('pending_approval'));
      await service.approveTransfer('t-off-1', trustSender: true);

      expect(service.trustedDevices, hasLength(1));

      final second = await initiate('t-off-2', 'sender-toggled', 'tok-a');
      expect(second, contains('pending_approval'));
      expect(service.pendingRequests, hasLength(1));
    });

    test('a trusted id presenting a wrong token is NOT auto-accepted',
        () async {
      await AppSettingsService().setAutoAcceptTrusted(true);

      final first = await initiate('t-wrong-1', 'sender-wrong', 'tok-good');
      expect(first, contains('pending_approval'));
      await service.approveTransfer('t-wrong-1', trustSender: true);

      // Same sender id, but the token no longer matches the stored record.
      final second = await initiate('t-wrong-2', 'sender-wrong', 'tok-forged');
      expect(second, contains('pending_approval'));
      expect(second, isNot(contains('authorized')));
      expect(service.pendingRequests, hasLength(1));
    });
  });
}