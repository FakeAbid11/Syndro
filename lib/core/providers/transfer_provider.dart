import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/transfer_service.dart';
import '../services/file_service.dart';

// ============================================
// FILE SERVICE PROVIDER
// ============================================

/// Provider for [FileService] instance
///
/// Provides a singleton [FileService] for file operations
/// such as picking files, scanning directories, and
/// reading/writing file streams.
final fileServiceProvider = Provider<FileService>((ref) {
  return FileService();
});

// ============================================
// TRANSFER SERVICE PROVIDER
// ============================================

/// Provider for [TransferService] instance
///
/// Provides the core transfer service that handles:
/// - File transfers between devices
/// - Transfer state management
/// - Encryption for secure transfers
/// - Checkpoint/resume functionality
///
/// The service is automatically disposed when the provider
/// is no longer needed.
final transferServiceProvider = Provider<TransferService>((ref) {
  final fileService = ref.watch(fileServiceProvider);
  final service = TransferService(fileService);

  // FIXED: Removed duplicate onDispose callbacks that caused race conditions
  // FIX: onDispose doesn't await - call dispose without await
  ref.onDispose(() {
    service.dispose().timeout(
      const Duration(seconds: 5),
      onTimeout: () {},
    ).catchError((e) {
      return;
    });
  });

  return service;
});

// ============================================
// PENDING TRANSFER REQUESTS PROVIDER
// ============================================

/// Stream provider for pending transfer requests
/// This allows the UI to reactively listen for incoming transfer requests
final pendingTransferRequestsProvider =
    StreamProvider<List<PendingTransferRequest>>((ref) {
  final service = ref.watch(transferServiceProvider);
  return service.pendingRequestsStream;
});

/// Provider to get trusted devices list
final trustedDevicesProvider = Provider<List<TrustedDevice>>((ref) {
  final service = ref.watch(transferServiceProvider);
  return service.trustedDevices;
});
