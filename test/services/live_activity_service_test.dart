import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/live_activity_service.dart';

void main() {
  group('LiveActivityService', () {
    setUp(() {
      // Reset state between tests by ensuring no active activity
      // (The service uses static fields, so we test the observable behavior)
    });

    test('hasActiveActivity should be false initially', () {
      expect(LiveActivityService.hasActiveActivity, isFalse);
    });

    test('currentActivityId should be null initially', () {
      expect(LiveActivityService.currentActivityId, isNull);
    });

    test('updateProgress should not throw when no activity is active', () async {
      // Should be a no-op since _currentActivityId is null
      await LiveActivityService.updateProgress(
        bytesTransferred: 1024,
        speed: 512.0,
      );
      // No assertion needed — just verifying no exception is thrown
    });

    test('updateTransferState should not throw when no activity is active', () async {
      await LiveActivityService.updateTransferState(
        bytesTransferred: 1024,
        totalBytes: 2048,
        speed: 512.0,
        eta: '10s',
      );
      // No assertion needed — just verifying no exception is thrown
    });

    test('cancelActivity should not throw when no activity is active', () async {
      await LiveActivityService.cancelActivity();
      expect(LiveActivityService.hasActiveActivity, isFalse);
    });

    test('endActivity should not throw when no activity is active', () async {
      await LiveActivityService.endActivity(
        success: true,
        message: 'Transfer complete',
      );
      expect(LiveActivityService.hasActiveActivity, isFalse);
    });
  });
}
