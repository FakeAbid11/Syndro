import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_logger.dart';

/// Result of a successful update check when a newer release is available.
class UpdateInfo {
  /// The release version, normalized without a leading `v` (e.g. `1.2.0`).
  final String version;

  /// The GitHub release page URL (always present, used as a fallback).
  final String releaseUrl;

  /// Release notes / changelog body (may be empty).
  final String notes;

  /// Direct download URL for this platform's asset, if one was found.
  final String? assetUrl;

  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    this.assetUrl,
  });

  /// Preferred URL to open: the platform asset if present, else the release page.
  String get downloadUrl => assetUrl ?? releaseUrl;
}

/// Checks GitHub Releases for a newer version of the app and opens the download
/// page in the system browser. Read-only: never downloads or installs anything.
class UpdateService {
  UpdateService._();

  static const String _owner = 'FakeAbid11';
  static const String _repo = 'Syndro';
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Prefix for the "skip this version" flag stored in shared_preferences.
  static const String _skipPrefix = 'syndro.update.skip.';

  static const Duration _timeout = Duration(seconds: 8);

  /// Query GitHub for the latest release. Returns an [UpdateInfo] only when the
  /// remote version is strictly newer than the running app; otherwise null.
  ///
  /// Never throws — any network/parse failure is logged and returns null.
  static Future<UpdateInfo?> checkForUpdate() async {
    try {
      final response = await http.get(
        Uri.parse(_latestReleaseUrl),
        headers: const {
          'Accept': 'application/vnd.github+json',
          'User-Agent': 'Syndro-App',
        },
      ).timeout(_timeout);

      if (response.statusCode != 200) {
        AppLogger.warn('Update check: HTTP ${response.statusCode}');
        return null;
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) return null;

      // Skip drafts / prereleases.
      if (data['draft'] == true || data['prerelease'] == true) return null;

      final tagName = (data['tag_name'] as String?)?.trim() ?? '';
      final releaseUrl = (data['html_url'] as String?)?.trim() ?? '';
      final notes = (data['body'] as String?)?.trim() ?? '';
      if (tagName.isEmpty || releaseUrl.isEmpty) return null;

      final latestVersion = _normalize(tagName);
      final currentVersion = await _currentVersion();

      if (!_isNewer(latestVersion, currentVersion)) {
        return null;
      }

      final assets = (data['assets'] as List?) ?? const [];
      final assetUrl = _selectAssetUrl(assets);

      return UpdateInfo(
        version: latestVersion,
        releaseUrl: releaseUrl,
        notes: notes,
        assetUrl: assetUrl,
      );
    } on TimeoutException {
      AppLogger.warn('Update check timed out');
      return null;
    } catch (e) {
      AppLogger.warn('Update check failed: $e');
      return null;
    }
  }

  /// Open the download URL for [info] in the system browser / default handler.
  static Future<bool> openDownload(UpdateInfo info) async {
    try {
      final uri = Uri.parse(info.downloadUrl);
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      AppLogger.warn('Could not open download URL: $e');
      return false;
    }
  }

  /// Remember that the user chose to skip [version] (used by the startup check).
  static Future<void> skipVersion(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('$_skipPrefix$version', true);
    } catch (_) {
      // Non-critical.
    }
  }

  /// Whether [version] was previously skipped by the user.
  static Future<bool> isSkipped(String version) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool('$_skipPrefix$version') ?? false;
    } catch (_) {
      return false;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  static Future<String> _currentVersion() async {
    final info = await PackageInfo.fromPlatform();
    return _normalize(info.version);
  }

  /// Strip a leading `v` and any build metadata (`+N`) or pre-release suffix.
  static String _normalize(String raw) {
    var v = raw.trim();
    if (v.startsWith('v') || v.startsWith('V')) v = v.substring(1);
    // Drop build metadata / pre-release: 1.2.0+3 → 1.2.0, 1.2.0-beta → 1.2.0
    final plus = v.indexOf('+');
    if (plus != -1) v = v.substring(0, plus);
    final dash = v.indexOf('-');
    if (dash != -1) v = v.substring(0, dash);
    return v.trim();
  }

  /// Numeric, component-wise comparison. Returns true if [latest] > [current].
  /// Malformed input is treated conservatively (returns false → "up to date").
  static bool _isNewer(String latest, String current) {
    final a = _parts(latest);
    final b = _parts(current);
    if (a.isEmpty) return false;

    final len = a.length > b.length ? a.length : b.length;
    for (var i = 0; i < len; i++) {
      final ai = i < a.length ? a[i] : 0;
      final bi = i < b.length ? b[i] : 0;
      if (ai > bi) return true;
      if (ai < bi) return false;
    }
    return false; // equal
  }

  static List<int> _parts(String version) {
    if (version.isEmpty) return const [];
    final result = <int>[];
    for (final segment in version.split('.')) {
      final n = int.tryParse(segment.trim());
      if (n == null) return const []; // malformed → treat as "up to date"
      result.add(n);
    }
    return result;
  }

  /// Pick the best download asset for the current platform, or null to fall
  /// back to the release page.
  static String? _selectAssetUrl(List<dynamic> assets) {
    final entries = <MapEntry<String, String>>[];
    for (final a in assets) {
      if (a is Map) {
        final name = (a['name'] as String?)?.toLowerCase() ?? '';
        final url = (a['browser_download_url'] as String?) ?? '';
        if (name.isNotEmpty && url.isNotEmpty) {
          entries.add(MapEntry(name, url));
        }
      }
    }
    if (entries.isEmpty) return null;

    bool matches(String name, List<String> needles) =>
        needles.any((n) => name.contains(n));

    List<String> needles;
    if (Platform.isAndroid) {
      needles = const ['.apk'];
    } else if (Platform.isWindows) {
      needles = const ['windows', '.zip', '.exe', '.msix'];
    } else if (Platform.isLinux) {
      needles = const ['linux', '.tar.gz', '.appimage', '.deb'];
    } else if (Platform.isMacOS) {
      needles = const ['macos', 'mac', '.dmg'];
    } else {
      return null;
    }

    for (final needle in needles) {
      for (final e in entries) {
        if (matches(e.key, [needle])) return e.value;
      }
    }
    return null;
  }
}
