import 'dart:io';


import '../../utils/app_logger.dart';
/// Configuration for parallel chunk transfers
///
/// Automatically adjusts based on device capabilities
class ParallelConfig {
  /// Number of parallel connections
  final int connections;

  /// Chunk size in bytes
  final int chunkSize;

  /// Minimum file size to use parallel transfer (bytes)
  final int minFileSize;

  /// Whether parallel transfer is enabled
  final bool enabled;

  /// Whether this is for browser transfer
  final bool isBrowser;

  const ParallelConfig({
    required this.connections,
    required this.chunkSize,
    required this.minFileSize,
    this.enabled = true,
    this.isBrowser = false,
  });

  /// Default config for App-to-App transfers (OPTIMIZED)
  static const ParallelConfig appToApp = ParallelConfig(
    connections: 8,                   // Increased from 4
    chunkSize: 2 * 1024 * 1024,      // 2MB (increased from 1MB)
    minFileSize: 10 * 1024 * 1024,   // 10MB minimum
    enabled: true,
    isBrowser: false,
  );

  /// Default config for App-to-Browser transfers (OPTIMIZED)
  static const ParallelConfig appToBrowser = ParallelConfig(
    connections: 4,                   // Increased from 2
    chunkSize: 2 * 1024 * 1024,      // 2MB (increased from 1MB)
    minFileSize: 10 * 1024 * 1024,   // 10MB minimum
    enabled: true,
    isBrowser: true,
  );

  /// Conservative config for low-end devices (4GB RAM or less)
  /// OPTIMIZED: Smaller chunks and fewer connections to minimize memory pressure
  /// This allows sending 50GB+ files on devices with only 2-4GB RAM
  static const ParallelConfig lowEnd = ParallelConfig(
    connections: 2,                   // Reduced from 4 - less memory overhead
    chunkSize: 512 * 1024,           // 512KB - smaller chunks for low memory
    minFileSize: 5 * 1024 * 1024,    // 5MB minimum - enable parallel for smaller files
    enabled: true,
    isBrowser: false,
  );

  /// Ultra-low-end config for very old devices (2GB RAM or less)
  /// Single connection, very small chunks - maximizes compatibility
  static const ParallelConfig ultraLowEnd = ParallelConfig(
    connections: 1,                   // Single connection - minimum memory
    chunkSize: 256 * 1024,           // 256KB - very small chunks
    minFileSize: 10 * 1024 * 1024,   // 10MB minimum
    enabled: true,
    isBrowser: false,
  );

  /// Config for single connection (fallback)
  static const ParallelConfig single = ParallelConfig(
    connections: 1,
    chunkSize: 1 * 1024 * 1024,      // 1MB
    minFileSize: 0,
    enabled: false,
    isBrowser: false,
  );

  /// Auto-detect best config based on device
  /// OPTIMIZED: Better detection for low-end devices to handle large files
  static Future<ParallelConfig> autoDetect({bool isBrowser = false}) async {
    if (isBrowser) {
      return appToBrowser;
    }

    try {
      final ramGB = await _getDeviceRAMGB();

      // Ultra-low-end: 2GB or less - use minimal resources
      if (ramGB <= 2) {
        AppLogger.info('📱 Ultra-low-end device detected ($ramGB GB RAM), using minimal config');
        return ultraLowEnd;
      }
      // Low-end: 2-4GB - conservative settings
      else if (ramGB <= 4) {
        AppLogger.info('📱 Low-end device detected ($ramGB GB RAM), using conservative config');
        return lowEnd;
      }
      // Mid-range: 4-8GB - balanced settings
      else if (ramGB <= 8) {
        AppLogger.info('📱 Mid-range device detected ($ramGB GB RAM), using balanced config');
        return appToApp;
      }
      // High-end: 8GB+ - maximum performance
      else {
        AppLogger.info('📱 High-end device detected ($ramGB GB RAM), using max performance config');
        return const ParallelConfig(
          connections: 12,                  // Increased from 6
          chunkSize: 4 * 1024 * 1024,      // 4MB (increased from 2MB)
          minFileSize: 10 * 1024 * 1024,
          enabled: true,
          isBrowser: false,
        );
      }
    } catch (e) {
      AppLogger.info('Could not detect device RAM, using default config: $e');
      return appToApp;
    }
  }

  /// Get device RAM in GB (approximate)
  static Future<int> _getDeviceRAMGB() async {
    try {
      if (Platform.isAndroid) {
        // Try to read from /proc/meminfo
        final file = File('/proc/meminfo');
        if (await file.exists()) {
          final content = await file.readAsString();
          final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(content);
          if (match != null) {
            final kb = int.tryParse(match.group(1)!);
            if (kb != null) {
              return (kb / 1024 / 1024).round(); // Convert to GB
            }
          }
        }
      } else if (Platform.isWindows || Platform.isLinux) {
        // Desktop usually has more RAM
        if (Platform.isLinux) {
          final file = File('/proc/meminfo');
          if (await file.exists()) {
            final content = await file.readAsString();
            final match = RegExp(r'MemTotal:\s+(\d+)\s+kB').firstMatch(content);
            if (match != null) {
              final kb = int.tryParse(match.group(1)!);
              if (kb != null) {
                return (kb / 1024 / 1024).round();
              }
            }
          }
        }
        // Assume 16GB for desktop if can't detect
        return 16;
      }
    } catch (e) {
      AppLogger.info('Error detecting RAM: $e');
    }

    // Default assumption: 8GB
    return 8;
  }

  /// Check if file should use parallel transfer
  bool shouldUseParallel(int fileSize) {
    return enabled && fileSize >= minFileSize;
  }

  /// Calculate number of chunks for a file
  int calculateChunkCount(int fileSize) {
    return (fileSize / chunkSize).ceil();
  }

  /// Get chunk info for a specific chunk index
  ChunkInfo getChunkInfo(int chunkIndex, int fileSize) {
    final start = chunkIndex * chunkSize;
    final end = (start + chunkSize).clamp(0, fileSize);
    final size = end - start;

    return ChunkInfo(
      index: chunkIndex,
      start: start,
      end: end,
      size: size,
    );
  }

  /// Get all chunk infos for a file
  List<ChunkInfo> getAllChunks(int fileSize) {
    final count = calculateChunkCount(fileSize);
    return List.generate(count, (i) => getChunkInfo(i, fileSize));
  }

  /// Calculate max RAM usage
  /// OPTIMIZED: More accurate calculation for low-end devices
  int get maxRamUsage => connections * chunkSize * 2; // *2 for safety margin
  
  /// Check if transfer is feasible given available memory
  /// Returns true if the device has enough RAM for this config
  bool isFeasibleForDevice(int availableRamBytes) {
    // Need at least 3x the max RAM usage for safe operation
    // (input buffer + output buffer + overhead)
    final requiredBytes = maxRamUsage * 3;
    return availableRamBytes > requiredBytes;
  }
  
  /// Get a safer config if current one might cause memory issues
  ParallelConfig getSafeConfigForMemory(int availableRamMB) {
    final availableBytes = availableRamMB * 1024 * 1024;
    
    if (isFeasibleForDevice(availableBytes)) {
      return this;
    }
    
    // Downgrade to safer config
    if (availableRamMB <= 512) {
      return ultraLowEnd; // 512MB or less
    } else if (availableRamMB <= 1024) {
      return lowEnd; // 1-2GB
    } else {
      // Reduce connections but keep chunk size
      return ParallelConfig(
        connections: (connections / 2).ceil(),
        chunkSize: chunkSize,
        minFileSize: minFileSize,
        enabled: enabled,
        isBrowser: isBrowser,
      );
    }
  }

  @override
  String toString() {
    return 'ParallelConfig(connections: $connections, chunkSize: ${chunkSize ~/ 1024}KB, '
        'minFileSize: ${minFileSize ~/ 1024 ~/ 1024}MB, enabled: $enabled)';
  }
}

/// Information about a single chunk
class ChunkInfo {
  final int index;
  final int start;
  final int end;
  final int size;

  const ChunkInfo({
    required this.index,
    required this.start,
    required this.end,
    required this.size,
  });

  @override
  String toString() => 'Chunk[$index]: $start-$end (${size}B)';
}

/// Transfer mode enum
enum TransferMode {
  /// Single connection (legacy)
  single,

  /// Parallel connections (fast)
  parallel,

  /// Auto-detect based on file size
  auto,
}
