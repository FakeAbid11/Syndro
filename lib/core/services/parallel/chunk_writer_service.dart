import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'parallel_config.dart';
import '../../utils/app_logger.dart';
import '../../utils/byte_formatter.dart';
import '../../utils/synchronized.dart';

/// RAM-efficient chunk writer service
/// 
/// Writes chunks directly to disk at specific offsets
/// Memory usage: ~1-2MB regardless of file size
class ChunkWriterService {
  final String filePath;
  final int totalSize;
  final int totalChunks;
  final ParallelConfig config;
  
  RandomAccessFile? _file;
  final Set<int> _receivedChunks = {};
  final _completionController = StreamController<double>.broadcast();
  bool _isComplete = false;
  bool _isClosed = false;

  /// Serializes seek+write pairs (and the shared bookkeeping below) so that
  /// concurrent connections cannot interleave `setPosition`/`writeFrom` on the
  /// single shared [RandomAccessFile] handle and corrupt the output.
  final SynchronizedLock<void> _writeLock = SynchronizedLock<void>();
  
  /// Track bytes received for progress
  int _bytesReceived = 0;

  ChunkWriterService({
    required this.filePath,
    required this.totalSize,
    required this.totalChunks,
    required this.config,
  });

  /// Stream of completion percentage (0.0 - 1.0)
  Stream<double> get completionStream => _completionController.stream;
  
  /// Current completion percentage
  double get completionPercentage =>
      totalChunks == 0 ? 0.0 : _receivedChunks.length / totalChunks;
  
  /// Bytes received so far
  int get bytesReceived => _bytesReceived;
  
  /// Check if transfer is complete
  bool get isComplete => _isComplete;
  
  /// Check if file is closed
  bool get isClosed => _isClosed;

  /// Initialize and pre-allocate file
  Future<void> initialize() async {
    if (_file != null) return;
    
    try {
      // Ensure directory exists
      final dir = Directory(filePath).parent;
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      
      // Create temp file
      final tempPath = '$filePath.tmp';
      final tempFile = File(tempPath);
      
      // Pre-allocate file with zeros (sparse file on supported systems)
      _file = await tempFile.open(mode: FileMode.write);
      
      // Seek to end to set file size (creates sparse file)
      await _file!.setPosition(totalSize - 1);
      await _file!.writeByte(0);
      await _file!.setPosition(0);
      
      AppLogger.info('📁 Pre-allocated file: $tempPath (${ByteFormatter.format(totalSize)})');
    } catch (e) {
      AppLogger.error('Error initializing chunk writer: $e');
      rethrow;
    }
  }

  /// Write a chunk at specific index
  /// 
  /// Thread-safe: Can be called from multiple isolates/connections
  Future<void> writeChunk(int chunkIndex, Uint8List data) async {
    if (_isClosed) {
      throw StateError('ChunkWriter is closed');
    }
    
    if (_file == null) {
      throw StateError('ChunkWriter not initialized');
    }

    if (chunkIndex >= totalChunks) {
      throw RangeError('Chunk index $chunkIndex out of range (max: ${totalChunks - 1})');
    }

    // Serialize the entire seek+write+bookkeeping section. The single
    // RandomAccessFile handle is shared across all parallel connections, so an
    // unlocked `setPosition` followed by `writeFrom` can be interleaved by
    // another connection's seek, silently writing chunks to the wrong offset.
    await _writeLock.synchronized(() async {
      if (_isClosed) {
        throw StateError('ChunkWriter is closed');
      }

      if (_receivedChunks.contains(chunkIndex)) {
        AppLogger.warn('⚠️ Chunk $chunkIndex already received, skipping');
        return;
      }

      try {
        // Calculate offset
        final offset = chunkIndex * config.chunkSize;

        // Seek to offset and write (atomic under the lock)
        await _file!.setPosition(offset);
        await _file!.writeFrom(data);

        // Mark chunk as received
        _receivedChunks.add(chunkIndex);
        _bytesReceived += data.length;

        // Emit progress
        final progress = _receivedChunks.length / totalChunks;
        if (!_completionController.isClosed) {
          _completionController.add(progress);
        }

        // Check if complete
        if (_receivedChunks.length == totalChunks) {
          _isComplete = true;
          AppLogger.info('✅ All $totalChunks chunks received');
        }
      } catch (e) {
        AppLogger.error('Error writing chunk $chunkIndex: $e');
        rethrow;
      }
    });
  }

  /// Get list of missing chunks (for retry)
  List<int> getMissingChunks() {
    final missing = <int>[];
    for (int i = 0; i < totalChunks; i++) {
      if (!_receivedChunks.contains(i)) {
        missing.add(i);
      }
    }
    return missing;
  }

  /// Check if specific chunk was received
  /// Read a chunk from the temp file at the given index.
  /// Returns null if the chunk has not been written yet.
  Future<Uint8List?> readChunk(int chunkIndex) async {
    if (_file == null || _isClosed) return null;
    if (chunkIndex >= totalChunks) return null;
    if (!_receivedChunks.contains(chunkIndex)) return null;

    final chunkStart = chunkIndex * config.chunkSize;
    final remainingSize = totalSize - chunkStart;
    final chunkSize = remainingSize > config.chunkSize ? config.chunkSize : remainingSize;

    // Use write lock to avoid concurrent seek/read races on the shared RAF
    Uint8List? result;
    await _writeLock.synchronized(() async {
      await _file!.setPosition(chunkStart);
      result = await _file!.read(chunkSize);
    });
    return result;
  }

  bool hasChunk(int chunkIndex) => _receivedChunks.contains(chunkIndex);

  /// Finalize and rename temp file to final
  Future<File> finalize() async {
    if (!_isComplete) {
      final missing = getMissingChunks();
      throw StateError('Cannot finalize: ${missing.length} chunks missing: $missing');
    }
    
    try {
      // Flush and close
      await _file?.flush();
      await _file?.close();
      _file = null;
      
      // Rename temp to final
      final tempPath = '$filePath.tmp';
      final tempFile = File(tempPath);

      // Do NOT clobber an existing file with the same name — pick a unique
      // destination (e.g. "photo (1).jpg") so an incoming transfer can never
      // silently overwrite a user's existing file.
      final destinationPath = await _resolveUniqueFinalPath(filePath);

      // Rename
      await tempFile.rename(destinationPath);

      _isClosed = true;
      await _completionController.close();

      AppLogger.info('✅ File finalized: $destinationPath');
      return File(destinationPath);
    } catch (e) {
      AppLogger.error('Error finalizing file: $e');
      rethrow;
    }
  }

  /// Resolve a non-colliding destination path.
  ///
  /// If [path] does not exist it is returned unchanged; otherwise a numeric
  /// suffix is inserted before the extension ("file (1).ext", "file (2).ext",
  /// …) until a free name is found.
  Future<String> _resolveUniqueFinalPath(String path) async {
    if (!await File(path).exists()) return path;

    final sep = Platform.pathSeparator;
    final lastSep = path.lastIndexOf(sep);
    final dir = lastSep >= 0 ? path.substring(0, lastSep + 1) : '';
    final name = lastSep >= 0 ? path.substring(lastSep + 1) : path;

    final dot = name.lastIndexOf('.');
    final base = dot > 0 ? name.substring(0, dot) : name;
    final ext = dot > 0 ? name.substring(dot) : '';

    for (int i = 1; i < 10000; i++) {
      final candidate = '$dir$base ($i)$ext';
      if (!await File(candidate).exists()) return candidate;
    }
    // Extremely unlikely fallback: timestamp-suffixed name.
    return '$dir$base (${DateTime.now().millisecondsSinceEpoch})$ext';
  }

  /// Abort and cleanup
  Future<void> abort() async {
    try {
      await _file?.close();
      _file = null;
      
      // Delete temp file
      final tempPath = '$filePath.tmp';
      final tempFile = File(tempPath);
      if (await tempFile.exists()) {
        await tempFile.delete();
      }
      
      _isClosed = true;
      await _completionController.close();
      
      AppLogger.info('🚫 Transfer aborted, temp file deleted');
    } catch (e) {
      AppLogger.error('Error aborting: $e');
    }
  }

  /// Close without finalizing (for cleanup)
  Future<void> close() async {
    if (_isClosed) return;
    
    try {
      await _file?.close();
      _file = null;
      _isClosed = true;
      
      if (!_completionController.isClosed) {
        await _completionController.close();
      }
    } catch (e) {
      AppLogger.error('Error closing chunk writer: $e');
    }
  }

}

/// Manages multiple chunk writers for a transfer session
class ChunkWriterManager {
  final Map<String, ChunkWriterService> _writers = {};

  /// Create a new chunk writer for a file
  Future<ChunkWriterService> createWriter({
    required String fileId,
    required String filePath,
    required int totalSize,
    required ParallelConfig config,
  }) async {
    if (_writers.containsKey(fileId)) {
      throw StateError('Writer already exists for file: $fileId');
    }
    
    final totalChunks = config.calculateChunkCount(totalSize);
    
    final writer = ChunkWriterService(
      filePath: filePath,
      totalSize: totalSize,
      totalChunks: totalChunks,
      config: config,
    );
    
    await writer.initialize();
    _writers[fileId] = writer;
    
    return writer;
  }

  /// Get existing writer
  ChunkWriterService? getWriter(String fileId) => _writers[fileId];

  /// Remove writer
  Future<void> removeWriter(String fileId) async {
    final writer = _writers.remove(fileId);
    await writer?.close();
  }

  /// Close all writers
  Future<void> closeAll() async {
    for (final writer in _writers.values) {
      await writer.close();
    }
    _writers.clear();
  }

  /// Abort all writers
  Future<void> abortAll() async {
    for (final writer in _writers.values) {
      await writer.abort();
    }
    _writers.clear();
  }
}
