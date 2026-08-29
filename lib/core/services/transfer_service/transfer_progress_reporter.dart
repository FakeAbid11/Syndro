import '../background_transfer_service.dart';
import '../live_activity_service.dart';

/// Centralizes per-transfer progress reporting to the OS notification and the
/// Android Live Activity.
///
/// The plain notification can be updated at full rate, but Live Activity
/// updates are an expensive native channel call, so they are throttled to one
/// update every [_liveActivityThrottle]. Callers invoke [begin] when a new
/// transfer (or resumed batch) starts so the throttle window resets.
class TransferProgressReporter {
  static const Duration _liveActivityThrottle = Duration(seconds: 2);

  DateTime? _lastLiveActivityUpdate;

  /// Reset throttling state for a new transfer.
  void begin() {
    _lastLiveActivityUpdate = null;
  }

  /// Report progress to the notification and (throttled) Live Activity.
  void report({
    required String title,
    required String fileName,
    required int progress,
    required int bytesTransferred,
    required int totalBytes,
  }) {
    BackgroundTransferService.updateProgress(
      title: title,
      fileName: fileName,
      progress: progress,
      bytesTransferred: bytesTransferred,
      totalBytes: totalBytes,
    );

    // Update Live Activity notification on Android (throttled)
    final now = DateTime.now();
    if (_lastLiveActivityUpdate == null ||
        now.difference(_lastLiveActivityUpdate!) >= _liveActivityThrottle) {
      _lastLiveActivityUpdate = now;
      LiveActivityService.updateTransferState(
        bytesTransferred: bytesTransferred,
        totalBytes: totalBytes,
        speed: 0,
      );
    }
  }
}