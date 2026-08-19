import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Appends startup milestones to a log file so release-mode startup problems
/// (where [debugPrint] is invisible) can be diagnosed after the fact.
class StartupLogger {
  StartupLogger._();

  static const int _maxBytes = 200 * 1024;

  static String? _path;

  /// Resolve (and rotate) the log file path. Returns `null` on any failure so
  /// logging can never break startup.
  static Future<String?> _resolve() async {
    if (_path != null) return _path;
    try {
      final support = await getApplicationSupportDirectory();
      final dir = Directory(p.join(support.path, 'logs'));
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, 'startup.log'));
      if (await file.exists()) {
        final length = await file.length();
        if (length > _maxBytes) {
          await file.writeAsString('', flush: true);
        }
      }
      _path = file.path;
      return _path;
    } catch (_) {
      return null;
    }
  }

  /// Append a single timestamped line. Fire-and-forget safe.
  static Future<void> log(String message) async {
    final path = await _resolve();
    if (path == null) return;
    try {
      final line = '${DateTime.now().toIso8601String()} $message';
      await File(path).writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {}
  }
}