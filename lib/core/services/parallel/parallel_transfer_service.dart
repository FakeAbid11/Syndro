import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cryptography/cryptography.dart';

import '../streaming_hash_service.dart';
import '../encryption_service.dart';
import 'parallel_config.dart';
import 'chunk_writer_service.dart';
import '../../models/device.dart';
import '../../utils/app_logger.dart';
import '../../utils/byte_formatter.dart';
import '../../utils/synchronized.dart';

/// Parallel transfer service for high-speed file transfers
/// 
/// FIXED: Proper resource cleanup, error handling, and timeout management
class ParallelTransferService {
  final ParallelConfig config;
  final ChunkWriterManager _writerManager = ChunkWriterManager();

  // BUG-005 FIX: Use shared AesGcm from EncryptionService
  final AesGcm _aesGcm = EncryptionService.aesGcm;

  final List<http.Client> _clientPool = [];
  static const int _maxPoolSize = 6;

  final Map<String, ParallelTransferState> _activeTransfers = {};

  final SynchronizedLock<void> _transfersLock = SynchronizedLock<void>();

  final _progressController = StreamController<ParallelProgress>.broadcast();
  Stream<ParallelProgress> get progressStream => _progressController.stream;

  bool _isDisposed = false;

  ParallelTransferService({ParallelConfig? config})
      : config = config ?? ParallelConfig.appToApp {
    for (int i = 0; i < _maxPoolSize; i++) {
      _clientPool.add(http.Client());
    }
  }

  http.Client _getClient(int connectionId) {
    return _clientPool[connectionId % _clientPool.length];
  }

  /// Send a file using parallel chunks
  /// 
  /// FIX: Initiates transfer BEFORE hash calculation to notify receiver immediately.
  /// Hash is calculated in parallel with chunk uploads and verified at completion.
  Future<void> sendFileParallel({
    required String transferId,
    required File file,
    required Device receiver,
    required String senderToken,
    required Device sender,
    SecretKey? encryptionKey,
    void Function(int bytesSent, int totalBytes)? onProgress,
  }) async {
    if (_isDisposed) {
      throw StateError('ParallelTransferService has been disposed');
    }

    final fileSize = await file.length();
    final fileName = file.path.split(Platform.pathSeparator).last;

    if (!config.shouldUseParallel(fileSize)) {
      AppLogger.info('📁 File too small for parallel, using single connection');
      throw UnsupportedError('Use regular sendFile for small files');
    }

    AppLogger.info(
        '🚀 Starting parallel transfer: $fileName (${ByteFormatter.format(fileSize)})');
    AppLogger.info(
        '   Connections: ${config.connections}, Chunk size: ${ByteFormatter.format(config.chunkSize)}');
    AppLogger.info(
        '   Receiver: ${receiver.ipAddress}:${receiver.port}');

    final chunks = config.getAllChunks(fileSize);
    AppLogger.info('   Total chunks: ${chunks.length}');

    final state = ParallelTransferState(
      transferId: transferId,
      fileName: fileName,
      fileSize: fileSize,
      totalChunks: chunks.length,
    );

    await _transfersLock.synchronized(() async {
      _activeTransfers[transferId] = state;
    });

    try {
      // FIX: Initiate transfer FIRST with placeholder hash
      // This notifies the receiver immediately so they can show the transfer request
      AppLogger.info('📤 Initiating transfer with receiver (hash will be calculated in parallel)...');
      final initResponse = await _initiateParallelTransfer(
        receiver: receiver,
        transferId: transferId,
        fileName: fileName,
        fileSize: fileSize,
        fileHash: 'pending', // Placeholder - actual hash sent at completion
        totalChunks: chunks.length,
        chunkSize: config.chunkSize,
        sender: sender,
        senderToken: senderToken,
        encrypted: encryptionKey != null,
      );

      // FIX: Handle pending_approval status - wait for receiver to approve
      final status = initResponse['status'] as String?;
      if (status == 'pending_approval') {
        AppLogger.info('⏳ Transfer pending approval. Waiting for receiver to accept...');
        
        // Wait for approval by polling the receiver
        final requestId = initResponse['requestId'] as String? ?? transferId;
        final approved = await _waitForApproval(
          receiver: receiver,
          requestId: requestId,
          timeout: const Duration(minutes: 5),
          senderId: sender.id,
          state: state,
        );
        
        if (!approved) {
          throw Exception('Transfer rejected or timed out');
        }
        
        AppLogger.info('✅ Transfer approved! Starting upload...');
      } else if (initResponse['success'] != true) {
        throw Exception(
            'Failed to initiate parallel transfer: ${initResponse['error']}');
      } else {
        AppLogger.info('✅ Receiver auto-accepted! Starting upload...');
      }

      // User cancelled while we were waiting for approval — abort now.
      if (state.isCancelled) {
        throw Exception('Transfer cancelled by user');
      }

      AppLogger.info('📤 Now calculating hash and uploading chunks in parallel...');

      // FIX: Calculate hash in parallel with chunk uploads
      final hashCompleter = Completer<String>();
      
      // Start hash calculation in background
      final hashFuture = _calculateHashInBackground(
        file: file,
        onProgress: (bytesProcessed, totalBytes) {
          if (bytesProcessed % (100 * 1024 * 1024) == 0) {
            AppLogger.info('   Hash progress: ${ByteFormatter.format(bytesProcessed)}/${ByteFormatter.format(totalBytes)}');
          }
        },
      ).then((hash) {
        if (!hashCompleter.isCompleted) {
          hashCompleter.complete(hash);
        }
        return hash;
      }).catchError((e) {
        AppLogger.error('❌ Hash calculation failed: $e');
        if (!hashCompleter.isCompleted) {
          hashCompleter.completeError(e);
        }
        throw e;
      });

      final chunkQueues = _distributeChunks(chunks, config.connections);

      final futures = <Future<void>>[];

      for (int connId = 0; connId < config.connections; connId++) {
        final queue = chunkQueues[connId];
        if (queue.isEmpty) continue;

        futures.add(_uploadChunkQueue(
          connectionId: connId,
          chunks: queue,
          file: file,
          receiver: receiver,
          transferId: transferId,
          senderToken: senderToken,
          sender: sender,
          encryptionKey: encryptionKey,
          state: state,
          onProgress: onProgress,
        ));
      }

      // Wait for all chunks to be uploaded
      await Future.wait(futures);

      // Wait for hash calculation to complete (should be done by now)
      AppLogger.info('⏳ Waiting for hash calculation to complete...');
      final fileHash = await hashFuture;
      AppLogger.info('✅ Hash calculated: ${fileHash.substring(0, 16)}...');

      // User cancelled mid-upload — the chunk queues stopped, so do not
      // finalize on the receiver as if the transfer succeeded.
      if (state.isCancelled) {
        throw Exception('Transfer cancelled by user');
      }

      final notified = await _notifyTransferComplete(
        receiver: receiver,
        transferId: transferId,
        fileHash: fileHash,
        senderId: sender.id,
      );

      if (!notified) {
        // The receiver rejected the finalize (hash mismatch, missing chunks,
        // corrupt file). The receiver has already deleted the bad file, so the
        // sender must report this transfer as failed — never as completed.
        throw Exception('Receiver reported failure for parallel transfer');
      }

      AppLogger.info('✅ Parallel transfer complete: $fileName');
    } on SocketException catch (e) {
      AppLogger.error('❌ Network error during parallel transfer: $e');
      rethrow;
    } on TimeoutException catch (e) {
      AppLogger.error('❌ Timeout during parallel transfer: $e');
      rethrow;
    } catch (e, stackTrace) {
      AppLogger.error('❌ Parallel transfer failed: $e');
      AppLogger.info('Stack trace: $stackTrace');
      rethrow;
    } finally {
      await _transfersLock.synchronized(() async {
        _activeTransfers.remove(transferId);
      });
    }
  }

  /// Calculate file hash in background
  Future<String> _calculateHashInBackground({
    required File file,
    void Function(int bytesProcessed, int totalBytes)? onProgress,
  }) async {
    final hashStartTime = DateTime.now();
    AppLogger.info('📝 Starting background hash calculation...');
    
    final filePath = file.path;
    final hash = await Isolate.run(() async {
      return StreamingHashService.calculateFileHash(File(filePath));
    });
    
    final hashDuration = DateTime.now().difference(hashStartTime);
    AppLogger.info('📝 Hash calculated in ${hashDuration.inSeconds}s');
    return hash;
  }

  List<List<ChunkInfo>> _distributeChunks(
      List<ChunkInfo> chunks, int connections) {
    final queues = List.generate(connections, (_) => <ChunkInfo>[]);

    for (int i = 0; i < chunks.length; i++) {
      final connId = i % connections;
      queues[connId].add(chunks[i]);
    }

    return queues;
  }

  Future<void> _uploadChunkQueue({
    required int connectionId,
    required List<ChunkInfo> chunks,
    required File file,
    required Device receiver,
    required String transferId,
    required String senderToken,
    required Device sender,
    required ParallelTransferState state,
    SecretKey? encryptionKey,
    void Function(int bytesSent, int totalBytes)? onProgress,
  }) async {
    AppLogger.info(
        '🔗 Connection $connectionId: Uploading ${chunks.length} chunks');

    RandomAccessFile? raf;
    try {
      raf = await file.open(mode: FileMode.read);

      for (final chunk in chunks) {
        if (state.isCancelled || _isDisposed) {
          AppLogger.info('🚫 Connection $connectionId: Transfer cancelled');
          break;
        }

        await raf.setPosition(chunk.start);
        final data = await raf.read(chunk.size);

        Uint8List dataToSend;
        if (encryptionKey != null) {
          dataToSend =
              await _encryptChunk(Uint8List.fromList(data), encryptionKey);
        } else {
          dataToSend = Uint8List.fromList(data);
        }

        await _uploadSingleChunkWithRetry(
          receiver: receiver,
          transferId: transferId,
          chunkIndex: chunk.index,
          chunkData: dataToSend,
          originalSize: chunk.size,
          senderToken: senderToken,
          senderId: sender.id,
          encrypted: encryptionKey != null,
          connectionId: connectionId,
        );

        await state.markChunkSent(chunk.index, chunk.size);
        onProgress?.call(state.bytesSent, state.fileSize);
        _emitProgress(state);
      }

      AppLogger.info('✅ Connection $connectionId: Complete');
    } on FileSystemException catch (e) {
      AppLogger.error('⚠️ File system error in connection $connectionId: $e');
      rethrow;
    } finally {
      // FIXED: Ensure file is always closed
      try {
        await raf?.close();
      } catch (e) {
        AppLogger.error('⚠️ Error closing file in connection $connectionId: $e');
      }
    }
  }

  Future<void> _uploadSingleChunkWithRetry({
    required Device receiver,
    required String transferId,
    required int chunkIndex,
    required Uint8List chunkData,
    required int originalSize,
    required String senderToken,
    required String senderId,
    required bool encrypted,
    required int connectionId,
    int maxRetries = 3,
  }) async {
    Exception? lastError;

    for (int attempt = 0; attempt < maxRetries; attempt++) {
      try {
        await _uploadSingleChunk(
          receiver: receiver,
          transferId: transferId,
          chunkIndex: chunkIndex,
          chunkData: chunkData,
          originalSize: originalSize,
          senderToken: senderToken,
          senderId: senderId,
          encrypted: encrypted,
          connectionId: connectionId,
        );
        return;
      } on SocketException catch (e) {
        lastError = e;
        AppLogger.error(
            '⚠️ Network error uploading chunk $chunkIndex (attempt ${attempt + 1}): $e');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      } on TimeoutException catch (e) {
        lastError = e;
        AppLogger.warn(
            '⚠️ Timeout uploading chunk $chunkIndex (attempt ${attempt + 1}): $e');
        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 1000 * (attempt + 1)));
        }
      } catch (e) {
        lastError = e is Exception ? e : Exception(e.toString());
        AppLogger.error(
            '⚠️ Chunk $chunkIndex upload failed (attempt ${attempt + 1}): $e');

        if (attempt < maxRetries - 1) {
          await Future.delayed(Duration(milliseconds: 500 * (attempt + 1)));
        }
      }
    }

    throw lastError ??
        Exception('Chunk upload failed after $maxRetries retries');
  }

  Future<void> _uploadSingleChunk({
    required Device receiver,
    required String transferId,
    required int chunkIndex,
    required Uint8List chunkData,
    required int originalSize,
    required String senderToken,
    required String senderId,
    required bool encrypted,
    required int connectionId,
  }) async {
    final url = Uri.parse(
        'http://${receiver.ipAddress}:${receiver.port}/transfer/chunk');

    final client = _getClient(connectionId);

    final response = await client
        .post(
          url,
          headers: {
            'Content-Type': 'application/octet-stream',
            'X-Transfer-Id': transferId,
            'X-Chunk-Index': chunkIndex.toString(),
            'X-Original-Size': originalSize.toString(),
            'X-Sender-Token': senderToken,
            'X-Sender-Id': senderId,
            'X-Encrypted': encrypted.toString(),
            'x-device-id': senderId,
          },
          body: chunkData,
        )
        .timeout(
          const Duration(seconds: 60),
          onTimeout: () {
            throw TimeoutException('Chunk upload timed out after 60 seconds');
          },
        );

    if (response.statusCode != 200) {
      throw HttpException(
          'Chunk upload failed: ${response.statusCode} ${response.body}');
    }
  }

  Future<Map<String, dynamic>> _initiateParallelTransfer({
    required Device receiver,
    required String transferId,
    required String fileName,
    required int fileSize,
    required String fileHash,
    required int totalChunks,
    required int chunkSize,
    required Device sender,
    required String senderToken,
    required bool encrypted,
  }) async {
    final url = Uri.parse(
        'http://${receiver.ipAddress}:${receiver.port}/transfer/parallel/initiate');

    AppLogger.info('📤 Initiating parallel transfer to ${AppLogger.sanitize('${receiver.ipAddress}:${receiver.port}')}');

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': sender.id,
            },
            body: jsonEncode({
              'transferId': transferId,
              'fileName': fileName,
              'fileSize': fileSize,
              'fileHash': fileHash,
              'totalChunks': totalChunks,
              'chunkSize': chunkSize,
              'senderId': sender.id,
              'senderName': sender.name,
              'senderToken': senderToken,
              'encrypted': encrypted,
            }),
          )
          .timeout(
            const Duration(seconds: 30), // Increased from 10s for large file preparation
            onTimeout: () {
              throw TimeoutException('Initiation timed out after 30 seconds');
            },
          );

      AppLogger.info('📥 Initiation response: ${response.statusCode}');
      
      if (response.statusCode == 200) {
        return {'success': true, ...jsonDecode(response.body)};
      } else {
        return {'success': false, 'error': response.body};
      }
    } on SocketException catch (e) {
      AppLogger.error('❌ Socket error during initiation: $e');
      return {'success': false, 'error': 'Network error: $e'};
    } on TimeoutException catch (e) {
      AppLogger.error('❌ Timeout during initiation: $e');
      return {'success': false, 'error': 'Request timeout: $e'};
    } on FormatException catch (e) {
      AppLogger.error('❌ Invalid response format: $e');
      return {'success': false, 'error': 'Invalid response format: $e'};
    } catch (e) {
      AppLogger.error('❌ Unexpected error during initiation: $e');
      return {'success': false, 'error': e.toString()};
    }
  }

  /// Notify the receiver that all chunks are uploaded and ask it to finalize
  /// (verify hash + rename temp file). Returns true only when the receiver
  /// confirmed success; a hash mismatch or missing chunks returns false so the
  /// sender can mark the transfer as failed instead of completed.
  Future<bool> _notifyTransferComplete({
    required Device receiver,
    required String transferId,
    required String fileHash,
    required String senderId,
  }) async {
    final url = Uri.parse(
        'http://${receiver.ipAddress}:${receiver.port}/transfer/parallel/complete');

    try {
      final response = await http
          .post(
            url,
            headers: {
              'Content-Type': 'application/json',
              'x-device-id': senderId,
            },
            body: jsonEncode({
              'transferId': transferId,
              'fileHash': fileHash,
            }),
          )
          .timeout(
            const Duration(seconds: 10),
            onTimeout: () {
              throw TimeoutException('Completion notification timed out');
            },
          );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        return data['success'] == true;
      }
      return false;
    } catch (e) {
      AppLogger.error('⚠️ Failed to notify transfer completion: $e');
      return false;
    }
  }

  /// Wait for receiver to approve the transfer
  Future<bool> _waitForApproval({
    required Device receiver,
    required String requestId,
    required Duration timeout,
    required String senderId,
    ParallelTransferState? state,
  }) async {
    final startTime = DateTime.now();
    final approvalUrl = 'http://${receiver.ipAddress}:${receiver.port}/transfer/approval/$requestId';
    
    while (DateTime.now().difference(startTime) < timeout) {
      // User cancelled while waiting — stop polling so we abort promptly.
      if (state != null && state.isCancelled) {
        return false;
      }

      try {
        final response = await http
            .get(
              Uri.parse(approvalUrl),
              headers: {'x-device-id': senderId},
            )
            .timeout(const Duration(seconds: 5));
        
        if (response.statusCode == 200) {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          final status = data['status'] as String?;
          
          if (status == 'approved') {
            AppLogger.info('✅ Transfer approved by receiver');
            return true;
          } else if (status == 'rejected' || status == 'expired') {
            AppLogger.error('❌ Transfer $status by receiver');
            return false;
          }
          // status == 'pending' - continue waiting
        }
      } catch (e) {
        AppLogger.error('⚠️ Error checking approval status: $e');
      }
      
      // Wait before polling again
      await Future.delayed(const Duration(milliseconds: 500));
    }
    
    AppLogger.info('⏰ Transfer approval timed out');
    return false;
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

  Future<Uint8List> decryptChunk(
      Uint8List encryptedData, SecretKey secretKey) async {
    if (encryptedData.length < 28) {
      throw ArgumentError('Data too small to decrypt: ${encryptedData.length} bytes (minimum 28)');
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
    } on SecretBoxAuthenticationError catch (e) {
      throw DecryptionException(
        'Decryption failed: Authentication error - data may be corrupted or tampered',
        originalError: e,
      );
    } on ArgumentError catch (e) {
      throw DecryptionException('Invalid encrypted data: ${e.message}', originalError: e);
    } catch (e) {
      throw DecryptionException('Decryption failed: ${e.runtimeType}', originalError: e);
    }
  }

  void _emitProgress(ParallelTransferState state) {
    if (!_progressController.isClosed && !_isDisposed) {
      try {
        _progressController.add(ParallelProgress(
          transferId: state.transferId,
          fileName: state.fileName,
          bytesSent: state.bytesSent,
          totalBytes: state.fileSize,
          chunksSent: state.chunksSent,
          totalChunks: state.totalChunks,
          percentage: state.percentage,
        ));
      } catch (e) {
        AppLogger.error('⚠️ Error emitting progress: $e');
      }
    }
  }

  void cancelTransfer(String transferId) {
    final state = _activeTransfers[transferId];
    if (state != null) {
      state.cancel();
      _activeTransfers.remove(transferId);
    }
  }

  ChunkWriterManager get writerManager => _writerManager;

  // FIXED: Comprehensive disposal with proper error handling
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    AppLogger.info('🧹 Disposing ParallelTransferService...');

    // Cancel all active transfers first to unblock any pending lock waiters
    try {
      for (final state in _activeTransfers.values) {
        state.cancel();
      }
      _activeTransfers.clear();
    } catch (e) {
      AppLogger.error('⚠️ Error cancelling active transfers: $e');
    }

    // Dispose the transfer lock so any pending waiters are released
    try {
      _transfersLock.dispose();
    } catch (e) {
      AppLogger.error('⚠️ Error disposing transfer lock: $e');
    }

    // FIXED: Close HTTP clients with error handling
    for (final client in _clientPool) {
      try {
        client.close();
      } catch (e) {
        AppLogger.error('⚠️ Error closing HTTP client: $e');
      }
    }
    _clientPool.clear();

    // FIXED: Close writer manager with error handling
    try {
      await _writerManager.closeAll();
    } catch (e) {
      AppLogger.error('⚠️ Error closing writer manager: $e');
    }

    // FIXED: Close progress controller with error handling
    try {
      if (!_progressController.isClosed) {
        await _progressController.close();
      }
    } catch (e) {
      AppLogger.error('⚠️ Error closing progress controller: $e');
    }

    AppLogger.info('✅ ParallelTransferService disposed');
  }

}

/// State for tracking parallel transfer progress
class ParallelTransferState {
  final String transferId;
  final String fileName;
  final int fileSize;
  final int totalChunks;

  final Set<int> _sentChunks = {};
  int _bytesSent = 0;
  bool _isCancelled = false;

  final SynchronizedLock<void> _lock = SynchronizedLock<void>();

  ParallelTransferState({
    required this.transferId,
    required this.fileName,
    required this.fileSize,
    required this.totalChunks,
  });

  Future<void> markChunkSent(int chunkIndex, int chunkSize) async {
    await _lock.synchronized(() async {
      if (!_sentChunks.contains(chunkIndex)) {
        _sentChunks.add(chunkIndex);
        _bytesSent += chunkSize;
      }
    });
  }

  int get chunksSent => _sentChunks.length;
  int get bytesSent => _bytesSent;
  
  /// Calculate percentage based on bytes for accurate progress
  /// This ensures monotonically increasing progress without jumps
  double get percentage =>
      fileSize > 0 ? _bytesSent / fileSize : 0;
  bool get isComplete => _sentChunks.length == totalChunks;
  bool get isCancelled => _isCancelled;

  void cancel() => _isCancelled = true;
}

/// Progress update for parallel transfer
class ParallelProgress {
  final String transferId;
  final String fileName;
  final int bytesSent;
  final int totalBytes;
  final int chunksSent;
  final int totalChunks;
  final double percentage;

  ParallelProgress({
    required this.transferId,
    required this.fileName,
    required this.bytesSent,
    required this.totalBytes,
    required this.chunksSent,
    required this.totalChunks,
    required this.percentage,
  });

  @override
  String toString() =>
      'Progress: $chunksSent/$totalChunks chunks (${(percentage * 100).toStringAsFixed(1)}%)';
}

/// Custom exception for decryption errors in parallel transfers
class DecryptionException implements Exception {
  final String message;
  final dynamic originalError;

  DecryptionException(this.message, {this.originalError});

  @override
  String toString() {
    if (originalError != null) {
      return 'DecryptionException: $message (caused by: $originalError)';
    }
    return 'DecryptionException: $message';
  }
}
