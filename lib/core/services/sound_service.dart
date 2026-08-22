import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Service to play notification sounds across all platforms.
///
/// - Android: Uses native MethodChannel to play system notification sound.
/// - Windows: Uses PowerShell toast notification sound.
/// - Linux: Uses system sound files via paplay/aplay.
/// - Other platforms: No-op.
class SoundService {
  static final SoundService _instance = SoundService._internal();
  factory SoundService() => _instance;
  SoundService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.syndro.app/sound');

  /// Play sound for incoming transfer request.
  Future<void> playRequestSound() async {
    await _playNotificationSound(isRequest: true);
  }

  /// Play sound for completed transfer.
  Future<void> playCompleteSound() async {
    await _playNotificationSound(isRequest: false);
  }

  Future<void> _playNotificationSound({bool isRequest = false}) async {
    if (Platform.isAndroid) {
      await _playAndroidSound();
    } else if (Platform.isWindows) {
      await _playWindowsSound();
    } else if (Platform.isLinux) {
      await _playLinuxSound(isRequest: isRequest);
    }
    // No-op on macOS and other platforms
  }

  /// Play default Android notification sound via native channel.
  Future<void> _playAndroidSound() async {
    try {
      await _channel.invokeMethod('playNotificationSound');
    } catch (e) {
      debugPrint('Could not play Android notification sound: $e');
    }
  }

  /// Play notification sound on Windows using PowerShell toast.
  Future<void> _playWindowsSound() async {
    try {
      const script = '''
[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null
\$template = @"
<toast duration="short">
  <visual>
    <binding template="ToastText02">
      <text id="1">Syndro</text>
      <text id="2">Notification</text>
    </binding>
  </visual>
  <audio src="ms-winsoundevent:Notification.Default"/>
</toast>
"@
\$xml = New-Object Windows.Data.Xml.Dom.XmlDocument
\$xml.LoadXml(\$template)
\$toast = [Windows.UI.Notifications.ToastNotification]::new(\$xml)
[Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("Syndro").Show(\$toast)
''';

      await Process.run(
        'powershell',
        ['-ExecutionPolicy', 'Bypass', '-Command', script],
        runInShell: true,
      );
    } catch (e) {
      debugPrint('Could not play Windows notification sound: $e');
    }
  }

  /// Play notification sound on Linux using system sound files.
  Future<void> _playLinuxSound({bool isRequest = false}) async {
    try {
      final soundPaths = isRequest
          ? [
              '/usr/share/sounds/freedesktop/stereo/message.oga',
              '/usr/share/sounds/gnome/default/sounds/message.ogg',
              '/usr/share/sounds/freedesktop/stereo/complete.oga',
              '/usr/share/sounds/gnome/default/sounds/complete.ogg',
            ]
          : [
              '/usr/share/sounds/freedesktop/stereo/complete.oga',
              '/usr/share/sounds/gnome/default/sounds/complete.ogg',
              '/usr/share/sounds/freedesktop/stereo/message.oga',
              '/usr/share/sounds/gnome/default/sounds/message.ogg',
            ];

      String? validSoundPath;
      for (final path in soundPaths) {
        if (await File(path).exists()) {
          validSoundPath = path;
          break;
        }
      }

      if (validSoundPath == null) {
        // No system sound file found — silently skip
        return;
      }

      // Try paplay first (PulseAudio), then fall back to aplay (ALSA)
      var result = await Process.run('which', ['paplay']);
      if (result.exitCode == 0) {
        await Process.run('paplay', [validSoundPath]);
        return;
      }

      result = await Process.run('which', ['aplay']);
      if (result.exitCode == 0) {
        await Process.run('aplay', [validSoundPath]);
      }
    } catch (e) {
      // Sound playback is best-effort; ignore failures
    }
  }
}
