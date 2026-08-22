import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

import 'parallel_config.dart';
import 'chunk_writer_service.dart';
import '../streaming_hash_service.dart';
import '../file_service.dart';
import '../encryption_service.dart';
import '../../utils/app_logger.dart';
import '../../utils/byte_formatter.dart';
import '../../utils/synchronized.dart';

/// Handles receiving parallel chunk transfers
class ParallelReceiverHandler {
  final FileService _fileService;
  final ChunkWriterManager _writerManager = ChunkWriterManager();
  final Map<String, ParallelReceiveSession> _sessions = {};

  final SynchronizedLock<void> _sessionsLock = SynchronizedLock<void>();

  // BUG-005 FIX: Use shared AesGcm from EncryptionService
  final AesGcm _aesGcm = EncryptionService.aesGcm;

  void Function(String transferId, int bytesReceived, int totalBytes)?
      onProgress;

  void Function(String transferId, String filePath)? onComplete;

  bool _isDisposed = false;

  ParallelReceiverHandler(this._fileService);

  /// Handle parallel transfer initiation
  Future<Map<String, dynamic>> handleInitiate(Map<String, dynamic> data) async {
    if (_isDisposed) {
      return {'success': false, 'error': 'Handler is disposed'};
    }

    final transferId = data['transferId'] as String? ?? '';
    final fileName = data['fileName'] as String? ?? '';
    final fileSize = data['fileSize'] as int? ?? 0;
    final fileHash = data['fileHash'] as String? ?? '';
    final totalChunks = data['totalChunks'] as int? ?? 0;
    final chunkSize = data['chunkSize'] as int? ?? 0;
    final senderId = data['senderId'] as String? ?? '';
    final senderName = data['senderName'] as String? ?? '';
    final encrypted = data['encrypted'] as bool? ?? false;

    if (transferId.isEmpty ||
        fileName.isEmpty ||
        fileSize <= 0 ||
        totalChunks <= 0) {
      return {'success': false, 'error': 'Missing required fields'};
    }

    AppLogger.info('📥 Parallel transfer initiated: $fileName');
    AppLogger.info('   Size: ${ByteFormatter.format(fileSize)}, Chunks: $totalChunks');

    try {
      final downloadDir = await _fileService.getDownloadDirectory();
      final sanitizedName = _fileService.sanitizeFilename(fileName);
      final filePath = '$downloadDir${Platform.pathSeparator}$sanitizedName';

      if (!_fileService.isPathWithinDirectory(filePath, downloadDir)) {
        return {'success': false, 'error': 'Invalid file path'};
      }

      final config = ParallelConfig(
        connections: 4,
        chunkSize: chunkSize,
        minFileSize: 0,
        enabled: true,
      );

      final writer = await _writerManager.createWriter(
        fileId: transferId,
        filePath: filePath,
        totalSize: fileSize,
        config: config,
      );

      final session = ParallelReceiveSession(
        transferId: transferId,
        fileName: sanitizedName,
        filePath: filePath,
        fileSize: fileSize,
        fileHash: fileHash,
        totalChunks: totalChunks,
        chunkSize: chunkSize,
        senderId: senderId,
        senderName: senderName,
        encrypted: encrypted,
        writer: writer,
      );

      await _sessionsLock.synchronized(() async {
        _sessions[transferId] = session;
      });

      // Start periodic progress emitter to keep UI alive during chunk gaps
      Timer.periodic(const Duration(seconds: 1), (timer) async {
        ParallelReceiveSession? s;
        await _sessionsLock.synchronized(() async {
          s = _sessions[transferId];
        });
        if (s == null || s!.writer.isComplete) {
          timer.cancel();
          return;
        }
        onProgress?.call(transferId, s!.bytesReceived, s!.fileSize);
      });

      return {
        'success': true,
        'transferId': transferId,
        'message': 'Ready to receive chunks',
      };
    } catch (e) {
      AppLogger.error('Error initiating parallel receive: $e');
      return {
        'success': false,
        'error': e.toString(),
      };
    }
  }

  /// Handle incoming chunk
  Future<Map<String, dynamic>> handleChunk({
    required String transferId,
    required int chunkIndex,
    required Uint8List chunkData,
    required int originalSize,
    required bool encrypted,
    SecretKey? decryptionKey,
  }) async {
    if (_isDisposed) {
      return {'success': false, 'error': 'Handler is disposed'};
    }

    ParallelReceiveSession? session;
    await _sessionsLock.synchronized(() async {
      session = _sessions[transferId];
    });

    if (session == null) {
      return {'success': false, 'error': 'Unknown transfer'};
    }

    try {
      Uint8List dataToWrite;
      if (encrypted && decryptionKey != null) {
        dataToWrite = await _decryptChunk(chunkData, decryptionKey);
      } else {
        dataToWrite = chunkData;
      }

      if (originalSize > 0 && dataToWrite.length != originalSize) {
        AppLogger.warn(
            '⚠️ Chunk size mismatch: expected $originalSize, got ${dataToWrite.length}');
      }

      await session!.writer.writeChunk(chunkIndex, dataToWrite);

      await session!.incrementProgress(dataToWrite.length);

      onProgress?.call(transferId, session!.bytesReceived, session!.fileSize);

      return {
        'success': true,
        'chunkIndex': chunkIndex,
        'chunksReceived': session!.chunksReceived,
        'totalChunks': session!.totalChunks,
      };
    } catch (e) {
      AppLogger.error('Error receiving chunk $chunkIndex: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Handle transfer completion notification
  Future<Map<String, dynamic>> handleComplete({
    required String transferId,
    required String fileHash,
  }) async {
    if (_isDisposed) {
      return {'success': false, 'error': 'Handler is disposed'};
    }

    ParallelReceiveSession? session;
    await _sessionsLock.synchronized(() async {
      session = _sessions[transferId];
    });

    if (session == null) {
      return {'success': false, 'error': 'Unknown transfer'};
    }

    try {
      if (!session!.writer.isComplete) {
        final missing = session!.writer.getMissingChunks();
        return {
          'success': false,
          'error': 'Missing chunks: $missing',
          'missingChunks': missing,
        };
      }

      final file = await session!.writer.finalize();

      AppLogger.info('📝 Verifying file hash...');
      final calculatedHash = await StreamingHashService.calculateFileHash(file);

      if (calculatedHash != fileHash) {
        AppLogger.error('❌ Hash mismatch! Deleting corrupted file.');

        try {
          await file.delete();
        } catch (e) {
          AppLogger.error('Error deleting corrupted file: $e');
        }

        await _cleanupSession(transferId);

        return {
          'success': false,
          'error': 'Hash mismatch - file corrupted',
          'expectedHash': fileHash,
          'calculatedHash': calculatedHash,
        };
      }

      AppLogger.info('✅ File verified and saved: ${session!.filePath}');

      final filePath = session!.filePath;
      final fileSize = session!.fileSize;

      await _cleanupSession(transferId);

      onComplete?.call(transferId, filePath);

      return {
        'success': true,
        'filePath': filePath,
        'fileSize': fileSize,
        'verified': true,
      };
    } catch (e) {
      AppLogger.error('Error completing transfer: $e');

      await _cleanupSessionOnError(transferId);

      return {'success': false, 'error': e.toString()};
    }
  }

  Future<void> _cleanupSession(String transferId) async {
    await _sessionsLock.synchronized(() async {
      _sessions.remove(transferId);
    });
    await _writerManager.removeWriter(transferId);
  }

  Future<void> _cleanupSessionOnError(String transferId) async {
    ParallelReceiveSession? session;

    await _sessionsLock.synchronized(() async {
      session = _sessions.remove(transferId);
    });

    if (session != null) {
      try {
        await session!.writer.abort();
      } catch (e) {
        AppLogger.error('Error aborting writer: $e');
      }

      try {
        final tempFile = File('${session!.filePath}.tmp');
        if (await tempFile.exists()) {
          await tempFile.delete();
          AppLogger.info('🧹 Deleted temp file: ${tempFile.path}');
        }
      } catch (e) {
        AppLogger.error('Error deleting temp file: $e');
      }
    }

    await _writerManager.removeWriter(transferId);
  }

  Future<Uint8List> _decryptChunk(
      Uint8List encryptedData, SecretKey secretKey) async {
    if (encryptedData.length < 28) {
      throw Exception(
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

    final plaintext = await _aesGcm.decrypt(
      secretBox,
      secretKey: secretKey,
    );

    return Uint8List.fromList(plaintext);
  }

  ParallelReceiveSession? getSession(String transferId) {
    return _sessions[transferId];
  }

  Future<void> abortTransfer(String transferId) async {
    await _cleanupSessionOnError(transferId);
  }

  Future<void> dispose() async {
    _isDisposed = true;

    final sessionIds = _sessions.keys.toList();

    for (final transferId in sessionIds) {
      await _cleanupSessionOnError(transferId);
    }

    _sessions.clear();
    await _writerManager.closeAll();
  }


}

/// Session state for receiving parallel transfer
class ParallelReceiveSession {
  final String transferId;
  final String fileName;
  final String filePath;
  final int fileSize;
  final String fileHash;
  final int totalChunks;
  final int chunkSize;
  final String senderId;
  final String senderName;
  final bool encrypted;
  final ChunkWriterService writer;

  int _chunksReceived = 0;
  int _bytesReceived = 0;
  final SynchronizedLock<void> _lock = SynchronizedLock<void>();

  DateTime startTime = DateTime.now();

  ParallelReceiveSession({
    required this.transferId,
    required this.fileName,
    required this.filePath,
    required this.fileSize,
    required this.fileHash,
    required this.totalChunks,
    required this.chunkSize,
    required this.senderId,
    required this.senderName,
    required this.encrypted,
    required this.writer,
  });

  int get chunksReceived => _chunksReceived;
  int get bytesReceived => _bytesReceived;

  Future<void> incrementProgress(int bytes) async {
    await _lock.synchronized(() async {
      _chunksReceived++;
      _bytesReceived += bytes;
    });
  }

  double get progress => totalChunks > 0 ? _chunksReceived / totalChunks : 0;
  bool get isComplete => _chunksReceived == totalChunks;

  Duration get elapsed => DateTime.now().difference(startTime);

  double get speed {
    final seconds = elapsed.inMilliseconds / 1000;
    if (seconds <= 0) return 0;
    return _bytesReceived / seconds;
  }
}
