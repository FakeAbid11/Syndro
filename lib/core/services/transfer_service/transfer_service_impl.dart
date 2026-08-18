import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:cryptography/cryptography.dart';
import 'package:crypto/crypto.dart' as crypto_hash;

import '../streaming_hash_service.dart' show AccumulatorSink;
import '../../models/device.dart';
import '../../models/transfer.dart';
import '../../models/transfer_checkpoint.dart';
import '../../database/database_helper.dart';
import '../encryption_service.dart';
import '../file_service.dart';
import '../app_settings_service.dart';
import '../checkpoint_manager.dart';
import '../background_transfer_service.dart';
import '../device_nickname_service.dart';
import 'models.dart';

import '../parallel/parallel_config.dart';
import '../parallel/parallel_receiver_handler.dart';
import '../parallel/parallel_transfer_service.dart';
import '../live_activity_service.dart';
import '../../config/app_config.dart';
import '../../utils/app_logger.dart';

/// Core transfer service for peer-to-peer file transfers.
///
/// This service handles all aspects of file transfers between devices:
/// - HTTP server for receiving files
/// - HTTP client for sending files
/// - Encryption and key exchange (X25519, AES-256-GCM)
/// - Trusted device management
/// - Transfer progress tracking
/// - Resume/checkpoint support for large files
/// - Parallel transfer support for improved speed
///
/// ## Usage
///
/// ```dart
/// final transferService = TransferService(fileService);
/// await transferService.initialize();
/// await transferService.startServer(8765);
///
/// // Send files
/// await transferService.sendFiles(
///   recipientIp: '192.168.1.100',
///   recipientPort: 8765,
///   files: [TransferItem(...)],
/// );
///
/// // Listen for incoming transfer requests
/// transferService.onTransferRequest = (senderId, senderName, items) {
///   // Handle incoming transfer request
/// };
/// ```
///
/// ## Encryption
///
/// All transfers are encrypted by default using:
/// - X25519 for key exchange (same as Signal, WhatsApp)
/// - AES-256-GCM for symmetric encryption
/// - Unique nonce per chunk to prevent replay attacks
///
/// ## Parallel Transfers
///
/// For large files (>10MB), parallel transfers are automatically enabled:
/// - Multiple HTTP connections for faster transfer
/// - Chunk-based transfer with resume support
/// - Automatic speed optimization
class TransferService {
  final FileService _fileService;
  final CheckpointManager _checkpointManager = CheckpointManager();
  final DeviceNicknameService _nicknameService = DeviceNicknameService();
  final _uuid = const Uuid();

  final _transferController = StreamController<Transfer>.broadcast();
  final Map<String, Transfer> _activeTransfers = {};
  /// Transfer-scoped authorization: maps an approved transferId to the exact
  /// sender token that was accepted for it. Upload/chunk/complete handlers must
  /// present a matching token so a device with a valid encryption session
  /// cannot push data into a transfer approved for a *different* sender.
  final Map<String, String> _transferTokens = {};
  final Map<String, StreamController<TransferProgress>> _progressControllers =
      {};

  late final ParallelReceiverHandler _parallelReceiver;
  ParallelTransferService? _parallelSender;
  ParallelConfig? _parallelConfig;

  final FlutterSecureStorage _secureStorage = const FlutterSecureStorage();
  static const String _trustedDevicesKey = 'syndro_trusted_devices';
  /// Storage key holding the 32-byte X25519 private seed (base64) for this
  /// device's persistent long-term identity used in TOFU pinning.
  static const String _identityKeyStorageKey = 'syndro.identity.privkey';
  /// Storage key holding this device's persistent auth token. The token
  /// authenticates us to peers that have trusted us; it MUST survive app
  /// restarts, otherwise a restart makes trusted-device auto-accept fail
  /// (the presented token would no longer match the peer's stored record).
  static const String _deviceTokenStorageKey = 'syndro.device.token';
  final AppSettingsService _settingsService = AppSettingsService();

  final Map<String, TrustedDevice> _trustedDevices = {};
  final Map<String, PendingTransferRequest> _pendingRequests = {};

  /// Per-transfer gate: when present the transfer is paused and its chunk
  /// loop awaits the completer before sending more data.
  final Map<String, Completer<void>> _pauseGates = {};
    // Receiver devices of in-flight parallel sends, so a user cancel can tell
  // the receiver to abort its session instead of leaking it.
  final Map<String, Device> _parallelTransferReceivers = {};

  // Per-IP rate limit for transfer initiation — a remote device must not be
  // able to spam approval prompts (mirrors ShareServer's limiter).
  static const int _maxInitiatesPerMinute = 20;
  static const Duration _initiateRateLimitWindow = Duration(minutes: 1);
  final Map<String, List<DateTime>> _initiateTimestamps = {};

  final _pendingRequestsController =
      StreamController<List<PendingTransferRequest>>.broadcast();

  final _receivedTextController =
      StreamController<ReceivedTextMessage>.broadcast();

  HttpServer? _server;

  String _deviceId = '';
  String _deviceName = '';
  String _devicePlatform = '';
  String _deviceToken = '';

  static const int maxRetries = 3;
  static const int initialRetryDelaySeconds = 2;
  // Use AppConfig for max completed transfers
  int get _maxCompletedTransfers => AppConfig.maxCompletedTransfers;
  // OPTIMIZED: Support files up to 100GB for low-end devices
  // Using streaming transfer, only one chunk is loaded in memory at a time
  static const int _maxFileSizeBytes = 100 * 1024 * 1024 * 1024; // 100GB limit
  static const int _maxTextLengthBytes = 64 * 1024; // 64KB text-message limit

  static const Duration _sessionMaxAge = Duration(hours: 1);
  Timer? _sessionCleanupTimer;

  Timer? _pendingRequestsCleanupTimer;
  StreamSubscription<Map<String, dynamic>>? _notificationEventSubscription;

  bool encryptionEnabled = true;
  // BUG-005 FIX: Use shared AesGcm from EncryptionService
  final AesGcm _aesGcm = EncryptionService.aesGcm;
  final X25519 _keyExchange = X25519();
  SimpleKeyPair? _encryptionKeyPair;
  final Map<String, EncryptionSession> _encryptionSessions = {};

  Function(String senderId, String senderName, List<TransferItem> items)?
      onTransferRequest;

  bool _isDisposed = false;

  bool _isInitialized = false;
  Future<void>? _initFuture;

  TransferService(this._fileService) {
    _startPendingRequestsCleanup();
    _listenToNotificationEvents();
    _initializeParallelTransfer();
    _startSessionCleanup();
    _startTrustedDevicesCleanup();
  }

  /// Must be awaited before using the service for transfers.
  Future<void> initialize() async {
    // If already initialized, return immediately
    if (_isInitialized) return;
    // If initialization is in progress, wait for it
    if (_initFuture != null) {
      return _initFuture;
    }
    // Start initialization and store the future
    // Use catchError to reset _initFuture on failure, allowing retries
    _initFuture = _doInitialize().catchError((Object e, StackTrace st) {
      if (kDebugMode) AppLogger.error('TransferService initialization failed: $e\n$st');
      _initFuture = null; // Allow retry on failure
    });
    return _initFuture;
  }

  Future<void> _doInitialize() async {
    await _loadTrustedDevices();
    await _initializeEncryption();
    _isInitialized = true;
    if (kDebugMode) AppLogger.info('✅ TransferService initialized');
  }

  Stream<Transfer> get transferStream => _transferController.stream;
  List<Transfer> get activeTransfers => _activeTransfers.values.toList();
  List<PendingTransferRequest> get pendingRequests =>
      _pendingRequests.values.toList();
  Stream<List<PendingTransferRequest>> get pendingRequestsStream =>
      _pendingRequestsController.stream;
  Stream<ReceivedTextMessage> get receivedTextStream =>
      _receivedTextController.stream;
  List<TrustedDevice> get trustedDevices => _trustedDevices.values.toList();
  bool get isEncryptionReady => _encryptionKeyPair != null;

  Future<void> _initializeEncryption() async {
    try {
      // Load a persisted long-term identity if present so peers who pinned
      // this device (TOFU) don't get a false MITM alarm after a restart.
      final stored = await _secureStorage.read(key: _identityKeyStorageKey);
      if (stored != null && stored.isNotEmpty) {
        try {
          final seed = base64Decode(stored);
          if (seed.length == 32) {
            _encryptionKeyPair = await _keyExchange.newKeyPairFromSeed(seed);
            if (kDebugMode) {
              AppLogger.info('🔐 Encryption initialized (persistent identity)');
            }
            return;
          }
        } catch (e) {
          if (kDebugMode) {
            AppLogger.warn('⚠️ Corrupt stored identity, regenerating: $e');
          }
        }
      }

      // First run (or unreadable identity): generate and persist.
      _encryptionKeyPair = await _keyExchange.newKeyPair();
      try {
        final data = await _encryptionKeyPair!.extract();
        await _secureStorage.write(
          key: _identityKeyStorageKey,
          value: base64Encode(data.bytes),
        );
      } catch (e) {
        if (kDebugMode) AppLogger.warn('⚠️ Could not persist device identity: $e');
      }
      if (kDebugMode) AppLogger.info('🔐 Encryption initialized (X25519 + AES-256-GCM)');
    } catch (e) {
      if (kDebugMode) AppLogger.error('❌ Failed to initialize encryption: $e');
      _encryptionKeyPair = null;
      encryptionEnabled = false;
    }
  }

  /// Load this device's persistent auth token from secure storage, or
  /// generate and persist one on first run. Keeping the token stable across
  /// launches is what allows trusted-device auto-accept to survive a restart:
  /// peers store this token in their trusted-device record and compare against
  /// it (directly, or via the pinned bound token) on every later transfer.
  Future<void> _loadOrCreateDeviceToken() async {
    if (_deviceToken.isNotEmpty) return;
    try {
      final stored = await _secureStorage.read(key: _deviceTokenStorageKey);
      if (stored != null && stored.isNotEmpty) {
        _deviceToken = stored;
        return;
      }
    } catch (e) {
      if (kDebugMode) AppLogger.warn('⚠️ Could not read device token: $e');
    }

    _deviceToken = _generateSecureToken();
    try {
      await _secureStorage.write(
        key: _deviceTokenStorageKey,
        value: _deviceToken,
      );
    } catch (e) {
      if (kDebugMode) AppLogger.warn('⚠️ Could not persist device token: $e');
    }
  }

  Future<Uint8List?> getPublicKey() async {
    if (_encryptionKeyPair == null) return null;
    final publicKey = await _encryptionKeyPair!.extractPublicKey();
    return Uint8List.fromList(publicKey.bytes);
  }

  Future<SecretKey> _performKeyExchange(Uint8List theirPublicKeyBytes) async {
    if (_encryptionKeyPair == null) {
      throw EncryptionException('Encryption not initialized');
    }

    final theirPublicKey = SimplePublicKey(
      theirPublicKeyBytes,
      type: KeyPairType.x25519,
    );

    final sharedSecret = await _keyExchange.sharedSecretKey(
      keyPair: _encryptionKeyPair!,
      remotePublicKey: theirPublicKey,
    );

    return sharedSecret;
  }

  Future<Uint8List> _encryptChunk(
      Uint8List plaintext, SecretKey secretKey) async {
    final nonce = _aesGcm.newNonce();
    final secretBox = await _aesGcm.encrypt(
      plaintext,
      secretKey: secretKey,
      nonce: nonce,
    );

    final result = Uint8List(12 + secretBox.cipherText.length + 16);
    int offset = 0;
    result.setRange(offset, offset + 12, nonce);
    offset += 12;
    result.setRange(
        offset, offset + secretBox.cipherText.length, secretBox.cipherText);
    offset += secretBox.cipherText.length;
    result.setRange(offset, offset + 16, secretBox.mac.bytes);

    return result;
  }

  Future<Uint8List> _decryptChunk(
      Uint8List encryptedData, SecretKey secretKey) async {
    if (encryptedData.length < 28) {
      throw EncryptionException(
          'Data too small to decrypt: ${encryptedData.length} bytes');
    }

    final nonce = encryptedData.sublist(0, 12);
    final mac = encryptedData.sublist(encryptedData.length - 16);
    final ciphertext = encryptedData.sublist(12, encryptedData.length - 16);

    final secretBox = SecretBox(
      ciphertext,
      nonce: nonce,
      mac: Mac(mac),
    );

    try {
      final plaintext = await _aesGcm.decrypt(
        secretBox,
        secretKey: secretKey,
      );
      return Uint8List.fromList(plaintext);
    } catch (e) {
      throw EncryptionException('Decryption failed: Authentication error',
          originalError: e);
    }
  }

  Future<String> _calculateHashFromFile(File file) async {
    final digest = await crypto_hash.sha256.bind(file.openRead()).last;
    return digest.toString();
  }

  void _startSessionCleanup() {
    _sessionCleanupTimer = Timer.periodic(
      const Duration(minutes: 15),
      (_) => _cleanupExpiredSessions(),
    );
  }

  void _cleanupExpiredSessions() {
    final now = DateTime.now();
    final expiredIds = <String>[];

    for (final entry in _encryptionSessions.entries) {
      if (now.difference(entry.value.createdAt) > _sessionMaxAge) {
        expiredIds.add(entry.key);
      }
    }

    for (final id in expiredIds) {
      _encryptionSessions.remove(id);
    }

    if (expiredIds.isNotEmpty) {
      if (kDebugMode) {
        AppLogger.info(
            '🧹 Cleaned up ${expiredIds.length} expired encryption sessions');
      }
    }
  }

  // Trusted devices cleanup - remove old entries to prevent unbounded growth
  static const Duration _trustedDevicesMaxAge = Duration(days: 90);
  Timer? _trustedDevicesCleanupTimer;

  void _startTrustedDevicesCleanup() {
    _trustedDevicesCleanupTimer = Timer.periodic(
      const Duration(hours: 24),
      (_) => _cleanupOldTrustedDevices(),
    );
  }

  void _cleanupOldTrustedDevices() {
    if (_trustedDevices.isEmpty) return;

    final now = DateTime.now();
    final expiredIds = <String>[];

    for (final entry in _trustedDevices.entries) {
      if (now.difference(entry.value.trustedAt) > _trustedDevicesMaxAge) {
        expiredIds.add(entry.key);
      }
    }

    for (final id in expiredIds) {
      _trustedDevices.remove(id);
    }

    if (expiredIds.isNotEmpty) {
      if (kDebugMode) AppLogger.info('🧹 Cleaned up ${expiredIds.length} old trusted devices');
      _saveTrustedDevices();
    }
  }

  void _initializeParallelTransfer() {
    _parallelReceiver = ParallelReceiverHandler(_fileService);

    int lastProgress = -1;
    _parallelReceiver.onProgress = (transferId, received, total) {
      final transfer = _activeTransfers[transferId];
      if (transfer != null) {
        final updatedTransfer = transfer.copyWith(
          status: TransferStatus.transferring,
          progress: TransferProgress(
            bytesTransferred: received,
            totalBytes: total,
          ),
        );
        _activeTransfers[transferId] = updatedTransfer;
        _transferController.add(updatedTransfer);

        final progressPercent = (received / total * 100).toInt();
        if (progressPercent != lastProgress) {
          lastProgress = progressPercent;
          BackgroundTransferService.updateProgress(
            title: 'Receiving file',
            fileName: transfer.items.first.name,
            progress: progressPercent,
            bytesTransferred: received,
            totalBytes: total,
          );
        }
      }
    };

    _parallelReceiver.onComplete = (transferId, filePath) {
      final transfer = _activeTransfers[transferId];
      if (transfer != null) {
        final updatedTransfer = transfer.copyWith(
          status: TransferStatus.completed,
          progress: TransferProgress(
            bytesTransferred: transfer.progress.totalBytes,
            totalBytes: transfer.progress.totalBytes,
          ),
        );
        _activeTransfers[transferId] = updatedTransfer;
        _transferController.add(updatedTransfer);
        _cleanupProgressController(transferId);

        // Record the received file in history (was previously invisible).
        DatabaseHelper.instance
            .insertTransfer(updatedTransfer, null, null)
            .catchError((e) {
          AppLogger.error('Failed to insert parallel receive into history: $e');
        });
      }
    };

    AppLogger.info('⚡ Parallel transfer handlers initialized');
  }

  Future<void> _handleParallelInitiate(HttpRequest request) async {
    try {
      // Per-IP rate limit: same spam protection as the sequential initiate.
      final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      if (!_checkInitiateRateLimit(remoteIp)) {
        await _sendTooManyRequests(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final transferId = data['transferId'] as String? ?? '';
      final fileName = data['fileName'] as String? ?? '';
      final fileSize = data['fileSize'] as int? ?? 0;
      final senderId = data['senderId'] as String? ?? '';
      final senderName = data['senderName'] as String? ?? '';
      final senderToken = data['senderToken'] as String? ?? '';

      if (transferId.isEmpty || fileName.isEmpty || fileSize <= 0) {
        await _sendBadRequest(request, 'Missing required fields');
        return;
      }

      // Idempotency: a retried initiate for an already-active parallel
      // transfer must not create a duplicate session (the writer would throw
      // "Writer already exists" and the sender would see a confusing 500).
      if (_transferTokens.containsKey(transferId) ||
          _pendingRequests.containsKey(transferId) ||
          _parallelReceiver.getSession(transferId) != null) {
        await _sendResponse(request, HttpStatus.conflict, {
          'success': false,
          'error': 'Transfer already exists',
        });
        return;
      }

      // Enforce the global size cap on the parallel receive path too.
      if (fileSize > _maxFileSizeBytes) {
        AppLogger.info(
            'Security: File size $fileSize exceeds maximum $_maxFileSizeBytes');
        await _sendBadRequest(request,
            'File size exceeds maximum allowed size (${_maxFileSizeBytes ~/ (1024 * 1024 * 1024)}GB)');
        return;
      }

      // Check if auto-accept is enabled for trusted devices
      final trustedDevice = _trustedDevices[senderId];
      final autoAcceptTrusted = await _settingsService.getAutoAcceptTrusted();

      if (trustedDevice != null &&
          await _verifyDeviceToken(
            senderId: senderId,
            presentedToken: senderToken,
          ) &&
          autoAcceptTrusted) {
        // Auto-accept: proceed with transfer immediately
        AppLogger.info('✅ Auto-accepting parallel transfer from trusted device: $senderName');

        _transferTokens[transferId] = senderToken;
        final result = await _parallelReceiver.handleInitiate(data);
        await _sendResponse(request,
            result['success'] == true ? HttpStatus.ok : HttpStatus.badRequest, result);
        return;
      }

      // FIX: Create pending request for UI approval
      // This ensures the transfer request dialog is shown before transfer starts
      final item = TransferItem(
        name: fileName,
        path: '', // Path not known yet on receiver side
        size: fileSize,
      );

      _pendingRequests[transferId] = PendingTransferRequest(
        requestId: transferId,
        senderId: senderId,
        senderName: senderName,
        senderToken: senderToken,
        items: [item],
        timestamp: DateTime.now(),
        senderPublicKey: null,
        isParallelTransfer: true,
        parallelData: data,
        isTrusted: trustedDevice != null,
      );

      // Notify UI via stream (this will show the transfer request dialog)
      if (!_pendingRequestsController.isClosed) {
        _pendingRequestsController.add(_pendingRequests.values.toList());
      }

      if (kDebugMode) AppLogger.info('📥 Parallel transfer pending approval: $fileName from $senderName');

      // Return pending_approval status so sender waits for approval
      await _sendResponse(request, HttpStatus.ok, {
        'status': 'pending_approval',
        'requestId': transferId,
        'message': 'Waiting for receiver approval',
      });
    } catch (e) {
      await _sendError(request, 'Error initiating parallel transfer: $e');
    }
  }

  Future<void> _handleChunkUpload(HttpRequest request) async {
    try {
      final transferId = request.headers.value('X-Transfer-Id');
      final chunkIndexStr = request.headers.value('X-Chunk-Index');
      final originalSizeStr = request.headers.value('X-Original-Size');
      final encryptedStr = request.headers.value('X-Encrypted');
      final senderId = request.headers.value('X-Sender-Id');
      final senderToken = request.headers.value('X-Sender-Token');

      if (transferId == null || chunkIndexStr == null) {
        await _sendBadRequest(request, 'Missing required headers');
        return;
      }

      // Transfer-scoped authorization: the chunk must belong to an approved
      // parallel transfer and present the token accepted for it. Without this a
      // device with any encryption session could inject chunks into another
      // sender's transfer.
      if (!await _isTransferAuthorized(
        transferId: transferId,
        senderId: senderId,
        presentedToken: senderToken,
      )) {
        AppLogger.info('Security: Unauthorized chunk upload for transfer $transferId');
        await _sendUnauthorized(request, 'Invalid sender token');
        return;
      }

      // FIX (Bug #34): Use int.tryParse instead of int.parse
      final chunkIndex = int.tryParse(chunkIndexStr);
      if (chunkIndex == null) {
        await _sendBadRequest(request, 'Invalid chunk index');
        return;
      }

      final originalSize = int.tryParse(originalSizeStr ?? '0') ?? 0;
      final encrypted = encryptedStr == 'true';

      // B4: reject a plaintext chunk downgrade. If we hold an encryption session
      // for this sender (key exchange completed), an attacker-supplied
      // X-Encrypted: false must not slip an unencrypted chunk past us.
      if (!encrypted && senderId != null && _encryptionSessions.containsKey(senderId)) {
        AppLogger.info('Security: Rejected plaintext chunk for key-exchanged sender $senderId');
        await _sendUnauthorized(request, 'Encryption required for this session');
        return;
      }

      // Cap the chunk body: the sender streams bounded chunks (4MB + encryption
      // overhead), so anything beyond 8MB is a runaway or an attempt to exhaust
      // memory. Drain the request so the connection is reusable, then reject.
      final session = _parallelReceiver.getSession(transferId);
      final maxChunkBytes = session != null
          ? session.chunkSize * 2
          : 8 * 1024 * 1024;
      final chunks = <int>[];
      var receivedBytes = 0;
      var overLimit = false;
      await for (final chunk in request) {
        receivedBytes += chunk.length;
        if (receivedBytes > maxChunkBytes) {
          overLimit = true;
          continue;
        }
        chunks.addAll(chunk);
      }
      if (overLimit) {
        AppLogger.info(
            'Security: Chunk body $receivedBytes bytes exceeds cap '
            '$maxChunkBytes for transfer $transferId');
        await _sendBadRequest(request, 'Chunk body exceeds allowed size');
        return;
      }
      final chunkData = Uint8List.fromList(chunks);

      SecretKey? decryptionKey;
      if (encrypted && session != null) {
        decryptionKey = _encryptionSessions[session.senderId]?.sharedSecret;
      }

      final result = await _parallelReceiver.handleChunk(
        transferId: transferId,
        chunkIndex: chunkIndex,
        chunkData: chunkData,
        originalSize: originalSize,
        encrypted: encrypted,
        decryptionKey: decryptionKey,
      );

      await _sendResponse(request,
          result['success'] == true ? HttpStatus.ok : HttpStatus.badRequest, result);
    } catch (e) {
      await _sendError(request, 'Error receiving chunk: $e');
    }
  }

  Future<void> _handleChunkDownload(HttpRequest request) async {
    try {
      final pathParts = request.uri.path.split('/');

      if (pathParts.length < 5) {
        await _sendBadRequest(request, 'Invalid path');
        return;
      }

      final transferId = pathParts[3];

      final session = _parallelReceiver.getSession(transferId);
      if (session == null) {
        await _sendNotFound(request, 'Transfer not found');
        return;
      }

      // Chunk download via browser not supported - use parallel transfer instead
      await _sendError(request, 'Chunk download not supported for browser mode');
    } catch (e) {
      await _sendError(request, 'Error serving chunk: $e');
    }
  }

  Future<void> _handleParallelComplete(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;

      final transferId = data['transferId'] as String;
      final fileHash = data['fileHash'] as String;

      // Transfer-scoped identity check: the completing device must be the same
      // sender the parallel receive session was approved for. (The completion
      // request carries no body token; chunk uploads already enforce the token,
      // so binding the finalize to the approved senderId is the invariant here.)
      final callerId = request.headers.value('x-device-id');
      final parallelSession = _parallelReceiver.getSession(transferId);
      if (parallelSession == null ||
          callerId == null ||
          parallelSession.senderId != callerId) {
        AppLogger.info(
            'Security: Unauthorized parallel complete for transfer $transferId');
        await _sendUnauthorized(request, 'Not authorized for this transfer');
        return;
      }

      final result = await _parallelReceiver.handleComplete(
        transferId: transferId,
        fileHash: fileHash,
      );

      if (result['success'] == true) {
        _transferTokens.remove(transferId);
        await BackgroundTransferService.showTransferComplete(
          fileName:
              result['filePath'].toString().split(Platform.pathSeparator).last,
          filePath: result['filePath'] as String,
          fileCount: 1,
          totalSize: result['fileSize'] as int,
        );
      } else {
        // The receiver rejected the finalize (hash mismatch / missing chunks)
        // and already deleted the temp file — reconcile the UI so the
        // transfer does not stay stuck in "transferring".
        final receiveTransfer = _activeTransfers[transferId];
        if (receiveTransfer != null) {
          final failedTransfer = receiveTransfer.copyWith(
            status: TransferStatus.failed,
            errorMessage: result['error']?.toString() ?? 'Receiver rejected finalize',
          );
          _activeTransfers[transferId] = failedTransfer;
          _transferController.add(failedTransfer);
        }
        _transferTokens.remove(transferId);
      }

      await _sendResponse(request,
          result['success'] == true ? HttpStatus.ok : HttpStatus.badRequest, result);
    } catch (e) {
      await _sendError(request, 'Error completing parallel transfer: $e');
    }
  }

  /// Receiver side of a user-initiated sender cancel: abort the receive
  /// session (deletes the temp file) so nothing leaks on this device.
  Future<void> _handleParallelCancel(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = jsonDecode(body) as Map<String, dynamic>;
      final transferId = data['transferId'] as String? ?? '';
      final callerId = request.headers.value('x-device-id');

      // Bind the cancel to the approved sender of the session, exactly like
      // the parallel complete handler.
      final session = _parallelReceiver.getSession(transferId);
      if (transferId.isEmpty ||
          session == null ||
          callerId == null ||
          session.senderId != callerId) {
        AppLogger.info(
            'Security: Unauthorized parallel cancel for transfer $transferId');
        await _sendUnauthorized(request, 'Not authorized for this transfer');
        return;
      }

      await _parallelReceiver.abortTransfer(transferId);
      _transferTokens.remove(transferId);

      // Reconcile the UI: the sender cancelled — the receive must not stay
      // stuck in "transferring".
      final cancelledTransfer = _activeTransfers[transferId];
      if (cancelledTransfer != null) {
        final updated = cancelledTransfer.copyWith(
          status: TransferStatus.cancelled,
        );
        _activeTransfers[transferId] = updated;
        _transferController.add(updated);
        _cleanupProgressController(transferId);
      }
      await _sendResponse(request, HttpStatus.ok, {'success': true});
    } catch (e) {
      await _sendError(request, 'Error cancelling parallel transfer: $e');
    }
  }

  void _listenToNotificationEvents() {
    _notificationEventSubscription =
        BackgroundTransferService.transferEvents.listen((event) {
      final eventType = event['event'] as String?;
      final requestId = event['requestId'] as String?;

      if (kDebugMode) AppLogger.info('📱 Notification event: $eventType for request: $requestId');

      switch (eventType) {
        case 'cancelled':
          AppLogger.info('📱 Transfer cancelled from notification: $requestId');
          if (requestId != null && _activeTransfers.containsKey(requestId)) {
            cancelTransfer(requestId);
          }
          break;
        case 'accepted':
          AppLogger.info('📱 Transfer accepted from notification: $requestId');
          if (requestId != null) {
            // FIX: Check if request still exists before approving
            if (_pendingRequests.containsKey(requestId)) {
              approveTransfer(requestId, trustSender: false);
            } else {
              AppLogger.warn('⚠️ Request $requestId no longer exists (may have been handled by UI)');
            }
          }
          break;
        case 'accepted_trusted':
          AppLogger.info('📱 Transfer accepted + trusted from notification: $requestId');
          if (requestId != null) {
            // FIX: Check if request still exists before approving
            if (_pendingRequests.containsKey(requestId)) {
              approveTransfer(requestId, trustSender: true);
            } else {
              AppLogger.warn('⚠️ Request $requestId no longer exists (may have been handled by UI)');
            }
          }
          break;
        case 'rejected':
          AppLogger.info('📱 Transfer rejected from notification: $requestId');
          if (requestId != null) {
            // FIX: Check if request still exists before rejecting
            if (_pendingRequests.containsKey(requestId)) {
              rejectTransfer(requestId);
            } else {
              AppLogger.warn('⚠️ Request $requestId no longer exists (may have been handled by UI)');
            }
          }
          break;
      }
    }, onError: (error) {
      if (kDebugMode) AppLogger.error('❌ Error in notification events: $error');
    });
  }

  Future<void> _loadTrustedDevices() async {
    try {
      final jsonString = await _secureStorage.read(key: _trustedDevicesKey);
      if (jsonString != null && jsonString.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(jsonString);
        for (final json in jsonList) {
          final device = TrustedDevice.fromJson(json as Map<String, dynamic>);
          _trustedDevices[device.senderId] = device;
        }
        AppLogger.info('✅ Loaded ${_trustedDevices.length} trusted devices');
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error loading trusted devices: $e');
    }
  }

  Future<void> _saveTrustedDevices() async {
    try {
      final jsonList = _trustedDevices.values.map((d) => d.toJson()).toList();
      await _secureStorage.write(
        key: _trustedDevicesKey,
        value: jsonEncode(jsonList),
      );
      if (kDebugMode) AppLogger.info('✅ Saved ${_trustedDevices.length} trusted devices');
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error saving trusted devices: $e');
    }
  }

  void _startPendingRequestsCleanup() {
    _pendingRequestsCleanupTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _cleanupExpiredPendingRequests(),
    );
  }

  void _cleanupExpiredPendingRequests() {
    final now = DateTime.now();
    final expiredIds = <String>[];

    for (final entry in _pendingRequests.entries) {
      if (now.difference(entry.value.timestamp).inMinutes > 5) {
        expiredIds.add(entry.key);
      }
    }

    if (expiredIds.isNotEmpty) {
      for (final id in expiredIds) {
        _pendingRequests.remove(id);
      }
      if (!_pendingRequestsController.isClosed) {
        _pendingRequestsController.add(_pendingRequests.values.toList());
      }
      if (kDebugMode) AppLogger.info('🧹 Cleaned up ${expiredIds.length} expired pending requests');
    }
  }

  Future<void> setDeviceInfo({
    required String id,
    required String name,
    required String platform,
  }) async {
    _deviceId = id;
    _devicePlatform = platform;

    try {
      final customNickname = await _nicknameService.getNickname(id);
      if (customNickname != null && customNickname.isNotEmpty) {
        _deviceName = customNickname;
        AppLogger.info(
            '✅ Using custom nickname for transfer service: $_deviceName');
      } else {
        _deviceName = name;
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error getting custom nickname: $e');
      _deviceName = name;
    }

    await _loadOrCreateDeviceToken();
  }

  Future<void> updateDeviceName() async {
    try {
      final customNickname = await _nicknameService.getNickname(_deviceId);
      if (customNickname != null && customNickname.isNotEmpty) {
        _deviceName = customNickname;
        AppLogger.info('✅ Updated device name to: $_deviceName');
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error updating device name: $e');
    }
  }

  String _generateSecureToken() {
    final random = math.Random.secure();
    final values = List<int>.generate(32, (i) => random.nextInt(256));
    return base64Url.encode(values);
  }

  /// Generate a unique checkpoint key using SHA-256 for better collision resistance
  String _generateCheckpointKey(
      String senderId, String receiverId, List<TransferItem> items) {
    final itemsSignature =
        items.map((item) => '${item.name}:${item.size}').join('|');
    final keySource = '$senderId->$receiverId:$itemsSignature';
    
    // Use SHA-256 for cryptographic hash instead of weak custom hash
    final bytes = utf8.encode(keySource);
    final digest = crypto_hash.sha256.convert(bytes);
    final hashHex = digest.toString().substring(0, 16); // Use first 16 chars (64 bits)
    return 'ckpt_$hashHex';
  }

  Future<void> startServer(int port) async {
    if (_deviceId.isEmpty) {
      _deviceId = const Uuid().v4();
    }
    if (_deviceName.isEmpty) {
      _deviceName = await _getDeviceName();
    }
    if (_devicePlatform.isEmpty) {
      _devicePlatform = Platform.operatingSystem;
    }
    if (_deviceToken.isEmpty) {
      await _loadOrCreateDeviceToken();
    }

    if (_encryptionKeyPair == null && encryptionEnabled) {
      await _initializeEncryption();
      _initializeParallelTransfer();
    }

    for (int p = port; p <= port + 5; p++) {
      try {
        _server = await HttpServer.bind(InternetAddress.anyIPv4, p);
        AppLogger.info('🚀 Transfer server running on port ${_server!.port}');
        AppLogger.info(
            '🔐 Encryption: ${encryptionEnabled ? "ENABLED" : "DISABLED"}');
        // FIX: Don't await _serve() - it runs indefinitely and blocks initialization
        _serve(); // Run in background
        break;
      } catch (e) {
        if (p == port + 5) {
          AppLogger.error(
              'Failed to start transfer server on any port in range: $e');
          throw TransferException('Failed to start server',
              code: 'SERVER_START_FAILED', originalError: e);
        }
        AppLogger.info('Port $p busy, trying next port...');
      }
    }

    if (_server != null) {
      _parallelConfig = await ParallelConfig.autoDetect();
      _parallelSender = ParallelTransferService(config: _parallelConfig);
      if (kDebugMode) {
        AppLogger.info(
            '⚡ Parallel transfer: ${_parallelConfig!.connections} connections, ${_parallelConfig!.chunkSize ~/ (1024 * 1024)}MB chunks');
      }
    }
  }

  Future<String> _getDeviceName() async {
    if (_deviceId.isNotEmpty) {
      try {
        final customNickname = await _nicknameService.getNickname(_deviceId);
        if (customNickname != null && customNickname.isNotEmpty) {
          return customNickname;
        }
      } catch (e) {
        AppLogger.error('Error getting custom nickname: $e');
      }
    }

    try {
      if (Platform.isAndroid) {
        // FIX: Use proper method channel to get Android device name
        const platform = MethodChannel('com.syndro.app/device_info');
        try {
          final String? deviceName = await platform.invokeMethod('getDeviceName');
          if (deviceName != null && deviceName.isNotEmpty) {
            return deviceName;
          }
        } catch (e) {
          AppLogger.info('Platform channel not available: $e');
        }
        return 'Android Device';
      } else if (Platform.isWindows) {
        return Platform.environment['COMPUTERNAME'] ?? 'Windows PC';
      } else if (Platform.isLinux) {
        return Platform.environment['HOSTNAME'] ?? 'Linux PC';
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error getting device name: $e');
    }
    return 'Syndro Device';
  }

  Future<void> _serve() async {
    if (_server == null) return;

    try {
      await for (final request in _server!) {
        if (_isDisposed) break;
        try {
          await _handleRequest(request);
        } catch (e, stackTrace) {
          AppLogger.error('Error handling request: $e');
          AppLogger.info('Stack trace: $stackTrace');
          try {
            request.response.statusCode = HttpStatus.internalServerError;
            request.response.write('Internal server error');
            await request.response.close();
          } catch (closeError) { 
            // Response may already be closed or in error state
            AppLogger.error("Error closing response: $closeError"); 
          }
        }
      }
    } catch (e) {
      // Server was closed or socket error - this is expected during dispose
      if (!_isDisposed) {
        AppLogger.error('Server error: $e');
      }
    }
  }

  Future<void> _handleRequest(HttpRequest request) async {
    final path = request.uri.path;
    final method = request.method;

    try {
      if (method == 'GET' && path == '/syndro.json') {
        await _serveDeviceInfo(request);
        return;
      }

      if (method == 'POST' && path == '/key-exchange') {
        await _handleKeyExchange(request);
        return;
      }

      // SECURITY: Authorization is enforced per-handler, not by a blanket route
      // gate. Each data-bearing endpoint verifies a transfer-scoped token
      // (`_isTransferAuthorized` / `_verifyDeviceToken`) or binds the caller to
      // the approved sender of the session. A blanket "an encryption session
      // must already exist" gate cannot be used here: `/transfer/initiate` (and
      // `/transfer/parallel/initiate`) are the handshake that *establishes* the
      // session, so gating them on a pre-existing session deadlocks the very
      // first contact between two peers. The per-handler checks below are
      // strictly stronger than "some session exists".

      if (method == 'POST' && path == '/transfer/parallel/initiate') {
        await _handleParallelInitiate(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/chunk') {
        await _handleChunkUpload(request);
        return;
      }

      if (method == 'GET' && path.startsWith('/transfer/chunk/')) {
        await _handleChunkDownload(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/parallel/complete') {
        await _handleParallelComplete(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/parallel/cancel') {
        await _handleParallelCancel(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/initiate') {
        await _handleTransferInitiate(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/text') {
        await _handleTextTransfer(request);
        return;
      }

      if (method == 'GET' && path.startsWith('/transfer/approval/')) {
        final requestId = path.split('/').last;
        await _handleApprovalCheck(request, requestId);
        return;
      }

      if (method == 'POST' && path == '/transfer/upload') {
        await _handleFileUpload(request);
        return;
      }

      if (method == 'POST' && path == '/transfer/upload-encrypted') {
        await _handleEncryptedFileUpload(request);
        return;
      }

      if (method == 'GET' && path.startsWith('/transfer/status/')) {
        final transferId = path.split('/').last;
        await _handleTransferStatus(request, transferId);
        return;
      }

      await _sendNotFound(request, 'Not found');
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error handling request: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');
      await _sendError(request, 'Internal server error');
    }
  }

  Future<void> _handleKeyExchange(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = _validateAndParseJson(body);

      if (data == null) {
        await _sendBadRequest(request, 'Invalid JSON');
        return;
      }

      final theirDeviceId = data['deviceId'] as String?;
      final theirPublicKeyList = data['publicKey'] as List?;

      if (theirDeviceId == null || theirPublicKeyList == null) {
        await _sendBadRequest(request, 'Missing deviceId or publicKey');
        return;
      }

      final theirPublicKeyBytes =
          Uint8List.fromList(theirPublicKeyList.cast<int>());

      // TOFU PIN CHECK: if the sender is trusted and has a pinned
      // public key, verify the presented key matches the pin. A
      // mismatch indicates a possible MITM — abort immediately.
      final trustedDevice = _trustedDevices[theirDeviceId];
      if (trustedDevice != null && trustedDevice.hasActivePin) {
        try {
          await EncryptionService.verifyPinnedKey(
            deviceId: theirDeviceId,
            presentedPubKeyBytes: theirPublicKeyBytes,
            pinnedPubKeyBase64Url: trustedDevice.pinnedPubKey,
          );
        } on SecurityException catch (secEx) {
          if (kDebugMode) {
            AppLogger.info('🚫 TOFU pin mismatch during key exchange: $secEx');
          }
          await _sendUnauthorized(
            request,
            'Security: public key mismatch — device key may have changed',
          );
          return;
        }
      } else if (trustedDevice != null &&
          !trustedDevice.hasActivePin &&
          theirPublicKeyBytes.isNotEmpty) {
        // First key exchange after trust without a pin (legacy trust
        // or after rotatePinnedKey). Automatically pin the key now
        // so subsequent connections are protected.
        try {
          final pubKeyBase64 = base64Url.encode(theirPublicKeyBytes);
          await _pinTrustedDeviceKey(trustedDevice, pubKeyBase64);
          if (kDebugMode) {
            AppLogger.info(
                '📌 Auto-pinned public key for trusted device $theirDeviceId');
          }
        } catch (e) {
          if (kDebugMode) {
            AppLogger.error('⚠️ Auto-pin failed for $theirDeviceId: $e');
          }
        }
      }

      final sharedSecret = await _performKeyExchange(theirPublicKeyBytes);

      _encryptionSessions[theirDeviceId] = EncryptionSession(
        sessionId: '$_deviceId-$theirDeviceId',
        sharedSecret: sharedSecret,
        createdAt: DateTime.now(),
      );

      final myPublicKey = await getPublicKey();

      await _sendResponse(request, HttpStatus.ok, {
        'deviceId': _deviceId,
        'publicKey': myPublicKey?.toList() ?? [],
      });

      if (kDebugMode) AppLogger.info('🔐 Key exchange completed with $theirDeviceId');
    } catch (e) {
      if (kDebugMode) AppLogger.error('Key exchange error: $e');
      await _sendError(request, 'Key exchange failed');
    }
  }

  Future<void> _serveDeviceInfo(HttpRequest request) async {
    String currentName = _deviceName;

    try {
      final customNickname = await _nicknameService.getNickname(_deviceId);
      if (customNickname != null && customNickname.isNotEmpty) {
        currentName = customNickname;
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error getting nickname for device info: $e');
    }

    final myPublicKey = await getPublicKey();

    final info = {
      'id': _deviceId,
      'name': currentName,
      'os': _devicePlatform,
      'platform': _devicePlatform,
      'version': '2.0',
      'encryption': encryptionEnabled,
      'publicKey': myPublicKey?.toList(),
    };

    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(info));
    await request.response.close();
  }

  Future<void> _sendResponse(
      HttpRequest request, int statusCode, Map<String, dynamic> body) async {
    request.response.statusCode = statusCode;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }

  Future<void> _sendNotFound(HttpRequest request, String message) async {
    request.response.statusCode = HttpStatus.notFound;
    request.response.write(message);
    await request.response.close();
  }

  Future<void> _sendBadRequest(HttpRequest request, String message) async {
    request.response.statusCode = HttpStatus.badRequest;
    request.response.write(message);
    await request.response.close();
  }

  Future<void> _sendUnauthorized(HttpRequest request, String message) async {
    request.response.statusCode = HttpStatus.unauthorized;
    request.response.write(message);
    await request.response.close();
  }

  Future<void> _sendTooManyRequests(HttpRequest request) async {
    request.response.statusCode = HttpStatus.tooManyRequests;
    request.response.write('Too many requests, try again later');
    await request.response.close();
  }

  /// True when the caller's IP is under the initiate-rate limit.
  bool _checkInitiateRateLimit(String ipAddress) {
    final now = DateTime.now();
    final windowStart = now.subtract(_initiateRateLimitWindow);
    final timestamps = _initiateTimestamps[ipAddress] ?? [];
    timestamps.removeWhere((t) => t.isBefore(windowStart));
    if (timestamps.length >= _maxInitiatesPerMinute) {
      AppLogger.warn(
          '⚠️ Rate limit exceeded for ${AppLogger.sanitize(ipAddress)}: '
          '${timestamps.length} initiates in last minute');
      _initiateTimestamps[ipAddress] = timestamps;
      return false;
    }
    timestamps.add(now);
    _initiateTimestamps[ipAddress] = timestamps;
    return true;
  }

  Future<void> _sendError(HttpRequest request, String message) async {
    request.response.statusCode = HttpStatus.internalServerError;
    request.response.write(message);
    await request.response.close();
  }

  Map<String, dynamic>? _validateAndParseJson(String body) {
    try {
      final data = jsonDecode(body);
      if (data is! Map<String, dynamic>) {
        return null;
      }
      return data;
    } catch (e) {
      if (kDebugMode) AppLogger.error('JSON parse error: $e');
      return null;
    }
  }

  bool _validateTransferData(Map<String, dynamic> data) {
    if (!data.containsKey('senderId') || data['senderId'] is! String) {
      return false;
    }
    if (!data.containsKey('id') || data['id'] is! String) return false;
    if (!data.containsKey('items') || data['items'] is! List) return false;
    if (!data.containsKey('senderToken') || data['senderToken'] is! String) {
      return false;
    }

    final senderId = data['senderId'] as String;
    if (senderId.isEmpty || senderId.length > 100) return false;

    final items = data['items'] as List;
    if (items.isEmpty || items.length > 1000) return false;

    return true;
  }

  bool _secureTokenCompare(String a, String b) {
    // Use constant-time comparison to prevent timing attacks
    // Always iterate through both strings regardless of length
    final lenA = a.length;
    final lenB = b.length;
    final minLen = lenA < lenB ? lenA : lenB;
    final maxLen = lenA > lenB ? lenA : lenB;
    
    int result = lenA ^ lenB; // Include length difference in timing
    for (int i = 0; i < minLen; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    // Process remaining characters (if any) to maintain constant time
    for (int i = minLen; i < maxLen; i++) {
      result |= lenA > lenB ? a.codeUnitAt(i) ^ 0 : 0 ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  // ─────────────────────────────────────────────
  //  TOFU pin helpers
  // ─────────────────────────────────────────────

  /// Store a public key pin for a trusted device, updating both the
  /// in-memory map and the secure-storage entry. Called when a new key
  /// is auto-pinned during key exchange or explicitly pinned via QR scan.
  Future<void> _pinTrustedDeviceKey(
      TrustedDevice device, String pubKeyBase64) async {
    final updated = device.copyWith(
      pinnedPubKey: pubKeyBase64,
      pendingRepin: false,
    );
    _trustedDevices[device.senderId] = updated;
    await _saveTrustedDevices();

    // Also persist to the namespaced pin key for fast lookups
    await _secureStorage.write(
      key: 'syndro.pin.${device.senderId}',
      value: pubKeyBase64,
    );
  }

  /// Verify the presented token against the trusted device's record.
  ///
  /// Returns `true` when the raw static token matches (legacy path)
  /// OR when a pinned public key is set and the bound token matches
  /// (new TOFU path). Always falls back to static token for backward
  /// compatibility with unpinned devices.
  Future<bool> _verifyDeviceToken({
    required String senderId,
    required String presentedToken,
  }) async {
    final trustedDevice = _trustedDevices[senderId];
    if (trustedDevice == null) return false;

    // Fast path: raw static token matches (legacy / unpinned)
    if (_secureTokenCompare(trustedDevice.token, presentedToken)) {
      return true;
    }

    // New path: pinned device → compare bound token
    if (trustedDevice.hasActivePin) {
      try {
        final expectedBound = await EncryptionService.deriveBoundToken(
          senderToken: trustedDevice.token,
          pinnedPubKeyBase64Url: trustedDevice.pinnedPubKey!,
        );
        return _secureTokenCompare(expectedBound, presentedToken);
      } catch (_) {
        return false;
      }
    }

    return false;
  }

  /// Transfer-scoped authorization gate for upload/chunk/complete endpoints.
  ///
  /// Confirms (1) the transfer was approved (`_activeTransfers` has it or a
  /// parallel receive session exists), (2) the presented [senderId] matches the
  /// approved sender, and (3) the presented [presentedToken] matches the exact
  /// token accepted for this transfer — or is a valid trusted-device token.
  ///
  /// This closes the gap where any device with *some* encryption session could
  /// push data into a transfer approved for a different sender.
  Future<bool> _isTransferAuthorized({
    required String transferId,
    required String? senderId,
    required String? presentedToken,
  }) async {
    if (senderId == null || senderId.isEmpty) return false;

    // The sender bound to this transfer, from either the classic or the
    // parallel approval path.
    final transfer = _activeTransfers[transferId];
    final parallelSession = _parallelReceiver.getSession(transferId);
    final approvedSenderId = transfer?.senderId ?? parallelSession?.senderId;

    if (approvedSenderId == null) return false;
    if (approvedSenderId != senderId) return false;

    final expectedToken = _transferTokens[transferId];
    if (expectedToken != null &&
        presentedToken != null &&
        _secureTokenCompare(expectedToken, presentedToken)) {
      return true;
    }

    // Fall back to a valid trusted-device token (covers auto-accept where the
    // per-transfer token may not have been recorded yet).
    if (presentedToken != null && presentedToken.isNotEmpty) {
      return await _verifyDeviceToken(
        senderId: senderId,
        presentedToken: presentedToken,
      );
    }

    return false;
  }

  /// Return the appropriate sender token for a specific receiver device.
  ///
  /// When we have a pinned public key for the receiver (meaning we've
  /// previously done a QR pairing or key exchange with them), we send
  /// the **bound token** = HMAC(senderToken, pinnedPubKey) to prove
  /// possession of the pinned key. Otherwise, fall back to the raw
  /// `_deviceToken` for backward compatibility with unpinned devices.
  Future<String> _getSenderTokenForDevice(String receiverId) async {
    final trustedDevice = _trustedDevices[receiverId];

    if (trustedDevice != null && trustedDevice.hasActivePin) {
      try {
        return await EncryptionService.deriveBoundToken(
          senderToken: _deviceToken,
          pinnedPubKeyBase64Url: trustedDevice.pinnedPubKey!,
        );
      } catch (_) {
        // Fall through to raw token on derivation failure
      }
    }

    return _deviceToken;
  }

  Future<void> _handleTransferInitiate(HttpRequest request) async {
    try {
      // Per-IP rate limit: prevent approval-prompt spam / DoS.
      final remoteIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';
      if (!_checkInitiateRateLimit(remoteIp)) {
        await _sendTooManyRequests(request);
        return;
      }

      final body = await utf8.decoder.bind(request).join();
      final data = _validateAndParseJson(body);

      if (data == null) {
        await _sendBadRequest(request, 'Invalid JSON format');
        return;
      }

      if (!_validateTransferData(data)) {
        await _sendBadRequest(request, 'Missing or invalid required fields');
        return;
      }

      final senderId = data['senderId'] as String;
      final senderName = data['senderName'] as String? ?? 'Unknown Device';
      final senderToken = data['senderToken'] as String;
      final requestId = data['id'] as String;
      final senderPublicKeyList = data['publicKey'] as List?;

      Uint8List? senderPublicKey;
      if (senderPublicKeyList != null) {
        senderPublicKey = Uint8List.fromList(senderPublicKeyList.cast<int>());
      }

      List<TransferItem> items;
      try {
        items = (data['items'] as List).map((item) {
          if (item is! Map<String, dynamic>) {
            throw const FormatException('Invalid item format');
          }
          return TransferItem.fromJson(item);
        }).toList();
      } catch (e) {
        await _sendBadRequest(request, 'Invalid transfer items format');
        return;
      }

      if (items.isEmpty) {
        await _sendBadRequest(request, 'No items to transfer');
        return;
      }

      // Idempotency: a retried or duplicated /transfer/initiate for a transfer
      // we've already seen must NOT spawn a second approval prompt. This guards
      // against the sender's retry logic (or a double send) re-initiating —
      // especially after the user already approved, which would otherwise
      // recreate a pending request and pop the sheet a second time.
      if (_activeTransfers.containsKey(requestId)) {
        // Already approved / in-flight — report the approved state so a retried
        // initiate can resume instead of prompting again.
        final myPublicKey = await getPublicKey();
        await _sendResponse(request, HttpStatus.ok, {
          'status': 'accepted',
          'transferId': requestId,
          'authorized': true,
          'encryption': encryptionEnabled,
          'publicKey': myPublicKey?.toList(),
        });
        return;
      }
      if (_pendingRequests.containsKey(requestId)) {
        // Still awaiting the user's decision — re-report pending without adding
        // another PendingTransferRequest (which would re-emit and re-show).
        await _sendResponse(request, HttpStatus.ok, {
          'status': 'pending_approval',
          'requestId': requestId,
          'message': 'Waiting for receiver approval',
        });
        return;
      }

      final trustedDevice = _trustedDevices[senderId];
      
      // Check if auto-accept is enabled for trusted devices
      final autoAcceptTrusted = await _settingsService.getAutoAcceptTrusted();
      
      if (trustedDevice != null &&
          await _verifyDeviceToken(
            senderId: senderId,
            presentedToken: senderToken,
          ) &&
          autoAcceptTrusted) {
        if (senderPublicKey != null && encryptionEnabled) {
          final sharedSecret = await _performKeyExchange(senderPublicKey);
          _encryptionSessions[senderId] = EncryptionSession(
            sessionId: '$_deviceId-$senderId',
            sharedSecret: sharedSecret,
            createdAt: DateTime.now(),
          );
        }

        _approveTransferRequest(
            requestId, senderId, senderName, senderToken, items);

        final myPublicKey = await getPublicKey();

        await _sendResponse(request, HttpStatus.ok, {
          'status': 'accepted',
          'transferId': requestId,
          'authorized': true,
          'encryption': encryptionEnabled,
          'publicKey': myPublicKey?.toList(),
        });
        return;
      }

      _pendingRequests[requestId] = PendingTransferRequest(
        requestId: requestId,
        senderId: senderId,
        senderName: senderName,
        senderToken: senderToken,
        items: items,
        timestamp: DateTime.now(),
        senderPublicKey: senderPublicKey,
        isTrusted: trustedDevice != null,
      );

      // Notify UI via stream (this will show the modal sheet if app is in foreground)
      if (!_pendingRequestsController.isClosed) {
        _pendingRequestsController.add(_pendingRequests.values.toList());
      }

      // NOTE: onTransferRequest callback is NOT called here to avoid double-showing
      // The UI listens to pendingRequestsStream via pendingTransferRequestsProvider
      // Calling both would result in duplicate transfer request dialogs

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'pending_approval',
        'requestId': requestId,
        'message': 'Waiting for receiver approval',
      });
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error initiating transfer: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');
      await _sendError(request, 'Error initiating transfer');
    }
  }

  bool _validateTextData(Map<String, dynamic> data) {
    if (!data.containsKey('senderId') || data['senderId'] is! String) {
      return false;
    }
    if (!data.containsKey('id') || data['id'] is! String) return false;
    if (!data.containsKey('senderToken') || data['senderToken'] is! String) {
      return false;
    }

    final text = data['text'];
    if (text is! String || text.trim().isEmpty) return false;
    if (text.length > _maxTextLengthBytes) return false;

    final senderId = data['senderId'] as String;
    if (senderId.isEmpty || senderId.length > 100) return false;

    return true;
  }

  /// Handles an incoming text-message transfer (`POST /transfer/text`).
  ///
  /// Text rides the same approval pipeline as files: an unknown sender is
  /// queued for manual approval (sheet, notification actions, trust checkbox
  /// all apply unchanged), while a trusted sender with a valid token and
  /// auto-accept enabled gets the message delivered immediately.
  Future<void> _handleTextTransfer(HttpRequest request) async {
    try {
      final body = await utf8.decoder.bind(request).join();
      final data = _validateAndParseJson(body);

      if (data == null) {
        await _sendBadRequest(request, 'Invalid JSON format');
        return;
      }

      if (!_validateTextData(data)) {
        await _sendBadRequest(request, 'Missing or invalid required fields');
        return;
      }

      final senderId = data['senderId'] as String;
      final senderName = data['senderName'] as String? ?? 'Unknown Device';
      final senderToken = data['senderToken'] as String;
      final requestId = data['id'] as String;
      final text = (data['text'] as String).trim();

      // Idempotency: a retried /transfer/text for a request we already saw
      // must not queue a second prompt or deliver twice.
      if (_activeTransfers.containsKey(requestId)) {
        await _sendResponse(request, HttpStatus.ok, {
          'status': 'accepted',
          'transferId': requestId,
        });
        return;
      }
      if (_pendingRequests.containsKey(requestId)) {
        await _sendResponse(request, HttpStatus.ok, {
          'status': 'pending_approval',
          'requestId': requestId,
          'message': 'Waiting for receiver approval',
        });
        return;
      }

      final trustedDevice = _trustedDevices[senderId];
      final autoAcceptTrusted = await _settingsService.getAutoAcceptTrusted();

      if (trustedDevice != null &&
          await _verifyDeviceToken(
            senderId: senderId,
            presentedToken: senderToken,
          ) &&
          autoAcceptTrusted) {
        await _deliverText(
          senderId: senderId,
          senderName: senderName,
          text: text,
          requestId: requestId,
        );
        await _sendResponse(request, HttpStatus.ok, {
          'status': 'accepted',
          'transferId': requestId,
        });
        return;
      }

      _pendingRequests[requestId] = PendingTransferRequest(
        requestId: requestId,
        senderId: senderId,
        senderName: senderName,
        senderToken: senderToken,
        items: const [],
        timestamp: DateTime.now(),
        textContent: text,
        isTrusted: trustedDevice != null,
      );

      if (!_pendingRequestsController.isClosed) {
        _pendingRequestsController.add(_pendingRequests.values.toList());
      }

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'pending_approval',
        'requestId': requestId,
        'message': 'Waiting for receiver approval',
      });
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error receiving text: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');
      await _sendError(request, 'Error receiving text');
    }
  }

  /// Saves the message as a `.txt` note, records it in history/active
  /// transfers (so approval polls report "approved") and streams it to the UI.
  Future<void> _deliverText({
    required String senderId,
    required String senderName,
    required String text,
    required String requestId,
  }) async {
    final timestamp = DateTime.now();
    final safeSenderName = _fileService.sanitizeFilename(senderName);
    final fileName = '${safeSenderName.isEmpty ? 'device' : safeSenderName}-${timestamp.millisecondsSinceEpoch}.txt';

    final downloadDir = await _fileService.getDownloadDirectory();
    final notesDir =
        Directory('$downloadDir${Platform.pathSeparator}Syndro Notes');
    if (!await notesDir.exists()) {
      await notesDir.create(recursive: true);
    }
    final filePath = '${notesDir.path}${Platform.pathSeparator}$fileName';
    await File(filePath).writeAsString(text);

    if (!_receivedTextController.isClosed) {
      _receivedTextController.add(ReceivedTextMessage(
        senderId: senderId,
        senderName: senderName,
        text: text,
        filePath: filePath,
        timestamp: timestamp,
      ));
    }

    final transfer = Transfer(
      id: requestId,
      senderId: senderId,
      receiverId: _deviceId,
      items: [
        TransferItem(name: fileName, path: filePath, size: text.length),
      ],
      status: TransferStatus.completed,
      progress: TransferProgress(
        bytesTransferred: text.length,
        totalBytes: text.length,
      ),
      createdAt: timestamp,
    );

    _activeTransfers[requestId] = transfer;
    if (!_transferController.isClosed) {
      _transferController.add(transfer);
    }

    await DatabaseHelper.instance.insertTransfer(transfer, null, null);

    await BackgroundTransferService.showTransferComplete(
      fileName: fileName,
      filePath: filePath,
      fileCount: 1,
      totalSize: text.length,
    );
  }

  Future<void> _handleApprovalCheck(
      HttpRequest request, String requestId) async {
    if (requestId.isEmpty || requestId.length > 100) {
      await _sendBadRequest(request, 'Invalid request ID');
      return;
    }

    final pending = _pendingRequests[requestId];

    if (pending == null) {
      final transfer = _activeTransfers[requestId];
      if (transfer != null) {
        final myPublicKey = await getPublicKey();

        await _sendResponse(request, HttpStatus.ok, {
          'status': 'approved',
          'transferId': requestId,
          'encryption': encryptionEnabled,
          'publicKey': myPublicKey?.toList(),
        });
        return;
      }

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'rejected',
        'message': 'Request was rejected or expired',
      });
      return;
    }

    if (DateTime.now().difference(pending.timestamp).inMinutes > 5) {
      _pendingRequests.remove(requestId);
      _pendingRequestsController.add(_pendingRequests.values.toList());

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'expired',
        'message': 'Request expired',
      });
      return;
    }

    await _sendResponse(request, HttpStatus.ok, {
      'status': 'pending',
      'message': 'Waiting for approval',
    });
  }

  Future<void> approveTransfer(String requestId,
      {bool trustSender = false}) async {
    final pending = _pendingRequests[requestId];
    if (pending == null) {
      if (kDebugMode) {
        AppLogger.warn(
            '⚠️ Warning: Attempted to approve non-existent request: $requestId');
      }
      return;
    }

    // FIX: Remove from pending list immediately to prevent double-handling
    _pendingRequests.remove(requestId);
    if (!_pendingRequestsController.isClosed) {
      _pendingRequestsController.add(_pendingRequests.values.toList());
    }

    // Bridge the vulnerable window right after approval: the sender's upload
    // arrives a moment from now, but on Android (esp. MIUI/HyperOS) backgrounding
    // the app can freeze the isolate hosting our HTTP server, so the upload
    // connection gets refused. Bringing up the progress foreground service now
    // acquires CPU + Wi-Fi locks and keeps us alive until the upload starts.
    // On other platforms this just clears the request notification.
    if (Platform.isAndroid) {
      await BackgroundTransferService.startBackgroundTransfer(
        title: 'Receiving files...',
      );
    } else {
      BackgroundTransferService.dismissTransferRequest();
    }

    if (trustSender) {
      _trustedDevices[pending.senderId] = TrustedDevice(
        senderId: pending.senderId,
        senderName: pending.senderName,
        token: pending.senderToken,
        trustedAt: DateTime.now(),
      );
      await _saveTrustedDevices();
    }

    if (pending.senderPublicKey != null && encryptionEnabled) {
      try {
        final sharedSecret =
            await _performKeyExchange(pending.senderPublicKey!);
        _encryptionSessions[pending.senderId] = EncryptionSession(
          sessionId: '$_deviceId-${pending.senderId}',
          sharedSecret: sharedSecret,
          createdAt: DateTime.now(),
        );
        AppLogger.info('🔐 Key exchange completed on approval');
      } catch (e) {
        AppLogger.error('❌ Key exchange failed on approval: $e');
      }
    }

    // FIX: Handle parallel transfer approval differently
    if (pending.isText) {
      // Text messages need no upload phase — deliver straight from the
      // content carried in the request (saved as a .txt note + streamed UI).
      await _deliverText(
        senderId: pending.senderId,
        senderName: pending.senderName,
        text: pending.textContent!,
        requestId: pending.requestId,
      );
      return;
    }

    // FIX: Handle parallel transfer approval differently
    if (pending.isParallelTransfer && pending.parallelData != null) {
      // For parallel transfers, initialize the receiver session
      if (kDebugMode) AppLogger.info('✅ Approving parallel transfer: ${pending.requestId}');
      _transferTokens[pending.requestId] = pending.senderToken;
      final result = await _parallelReceiver.handleInitiate(pending.parallelData!);
      if (result['success'] != true) {
        AppLogger.error('❌ Failed to initialize parallel receiver: ${result['error']}');
      } else {
        // Track the receive in _activeTransfers so the UI shows progress and
        // the completed file lands in history (parallel receives were
        // previously invisible: only an OS notification was shown).
        final receiveTransfer = Transfer(
          id: pending.requestId,
          senderId: pending.senderId,
          receiverId: _deviceId,
          items: pending.items,
          status: TransferStatus.transferring,
          progress: const TransferProgress(bytesTransferred: 0, totalBytes: 0),
          createdAt: DateTime.now(),
          isParallel: true,
        );
        _activeTransfers[pending.requestId] = receiveTransfer;
        _transferController.add(receiveTransfer);
        BackgroundTransferService.startBackgroundTransfer(
          title: 'Receiving from ${pending.senderName}',
          fileName: pending.items.length == 1
              ? pending.items.first.name
              : '${pending.items.length} files',
        );
      }
      // The sender will check approval status and start uploading chunks
    } else {
      _approveTransferRequest(
        requestId,
        pending.senderId,
        pending.senderName,
        pending.senderToken,
        pending.items,
      );
    }
  }

  void rejectTransfer(String requestId) {
    // FIX: Check if request exists and remove it
    final removed = _pendingRequests.remove(requestId);
    if (removed == null) {
      if (kDebugMode) {
        AppLogger.warn(
            '⚠️ Warning: Attempted to reject non-existent request: $requestId');
      }
      return;
    }
    
    // Update UI
    if (!_pendingRequestsController.isClosed) {
      _pendingRequestsController.add(_pendingRequests.values.toList());
    }
    
    // Dismiss notifications
    BackgroundTransferService.stopBackgroundTransfer();
    BackgroundTransferService.dismissTransferRequest();
  }

  void _approveTransferRequest(
    String requestId,
    String senderId,
    String senderName,
    String senderToken,
    List<TransferItem> items,
  ) {
    _cleanupCompletedTransfers();

    final transfer = Transfer(
      id: requestId,
      senderId: senderId,
      receiverId: _deviceId,
      items: items,
      status: TransferStatus.pending,
      progress: const TransferProgress(bytesTransferred: 0, totalBytes: 0),
      createdAt: DateTime.now(),
    );

    _activeTransfers[transfer.id] = transfer;
    _transferTokens[requestId] = senderToken;
    _transferController.add(transfer);

    // Start Live Activity for Android lock screen progress
    if (items.isNotEmpty) {
      final totalBytes = items.fold<int>(0, (sum, item) => sum + item.size);
      if (Platform.isAndroid) {
        LiveActivityService.startTransferActivity(
          fileName: items.length == 1 ? items.first.name : '${items.length} files',
          totalBytes: totalBytes,
          senderName: senderName,
          isIncoming: true,
        );
      }
    }

    BackgroundTransferService.startBackgroundTransfer(
      title: 'Receiving from $senderName',
      fileName: items.length == 1 ? items.first.name : '${items.length} files',
    );
  }

  void _cleanupCompletedTransfers() {
    final completedIds = <String>[];

    for (final entry in _activeTransfers.entries) {
      final status = entry.value.status;
      if (status == TransferStatus.completed ||
          status == TransferStatus.failed ||
          status == TransferStatus.cancelled) {
        completedIds.add(entry.key);
      }
    }

    if (completedIds.length > _maxCompletedTransfers) {
      final toRemove = completedIds
          .map((id) => _activeTransfers[id]!)
          .toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final removeCount = completedIds.length - _maxCompletedTransfers;
      for (int i = 0; i < removeCount; i++) {
        final transfer = toRemove[i];
        _activeTransfers.remove(transfer.id);
        _transferTokens.remove(transfer.id);
        _cleanupProgressController(transfer.id);
        AppLogger.info('🧹 Cleaned up old transfer: ${transfer.id}');
      }
    }
  }

  void _cleanupProgressController(String transferId) {
    final controller = _progressControllers.remove(transferId);
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }

  Future<void> _handleEncryptedFileUpload(HttpRequest request) async {
    IOSink? fileSink;
    String? tempFilePath;
    String? transferId;

    try {
      transferId = request.headers.value('x-transfer-id');
      final fileName = request.headers.value('x-file-name');
      final originalSizeHeader = request.headers.value('x-original-size');
      final senderId = request.headers.value('x-sender-id');
      final senderToken = request.headers.value('x-sender-token');
      final fileHash = request.headers.value('x-file-hash');
      // Read file metadata timestamps
      final modifiedHeader = request.headers.value('x-file-modified');

      final originalSize = originalSizeHeader != null
          ? int.tryParse(originalSizeHeader) ?? 0
          : 0;
      
      // Parse metadata timestamps
      DateTime? fileModified;
      if (modifiedHeader != null) {
        final ms = int.tryParse(modifiedHeader);
        if (ms != null) fileModified = DateTime.fromMillisecondsSinceEpoch(ms);
      }

      if (transferId == null || transferId.isEmpty) {
        await _sendBadRequest(request, 'Missing transfer ID');
        return;
      }

      if (fileName == null || fileName.isEmpty) {
        await _sendBadRequest(request, 'Missing file name');
        return;
      }

      if (senderId == null || senderId.isEmpty) {
        await _sendBadRequest(request, 'Missing sender ID');
        return;
      }

      final transfer = _activeTransfers[transferId];
      if (transfer == null) {
        await _sendUnauthorized(request, 'Transfer not authorized');
        return;
      }

      if (transfer.senderId != senderId) {
        await _sendUnauthorized(request, 'Sender ID mismatch');
        return;
      }

      // Transfer-scoped token check (encrypted path previously verified no
      // token at all — only that some encryption session existed).
      if (!await _isTransferAuthorized(
        transferId: transferId,
        senderId: senderId,
        presentedToken: senderToken,
      )) {
        AppLogger.info('Security: Invalid sender token for transfer $transferId');
        await _sendUnauthorized(request, 'Invalid sender token');
        return;
      }

      final session = _encryptionSessions[senderId];
      if (session == null) {
        await _sendUnauthorized(request, 'No encryption session');
        return;
      }

      // Enforce the size cap on the encrypted path too — previously only the
      // plaintext upload path checked this, leaving encrypted receives
      // unbounded and vulnerable to disk-exhaustion.
      if (originalSize > _maxFileSizeBytes) {
        AppLogger.info(
            'Security: File size $originalSize exceeds maximum $_maxFileSizeBytes');
        await _sendBadRequest(request,
            'File size exceeds maximum allowed size (${_maxFileSizeBytes ~/ (1024 * 1024 * 1024)}GB)');
        return;
      }

      final sanitizedFileName = _fileService.sanitizeFilename(fileName);

      _activeTransfers[transferId] = transfer.copyWith(
        status: TransferStatus.transferring,
      );
      _transferController.add(_activeTransfers[transferId]!);

      final downloadDir = await _fileService.getDownloadDirectory();
      final finalFilePath =
          '$downloadDir${Platform.pathSeparator}$sanitizedFileName';
      // Scope temp path to the transfer id to avoid same-name collisions.
      tempFilePath = '$finalFilePath.$transferId.tmp';

      if (!_fileService.isPathWithinDirectory(finalFilePath, downloadDir)) {
        await _sendBadRequest(request, 'Invalid filename');
        return;
      }

      final dir = Directory(downloadDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final tempFile = File(tempFilePath);
      fileSink = tempFile.openWrite();

      int bytesReceived = 0;
      List<int> buffer = [];
      int lastReportedProgress = -1;
      const int maxBufferSize = 10 * 1024 * 1024; // 10MB max buffer

      // Use streaming SHA-256 to avoid loading entire file into memory
      final hashOutput = AccumulatorSink<crypto_hash.Digest>();
      final hashInput = crypto_hash.sha256.startChunkedConversion(hashOutput);

      await for (final chunk in request) {
        buffer.addAll(chunk);

        // Check buffer size to prevent memory exhaustion
        if (buffer.length > maxBufferSize) {
          AppLogger.info('Buffer overflow: ${buffer.length} > $maxBufferSize');
          await _sendBadRequest(request, 'Buffer overflow - chunk size mismatch');
          await fileSink.close();
          try {
            await File(tempFilePath).delete();
          } catch (e) {
            AppLogger.error('⚠️ Failed to delete temp file: $e');
          }
          return;
        }

        while (buffer.length >= 4) {
          final sizeBytes = Uint8List.fromList(buffer.sublist(0, 4));
          final byteData = ByteData.view(sizeBytes.buffer);
          final chunkSize = byteData.getUint32(0, Endian.big);

          if (buffer.length < 4 + chunkSize) {
            break;
          }

          final encryptedChunk =
              Uint8List.fromList(buffer.sublist(4, 4 + chunkSize));
          buffer = buffer.sublist(4 + chunkSize);

          final decrypted =
              await _decryptChunk(encryptedChunk, session.sharedSecret);

          fileSink.add(decrypted);
          hashInput.add(decrypted);

          bytesReceived += decrypted.length;

          final progressPercent = originalSize > 0
              ? ((bytesReceived / originalSize) * 100).toInt()
              : 0;

          if (progressPercent - lastReportedProgress >= 5) {
            lastReportedProgress = progressPercent;
            await BackgroundTransferService.updateProgress(
              title: 'Receiving (encrypted)...',
              fileName: sanitizedFileName,
              progress: progressPercent,
              bytesTransferred: bytesReceived,
              totalBytes: originalSize,
            );

            final updatedTransfer = _activeTransfers[transferId]!.copyWith(
              progress: TransferProgress(
                bytesTransferred: bytesReceived,
                totalBytes: originalSize > 0 ? originalSize : bytesReceived,
              ),
            );
            _activeTransfers[transferId] = updatedTransfer;
            _transferController.add(updatedTransfer);
          }
        }
      }

      await fileSink.flush();
      await fileSink.close();
      fileSink = null;

      // Byte accounting: a truncated upload (sender disconnected mid-stream,
      // or a malicious short send) must never be accepted as complete.
      if (originalSize > 0 && bytesReceived != originalSize) {
        AppLogger.info(
            'Security: Size mismatch for $transferId — declared $originalSize, '
            'received $bytesReceived');
        throw TransferException(
          'File size mismatch: expected $originalSize bytes, received $bytesReceived',
          code: 'SIZE_MISMATCH',
        );
      }

      hashInput.close();
      final calculatedHash = hashOutput.events.single.toString();

      // Integrity check is mandatory on the encrypted path — the sender always
      // sends x-file-hash, so a missing hash means a downgraded client or a
      // tampered request and must not pass silently.
      if (fileHash == null || fileHash.isEmpty) {
        AppLogger.info(
            'Security: Missing file hash for encrypted transfer $transferId');
        throw TransferException('Missing file integrity hash',
            code: 'MISSING_HASH');
      }

      if (calculatedHash != fileHash) {
        await File(tempFilePath).delete();
        throw TransferException('File integrity check failed',
            code: 'HASH_MISMATCH');
      }
      AppLogger.info('✅ File integrity verified');

      final tempFileRef = File(tempFilePath);
      final finalFile = File(finalFilePath);

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFileRef.rename(finalFilePath);
      tempFilePath = null;

      // Apply file metadata (modification time)
      if (fileModified != null) {
        try {
          await finalFile.setLastModified(fileModified);
          AppLogger.info('📅 Applied file modification time: $fileModified');
        } catch (e) {
          AppLogger.warn('⚠️ Could not set file modification time: $e');
        }
      }

      final completedTransfer = _activeTransfers[transferId]!.copyWith(
        status: TransferStatus.completed,
        progress: TransferProgress(
          bytesTransferred: bytesReceived,
          totalBytes: bytesReceived,
        ),
      );

      _activeTransfers[transferId] = completedTransfer;
      _transferController.add(completedTransfer);

      // End Live Activity on completion
      if (Platform.isAndroid) {
        LiveActivityService.endActivity(success: true, message: 'Transfer complete');
      }

      await BackgroundTransferService.showTransferComplete(
        fileName: sanitizedFileName,
        filePath: finalFilePath,
        fileCount: 1,
        totalSize: bytesReceived,
      );

      await DatabaseHelper.instance
          .insertTransfer(completedTransfer, null, null);

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'completed',
        'bytesReceived': bytesReceived,
        'filePath': finalFilePath,
        'encrypted': true,
        'verified': true,
      });

      if (kDebugMode) AppLogger.info('🔐 Encrypted file received: $finalFilePath');

      _cleanupCompletedTransfers();
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error receiving encrypted file: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');

      if (fileSink != null) {
        try {
          await fileSink.close();
        } catch (closeError) {
          AppLogger.error('Error closing file sink: $closeError');
        }
      }

      if (tempFilePath != null) {
        try {
          final tempFile = File(tempFilePath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (deleteError) {
          AppLogger.error('Error deleting temp file: $deleteError');
        }
      }

      // Reconcile the UI: the receive failed, so the transfer must not stay
      // stuck in "transferring" forever.
      if (transferId != null) {
        final activeTransfer = _activeTransfers[transferId];
        if (activeTransfer != null &&
            activeTransfer.status != TransferStatus.completed) {
          final failedTransfer = activeTransfer.copyWith(
            status: TransferStatus.failed,
            errorMessage: e.toString(),
          );
          _activeTransfers[transferId] = failedTransfer;
          _transferController.add(failedTransfer);
        }
      }

            await BackgroundTransferService.stopBackgroundTransfer();
      if (e is TransferException) {
        // Expected protocol failures (size mismatch, hash mismatch) are
        // client errors — 400, not 500.
        await _sendBadRequest(request, e.message);
      } else {
        await _sendError(request, 'Error receiving encrypted file');
      }
    }
  }

  Future<void> _handleFileUpload(HttpRequest request) async {
    IOSink? fileSink;
    String? tempFilePath;
    String? transferId;

    try {
      transferId = request.headers.value('x-transfer-id');
      final fileName = request.headers.value('x-file-name');
      final fileSizeHeader = request.headers.value('x-file-size');
      final senderId = request.headers.value('x-sender-id');
      final senderToken = request.headers.value('x-sender-token');
      // Read file metadata timestamps
      final modifiedHeader = request.headers.value('x-file-modified');

      final fileSize =
          fileSizeHeader != null ? int.tryParse(fileSizeHeader) ?? 0 : 0;
      
      // Parse metadata timestamps
      DateTime? fileModified;
      if (modifiedHeader != null) {
        final ms = int.tryParse(modifiedHeader);
        if (ms != null) fileModified = DateTime.fromMillisecondsSinceEpoch(ms);
      }

      if (transferId == null || transferId.isEmpty) {
        await _sendBadRequest(request, 'Missing transfer ID header');
        return;
      }

      if (fileName == null || fileName.isEmpty) {
        await _sendBadRequest(request, 'Missing file name header');
        return;
      }

      if (senderId == null || senderId.isEmpty) {
        await _sendBadRequest(request, 'Missing sender ID header');
        return;
      }

      if (senderToken == null || senderToken.isEmpty) {
        await _sendBadRequest(request, 'Missing sender token header');
        return;
      }

      // Validate file size limit
      if (fileSize > _maxFileSizeBytes) {
        AppLogger.info('Security: File size $fileSize exceeds maximum $_maxFileSizeBytes');
        await _sendBadRequest(request,
            'File size exceeds maximum allowed size (${_maxFileSizeBytes ~/ (1024 * 1024 * 1024)}GB)');
        return;
      }

      final transfer = _activeTransfers[transferId];
      if (transfer == null) {
        await _sendUnauthorized(
            request, 'Transfer not authorized. Request approval first.');
        return;
      }

      if (transfer.senderId != senderId) {
        AppLogger.info(
            'Security: Sender ID mismatch. Expected: ${transfer.senderId}, Got: $senderId');
        await _sendUnauthorized(request, 'Sender ID mismatch');
        return;
      }

      // Transfer-scoped token check: the presented token must match the token
      // accepted for THIS transfer (or a valid trusted-device token).
      if (!await _isTransferAuthorized(
        transferId: transferId,
        senderId: senderId,
        presentedToken: senderToken,
      )) {
        AppLogger.info('Security: Invalid sender token for transfer $transferId');
        await _sendUnauthorized(request, 'Invalid sender token');
        return;
      }

      // B4: Reject plaintext downgrade. If this sender completed a key exchange
      // we have a live encryption session for it; a plaintext upload on the
      // unencrypted endpoint would be a silent downgrade. Force the encrypted
      // path instead of trusting the sender's choice of endpoint.
      if (_encryptionSessions.containsKey(senderId)) {
        AppLogger.info(
            'Security: Rejected plaintext upload for key-exchanged sender $senderId');
        await _sendUnauthorized(
            request, 'Encryption required for this session');
        return;
      }

      final sanitizedFileName = _fileService.sanitizeFilename(fileName);
      if (sanitizedFileName != fileName) {
        AppLogger.info(
            'Security: Filename was sanitized. Original: $fileName, Sanitized: $sanitizedFileName');
      }

      _activeTransfers[transferId] = transfer.copyWith(
        status: TransferStatus.transferring,
      );
      _transferController.add(_activeTransfers[transferId]!);

      final downloadDir = await _fileService.getDownloadDirectory();
      final finalFilePath =
          '$downloadDir${Platform.pathSeparator}$sanitizedFileName';
      // Scope temp path to the transfer id so two concurrent transfers of the
      // same filename cannot collide on a shared "<name>.tmp" scratch file.
      tempFilePath = '$finalFilePath.$transferId.tmp';

      if (!_fileService.isPathWithinDirectory(finalFilePath, downloadDir)) {
        AppLogger.info(
            'Security: Path traversal attempt detected for file: $fileName');
        await _sendBadRequest(request, 'Invalid filename');
        return;
      }

      final dir = Directory(downloadDir);
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final tempFile = File(tempFilePath);
      fileSink = tempFile.openWrite();

      int bytesReceived = 0;
      int lastProgressPercent = 0;

      await for (final chunk in request) {
        fileSink.add(chunk);
        bytesReceived += chunk.length;

        final progressPercent =
            fileSize > 0 ? ((bytesReceived / fileSize) * 100).toInt() : 0;

        if (progressPercent != lastProgressPercent) {
          lastProgressPercent = progressPercent;

          await BackgroundTransferService.updateProgress(
            title: 'Receiving files...',
            fileName: sanitizedFileName,
            progress: progressPercent,
            bytesTransferred: bytesReceived,
            totalBytes: fileSize,
          );

          final updatedTransfer = _activeTransfers[transferId]!.copyWith(
            progress: TransferProgress(
              bytesTransferred: bytesReceived,
              totalBytes: fileSize > 0 ? fileSize : bytesReceived,
            ),
          );
          _activeTransfers[transferId] = updatedTransfer;
          _transferController.add(updatedTransfer);
        }
      }

      // Byte accounting: reject truncated uploads (sender disconnected
      // mid-stream) instead of silently accepting a partial file.
      if (fileSize > 0 && bytesReceived != fileSize) {
        AppLogger.info(
            'Security: Size mismatch for $transferId — declared $fileSize, '
            'received $bytesReceived');
        throw TransferException(
          'File size mismatch: expected $fileSize bytes, received $bytesReceived',
          code: 'SIZE_MISMATCH',
        );
      }

      await fileSink.flush();
      await fileSink.close();
      fileSink = null;

      final tempFileRef = File(tempFilePath);
      final finalFile = File(finalFilePath);

      if (await finalFile.exists()) {
        await finalFile.delete();
      }
      await tempFileRef.rename(finalFilePath);
      tempFilePath = null;

      // Apply file metadata (modification time)
      if (fileModified != null) {
        try {
          await finalFile.setLastModified(fileModified);
          AppLogger.info('📅 Applied file modification time: $fileModified');
        } catch (e) {
          AppLogger.warn('⚠️ Could not set file modification time: $e');
        }
      }

      final completedTransfer = _activeTransfers[transferId]!.copyWith(
        status: TransferStatus.completed,
        progress: TransferProgress(
          bytesTransferred: bytesReceived,
          totalBytes: bytesReceived,
        ),
      );

      _activeTransfers[transferId] = completedTransfer;
      _transferController.add(completedTransfer);

      // End Live Activity on completion
      if (Platform.isAndroid) {
        LiveActivityService.endActivity(success: true, message: 'Transfer complete');
      }

      await BackgroundTransferService.showTransferComplete(
        fileName: sanitizedFileName,
        filePath: finalFilePath,
        fileCount: 1,
        totalSize: bytesReceived,
      );

      await DatabaseHelper.instance
          .insertTransfer(completedTransfer, null, null);

      await _sendResponse(request, HttpStatus.ok, {
        'status': 'completed',
        'bytesReceived': bytesReceived,
        'filePath': finalFilePath,
        'encrypted': false,
      });

      _cleanupCompletedTransfers();
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error uploading file: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');

      if (fileSink != null) {
        try {
          await fileSink.close();
        } catch (closeError) {
          AppLogger.error('Error closing file sink: $closeError');
        }
      }

      if (tempFilePath != null) {
        try {
          final tempFile = File(tempFilePath);
          if (await tempFile.exists()) {
            await tempFile.delete();
          }
        } catch (deleteError) {
          AppLogger.error('Error deleting temp file: $deleteError');
        }
      }

      // Reconcile the UI: the receive failed, so the transfer must not stay
      // stuck in "transferring" forever.
      if (transferId != null) {
        final activeTransfer = _activeTransfers[transferId];
        if (activeTransfer != null &&
            activeTransfer.status != TransferStatus.completed) {
          final failedTransfer = activeTransfer.copyWith(
            status: TransferStatus.failed,
            errorMessage: e.toString(),
          );
          _activeTransfers[transferId] = failedTransfer;
          _transferController.add(failedTransfer);
        }
      }

            await BackgroundTransferService.stopBackgroundTransfer();
      if (e is TransferException) {
        // Expected protocol failures (size mismatch) are client errors.
        await _sendBadRequest(request, e.message);
      } else {
        await _sendError(request, 'Error uploading file');
      }
    }
  }

  Future<void> _handleTransferStatus(
      HttpRequest request, String transferId) async {
    if (transferId.isEmpty || transferId.length > 100) {
      await _sendBadRequest(request, 'Invalid transfer ID');
      return;
    }

    final transfer = _activeTransfers[transferId];
    if (transfer == null) {
      await _sendNotFound(request, 'Transfer not found');
      return;
    }

    await _sendResponse(request, HttpStatus.ok, {
      'id': transfer.id,
      'status': transfer.status.name,
      'progress': {
        'bytesTransferred': transfer.progress.bytesTransferred,
        'totalBytes': transfer.progress.totalBytes,
        'percentage': transfer.progress.percentage,
      },
    });
  }

  Future<void> sendFiles({
    required Device sender,
    required Device receiver,
    required List<TransferItem> items,
    bool? encrypted,
  }) async {
    // IMPROVEMENT: Add validation for placeholder/empty IDs
    if (sender.isPlaceholder) {
      throw TransferException('Invalid sender device', code: 'INVALID_SENDER');
    }
    
    if (receiver.isPlaceholder) {
      throw TransferException('Invalid receiver device', code: 'INVALID_RECEIVER');
    }
    
    if (items.isEmpty) {
      throw TransferException('No items to transfer', code: 'EMPTY_ITEMS');
    }

    // IMPROVEMENT: Validate all items have valid paths
    for (final item in items) {
      if (item.path.isEmpty) {
        throw TransferException('Item has invalid path: ${item.name}', code: 'INVALID_PATH');
      }
    }

    _cleanupCompletedTransfers();

    final checkpointKey = _generateCheckpointKey(sender.id, receiver.id, items);
    final checkpoint = await _checkpointManager.loadCheckpoint(checkpointKey);
    final startIndex = checkpoint?.currentFileIndex ?? 0;
    final resumedBytes = checkpoint?.bytesTransferred ?? 0;

    final transferId = checkpoint != null ? checkpointKey : _uuid.v4();
    final totalSize = items.fold<int>(0, (sum, item) => sum + item.size);

    final useParallel = _parallelConfig?.shouldUseParallel(totalSize) ?? false;

    // Store in local variable to avoid force unwrap and ensure thread safety
    final parallelSender = _parallelSender;
    if (useParallel && items.length == 1 && parallelSender != null) {
      if (kDebugMode) {
        AppLogger.info(
            '⚡ Using parallel transfer for large file (${totalSize ~/ (1024 * 1024)}MB)');
      }

      final item = items.first;
      final file = File(item.path);

      SecretKey? encryptionKey;
      final shouldEncrypt = encrypted ?? encryptionEnabled;

      if (shouldEncrypt && encryptionEnabled) {
        AppLogger.info('🔐 Starting key exchange with receiver...');
        final myPublicKey = await getPublicKey();

        final keyExchangeUrl =
            'http://${receiver.ipAddress}:${receiver.port}/key-exchange';

        try {
          final keyResponse = await http.post(
            Uri.parse(keyExchangeUrl),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'deviceId': sender.id,
              'publicKey': myPublicKey?.toList(),
            }),
          ).timeout(
            const Duration(seconds: 10),
            onTimeout: () => throw TimeoutException('Key exchange timeout'),
          );

          if (keyResponse.statusCode == 200) {
            final keyData = jsonDecode(keyResponse.body);
            final receiverPublicKeyList = keyData['publicKey'] as List?;

            if (receiverPublicKeyList != null) {
              final receiverPublicKey =
                  Uint8List.fromList(receiverPublicKeyList.cast<int>());
              encryptionKey = await _performKeyExchange(receiverPublicKey);

              _encryptionSessions[receiver.id] = EncryptionSession(
                sessionId: '${sender.id}-${receiver.id}',
                sharedSecret: encryptionKey,
                createdAt: DateTime.now(),
              );
              AppLogger.info('🔐 Key exchange successful');
            }
          }
        } catch (e) {
          // B4: never silently downgrade a parallel transfer to plaintext.
          AppLogger.error('❌ Key exchange failed: $e');
          throw TransferException(
            'Secure key exchange failed; refusing to send unencrypted. $e',
            code: 'KEY_EXCHANGE_FAILED',
          );
        }

        // B4: if encryption was requested but no key was derived (e.g. receiver
        // returned no public key / non-200), abort rather than send plaintext.
        if (encryptionKey == null) {
          throw TransferException(
            'Secure key exchange failed; refusing to send unencrypted.',
            code: 'KEY_EXCHANGE_FAILED',
          );
        }
      }

      // Create transfer with "transferring" status
      // FIX: Receiver is now notified immediately (hash calculated in parallel with upload)
      final parallelTransfer = Transfer(
        id: transferId,
        senderId: sender.id,
        receiverId: receiver.id,
        items: items,
        status: TransferStatus.transferring,
        progress: TransferProgress(
          bytesTransferred: 0,
          totalBytes: totalSize,
        ),
        createdAt: DateTime.now(),
        isParallel: true,
      );

      _activeTransfers[transferId] = parallelTransfer;
      _transferController.add(parallelTransfer);
      _parallelTransferReceivers[transferId] = receiver;

      int lastReportedProgress = -1;
      try {
        // Compute sender token — uses bound token for pinned devices
        final senderToken = await _getSenderTokenForDevice(receiver.id);
        await parallelSender.sendFileParallel(
          transferId: transferId,
          file: file,
          receiver: receiver,
          senderToken: senderToken,
          sender: sender,
          encryptionKey: encryptionKey,
          onProgress: (sent, total) {
            final updatedTransfer = parallelTransfer.copyWith(
              status: TransferStatus.transferring,
              progress: TransferProgress(
                bytesTransferred: sent,
                totalBytes: total,
              ),
            );
            _activeTransfers[transferId] = updatedTransfer;
            _transferController.add(updatedTransfer);

            final progressPercent = (sent / total * 100).toInt();
            if (progressPercent != lastReportedProgress) {
              lastReportedProgress = progressPercent;
              BackgroundTransferService.updateProgress(
                title: 'Sending to ${receiver.name}',
                fileName: item.name,
                progress: progressPercent,
                bytesTransferred: sent,
                totalBytes: total,
              );
            }
          },
        );

        final completedTransfer = parallelTransfer.copyWith(
          status: TransferStatus.completed,
          progress: TransferProgress(
            bytesTransferred: totalSize,
            totalBytes: totalSize,
          ),
        );

        _activeTransfers[transferId] = completedTransfer;
        _transferController.add(completedTransfer);

        await DatabaseHelper.instance
            .insertTransfer(completedTransfer, sender, receiver);

        await BackgroundTransferService.showTransferComplete(
          fileName: item.name,
          filePath: item.path,
          fileCount: 1,
          totalSize: totalSize,
        );

        _cleanupProgressController(transferId);
        _parallelTransferReceivers.remove(transferId);
        return;
      } catch (e) {
        AppLogger.error('❌ Parallel transfer failed: $e');

        // A user-initiated cancellation already updated the state — don't
        // overwrite it with "failed" (mirrors the sequential path).
        if (_activeTransfers[transferId]?.status == TransferStatus.cancelled) {
          if (kDebugMode) {
            AppLogger.info('Parallel transfer cancelled by user: $transferId');
          }
          _parallelTransferReceivers.remove(transferId);
          BackgroundTransferService.stopBackgroundTransfer();
          _cleanupProgressController(transferId);
          _cleanupCompletedTransfers();
          return;
        }

        final failedTransfer = parallelTransfer.copyWith(
          status: TransferStatus.failed,
          errorMessage: e.toString(),
        );

        _activeTransfers[transferId] = failedTransfer;
        _transferController.add(failedTransfer);
        _parallelTransferReceivers.remove(transferId);

        BackgroundTransferService.stopBackgroundTransfer();
        _cleanupProgressController(transferId);
        rethrow;
      }
    }

    AppLogger.info('Using sequential transfer for ${items.length} file(s)');

    if (checkpoint != null) {
      if (kDebugMode) {
        AppLogger.info(
            '📂 Resuming transfer from checkpoint: file $startIndex, $resumedBytes bytes');
      }
    }

    final transfer = Transfer(
      id: transferId,
      senderId: sender.id,
      receiverId: receiver.id,
      items: items,
      status: TransferStatus.connecting,
      progress: TransferProgress(
        bytesTransferred: resumedBytes,
        totalBytes: totalSize,
      ),
      createdAt: DateTime.now(),
    );

    _activeTransfers[transferId] = transfer;
    _transferController.add(transfer);

    await BackgroundTransferService.startBackgroundTransfer(
      title: 'Sending to ${receiver.name}',
      fileName: items.length == 1 ? items.first.name : '${items.length} files',
    );

    try {
      final myPublicKey = await getPublicKey();
      // Compute sender token — uses bound token for pinned devices
      final senderToken = await _getSenderTokenForDevice(receiver.id);

      final initiateUrl =
          'http://${receiver.ipAddress}:${receiver.port}/transfer/initiate';

      final initiateResponse = await _retryRequest(
        () => http.post(
          Uri.parse(initiateUrl),
          headers: {
            'Content-Type': 'application/json',
            'x-device-id': sender.id,
          },
          body: jsonEncode({
            'id': transferId,
            'senderId': sender.id,
            'senderName': sender.name,
            'senderToken': senderToken,
            'receiverId': receiver.id,
            'items': items.map((item) => item.toJson()).toList(),
            'publicKey': myPublicKey?.toList(),
          }),
        ).timeout(
          const Duration(seconds: 15),
          onTimeout: () => throw TimeoutException('Transfer initiate timeout'),
        ),
      );

      if (initiateResponse.statusCode != 200) {
        throw TransferException(
          'Failed to initiate transfer',
          code: 'INITIATE_FAILED_${initiateResponse.statusCode}',
        );
      }

      final initiateData = _validateAndParseJson(initiateResponse.body);
      if (initiateData == null) {
        throw TransferException('Invalid response from receiver',
            code: 'INVALID_RESPONSE');
      }

      final status = initiateData['status'] as String? ?? '';
      final receiverSupportsEncryption =
          initiateData['encryption'] as bool? ?? false;
      final receiverPublicKeyList = initiateData['publicKey'] as List?;

      bool useEncryption = encrypted ??
          (encryptionEnabled &&
              receiverSupportsEncryption &&
              receiverPublicKeyList != null);

      SecretKey? sharedSecret;
      if (useEncryption && receiverPublicKeyList != null) {
        try {
          final receiverPublicKey =
              Uint8List.fromList(receiverPublicKeyList.cast<int>());
          sharedSecret = await _performKeyExchange(receiverPublicKey);

          _encryptionSessions[receiver.id] = EncryptionSession(
            sessionId: '${sender.id}-${receiver.id}',
            sharedSecret: sharedSecret,
            createdAt: DateTime.now(),
          );

          AppLogger.info('🔐 Key exchange successful, encryption enabled');
        } catch (e) {
          // B4: Do NOT silently fall back to plaintext. If encryption was
          // negotiated, a key-exchange failure must surface to the user rather
          // than downgrading the transfer to an unencrypted channel.
          AppLogger.error('❌ Key exchange failed: $e');
          throw TransferException(
            'Secure key exchange failed; refusing to send unencrypted. $e',
            code: 'KEY_EXCHANGE_FAILED',
          );
        }
      }

      if (status == 'pending_approval') {
        _activeTransfers[transferId] = transfer.copyWith(
          status: TransferStatus.pending,
        );
        _transferController.add(_activeTransfers[transferId]!);

        final approved = await _waitForApproval(
          receiver: receiver,
          requestId: transferId,
          timeout: const Duration(minutes: 5),
          senderId: sender.id,
        );

        if (!approved.approved) {
          throw TransferException('Transfer rejected or timed out',
              code: 'REJECTED');
        }

        // In the manual-approval flow the receiver only performs key exchange
        // once the user approves, so the encryption negotiation is finalized
        // here (not in the initiate response). Adopt the session established
        // during approval; otherwise we would send plaintext to a receiver
        // that now expects encryption and get rejected mid-upload.
        if (approved.sharedSecret != null) {
          useEncryption = true;
          sharedSecret = approved.sharedSecret;
        }
      }

      int totalBytesTransferred = checkpoint?.bytesTransferred ?? 0;

      for (int i = startIndex; i < items.length; i++) {
        final item = items[i];

        try {
          final file = File(item.path);

          if (!await file.exists()) {
            throw TransferException('File not found: ${item.path}',
                code: 'FILE_NOT_FOUND');
          }

          final fileSize = await file.length();

          if (useEncryption && sharedSecret != null) {
            await _sendFileEncrypted(
              receiver: receiver,
              transferId: transferId,
              sender: sender,
              item: item,
              file: file,
              fileSize: fileSize,
              sharedSecret: sharedSecret,
              totalSize: totalSize,
              totalBytesTransferred: totalBytesTransferred,
            );
          } else {
            await _sendFileUnencrypted(
              receiver: receiver,
              transferId: transferId,
              sender: sender,
              item: item,
              file: file,
              fileSize: fileSize,
              totalSize: totalSize,
              totalBytesTransferred: totalBytesTransferred,
            );
          }

          totalBytesTransferred += fileSize;

          await _checkpointManager.saveCheckpoint(
            TransferCheckpoint(
              transferId: transferId,
              fileId: item.path,
              bytesTransferred: totalBytesTransferred,
              timestamp: DateTime.now(),
              currentFileIndex: i + 1,
              totalFiles: items.length,
            ),
          );
        } catch (e, stackTrace) {
          AppLogger.error('Error sending file ${item.name}: $e');
          AppLogger.info('Stack trace: $stackTrace');
          rethrow;
        }
      }

      final completedTransfer = transfer.copyWith(
        status: TransferStatus.completed,
        progress: TransferProgress(
            bytesTransferred: totalSize, totalBytes: totalSize),
      );

      _activeTransfers[transferId] = completedTransfer;
      _transferController.add(completedTransfer);

      // End Live Activity on completion
      if (Platform.isAndroid) {
        LiveActivityService.endActivity(success: true, message: 'Transfer complete');
      }

      await BackgroundTransferService.showTransferComplete(
        fileName:
            items.length == 1 ? items.first.name : '${items.length} files',
        filePath: '',
        fileCount: items.length,
        totalSize: totalSize,
      );

      await DatabaseHelper.instance
          .insertTransfer(completedTransfer, sender, receiver);

      await _checkpointManager.clearCheckpoint(transferId);

      if (kDebugMode) {
        AppLogger.info(
            '✅ Transfer completed ${useEncryption ? "(encrypted)" : "(unencrypted)"}');
      }

      _cleanupCompletedTransfers();
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error sending files: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');

      await BackgroundTransferService.stopBackgroundTransfer();

      // A user-initiated cancellation (e.g. while paused) already updated
      // the state — don't overwrite it with "failed".
      if (_activeTransfers[transferId]?.status == TransferStatus.cancelled) {
        if (kDebugMode) {
          AppLogger.info('Transfer cancelled by user: $transferId');
        }
        _cleanupCompletedTransfers();
        return;
      }

      final failedTransfer = transfer.copyWith(
        status: TransferStatus.failed,
        errorMessage: e.toString(),
      );

      _activeTransfers[transferId] = failedTransfer;
      _transferController.add(failedTransfer);

      await DatabaseHelper.instance
          .insertTransfer(failedTransfer, sender, receiver);

      if (e is TransferException) {
        rethrow;
      }

      throw TransferException('Transfer failed', originalError: e);
    }
  }

  Future<void> _sendFileEncrypted({
    required Device receiver,
    required String transferId,
    required Device sender,
    required TransferItem item,
    required File file,
    required int fileSize,
    required SecretKey sharedSecret,
    required int totalSize,
    required int totalBytesTransferred,
  }) async {
    final uploadUrl =
        'http://${receiver.ipAddress}:${receiver.port}/transfer/upload-encrypted';

    final fileHash = await _calculateHashFromFile(file);
    // Compute sender token — uses bound token for pinned devices
    final senderToken = await _getSenderTokenForDevice(receiver.id);

    final request = http.StreamedRequest('POST', Uri.parse(uploadUrl));

    request.headers['x-transfer-id'] = transferId;
    request.headers['x-sender-id'] = sender.id;
    request.headers['x-sender-token'] = senderToken;
    request.headers['x-file-name'] = item.name;
    request.headers['x-original-size'] = fileSize.toString();
    request.headers['x-file-hash'] = fileHash;
    // Add file metadata timestamps
    if (item.modifiedAt != null) {
      request.headers['x-file-modified'] = item.modifiedAt!.millisecondsSinceEpoch.toString();
    }
    if (item.createdAt != null) {
      request.headers['x-file-created'] = item.createdAt!.millisecondsSinceEpoch.toString();
    }
    request.headers['Content-Type'] = 'application/octet-stream';
    request.headers['x-device-id'] = sender.id;

    int bytesSent = 0;
    int lastReportedProgress = -1;
    const chunkSize = 1024 * 1024;

    // Use await-for to avoid async race condition in stream listener
    final fileStream = file.openRead();
    List<int> buffer = [];

    try {
      await for (final chunk in fileStream) {
        buffer.addAll(chunk);

        while (buffer.length >= chunkSize) {
          await _checkPauseGate(transferId);
          final plainChunk = Uint8List.fromList(buffer.sublist(0, chunkSize));
          buffer = buffer.sublist(chunkSize);

          final encrypted = await _encryptChunk(plainChunk, sharedSecret);

          final sizeBytes = Uint8List(4);
          final byteData = ByteData.view(sizeBytes.buffer);
          byteData.setUint32(0, encrypted.length, Endian.big);

          request.sink.add(sizeBytes);
          request.sink.add(encrypted);

          bytesSent += plainChunk.length;

          final progressPercent =
              ((totalBytesTransferred + bytesSent) / totalSize * 100).toInt();

          if (progressPercent != lastReportedProgress) {
            lastReportedProgress = progressPercent;
            BackgroundTransferService.updateProgress(
              title: 'Sending (encrypted) to ${receiver.name}',
              fileName: item.name,
              progress: progressPercent,
              bytesTransferred: totalBytesTransferred + bytesSent,
              totalBytes: totalSize,
            );
          }

          final updatedTransfer = _activeTransfers[transferId]!.copyWith(
            status: TransferStatus.transferring,
            progress: TransferProgress(
              bytesTransferred: totalBytesTransferred + bytesSent,
              totalBytes: totalSize,
            ),
          );
          _activeTransfers[transferId] = updatedTransfer;
          _transferController.add(updatedTransfer);
        }
      }

      // Flush remaining bytes in buffer
      if (buffer.isNotEmpty) {
        final plainChunk = Uint8List.fromList(buffer);
        final encrypted = await _encryptChunk(plainChunk, sharedSecret);

        final sizeBytes = Uint8List(4);
        final byteData = ByteData.view(sizeBytes.buffer);
        byteData.setUint32(0, encrypted.length, Endian.big);

        request.sink.add(sizeBytes);
        request.sink.add(encrypted);
      }

      request.sink.close();
    } catch (e) {
      request.sink.addError(e);
      request.sink.close();
      rethrow;
    }

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode == HttpStatus.unauthorized) {
      throw TransferException('Transfer not authorized: $responseBody',
          code: 'UNAUTHORIZED');
    }

    if (response.statusCode != 200) {
      throw TransferException(
        'Encrypted upload failed: ${response.statusCode} - $responseBody',
        code: 'UPLOAD_FAILED_${response.statusCode}',
      );
    }

    AppLogger.info('🔐 File sent encrypted: ${item.name}');
  }

  Future<void> _sendFileUnencrypted({
    required Device receiver,
    required String transferId,
    required Device sender,
    required TransferItem item,
    required File file,
    required int fileSize,
    required int totalSize,
    required int totalBytesTransferred,
  }) async {
    final uploadUrl =
        'http://${receiver.ipAddress}:${receiver.port}/transfer/upload';

    // Compute sender token — uses bound token for pinned devices
    final senderToken = await _getSenderTokenForDevice(receiver.id);

    final request = http.StreamedRequest('POST', Uri.parse(uploadUrl));

    request.headers['x-transfer-id'] = transferId;
    request.headers['x-sender-id'] = sender.id;
    request.headers['x-sender-token'] = senderToken;
    request.headers['x-file-name'] = item.name;
    request.headers['x-file-size'] = fileSize.toString();
    request.headers['x-relative-path'] = item.parentPath ?? '';
    request.headers['Content-Type'] = 'application/octet-stream';
    request.headers['Content-Length'] = fileSize.toString();
    request.headers['x-device-id'] = sender.id;

    int bytesSent = 0;
    int lastReportedProgress = -1;
    final fileStream = file.openRead();

    try {
      await for (final chunk in fileStream) {
        await _checkPauseGate(transferId);
        request.sink.add(chunk);
        bytesSent += chunk.length;

        final progressPercent =
            ((totalBytesTransferred + bytesSent) / totalSize * 100).toInt();

        if (progressPercent != lastReportedProgress) {
          lastReportedProgress = progressPercent;
          BackgroundTransferService.updateProgress(
            title: 'Sending to ${receiver.name}',
            fileName: item.name,
            progress: progressPercent,
            bytesTransferred: totalBytesTransferred + bytesSent,
            totalBytes: totalSize,
          );
        }

        final updatedTransfer = _activeTransfers[transferId]!.copyWith(
          status: TransferStatus.transferring,
          progress: TransferProgress(
            bytesTransferred: totalBytesTransferred + bytesSent,
            totalBytes: totalSize,
          ),
        );
        _activeTransfers[transferId] = updatedTransfer;
        _transferController.add(updatedTransfer);
      }
      request.sink.close();
    } catch (e) {
      request.sink.addError(e);
      request.sink.close();
      rethrow;
    }

    final response = await request.send();
    final responseBody = await response.stream.bytesToString();

    if (response.statusCode == HttpStatus.unauthorized) {
      throw TransferException('Transfer not authorized: $responseBody',
          code: 'UNAUTHORIZED');
    }

    if (response.statusCode != 200) {
      throw TransferException(
        'Upload failed: ${response.statusCode} - $responseBody',
        code: 'UPLOAD_FAILED_${response.statusCode}',
      );
    }
  }

  Future<({bool approved, SecretKey? sharedSecret})> _waitForApproval({
    required Device receiver,
    required String requestId,
    required Duration timeout,
    required String senderId,
  }) async {
    final endTime = DateTime.now().add(timeout);
    final checkUrl =
        'http://${receiver.ipAddress}:${receiver.port}/transfer/approval/$requestId';

    while (DateTime.now().isBefore(endTime) && !_isDisposed) {
      try {
        final response = await http.get(
              Uri.parse(checkUrl),
              headers: {'x-device-id': senderId},
            ).timeout(
              const Duration(seconds: 5),
            );

        if (response.statusCode == 200) {
          final data = _validateAndParseJson(response.body);
          if (data != null) {
            final status = data['status'] as String? ?? '';

            if (status == 'approved') {
              // Follow the RECEIVER's decision: it only sets up an encryption
              // session (and expects encrypted uploads) when it advertises
              // encryption. Basing this on the sender's own setting caused a
              // mismatch where the receiver created a session but the sender
              // sent plaintext, which the B4 guard then rejected mid-upload.
              final receiverEncryption = data['encryption'] as bool? ?? false;
              final publicKeyList = data['publicKey'] as List?;
              if (receiverEncryption && publicKeyList != null) {
                try {
                  final publicKey =
                      Uint8List.fromList(publicKeyList.cast<int>());
                  final sharedSecret = await _performKeyExchange(publicKey);

                  _encryptionSessions[receiver.id] = EncryptionSession(
                    sessionId: '$_deviceId-${receiver.id}',
                    sharedSecret: sharedSecret,
                    createdAt: DateTime.now(),
                  );

                  AppLogger.info('🔐 Key exchange completed on approval');
                  return (approved: true, sharedSecret: sharedSecret);
                } catch (e) {
                  // B4: refuse to proceed unencrypted after a failed exchange.
                  AppLogger.error('❌ Key exchange failed: $e');
                  throw TransferException(
                    'Secure key exchange failed on approval; refusing to send unencrypted. $e',
                    code: 'KEY_EXCHANGE_FAILED',
                  );
                }
              }
              return (approved: true, sharedSecret: null);
            } else if (status == 'rejected' || status == 'expired') {
              return (approved: false, sharedSecret: null);
            }
          }
        }
      } catch (e) {
        // B4: a key-exchange failure must abort, not be retried into a timeout.
        if (e is TransferException && e.code == 'KEY_EXCHANGE_FAILED') {
          rethrow;
        }
        AppLogger.error('Error checking approval: $e');
      }

      await Future.delayed(const Duration(milliseconds: 500)); // FIX: Faster polling (was 2 seconds)
    }

    return (approved: false, sharedSecret: null);
  }

  Future<http.Response> _retryRequest(
    Future<http.Response> Function() request, {
    int attempts = 0,
  }) async {
    try {
      final response = await request().timeout(const Duration(seconds: 30));

      if (response.statusCode >= 200 && response.statusCode < 300) {
        return response;
      }

      throw HttpException('HTTP ${response.statusCode}');
    } catch (e) {
      if (attempts < maxRetries && _isRetryableError(e)) {
        // FIX: Use fixed 1-second delay for local network (was exponential backoff)
        const delay = 1; // Fixed 1 second instead of 2^attempts
        AppLogger.info(
            'Retry attempt ${attempts + 1}/$maxRetries after ${delay}s delay');
        await Future.delayed(const Duration(seconds: delay));
        return _retryRequest(request, attempts: attempts + 1);
      }
      rethrow;
    }
  }

  bool _isRetryableError(dynamic error) {
    if (error is SocketException) {
      return true;
    }
    if (error is TimeoutException) {
      return true;
    }
    if (error is HttpException) {
      // Extract status code from "HTTP <code>" formatted message
      final match = RegExp(r'HTTP\s+(\d+)').firstMatch(error.message);
      if (match != null) {
        final statusCode = int.tryParse(match.group(1)!) ?? 0;
        return statusCode >= 500 && statusCode < 600;
      }
    }
    return false;
  }

  /// Sends a text message (note/link/clipboard text) to [receiver].
  ///
  /// Mirrors the file flow: POST `/transfer/text`, then wait for approval if
  /// the receiver queues it for manual acceptance. Returns the transfer id.
  /// Throws [TransferException] on rejection, timeout or network failure.
  Future<String> sendText(Device receiver, String text,
      {String? transferId}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw TransferException('Text is empty', code: 'EMPTY_TEXT');
    }
    if (trimmed.length > _maxTextLengthBytes) {
      throw TransferException('Text is too long (max 64 KB)',
          code: 'TEXT_TOO_LONG');
    }

    final id = transferId ?? _uuid.v4();
    final senderToken = await _getSenderTokenForDevice(receiver.id);
    final textBytes = utf8.encode(trimmed).length;

    final transfer = Transfer(
      id: id,
      senderId: _deviceId,
      receiverId: receiver.id,
      items: [
        TransferItem(name: 'Message', path: '', size: textBytes),
      ],
      status: TransferStatus.connecting,
      progress: TransferProgress(
        bytesTransferred: 0,
        totalBytes: textBytes,
      ),
      createdAt: DateTime.now(),
    );
    _activeTransfers[id] = transfer;
    if (!_transferController.isClosed) {
      _transferController.add(transfer);
    }

    try {
      final response = await _retryRequest(
        () => http
            .post(
              Uri.parse(
                  'http://${receiver.ipAddress}:${receiver.port}/transfer/text'),
              headers: {
                'Content-Type': 'application/json',
                'x-device-id': _deviceId,
              },
              body: jsonEncode({
                'id': id,
                'senderId': _deviceId,
                'senderName': _deviceName,
                'senderToken': senderToken,
                'text': trimmed,
              }),
            )
            .timeout(
              const Duration(seconds: 15),
              onTimeout: () =>
                  throw TimeoutException('Text send timeout'),
            ),
      );

      if (response.statusCode != 200) {
        throw TransferException('Failed to send text',
            code: 'TEXT_SEND_FAILED_${response.statusCode}');
      }

      final data = _validateAndParseJson(response.body);
      if (data == null) {
        throw TransferException('Invalid response from receiver',
            code: 'INVALID_RESPONSE');
      }

      final status = data['status'] as String? ?? '';
      if (status == 'pending_approval') {
        _activeTransfers[id] =
            transfer.copyWith(status: TransferStatus.pending);
        if (!_transferController.isClosed) {
          _transferController.add(_activeTransfers[id]!);
        }

        final approved = await _waitForApproval(
          receiver: receiver,
          requestId: id,
          timeout: const Duration(minutes: 5),
          senderId: _deviceId,
        );
        if (!approved.approved) {
          throw TransferException('Message rejected or timed out',
              code: 'REJECTED');
        }
      } else if (status != 'accepted') {
        throw TransferException('Unexpected receiver status: $status',
            code: 'UNEXPECTED_STATUS');
      }

      final completedTransfer = transfer.copyWith(
        status: TransferStatus.completed,
        progress: TransferProgress(
          bytesTransferred: textBytes,
          totalBytes: textBytes,
        ),
      );
      _activeTransfers[id] = completedTransfer;
      if (!_transferController.isClosed) {
        _transferController.add(completedTransfer);
      }

      await DatabaseHelper.instance
          .insertTransfer(completedTransfer, null, null);

      _cleanupCompletedTransfers();
      return id;
    } catch (e, stackTrace) {
      if (kDebugMode) AppLogger.error('Error sending text: $e');
      if (kDebugMode) AppLogger.info('Stack trace: $stackTrace');

      final failedTransfer = transfer.copyWith(
        status: TransferStatus.failed,
        errorMessage: e.toString(),
      );
      _activeTransfers[id] = failedTransfer;
      if (!_transferController.isClosed) {
        _transferController.add(failedTransfer);
      }
      await DatabaseHelper.instance
          .insertTransfer(failedTransfer, null, null);

      if (e is TransferException) rethrow;
      throw TransferException('Text transfer failed', originalError: e);
    }
  }

  void cancelTransfer(String transferId) {
    final transfer = _activeTransfers[transferId];
    if (transfer != null) {
      _activeTransfers[transferId] = transfer.copyWith(
        status: TransferStatus.cancelled,
      );
      _transferController.add(_activeTransfers[transferId]!);
      BackgroundTransferService.stopBackgroundTransfer();
      _cleanupProgressController(transferId);

      // Parallel sends: stop the chunk queues locally and ask the receiver to
      // abort its session so no temp file/session is leaked on the other side.
      if (transfer.isParallel == true) {
        try {
          _parallelSender?.cancelTransfer(transferId);
        } catch (e) {
          AppLogger.error('Error cancelling parallel sender: $e');
        }
        final receiver = _parallelTransferReceivers.remove(transferId);
        if (receiver != null) {
          _notifyReceiverParallelCancel(transferId, receiver, transfer.senderId);
        }
      }
    } else {
      if (kDebugMode) {
        AppLogger.warn(
            'Warning: Attempted to cancel non-existent transfer: $transferId');
      }
    }

    // Release the pause gate so a paused loop wakes up and aborts.
    final gate = _pauseGates.remove(transferId);
    if (gate != null && !gate.isCompleted) {
      gate.complete();
    }
  }

  /// Best-effort one-way notification that the receiver should abort its
  /// parallel receive session (temp file cleanup). Failures are logged, never
  /// thrown — the local cancel already succeeded.
  void _notifyReceiverParallelCancel(
      String transferId, Device receiver, String senderId) {
    try {
      final url = Uri.parse(
          'http://${receiver.ipAddress}:${receiver.port}/transfer/parallel/cancel');
      http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': senderId,
            },
            body: jsonEncode({'transferId': transferId}),
          )
          .timeout(const Duration(seconds: 5))
          .then((response) {
            if (response.statusCode != 200 && kDebugMode) {
              AppLogger.warn(
                  'Receiver parallel cancel returned ${response.statusCode}');
            }
          })
          .catchError((e) {
            AppLogger.error('Failed to notify receiver of cancel: $e');
          });
    } catch (e) {
      AppLogger.error('Failed to notify receiver of cancel: $e');
    }
  }

  /// Pauses an in-flight sequential transfer. Parallel transfers and
  /// terminal transfers are ignored (the UI hides the control for those).
  void pauseTransfer(String transferId) {
    final transfer = _activeTransfers[transferId];
    if (transfer == null ||
        transfer.status.isTerminal ||
        transfer.isParallel == true) {
      return;
    }
    if (_pauseGates.containsKey(transferId)) return;

    _pauseGates[transferId] = Completer<void>();
    _activeTransfers[transferId] =
        transfer.copyWith(status: TransferStatus.paused);
    _transferController.add(_activeTransfers[transferId]!);
    BackgroundTransferService.stopBackgroundTransfer();
  }

  /// Resumes a paused transfer.
  void resumeTransfer(String transferId) {
    final gate = _pauseGates.remove(transferId);
    if (gate == null || gate.isCompleted) return;

    final transfer = _activeTransfers[transferId];
    if (transfer == null || transfer.status != TransferStatus.paused) return;

    gate.complete();
    _activeTransfers[transferId] =
        transfer.copyWith(status: TransferStatus.transferring);
    _transferController.add(_activeTransfers[transferId]!);
    BackgroundTransferService.startBackgroundTransfer(
      title: 'Sending files...',
      fileName: '',
    );
  }

  /// Blocks while [transferId] is paused; throws when the transfer was
  /// cancelled so the sending loop aborts cleanly. The cancelled check runs
  /// before AND after the gate: a cancellation that lands while the loop is
  /// blocked elsewhere (e.g. in a full socket buffer) still aborts it at the
  /// next chunk boundary, even though the gate is already released.
  Future<void> _checkPauseGate(String transferId) async {
    if (_activeTransfers[transferId]?.status == TransferStatus.cancelled) {
      throw TransferException('Transfer cancelled', code: 'CANCELLED');
    }
    final gate = _pauseGates[transferId];
    if (gate == null) return;
    await gate.future;
    if (_activeTransfers[transferId]?.status == TransferStatus.cancelled) {
      throw TransferException('Transfer cancelled', code: 'CANCELLED');
    }
  }

  Future<void> revokeTrust(String senderId) async {
    final removed = _trustedDevices.remove(senderId);
    if (removed != null) {
      if (kDebugMode) {
        AppLogger.info('Revoked trust for device: ${removed.senderName}');
      }
      await _saveTrustedDevices();
    }
  }

  /// Reset the TOFU pin for a trusted device, forcing re-verification
  /// on the next key exchange. Clears the pinned public key and sets
  /// the pendingRepin flag so the next connection auto-pins a fresh key.
  Future<void> rotatePinnedKey(String deviceId) async {
    final device = _trustedDevices[deviceId];
    if (device == null) return;

    // Clear the pin from secure storage
    await _secureStorage.delete(key: 'syndro.pin.$deviceId');

    // Update in-memory record
    _trustedDevices[deviceId] = device.copyWith(
      pinnedPubKey: null,
      pendingRepin: true,
    );
    await _saveTrustedDevices();

    if (kDebugMode) {
      AppLogger.info('🔄 Rotated pin for device: ${device.senderName} ($deviceId)');
    }
  }

  Future<void> clearTrustedSenders() async {
    _trustedDevices.clear();
    await _saveTrustedDevices();
    AppLogger.info('Cleared all trusted devices');
  }

  Stream<TransferProgress> getTransferProgress(String transferId) {
    if (!_progressControllers.containsKey(transferId)) {
      _progressControllers[transferId] =
          StreamController<TransferProgress>.broadcast();
    }
    return _progressControllers[transferId]!.stream;
  }

  // FIX (Bug #32): Proper disposal with try-catch for all resources
  Future<void> dispose() async {
    _isDisposed = true;

    // Cancel timers
    try {
      _pendingRequestsCleanupTimer?.cancel();
      _pendingRequestsCleanupTimer = null;
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error cancelling pending requests cleanup timer: $e');
    }

    try {
      _sessionCleanupTimer?.cancel();
      _sessionCleanupTimer = null;
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error cancelling session cleanup timer: $e');
    }

    try {
      _trustedDevicesCleanupTimer?.cancel();
      _trustedDevicesCleanupTimer = null;
    } catch (e) {
      AppLogger.warn('Failed to cancel trusted devices cleanup timer: $e');
    }

    // Cancel notification subscription
    try {
      await _notificationEventSubscription?.cancel();
      _notificationEventSubscription = null;
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error cancelling notification subscription: $e');
    }

    // Close server
    try {
      await _server?.close(force: true);
      _server = null;
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error closing server: $e');
    }

    // Close controllers
    try {
      if (!_transferController.isClosed) {
        await _transferController.close();
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error closing transfer controller: $e');
    }

    try {
      if (!_pendingRequestsController.isClosed) {
        await _pendingRequestsController.close();
      }
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error closing pending requests controller: $e');
    }

    // Close progress controllers
    for (final controller in _progressControllers.values) {
      try {
        if (!controller.isClosed) {
          await controller.close();
        }
      } catch (e) {
        AppLogger.error('Error closing progress controller: $e');
      }
    }

    _progressControllers.clear();
    _activeTransfers.clear();
    _pendingRequests.clear();
    _encryptionSessions.clear();

    // Dispose parallel handlers
    try {
      await _parallelReceiver.dispose();
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error disposing parallel receiver: $e');
    }

    try {
      await _parallelSender?.dispose();
    } catch (e) {
      if (kDebugMode) AppLogger.error('Error disposing parallel sender: $e');
    }

    AppLogger.info('✅ TransferService disposed');
  }
}
