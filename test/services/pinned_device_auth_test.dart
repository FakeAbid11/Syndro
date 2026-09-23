import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syndro/core/services/app_settings_service.dart';
import 'package:syndro/core/services/encryption_service.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// P0-1 regression: a trusted device with an active TOFU pin must authenticate
/// ONLY with the token bound to that pin.
///
/// Before the fix, `_verifyDeviceToken` compared the raw static token FIRST and
/// only consulted the pin afterwards, so a pinned device could still be
/// accepted on the raw token — the value an attacker would already hold from
/// before the pin existed. Pinning was therefore bypassable.
///
/// The observable used here is the one the receiver genuinely exposes: with
/// auto-accept enabled, a token that authenticates returns
/// `"status":"accepted"` + `"authorized":true`, and one that does not is queued
/// as `pending_approval`. Nothing about the crypto is stubbed — the pin is
/// established by a real X25519 key exchange and the bound token is derived
/// with the production `EncryptionService.deriveBoundToken`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  group('pinned-device authentication (P0-1)', () {
    late TransferService service;
    late int port;
    late String senderId;
    late String staticToken;

    /// The sender's real X25519 public key, as base64url (the pin format) and
    /// as the byte list the key-exchange endpoint expects.
    late String senderPubKeyB64;
    late List<int> senderPubKeyBytes;

    setUp(() async {
      service = TransferService(FileService());
      await service.initialize();
      // Distinct from the other loopback suites (18765 / 18766).
      port = 18771;
      await service.startServer(port);

      senderId = 'pinned-sender';
      staticToken = 'static-token-8f2c';

      final keyPair = await X25519().newKeyPair();
      final publicKey = await keyPair.extractPublicKey();
      senderPubKeyBytes = publicKey.bytes;
      senderPubKeyB64 = base64Url.encode(publicKey.bytes);
    });

    tearDown(() async {
      await service.dispose();
    });

    Future<String> rawPostFull(
      String path,
      Map<String, String> headers,
      String body,
    ) async {
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

    Future<String> initiate(String requestId, String token) => rawPostFull(
          '/transfer/initiate',
          {
            'Content-Type': 'application/json',
            'x-device-id': senderId,
          },
          jsonEncode({
            'id': requestId,
            'senderId': senderId,
            'senderName': 'Pinned Sender',
            'senderToken': token,
            'receiverId': 'this-device',
            'items': [
              {'name': 'hello.txt', 'size': 5}
            ],
          }),
        );

    /// Trust the sender on first contact, without any key exchange — so no pin.
    Future<void> trustWithoutPin() async {
      await AppSettingsService().setAutoAcceptTrusted(true);
      final first = await initiate('pin-setup-unpinned', staticToken);
      expect(first, contains('pending_approval'));
      await service.approveTransfer('pin-setup-unpinned', trustSender: true);
      expect(service.trustedDevices, hasLength(1));
      expect(service.trustedDevices.first.hasActivePin, isFalse,
          reason: 'precondition: trusted by key exchange has not run');
    }

    /// Perform a real key exchange, which auto-pins the presented public key.
    Future<void> pinSender() async {
      final response = await rawPostFull(
          '/key-exchange',
          {'Content-Type': 'application/json'},
          jsonEncode({
            'deviceId': senderId,
            'publicKey': senderPubKeyBytes,
          }));
      expect(response, contains('HTTP/1.1 200'));
      expect(service.trustedDevices.first.pinnedPubKey, senderPubKeyB64,
          reason: 'precondition: the pin must actually be active for these '
              'tests to mean anything');
      expect(service.trustedDevices.first.hasActivePin, isTrue);
    }

    Future<String> boundTokenFor(String pin) =>
        EncryptionService.deriveBoundToken(
          senderToken: staticToken,
          pinnedPubKeyBase64Url: pin,
        );

    // ── Unpinned device ───────────────────────────────────────────────────

    test('unpinned device presenting the raw static token is accepted',
        () async {
      await trustWithoutPin();

      final second = await initiate('unpinned-raw', staticToken);
      expect(second, contains('"status":"accepted"'));
      expect(second, contains('"authorized":true'));
    });

    test('unpinned device presenting a bound token is rejected', () async {
      await trustWithoutPin();

      // A bound token is meaningless until a pin exists to derive it against.
      final forged = await boundTokenFor(senderPubKeyB64);
      final response = await initiate('unpinned-bound', forged);
      expect(response, contains('pending_approval'));
      expect(response, isNot(contains('"authorized":true')));
    });

    // ── Pinned device ─────────────────────────────────────────────────────

    test('pinned device presenting the correct bound token is accepted',
        () async {
      await trustWithoutPin();
      await pinSender();

      final bound = await boundTokenFor(senderPubKeyB64);
      expect(bound, isNot(staticToken),
          reason: 'sanity: the bound token must differ from the raw token');

      final response = await initiate('pinned-bound-ok', bound);
      expect(response, contains('"status":"accepted"'),
          reason: 'a correctly bound token must still authenticate');
      expect(response, contains('"authorized":true'));
    });

    test('pinned device presenting the raw static token is REJECTED', () async {
      // The bypass itself: this is the case the old ordering accepted.
      await trustWithoutPin();
      await pinSender();

      final response = await initiate('pinned-raw', staticToken);
      expect(response, contains('pending_approval'),
          reason: 'P0-1: a pinned device must never authenticate with the raw '
              'static token');
      expect(response, isNot(contains('"authorized":true')));
      expect(service.pendingRequests, isNotEmpty);
    });

    test(
        'pinned device presenting a bound token derived from the wrong key '
        'is rejected', () async {
      await trustWithoutPin();
      await pinSender();

      // Same derivation, different input: what an attacker holding the static
      // token but not the real pinning material would produce.
      final otherKeyPair = await X25519().newKeyPair();
      final otherPub =
          base64Url.encode((await otherKeyPair.extractPublicKey()).bytes);
      final wrongBound = await boundTokenFor(otherPub);
      expect(wrongBound, isNot(await boundTokenFor(senderPubKeyB64)));

      final response = await initiate('pinned-bound-wrong', wrongBound);
      expect(response, contains('pending_approval'));
      expect(response, isNot(contains('"authorized":true')));
    });

    test('an unknown device id is rejected regardless of token', () async {
      await trustWithoutPin();
      await pinSender();

      final bound = await boundTokenFor(senderPubKeyB64);
      final response = await rawPostFull(
        '/transfer/initiate',
        {'Content-Type': 'application/json', 'x-device-id': 'someone-else'},
        jsonEncode({
          'id': 'unknown-id',
          'senderId': 'someone-else',
          'senderName': 'Impostor',
          'senderToken': bound,
          'receiverId': 'this-device',
          'items': [
            {'name': 'hello.txt', 'size': 5}
          ],
        }),
      );
      expect(response, contains('pending_approval'));
      expect(response, isNot(contains('"authorized":true')));
    });
  });
}
