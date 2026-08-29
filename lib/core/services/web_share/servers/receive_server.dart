import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path/path.dart' as path;

import '../../../utils/app_logger.dart';
import '../models/received_file.dart';
import '../models/pending_files_manager.dart';
import '../utils/network_utils.dart';
// REMOVED: import '../utils/platform_paths.dart'; (unused)
import '../utils/streaming_multipart_parser.dart';
import '../templates/receive_page_template.dart';

/// Pending upload confirmation request
class UploadPendingConfirmation {
  final String ipAddress;
  final String fileName;
  final int fileSize;
  final DateTime requestedAt;
  bool confirmed;
  bool denied;

  UploadPendingConfirmation({
    required this.ipAddress,
    required this.fileName,
    required this.fileSize,
    DateTime? requestedAt,
  })  : requestedAt = requestedAt ?? DateTime.now(),
        confirmed = false,
        denied = false;

  bool get isPending => !confirmed && !denied;
}

/// HTTP server for receiving files (upload mode)
/// Files are stored in temp location until user decides to save/discard
class ReceiveServer {
  HttpServer? _server;
  String? _shareUrl;
  String? _tempDirectory;
  String? _finalDirectory;
  Timer? _expirationTimer;

  // Pending files manager
  final PendingFilesManager _pendingFilesManager = PendingFilesManager();

  // Stream controller for received files (for backward compatibility)
  final StreamController<ReceivedFile> _receivedFilesController =
      StreamController<ReceivedFile>.broadcast();

  static const int _receivePort = 8767;
  static const Duration _shareExpiration = Duration(hours: 1);
  
  // FIX (Bug #6): Maximum upload size limit (10GB for browser uploads)
  static const int _maxUploadSizeBytes = 10 * 1024 * 1024 * 1024;
  // Maximum single file size (5GB)
  static const int _maxFileSizeBytes = 5 * 1024 * 1024 * 1024;

  // User confirmation tracking - require user confirmation before accepting uploads
  bool _requireConfirmation = true;
  final Map<String, UploadPendingConfirmation> _pendingConfirmations = {};
  final StreamController<UploadPendingConfirmation> _confirmationRequestController =
      StreamController<UploadPendingConfirmation>.broadcast();
  // Rate limiting - track requests per IP
  static const int _maxRequestsPerMinute = 60;
  final Map<String, List<DateTime>> _requestTimestamps = {};
  static const Duration _rateLimitWindow = Duration(minutes: 1);

  /// Stream of received files
  Stream<ReceivedFile> get receivedFilesStream => _receivedFilesController.stream;

  /// Get pending files manager for save/discard operations
  PendingFilesManager get pendingFilesManager => _pendingFilesManager;

  /// Stream of pending files list updates
  Stream<List<ReceivedFile>> get pendingFilesStream =>
      _pendingFilesManager.filesStream;

  /// Get current share URL
  String? get shareUrl => _shareUrl;

  /// Check if currently receiving
  bool get isReceiving => _server != null;

  /// Get final directory path
  String? get finalDirectory => _finalDirectory;

  /// Stream of pending upload confirmation requests
  Stream<UploadPendingConfirmation> get uploadConfirmationRequestStream =>
      _confirmationRequestController.stream;

  /// Get list of pending upload confirmations
  List<UploadPendingConfirmation> get pendingUploadConfirmations =>
      _pendingConfirmations.values.where((c) => c.isPending).toList();

  /// Enable or disable requiring user confirmation before accepting uploads
  void setRequireConfirmation(bool require) {
    _requireConfirmation = require;
  }

  /// Confirm an upload by its ID
  bool confirmUpload(String uploadId) {
    final confirmation = _pendingConfirmations[uploadId];
    if (confirmation != null && confirmation.isPending) {
      confirmation.confirmed = true;
      AppLogger.info('✅ Upload confirmed for $uploadId');
      return true;
    }
    return false;
  }

  /// Deny an upload by its ID
  bool denyUpload(String uploadId) {
    final confirmation = _pendingConfirmations[uploadId];
    if (confirmation != null && confirmation.isPending) {
      confirmation.denied = true;
      AppLogger.error('❌ Upload denied for $uploadId');
      return true;
    }
    return false;
  }

  /// Check if an upload is allowed
  bool isUploadAllowed(String uploadId) {
    if (!_requireConfirmation) return true;
    
    final confirmation = _pendingConfirmations[uploadId];
    if (confirmation == null) {
      // No confirmation request - treat as allowed for backward compatibility
      return true;
    }
    return confirmation.confirmed;
  }

  /// Check if request is allowed based on rate limits
  bool _checkRateLimit(String ipAddress) {
    final now = DateTime.now();
    final windowStart = now.subtract(_rateLimitWindow);
    
    final timestamps = _requestTimestamps[ipAddress] ?? [];
    timestamps.removeWhere((t) => t.isBefore(windowStart));
    
    if (timestamps.length >= _maxRequestsPerMinute) {
      AppLogger.warn('⚠️ Rate limit exceeded for $ipAddress');
      _requestTimestamps[ipAddress] = timestamps;
      return false;
    }
    
    timestamps.add(now);
    _requestTimestamps[ipAddress] = timestamps;
    return true;
  }

  /// Start receiving files via HTTP server
  Future<String?> startReceiving(String downloadDirectory) async {
    await stop();

    _finalDirectory = downloadDirectory;

    // Create temp directory for pending files
    _tempDirectory = await _createTempDirectory();
    if (_tempDirectory == null) {
      AppLogger.error('❌ Failed to create temp directory');
      return null;
    }

    // Initialize pending files manager
    await _pendingFilesManager.initialize(
      tempDirectory: _tempDirectory!,
      finalDirectory: _finalDirectory!,
    );

    AppLogger.info('📁 Temp directory: $_tempDirectory');
    AppLogger.info('📁 Final directory: $_finalDirectory');

    try {
      int port = _receivePort;

      // Try to bind to a port, incrementing if busy
      for (int attempt = 0; attempt < 10; attempt++) {
        try {
          _server = await HttpServer.bind(
            InternetAddress.anyIPv4,
            port,
            shared: true,
          );
          break;
        } catch (e) {
          port++;
          if (attempt == 9) {
            AppLogger.error('Failed to bind to any port');
            return null;
          }
        }
      }

      if (_server == null) return null;

      final localIp = await NetworkUtils.getLocalIp();
      _shareUrl = 'http://$localIp:${_server!.port}';

      AppLogger.info('Web receive server running at $_shareUrl');

      _serve();

      // Auto-expire after duration
      _expirationTimer = Timer(_shareExpiration, () {
        AppLogger.info('Receive session expired');
        stop();
      });

      return _shareUrl;
    } catch (e) {
      AppLogger.error('Error starting receive server: $e');
      return null;
    }
  }

  /// Create temp directory for pending files
  Future<String?> _createTempDirectory() async {
    try {
      String baseTempPath;

      if (Platform.isAndroid) {
        // Use app's cache directory on Android - use a more portable path
        baseTempPath = '/storage/emulated/0/Android/data/com.syndro.app/cache/pending_files';
        final externalDir = Directory(baseTempPath);
        if (!(await externalDir.parent.exists())) {
          // Fallback to app's internal cache
          baseTempPath = '/data/data/com.syndro.app/cache/pending_files';
        }
      } else if (Platform.isWindows) {
        final temp = Platform.environment['TEMP'] ?? 'C:\\Temp';
        baseTempPath = '$temp\\Syndro\\pending_files';
      } else if (Platform.isLinux) {
        final home = Platform.environment['HOME'] ?? '/tmp';
        baseTempPath = '$home/.cache/syndro/pending_files';
      } else {
        baseTempPath = '/tmp/syndro/pending_files';
      }

      // Add timestamp to make unique
      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final tempPath = '$baseTempPath/$timestamp';

      final dir = Directory(tempPath);
      await dir.create(recursive: true);

      return tempPath;
    } catch (e) {
      AppLogger.error('Error creating temp directory: $e');

      // Fallback to system temp
      try {
        final systemTemp = Directory.systemTemp;
        final fallbackPath =
            '${systemTemp.path}/syndro_pending_${DateTime.now().millisecondsSinceEpoch}';
        final dir = Directory(fallbackPath);
        await dir.create(recursive: true);
        return fallbackPath;
      } catch (e2) {
        AppLogger.error('Error creating fallback temp directory: $e2');
        return null;
      }
    }
  }

  /// Stop receiving and close server
  Future<void> stop() async {
    // FIX: Add try-catch for timer cancellation
    try {
      _expirationTimer?.cancel();
      _expirationTimer = null;
    } catch (e) {
      AppLogger.error('Error cancelling expiration timer: $e');
    }

    // FIX: Add try-catch for server closure
    try {
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
    } catch (e) {
      AppLogger.error('Error closing server: $e');
    }

    // Clean up rate limit entries to prevent unbounded growth
    final rateLimitWindowStart = DateTime.now().subtract(_rateLimitWindow);
    final keysToRemove = <String>[];
    for (final entry in _requestTimestamps.entries) {
      entry.value.removeWhere((t) => t.isBefore(rateLimitWindowStart));
      if (entry.value.isEmpty) {
        keysToRemove.add(entry.key);
      }
    }
    for (final key in keysToRemove) {
      _requestTimestamps.remove(key);
    }

    _shareUrl = null;
  }

  /// Dispose resources
  Future<void> dispose() async {
    await stop();
    
    // FIX: Add try-catch for pending files manager disposal
    try {
      await _pendingFilesManager.dispose();
    } catch (e) {
      AppLogger.error('Error disposing pending files manager: $e');
    }
    
    // FIX: Check if controller is closed before closing
    try {
      if (!_receivedFilesController.isClosed) {
        await _receivedFilesController.close();
      }
    } catch (e) {
      AppLogger.error('Error closing received files controller: $e');
    }

    // Clean up temp directory
    if (_tempDirectory != null) {
      try {
        final dir = Directory(_tempDirectory!);
        if (await dir.exists()) {
          await dir.delete(recursive: true);
        }
      } catch (e) {
        AppLogger.error('Error cleaning up temp directory: $e');
      }
    }
  }

  /// Serve HTTP requests
  void _serve() async {
    if (_server == null) return;

    await for (final request in _server!) {
      // PERF: Dispatch concurrently. Awaiting inline serialized every request
      // behind the previous one, so a large upload starved the index page and
      // logo requests. Per-request state is scoped and errors are answered
      // with a 500 below, so concurrent dispatch is safe.
      unawaited(_handleRequestSafely(request));
    }
  }

  /// Runs [_handleRequest] with the error handling that used to sit inline in
  /// the serve loop: any failure is logged and answered with a 500.
  Future<void> _handleRequestSafely(HttpRequest request) async {
    try {
      await _handleRequest(request);
    } catch (e) {
      AppLogger.error('Error handling receive request: $e');
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        await request.response.close();
      } catch (closeError) {
        AppLogger.error('Error closing error response: $closeError');
      }
    }
  }

  /// Handle HTTP request
  Future<void> _handleRequest(HttpRequest request) async {
    final uri = request.requestedUri;
    final requestPath = uri.path;
    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';

    // Rate limiting check
    if (!_checkRateLimit(clientIp)) {
      request.response.statusCode = HttpStatus.tooManyRequests;
      request.response.write('Rate limit exceeded. Please try again later.');
      await request.response.close();
      AppLogger.warn('⚠️ Rate limit blocked request from $clientIp');
      return;
    }

    // CORS headers
    request.response.headers.add('Access-Control-Allow-Origin', '*');
    request.response.headers
        .add('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    request.response.headers.add('Access-Control-Allow-Headers', '*');

    if (request.method == 'OPTIONS') {
      request.response.statusCode = HttpStatus.ok;
      await request.response.close();
      return;
    }

    // Route requests
    if (requestPath == '/' || requestPath == '/index.html') {
      await _serveIndexPage(request);
    } else if (request.method == 'GET' && requestPath == '/logo.png') {
      await _serveLogo(request);
    } else if (request.method == 'POST' && requestPath == '/upload') {
      await _handleFileUpload(request);
    } else {
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }

  /// Serve the index HTML page
  Future<void> _serveIndexPage(HttpRequest request) async {
    final html = ReceivePageTemplate.generate();

    request.response.headers.contentType = ContentType.html;
    request.response.write(html);
    await request.response.close();
  }

  /// Cached app-logo bytes (loaded once from the bundled asset).
  static Uint8List? _logoBytes;

  /// Serve the app logo (used as the header icon on the receive web page).
  Future<void> _serveLogo(HttpRequest request) async {
    try {
      _logoBytes ??=
          (await rootBundle.load('assets/icon/app_icon.png')).buffer.asUint8List();
      request.response.headers.contentType = ContentType('image', 'png');
      request.response.headers.add('Cache-Control', 'public, max-age=86400');
      request.response.add(_logoBytes!);
      await request.response.close();
    } catch (e) {
      AppLogger.error('Error serving logo: $e');
      request.response.statusCode = HttpStatus.notFound;
      await request.response.close();
    }
  }
  Future<void> _handleFileUpload(HttpRequest request) async {
    final clientIp = request.connectionInfo?.remoteAddress.address ?? 'unknown';

    if (_tempDirectory == null) {
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Server not properly initialized');
      await request.response.close();
      return;
    }

    AppLogger.info('📥 Receiving files to temp: $_tempDirectory');

    try {
      // Track uploaded files for response payload
      final uploadedFiles = <Map<String, dynamic>>[];
      final contentType = request.headers.contentType;

      if (contentType == null ||
          !contentType.mimeType.contains('multipart/form-data')) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('Invalid content type');
        await request.response.close();
        return;
      }

      final boundary = contentType.parameters['boundary'];
      if (boundary == null) {
        request.response.statusCode = HttpStatus.badRequest;
        request.response.write('No boundary found');
        await request.response.close();
        return;
      }

      // Generate a stable upload ID from the request metadata for approval checks
      final uploadId = '${clientIp}_${DateTime.now().millisecondsSinceEpoch}';

      // Create a pending confirmation entry if confirmation is required
      if (_requireConfirmation && !_pendingConfirmations.containsKey(uploadId)) {
        // We don't know the filename yet, use a placeholder
        final pending = UploadPendingConfirmation(
          ipAddress: clientIp,
          fileName: 'Upload from $clientIp',
          fileSize: 0, // Will be updated once we know the size
        );
        _pendingConfirmations[uploadId] = pending;
        _confirmationRequestController.add(pending);
        AppLogger.info('Upload confirmation requested for $clientIp');

        // Poll for approval (max 2 minutes)
        final approvalDeadline = DateTime.now().add(const Duration(minutes: 2));
        while (pending.isPending && DateTime.now().isBefore(approvalDeadline)) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
        if (pending.denied || pending.isPending) {
          request.response.statusCode = HttpStatus.forbidden;
          request.response.write('Upload denied by user');
          await request.response.close();
          _pendingConfirmations.remove(uploadId);
          return;
        }
        AppLogger.info('Upload approved for $clientIp');
      }

      // BUG-003 FIX: Check Content-Length BEFORE reading body to prevent OOM
      final contentLength = request.headers.value('content-length');
      if (contentLength != null) {
        final parsedLength = int.tryParse(contentLength);
        if (parsedLength != null && parsedLength > _maxFileSizeBytes) {
          request.response.statusCode = HttpStatus.requestEntityTooLarge;
          request.response.write('File exceeds maximum size limit (${_maxFileSizeBytes ~/ (1024 * 1024)}MB)');
          await request.response.close();
          return;
        }
      }

      // FIX (Bug #5): Stream request body to a temp file to avoid OOM on large uploads
      final tempBodyPath = path.join(_tempDirectory!, '_upload_body_${DateTime.now().millisecondsSinceEpoch}');
      final tempBodyFile = File(tempBodyPath);
      final tempSink = tempBodyFile.openWrite();
      int totalSize = 0;

      try {
        await for (final chunk in request) {
          tempSink.add(chunk);
          totalSize += chunk.length;
          
          // FIX (Bug #6): Validate total upload size during streaming
          if (totalSize > _maxUploadSizeBytes) {
            await tempSink.close();
            try {
              await tempBodyFile.delete();
            } catch (e, stack) {
              AppLogger.error('⚠️ Failed to delete temp file: $e\n$stack');
            }
            request.response.statusCode = HttpStatus.requestEntityTooLarge;
            request.response.write('Upload exceeds maximum size limit (${_maxUploadSizeBytes ~/ (1024 * 1024 * 1024)}GB)');
            await request.response.close();
            return;
          }
        }
        await tempSink.flush();
        await tempSink.close();

        AppLogger.info('📦 Received $totalSize bytes (streamed to temp file)');

        // Parse the spooled body with the streaming multipart parser: each
        // part is written to its own temp file as it is scanned, so neither
        // the body nor any single part is ever fully resident in memory.
        // (The old flow read the whole body back with readAsBytes and parsed
        // it in RAM, capping uploads at the in-memory parse limit.)
        final uploadTimestamp = DateTime.now().millisecondsSinceEpoch;
        var partCounter = 0;

        await StreamingMultipartParser.parseFile<_IncomingPart>(
          bodyFile: tempBodyFile,
          boundary: boundary,
          maxPartBytes: _maxFileSizeBytes,
          onPartStart: (filename) {
            if (filename.isEmpty) return null;
            // Clean filename (remove path traversal attempts)
            final cleanFilename = path.basename(filename);
            if (cleanFilename.isEmpty ||
                cleanFilename == '.' ||
                cleanFilename == '..') {
              return null;
            }
            final tempFilePath = path.join(_tempDirectory!,
                '${uploadTimestamp}_${partCounter++}_$cleanFilename');
            try {
              final raf = File(tempFilePath).openSync(mode: FileMode.write);
              return _IncomingPart(
                cleanFilename: cleanFilename,
                tempFilePath: tempFilePath,
                raf: raf,
              );
            } catch (e) {
              AppLogger.error(
                  '❌ Error creating temp file for $cleanFilename: $e');
              return null;
            }
          },
          onPartData: (part, chunk) async {
            // The parser only invokes this for parts accepted in onPartStart.
            final target = part;
            if (target == null) return;
            await target.raf.writeFrom(chunk);
          },
          onPartEnd: (part, filename, bytesSeen, skipped) async {
            if (part == null) return;
            try {
              await part.raf.flush();
              await part.raf.close();
            } catch (e) {
              AppLogger.error(
                  '❌ Error closing temp file for ${part.cleanFilename}: $e');
            }

            if (skipped) {
              // Part exceeded the per-file cap: discard the partial write.
              AppLogger.warn(
                  '⚠️ File ${part.cleanFilename} exceeds size limit, discarding');
              try {
                await File(part.tempFilePath).delete();
              } catch (_) {}
              return;
            }
            if (bytesSeen == 0) {
              // Empty part — nothing to keep.
              try {
                await File(part.tempFilePath).delete();
              } catch (_) {}
              return;
            }

            AppLogger.info(
                '✅ File saved to temp: ${part.cleanFilename} ($bytesSeen bytes)');

            uploadedFiles.add({
              'name': part.cleanFilename,
              'size': bytesSeen,
              'tempPath': part.tempFilePath,
            });

            // Create ReceivedFile with PENDING status
            final receivedFile = ReceivedFile(
              name: part.cleanFilename,
              tempPath: part.tempFilePath,
              size: bytesSeen,
              receivedAt: DateTime.now(),
              status: FileReceiveStatus.pending,
            );

            // Add to pending files manager
            _pendingFilesManager.addFile(receivedFile);

            // Also notify via stream (for backward compatibility)
            _receivedFilesController.add(receivedFile);
          },
        );
      } finally {
        // Clean up temp body file
        try {
          if (await tempBodyFile.exists()) {
            await tempBodyFile.delete();
          }
        } catch (deleteError) {
          AppLogger.error('Error deleting temp body file: $deleteError');
        }
      }

      AppLogger.info('📊 Total files received: ${uploadedFiles.length}');

      // Send response
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode({
        'status': 'success',
        'files': uploadedFiles,
        'count': uploadedFiles.length,
        'message': 'Files received and pending review',
      }));
      await request.response.close();
    } catch (e) {
      AppLogger.error('❌ Error handling upload: $e');
      request.response.statusCode = HttpStatus.internalServerError;
      request.response.write('Upload failed: $e');
      await request.response.close();
    }
  }
}

/// Per-part write state handed to the [StreamingMultipartParser] callbacks:
/// each accepted file part streams straight into its own temp file.
class _IncomingPart {
  final String cleanFilename;
  final String tempFilePath;
  final RandomAccessFile raf;

  _IncomingPart({
    required this.cleanFilename,
    required this.tempFilePath,
    required this.raf,
  });
}
