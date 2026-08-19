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

  /// File name of the selected asset (e.g. `Syndro-Setup-1.2.0.exe`).
  final String? assetName;

  /// Byte size of the selected asset as reported by GitHub (may be null).
  final int? assetSize;

  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    this.assetUrl,
    this.assetName,
    this.assetSize,
  });

  /// Preferred URL to open: the platform asset if present, else the release page.
  String get downloadUrl => assetUrl ?? releaseUrl;

  /// Whether the selected asset is the Windows Inno Setup installer
  /// (`Syndro-Setup-<ver>.exe`), which can be run silently in-place.
  bool get isWindowsInstaller {
    final name = assetName?.toLowerCase() ?? '';
    return name.startsWith('syndro-setup') && name.endsWith('.exe');
  }
}

/// Checks GitHub Releases for a newer version of the app and, on Windows,
/// downloads the setup installer and runs it silently (the installer relaunches
/// the updated app). On other platforms it only opens the download page in the
/// system browser.
class UpdateService {
  UpdateService._();

  static const String _owner = 'FakeAbid11';
  static const String _repo = 'Syndro';
  static const String _latestReleaseUrl =
      'https://api.github.com/repos/$_owner/$_repo/releases/latest';

  /// Prefix for the "skip this version" flag stored in shared_preferences.
  static const String _skipPrefix = 'syndro.update.skip.';

  /// Timestamp key for the startup-check cooldown.
  static const String _lastCheckKey = 'syndro.update.lastCheckAt';

  /// How long between automatic (startup) checks before checking again.
  static const Duration _checkCooldown = Duration(hours: 24);

  static const Duration _timeout = Duration(seconds: 8);
  static const Duration _downloadTimeout = Duration(minutes: 10);

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
      final asset = _selectAsset(assets);

      return UpdateInfo(
        version: latestVersion,
        releaseUrl: releaseUrl,
        notes: notes,
        assetUrl: asset?.url,
        assetName: asset?.name,
        assetSize: asset?.size,
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

  /// Download the update asset for [info] (the Windows installer) to
  /// `%LOCALAPPDATA%\Syndro\updates` (or [targetDir] in tests) and return the
  /// path of the downloaded file. [onProgress] is invoked with
  /// (receivedBytes, totalBytes) as chunks arrive.
  ///
  /// Throws [UpdateDownloadException] on network failure or when the received
  /// byte count does not match the expected asset size (a partial or corrupted
  /// download is deleted again).
  static Future<String> downloadUpdate(
    UpdateInfo info, {
    void Function(int received, int? total)? onProgress,
    Directory? targetDir,
  }) async {
    final assetUrl = info.assetUrl;
    if (assetUrl == null || !info.isWindowsInstaller) {
      throw const UpdateDownloadException(
        'No Windows installer asset available for this release.',
      );
    }

    final dir = targetDir ?? _defaultDownloadDir();
    try {
      await dir.create(recursive: true);
    } catch (e) {
      AppLogger.warn('Could not create update dir: $e');
      throw UpdateDownloadException('Could not create update directory: $e');
    }

    final file = File('${dir.path}${Platform.pathSeparator}'
        'Syndro-Setup-${info.version}.exe');
    final expectedTotal = info.assetSize;

    try {
      final request = http.Request('GET', Uri.parse(assetUrl));
      request.headers['User-Agent'] = 'Syndro-App';
      final streamed = await http.Client().send(request).timeout(_downloadTimeout);

      if (streamed.statusCode != 200) {
        throw UpdateDownloadException(
          'Download failed: HTTP ${streamed.statusCode}',
        );
      }

      final contentLength = streamed.contentLength;
      final total = expectedTotal ?? contentLength;

      final sink = file.openWrite();
      var received = 0;
      try {
        await for (final chunk in streamed.stream.timeout(_downloadTimeout)) {
          sink.add(chunk);
          received += chunk.length;
          onProgress?.call(received, total);
        }
        await sink.flush();
      } finally {
        await sink.close();
      }

      if (total != null && received != total) {
        AppLogger.warn(
          'Update download size mismatch: got $received, expected $total',
        );
        await _deleteQuietly(file);
        throw UpdateDownloadException(
          'Downloaded file is incomplete ($received of $total bytes) and was '
          'discarded. Check your connection and try again.',
        );
      }

      return file.path;
    } on UpdateDownloadException {
      rethrow;
    } catch (e) {
      AppLogger.warn('Update download failed: $e');
      await _deleteQuietly(file);
      throw UpdateDownloadException('Download failed: $e');
    }
  }

  /// Run the downloaded Inno Setup installer silently. The caller is expected
  /// to exit the app right after; the installer (re)launches Syndro itself
  /// ([Run] entry in SyndroInstaller.iss).
  static Future<bool> installUpdate(String installerPath) async {
    if (!Platform.isWindows) {
      AppLogger.warn('installUpdate called on non-Windows platform');
      return false;
    }
    try {
      await Process.start(installerPath, const [
        '/VERYSILENT',
        '/SUPPRESSMSGBOXES',
        '/NORESTART',
        '/SP-',
      ]);
      return true;
    } catch (e) {
      AppLogger.warn('Could not start installer: $e');
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

  /// Gate for the automatic startup check: returns true at most once per
  /// [_checkCooldown]. Manual checks (Settings) call [checkForUpdate] directly
  /// and are never throttled. [now] exists for tests.
  static Future<bool> shouldAutoCheck({DateTime? now}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final last = prefs.getInt(_lastCheckKey);
      final current = now ?? DateTime.now();
      if (last != null) {
        final elapsed = current.difference(
          DateTime.fromMillisecondsSinceEpoch(last),
        );
        if (elapsed < _checkCooldown) return false;
      }
      await prefs.setInt(_lastCheckKey, current.millisecondsSinceEpoch);
      return true;
    } catch (_) {
      // Never block the startup path on preference failures.
      return true;
    }
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  static Directory _defaultDownloadDir() {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData != null && localAppData.isNotEmpty) {
      return Directory('$localAppData${Platform.pathSeparator}Syndro'
          '${Platform.pathSeparator}updates');
    }
    return Directory.systemTemp;
  }

  static Future<void> _deleteQuietly(File file) async {
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best effort.
    }
  }

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

  /// Selected release asset (name, download URL, size) for the current
  /// platform, or null to fall back to the release page.
  static ({String name, String url, int? size})? _selectAsset(
    List<dynamic> assets,
  ) {
    if (Platform.isWindows) return selectAssetForPlatform(assets, 'windows');
    if (Platform.isAndroid) return selectAssetForPlatform(assets, 'android');
    if (Platform.isLinux) return selectAssetForPlatform(assets, 'linux');
    if (Platform.isMacOS) return selectAssetForPlatform(assets, 'macos');
    return null;
  }

  /// Visible for testing: pick the best download asset for [platform]
  /// (`windows` | `android` | `linux` | `macos`) from a GitHub release asset
  /// list. On Windows the Inno Setup installer is preferred (used by the in-app
  /// updater); otherwise the first asset matching the platform's needles wins.
  static ({String name, String url, int? size})? selectAssetForPlatform(
    List<dynamic> assets,
    String platform,
  ) {
    final entries = <Map<String, String>>[];
    for (final a in assets) {
      if (a is Map) {
        final name = (a['name'] as String?)?.trim() ?? '';
        final url = (a['browser_download_url'] as String?)?.trim() ?? '';
        if (name.isNotEmpty && url.isNotEmpty) {
          entries.add({'name': name, 'url': url});
        }
      }
    }
    if (entries.isEmpty) return null;

    bool matches(String name, List<String> needles) =>
        needles.any((n) => name.toLowerCase().contains(n));

    // Windows: prefer the Inno Setup installer for the in-app updater, then
    // any platform zip/exe (portable) as the browser-fallback target.
    if (platform == 'windows') {
      for (final e in entries) {
        if (e['name']!.toLowerCase().startsWith('syndro-setup') &&
            e['name']!.toLowerCase().endsWith('.exe')) {
          return (
            name: e['name']!,
            url: e['url']!,
            size: _assetSize(assets, e['name']!),
          );
        }
      }
    }

    List<String> needles;
    switch (platform) {
      case 'android':
        needles = const ['.apk'];
      case 'windows':
        needles = const ['windows', '.zip', '.exe', '.msix'];
      case 'linux':
        needles = const ['linux', '.tar.gz', '.appimage', '.deb'];
      case 'macos':
        needles = const ['macos', 'mac', '.dmg'];
      default:
        return null;
    }

    for (final needle in needles) {
      for (final e in entries) {
        if (matches(e['name']!, [needle])) {
          return (
            name: e['name']!,
            url: e['url']!,
            size: _assetSize(assets, e['name']!),
          );
        }
      }
    }
    return null;
  }

  static int? _assetSize(List<dynamic> assets, String name) {
    for (final a in assets) {
      if (a is Map && (a['name'] as String?) == name) {
        final size = a['size'];
        if (size is int && size > 0) return size;
        return null;
      }
    }
    return null;
  }
}

/// Failure of an update download (network error, HTTP status, size mismatch).
class UpdateDownloadException implements Exception {
  final String message;
  const UpdateDownloadException(this.message);

  @override
  String toString() => message;
}