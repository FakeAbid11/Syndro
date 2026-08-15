import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;

import '../models/device.dart';
import '../models/encryption_models.dart';
import '../utils/app_logger.dart';
import 'encryption_service.dart';

/// Handles secure key exchange between devices
///
/// Uses X25519 Diffie-Hellman (same as Signal Protocol)
class KeyExchangeService {
  final EncryptionService _encryptionService;

  /// Secure storage for the persistent device identity seed.
  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();

  /// Storage key holding the 32-byte X25519 private seed (base64) for this
  /// device's long-term identity.
  static const String _identityKey = 'syndro.identity.privkey';

  // Cache of active sessions
  final Map<String, EncryptionSession> _sessions = {};

  // Our current key pair
  SimpleKeyPair? _currentKeyPair;
  SimplePublicKey? _currentPublicKey;

  KeyExchangeService(this._encryptionService);

  /// Initialize with a persistent key pair.
  ///
  /// Loads the device's long-term X25519 identity from secure storage, or
  /// generates and persists one on first run. Persisting the identity means
  /// peers who pinned this device (TOFU) will not see a false MITM alarm after
  /// an app restart.
  Future<void> initialize() async {
    try {
      final stored = await _secureStorage.read(key: _identityKey);
      if (stored != null && stored.isNotEmpty) {
        final seed = base64Decode(stored);
        _currentKeyPair = await _encryptionService.keyPairFromSeed(seed);
        _currentPublicKey =
            await _encryptionService.getPublicKey(_currentKeyPair!);
        AppLogger.info('🔐 Key exchange service initialized (persistent identity)');
        return;
      }
    } catch (e) {
      // Corrupt / unreadable identity — fall through to regenerate.
      AppLogger.warn('⚠️ Could not load persisted identity, regenerating: $e');
    }

    _currentKeyPair = await _encryptionService.generateKeyPair();
    _currentPublicKey =
        await _encryptionService.getPublicKey(_currentKeyPair!);

    try {
      final seed = await _encryptionService.keyPairSeedBytes(_currentKeyPair!);
      await _secureStorage.write(key: _identityKey, value: base64Encode(seed));
      AppLogger.info('🔐 Key exchange service initialized (new identity persisted)');
    } catch (e) {
      AppLogger.warn('⚠️ Could not persist device identity: $e');
    }
  }

  /// Get our public key for sharing
  Future<PublicKeyData> getMyPublicKey(String myDeviceId) async {
    if (_currentPublicKey == null) {
      await initialize();
    }

    final publicKeyBytes =
        await _encryptionService.publicKeyToBytes(_currentPublicKey!);

    return PublicKeyData(
      deviceId: myDeviceId,
      publicKey: publicKeyBytes,
      createdAt: DateTime.now(),
    );
  }

  /// Perform key exchange with another device (App-to-App)
  ///
  /// 1. Send our public key
  /// 2. Receive their public key
  /// 3. Derive shared secret
  Future<SecretKey> exchangeKeys({
    required Device localDevice,
    required Device remoteDevice,
  }) async {
    if (_currentKeyPair == null) {
      await initialize();
    }

    // Check if we already have a session
    final sessionKey = '${localDevice.id}-${remoteDevice.id}';
    final existingSession = _sessions[sessionKey];
    if (existingSession != null && !existingSession.isExpired) {
      return _encryptionService
          .secretKeyFromBytes(existingSession.sharedSecret);
    }

    try {
      // Step 1: Get our public key
      final myPublicKey = await getMyPublicKey(localDevice.id);

      // Step 2: Send our public key and get theirs
      final response = await http
          .post(
            Uri.parse(
                'http://${remoteDevice.ipAddress}:${remoteDevice.port}/key-exchange'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode(myPublicKey.toJson()),
          )
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) {
        throw KeyExchangeException(
            'Key exchange failed: ${response.statusCode}');
      }

      final theirPublicKeyData = PublicKeyData.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );

      // Step 3: Derive shared secret
      final theirPublicKey = _encryptionService.publicKeyFromBytes(
        theirPublicKeyData.publicKey,
      );

      final sharedSecret = await _encryptionService.deriveSharedSecret(
        myKeyPair: _currentKeyPair!,
        theirPublicKey: theirPublicKey,
      );

      // Cache the session
      final sharedSecretBytes =
          await _encryptionService.secretKeyToBytes(sharedSecret);

      _sessions[sessionKey] = EncryptionSession(
        sessionId: sessionKey,
        localDeviceId: localDevice.id,
        remoteDeviceId: remoteDevice.id,
        sharedSecret: sharedSecretBytes,
        createdAt: DateTime.now(),
        expiresAt: DateTime.now().add(const Duration(hours: 24)),
      );

      AppLogger.info('🔐 Key exchange successful with ${remoteDevice.name}');
      return sharedSecret;
    } catch (e) {
      AppLogger.error('❌ Key exchange failed: $e');
      rethrow;
    }
  }

  /// Handle incoming key exchange request (for receiver)
  Future<PublicKeyData> handleKeyExchangeRequest({
    required String myDeviceId,
    required PublicKeyData theirPublicKeyData,
  }) async {
    if (_currentKeyPair == null) {
      await initialize();
    }

    // Derive and cache shared secret
    final theirPublicKey = _encryptionService.publicKeyFromBytes(
      theirPublicKeyData.publicKey,
    );

    final sharedSecret = await _encryptionService.deriveSharedSecret(
      myKeyPair: _currentKeyPair!,
      theirPublicKey: theirPublicKey,
    );

    // Cache session
    final sessionKey = '$myDeviceId-${theirPublicKeyData.deviceId}';
    final sharedSecretBytes =
        await _encryptionService.secretKeyToBytes(sharedSecret);

    _sessions[sessionKey] = EncryptionSession(
      sessionId: sessionKey,
      localDeviceId: myDeviceId,
      remoteDeviceId: theirPublicKeyData.deviceId,
      sharedSecret: sharedSecretBytes,
      createdAt: DateTime.now(),
      expiresAt: DateTime.now().add(const Duration(hours: 24)),
    );

    // Return our public key
    return await getMyPublicKey(myDeviceId);
  }

  /// Get cached session secret (if exists)
  SecretKey? getCachedSecret(String localDeviceId, String remoteDeviceId) {
    final sessionKey = '$localDeviceId-$remoteDeviceId';
    final session = _sessions[sessionKey];

    if (session == null || session.isExpired) {
      return null;
    }

    return _encryptionService.secretKeyFromBytes(session.sharedSecret);
  }

  /// Generate a session key for browser (no key exchange, use URL parameter)
  Future<BrowserSession> createBrowserSession(String myDeviceId) async {
    final secretKey = await _encryptionService.generateRandomKey();
    final keyBytes = await _encryptionService.secretKeyToBytes(secretKey);

    // Encode key as base64url for URL-safe transmission
    final keyBase64 = base64Url.encode(keyBytes);

    return BrowserSession(
      sessionId: DateTime.now().millisecondsSinceEpoch.toString(),
      secretKey: secretKey,
      keyForUrl: keyBase64,
      createdAt: DateTime.now(),
    );
  }

  /// Clear all sessions
  void clearSessions() {
    _sessions.clear();
  }

  /// Clear specific session
  void clearSession(String localDeviceId, String remoteDeviceId) {
    final sessionKey = '$localDeviceId-$remoteDeviceId';
    _sessions.remove(sessionKey);
  }
}

/// Session for browser-based transfers
class BrowserSession {
  final String sessionId;
  final SecretKey secretKey;
  final String keyForUrl; // Base64url encoded key for QR code/URL
  final DateTime createdAt;

  BrowserSession({
    required this.sessionId,
    required this.secretKey,
    required this.keyForUrl,
    required this.createdAt,
  });
}

/// Custom exception for key exchange errors
class KeyExchangeException implements Exception {
  final String message;

  KeyExchangeException(this.message);

  @override
  String toString() => 'KeyExchangeException: $message';
}
