import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as path;
import 'package:syndro/core/services/encryption_service.dart';
import 'package:syndro/core/services/streaming_hash_service.dart';

/// Real end-to-end encrypted transfer over a loopback HttpServer.
///
/// Unlike a pure in-memory simulation, this stands up an actual `dart:io`
/// HttpServer on 127.0.0.1, performs a live X25519 key exchange over HTTP,
/// then uploads an AES-256-GCM encrypted file body to the server which
/// decrypts it and verifies integrity with SHA-256. This exercises the real
/// crypto path (EncryptionService + StreamingHashService) across a socket.
void main() {
  group('Encrypted loopback transfer', () {
    late EncryptionService serverCrypto;
    late EncryptionService clientCrypto;
    late Directory tempDir;
    late _LoopbackReceiver receiver;

    setUp(() async {
      serverCrypto = EncryptionService();
      clientCrypto = EncryptionService();
      tempDir = await Directory.systemTemp.createTemp('syndro_loopback_');
      receiver = await _LoopbackReceiver.start(serverCrypto, tempDir);
    });

    tearDown(() async {
      await receiver.stop();
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('key-exchange + encrypted body round-trips and preserves content',
        () async {
      final base = 'http://${InternetAddress.loopbackIPv4.address}:${receiver.port}';

      // 1. Client generates identity and performs key exchange over HTTP.
      final clientKeyPair = await clientCrypto.generateKeyPair();
      final clientPub = await clientCrypto.getPublicKey(clientKeyPair);
      final clientPubBytes = await clientCrypto.publicKeyToBytes(clientPub);

      final kxResp = await http.post(
        Uri.parse('$base/key-exchange'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'publicKey': clientPubBytes}),
      );
      expect(kxResp.statusCode, 200);

      final serverPubBytes =
          (jsonDecode(kxResp.body)['publicKey'] as List).cast<int>();
      final serverPub =
          clientCrypto.publicKeyFromBytes(Uint8List.fromList(serverPubBytes));
      final clientSecret = await clientCrypto.deriveSharedSecret(
        myKeyPair: clientKeyPair,
        theirPublicKey: serverPub,
      );

      // Both sides must derive the same shared secret.
      expect(receiver.sessionSecret, isNotNull);
      expect(await clientSecret.extractBytes(),
          equals(await receiver.sessionSecret!.extractBytes()));

      // 2. Prepare a payload and its integrity hash.
      final plaintext = Uint8List.fromList(utf8.encode(
          'Sensitive payload transferred over a real loopback socket. ' * 64));
      final srcFile = File(path.join(tempDir.path, 'src.bin'));
      await srcFile.writeAsBytes(plaintext);
      final expectedHash =
          await StreamingHashService.calculateFileHash(srcFile);

      // 3. Encrypt with the derived secret and upload the ciphertext.
      final ciphertext = await clientCrypto.encryptChunk(plaintext, clientSecret);

      final upResp = await http.post(
        Uri.parse('$base/upload'),
        headers: {'x-expected-hash': expectedHash},
        body: ciphertext,
      );

      expect(upResp.statusCode, 200);
      final body = jsonDecode(upResp.body) as Map<String, dynamic>;
      expect(body['status'], 'ok');
      expect(body['hashMatches'], isTrue);

      // 4. The server wrote the decrypted plaintext to disk intact.
      final received = File(path.join(tempDir.path, 'received.bin'));
      expect(await received.exists(), isTrue);
      expect(await received.readAsBytes(), equals(plaintext));
    });
  });
}

/// Minimal loopback receiver used only by this test. `/key-exchange` derives
/// and stores the shared secret; `/upload` decrypts the body with it, verifies
/// SHA-256, and writes the plaintext to disk.
class _LoopbackReceiver {
  final HttpServer _server;
  final EncryptionService _crypto;
  final SimpleKeyPair _keyPair;
  final Directory _dir;
  SecretKey? sessionSecret;

  _LoopbackReceiver._(this._server, this._crypto, this._keyPair, this._dir) {
    _server.listen(_handle);
  }

  int get port => _server.port;

  static Future<_LoopbackReceiver> start(
      EncryptionService crypto, Directory dir) async {
    final keyPair = await crypto.generateKeyPair();
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    return _LoopbackReceiver._(server, crypto, keyPair, dir);
  }

  Future<void> stop() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    try {
      if (request.method == 'POST' && request.uri.path == '/key-exchange') {
        final body = await utf8.decoder.bind(request).join();
        final theirPubBytes =
            (jsonDecode(body)['publicKey'] as List).cast<int>();
        final theirPub =
            _crypto.publicKeyFromBytes(Uint8List.fromList(theirPubBytes));
        sessionSecret = await _crypto.deriveSharedSecret(
          myKeyPair: _keyPair,
          theirPublicKey: theirPub,
        );

        final myPub = await _crypto.getPublicKey(_keyPair);
        final myPubBytes = await _crypto.publicKeyToBytes(myPub);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'publicKey': myPubBytes}));
        await request.response.close();
        return;
      }

      if (request.method == 'POST' && request.uri.path == '/upload') {
        final expectedHash = request.headers.value('x-expected-hash');
        final bytes = <int>[];
        await for (final chunk in request) {
          bytes.addAll(chunk);
        }
        final plaintext = await _crypto.decryptChunk(
            Uint8List.fromList(bytes), sessionSecret!);
        final outFile = File(path.join(_dir.path, 'received.bin'));
        await outFile.writeAsBytes(plaintext);
        final actualHash =
            await StreamingHashService.calculateFileHash(outFile);
        request.response.headers.contentType = ContentType.json;
        request.response.write(jsonEncode({
          'status': 'ok',
          'hashMatches': expectedHash == actualHash,
        }));
        await request.response.close();
        return;
      }

      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    } catch (e) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('error: $e');
      await request.response.close();
    }
  }
}
