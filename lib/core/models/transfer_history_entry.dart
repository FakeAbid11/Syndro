import '../utils/byte_formatter.dart';
import 'transfer.dart';

/// A single typed row of the transfer history.
///
/// The history screen previously consumed raw `Map<String, dynamic>` rows
/// straight from sqflite; this model gives the data layer a real contract and
/// centralizes the null-handling that used to live in the widget code.
class TransferHistoryEntry {
  final String id;
  final String senderId;
  final String receiverId;

  /// Display names as recorded at transfer time (may be null).
  final String? senderName;
  final String? receiverName;

  /// [TransferStatus] name as persisted (`completed`, `failed`, ...).
  final String status;
  final int totalBytes;
  final int bytesTransferred;
  final int fileCount;
  final DateTime createdAt;
  final DateTime? completedAt;
  final String? errorMessage;

  const TransferHistoryEntry({
    required this.id,
    required this.senderId,
    required this.receiverId,
    required this.senderName,
    required this.receiverName,
    required this.status,
    required this.totalBytes,
    required this.bytesTransferred,
    required this.fileCount,
    required this.createdAt,
    required this.completedAt,
    required this.errorMessage,
  });

  factory TransferHistoryEntry.fromRow(Map<String, dynamic> row) {
    final createdAtMillis = row['created_at'] as int? ?? 0;
    final completedMillis = row['completed_at'] as int?;
    return TransferHistoryEntry(
      id: row['id'] as String? ?? '',
      senderId: row['sender_id'] as String? ?? '',
      receiverId: row['receiver_id'] as String? ?? '',
      senderName: row['sender_name'] as String?,
      receiverName: row['receiver_name'] as String?,
      status: row['status'] as String? ?? 'unknown',
      totalBytes: row['total_bytes'] as int? ?? 0,
      bytesTransferred: row['bytes_transferred'] as int? ?? 0,
      fileCount: row['file_count'] as int? ?? 0,
      createdAt: createdAtMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(createdAtMillis)
          : DateTime.now(),
      completedAt: completedMillis != null && completedMillis > 0
          ? DateTime.fromMillisecondsSinceEpoch(completedMillis)
          : null,
      errorMessage: row['error_message'] as String?,
    );
  }

  /// Best display name for the remote side of the transfer.
  String get displayName {
    final receiver = receiverName;
    if (receiver != null && receiver.isNotEmpty) return receiver;
    final sender = senderName;
    if (sender != null && sender.isNotEmpty) return sender;
    return 'Unknown Device';
  }

  String get totalBytesFormatted => ByteFormatter.format(totalBytes);

  bool get isCompleted => status == TransferStatus.completed.name;
}