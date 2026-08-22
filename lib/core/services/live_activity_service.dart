import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service for managing Android transfer progress notifications.
///
/// Displays real-time transfer progress as an ongoing foreground notification
/// on Android 12+ (API 31+), visible on the lock screen and notification shade.
/// On unsupported platforms, all methods are safe no-ops.
class LiveActivityService {
  static const MethodChannel _channel = MethodChannel('syndro/live_activity');

  static bool _isInitialized = false;
  static String? _currentActivityId;

  /// Whether the current platform supports Live Activity notifications.
  static bool get _isSupported => Platform.isAndroid;

  /// Initialize the Live Activity service.
  ///
  /// Queries the native side for platform support (Android 12+).
  /// On desktop platforms this is a no-op.
  static Future<void> initialize() async {
    if (_isInitialized) return;
    if (!_isSupported) return;

    try {
      final isSupported = await _channel.invokeMethod<bool>('isSupported');
      if (isSupported == true) {
        _isInitialized = true;
        debugPrint('✅ Live Activity service initialized');
      } else {
        debugPrint('ℹ️ Live Activities not supported on this Android version');
      }
    } catch (e) {
      debugPrint('❌ Failed to initialize Live Activity service: $e');
    }
  }

  /// Check if Live Activities are supported on the current platform.
  static Future<bool> isSupported() async {
    if (!_isSupported) return false;

    try {
      final result = await _channel.invokeMethod<bool>('isSupported');
      return result ?? false;
    } catch (e) {
      return false;
    }
  }

  /// Start a new transfer Live Activity.
  ///
  /// Shows an ongoing progress notification on Android.
  ///
  /// [fileName] - Name of the file being transferred
  /// [totalBytes] - Total size of the file in bytes
  /// [senderName] - Name of the sender/recipient
  /// [isIncoming] - Whether this is an incoming transfer
  static Future<String?> startTransferActivity({
    required String fileName,
    required int totalBytes,
    required String senderName,
    required bool isIncoming,
  }) async {
    if (!_isSupported) return null;
    if (!_isInitialized) {
      await initialize();
    }

    if (!_isInitialized) {
      return null;
    }

    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'startTransferActivity',
        {
          'fileName': fileName,
          'totalBytes': totalBytes,
          'senderName': senderName,
          'isIncoming': isIncoming,
        },
      );

      if (result != null) {
        _currentActivityId = result['activityId'] as String?;
        return _currentActivityId;
      }
    } catch (e) {
      debugPrint('❌ Failed to start Live Activity: $e');
    }

    return null;
  }

  /// Update the progress of an active Live Activity.
  ///
  /// [bytesTransferred] - Number of bytes transferred so far
  /// [speed] - Current transfer speed in bytes per second
  static Future<void> updateProgress({
    required int bytesTransferred,
    required double speed,
  }) async {
    if (_currentActivityId == null || !_isInitialized) return;

    try {
      await _channel.invokeMethod('updateProgress', {
        'activityId': _currentActivityId,
        'bytesTransferred': bytesTransferred,
        'speed': speed,
      });
    } catch (e) {
      debugPrint('❌ Failed to update Live Activity progress: $e');
    }
  }

  /// Update the full transfer state in the active Live Activity.
  ///
  /// Provides complete progress information including percentage, speed,
  /// and estimated time remaining.
  static Future<void> updateTransferState({
    required int bytesTransferred,
    required int totalBytes,
    required double speed,
    String? eta,
  }) async {
    if (_currentActivityId == null || !_isInitialized) return;

    try {
      final progress =
          totalBytes > 0 ? (bytesTransferred / totalBytes * 100) : 0.0;

      await _channel.invokeMethod('updateTransferState', {
        'activityId': _currentActivityId,
        'bytesTransferred': bytesTransferred,
        'totalBytes': totalBytes,
        'progress': progress,
        'speed': speed,
        'eta': eta,
      });
    } catch (e) {
      debugPrint('❌ Failed to update Live Activity state: $e');
    }
  }

  /// End the current Live Activity.
  ///
  /// [success] - Whether the transfer completed successfully
  /// [message] - Optional message to display (e.g., "Transfer Complete")
  static Future<void> endActivity({
    required bool success,
    String? message,
  }) async {
    if (_currentActivityId == null) return;

    try {
      await _channel.invokeMethod('endActivity', {
        'activityId': _currentActivityId,
        'success': success,
        'message': message,
      });
    } catch (e) {
      debugPrint('❌ Failed to end Live Activity: $e');
    } finally {
      _currentActivityId = null;
    }
  }

  /// Cancel the current Live Activity.
  static Future<void> cancelActivity() async {
    await endActivity(success: false, message: 'Transfer cancelled');
  }

  /// Whether there is an active Live Activity.
  static bool get hasActiveActivity => _currentActivityId != null;

  /// The current activity ID, or null if none is active.
  static String? get currentActivityId => _currentActivityId;
}
