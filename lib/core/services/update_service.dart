import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../utils/app_logger.dart';
import '../utils/update_manifest.dart';
import '../utils/update_trust.dart';

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

  /// Hex SHA-256 the publisher signed for [assetName], or null when this
  /// release has no manifest, or its manifest failed verification.
  ///
  /// Null is the signal that stops the in-app installer: the bytes were
  /// published by someone we cannot authenticate, so they must never be run.
  /// The release page stays available because opening it cannot execute code.
  final String? trustedSha256;

  /// Exact byte length from the same signed manifest as [trustedSha256].
  ///
  /// Preferred over [assetSize], which comes from the unsigned release object
  /// and so cannot be trusted as an integrity expectation.
  final int? manifestSize;

  const UpdateInfo({
    required this.version,
    required this.releaseUrl,
    required this.notes,
    this.assetUrl,
    this.assetName,
    this.assetSize,
    this.trustedSha256,
    this.manifestSize,
  });

  /// Whether the payload for this release can be authenticated and therefore
  /// installed from inside the app.
  bool get hasVerifiedPayload => trustedSha256 != null;

  /// Preferred URL to open: the platform asset if present, else the release page.
  String get downloadUrl => assetUrl ?? releaseUrl;

  /// Whether the selected asset is the Windows Inno Setup installer
  /// (`Syndro-Setup-<ver>.exe`), which *can* be run silently in-place.
  ///
  /// Naming only — this says nothing about whether the asset is authentic.
  /// Pair with [hasVerifiedPayload] before offering to run it.
  bool get isWindowsInstaller {
    final name = assetName?.toLowerCase() ?? '';
    return name.startsWith('syndro-setup') && name.endsWith('.exe');
  }
}

/// Outcome of an update check. See [UpdateService.checkForUpdate].
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// A newer release is available for the running platform.
class UpdateAvailable extends UpdateCheckResult {
  final UpdateInfo info;

  const UpdateAvailable(this.info);
}

/// No newer release to offer.
///
/// [localNewerThanLatest] is true when the running app reports a version
/// *higher* than the latest published release. This happens when an install
/// predates a repo reset or a release was deleted from GitHub; without this
/// flag the UI can only say "up to date", which reads as a broken checker.
class UpToDate extends UpdateCheckResult {
  /// Version the running app reports (normalized, no `v`/`+N`).
  final String currentVersion;

  /// Latest published release version (normalized). Empty when the latest
  /// release object had no usable tag.
  final String latestVersion;

  final bool localNewerThanLatest;

  const UpToDate({
    required this.currentVersion,
    this.latestVersion = '',
    this.localNewerThanLatest = false,
  });
}

/// The check could not complete (network, HTTP status, malformed response).
///
/// Previously these failures were indistinguishable from "up to date", which
/// made the in-app updater look broken whenever GitHub rate-limited the check.
class UpdateCheckFailed extends UpdateCheckResult {
  /// Human-readable, user-facing reason.
  final String reason;

  final int? httpStatus;

  const UpdateCheckFailed(this.reason, {this.httpStatus});

  /// The response was reachable but not shaped like a GitHub release.
  const UpdateCheckFailed._parse() : reason = 'Unexpected response from GitHub.', httpStatus = null;
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

  static const Map<String, String> _githubHeaders = <String, String>{
    'Accept': 'application/vnd.github+json',
    'User-Agent': 'Syndro-App',
  };

  /// Query GitHub for the latest release.
  ///
  /// Returns an [UpdateCheckResult] describing exactly one of three outcomes:
  ///  - [UpdateAvailable]: the latest release is strictly newer than the
  ///    running app (includes this platform's asset, when present).
  ///  - [UpToDate]: nothing newer to offer — including the case where the
  ///    running app is *newer* than the published release
  ///    ([UpToDate.localNewerThanLatest]).
  ///  - [UpdateCheckFailed]: the check could not complete (network error,
  ///    non-200 status, malformed response).
  ///
  /// Never throws — every failure path is logged and returned as
  /// [UpdateCheckFailed] so callers can distinguish "checked, nothing newer"
  /// from "could not check".
  static Future<UpdateCheckResult> checkForUpdate({
    http.Client? client,
    String? currentVersionOverride,
    String? platformOverride,
    @visibleForTesting Map<String, List<int>>? trustedPublicKeys,
  }) async {
    // A single client serves both the release object and the signed manifest,
    // so a caller that injects one (tests) observes both requests — and the
    // instance we create for ourselves is actually closed.
    final httpClient = client ?? http.Client();
    final ownsClient = client == null;

    try {
      final response = await httpClient
          .get(Uri.parse(_latestReleaseUrl), headers: _githubHeaders)
          .timeout(_timeout);

      if (response.statusCode != 200) {
        AppLogger.warn('Update check: HTTP ${response.statusCode}');
        return UpdateCheckFailed(
          response.statusCode == 403
              ? 'GitHub rejected the request (HTTP 403 — rate limit or '
                  'blocked). Try again in a few minutes.'
              : 'GitHub returned HTTP ${response.statusCode}.',
          httpStatus: response.statusCode,
        );
      }

      final data = jsonDecode(response.body);
      if (data is! Map<String, dynamic>) {
        return const UpdateCheckFailed._parse();
      }

      final currentVersion =
          await _currentVersion(currentVersionOverride);

      // Skip drafts / prereleases.
      if (data['draft'] == true || data['prerelease'] == true) {
        return UpToDate(currentVersion: currentVersion);
      }

      final tagName = (data['tag_name'] as String?)?.trim() ?? '';
      final releaseUrl = (data['html_url'] as String?)?.trim() ?? '';
      final notes = (data['body'] as String?)?.trim() ?? '';
      if (tagName.isEmpty || releaseUrl.isEmpty) {
        return UpToDate(currentVersion: currentVersion);
      }

      final latestVersion = _normalize(tagName);

      if (!_isNewer(latestVersion, currentVersion)) {
        return UpToDate(
          currentVersion: currentVersion,
          latestVersion: latestVersion,
          localNewerThanLatest: _isNewer(currentVersion, latestVersion),
        );
      }

      final assets = (data['assets'] as List?) ?? const [];
      final platform = _effectivePlatform(platformOverride);
      final asset = _selectAsset(assets, platform);
      // Only Windows ever runs a payload in-app, so other platforms need no
      // manifest — skip the extra request rather than fetch it unused.
      final trusted = platform == 'windows'
          ? await _resolveTrustedAsset(
              httpClient,
              assets,
              selected: asset,
              version: latestVersion,
              trustedPublicKeys: trustedPublicKeys,
            )
          : null;

      return UpdateAvailable(
        UpdateInfo(
          version: latestVersion,
          releaseUrl: releaseUrl,
          notes: notes,
          assetUrl: asset?.url,
          assetName: asset?.name,
          assetSize: asset?.size,
          trustedSha256: trusted?.sha256Hex,
          manifestSize: trusted?.size,
        ),
      );
    } on TimeoutException {
      AppLogger.warn('Update check timed out');
      return const UpdateCheckFailed('The update check timed out.');
    } catch (e) {
      AppLogger.warn('Update check failed: $e');
      return UpdateCheckFailed('Unexpected error: $e');
    } finally {
      if (ownsClient) httpClient.close();
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
  /// Throws [UpdateIntegrityException] when the release has no verifiable
  /// signature or the downloaded bytes do not match the signed digest, and
  /// [UpdateDownloadException] on network failure or a short read. Anything
  /// that fails verification is deleted rather than left on disk.
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

    // The gate that matters: an unauthenticated payload must never reach
    // Process.start, whatever else about it looks right.
    final trustedSha256 = info.trustedSha256;
    if (trustedSha256 == null) {
      throw const UpdateIntegrityException(
        'This release carries no signature Syndro can verify, so it will not '
        'be installed from inside the app. Use "Open in browser" to download '
        'it from the release page yourself.',
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
    // Prefer the length the publisher signed over the one the release object
    // claims; the latter is unsigned and so is only a progress hint.
    final expectedTotal = info.manifestSize ?? info.assetSize;
    final client = http.Client();

    try {
      final request = http.Request('GET', Uri.parse(assetUrl));
      request.headers['User-Agent'] = 'Syndro-App';
      final streamed =
          await client.send(request).timeout(_downloadTimeout);

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

      // A matching length is not integrity: an attacker who controls the feed
      // controls the advertised size too. The digest comes from the signed
      // manifest, so only the publisher can authorise what gets executed.
      // Plain equality is deliberate here — this compares a public, published
      // value against a locally computed one, so there is no secret to leak
      // through timing.
      final actualSha256 = await _sha256OfFile(file);
      if (actualSha256 != trustedSha256.toLowerCase()) {
        AppLogger.error(
          'Update integrity failure: installer digest does not match the '
          'signed manifest.',
        );
        await _deleteQuietly(file);
        throw const UpdateIntegrityException(
          'The downloaded installer does not match its published signature '
          'and was deleted. Do not retry: the release feed may have been '
          'tampered with.',
        );
      }

      return file.path;
    } on UpdateDownloadException {
      rethrow;
    } catch (e) {
      AppLogger.warn('Update download failed: $e');
      await _deleteQuietly(file);
      throw UpdateDownloadException('Download failed: $e');
    } finally {
      client.close();
    }
  }

  /// Run the downloaded Inno Setup installer silently. The caller is expected
  /// to exit the app right after; the installer (re)launches Syndro itself
  /// ([Run] entry in SyndroInstaller.iss).
  ///
  /// [expectedSha256] is the digest from the signed manifest. It is re-checked
  /// against the file on disk immediately before launch, which narrows the
  /// window in which something else could replace the bytes between
  /// [downloadUpdate] and here. Throws [UpdateIntegrityException] rather than
  /// executing anything it cannot authenticate.
  static Future<bool> installUpdate(
    String installerPath, {
    String? expectedSha256,
    Directory? targetDir,
  }) async {
    // Every check below runs before the platform guard on purpose: the policy
    // "do not execute what we cannot authenticate" is not Windows-specific, and
    // keeping it reachable means CI actually exercises it.
    if (expectedSha256 == null) {
      throw const UpdateIntegrityException(
        'Refusing to run an installer that was never authenticated against a '
        'signed manifest.',
      );
    }

    final installer = File(installerPath).absolute;
    final updatesDir = (targetDir ?? _defaultDownloadDir()).absolute;

    // Only ever execute a setup binary we ourselves wrote into the updates
    // directory — never an arbitrary path handed to us.
    final name = p.basename(installer.path);
    if (!name.startsWith('Syndro-Setup-') || !name.endsWith('.exe')) {
      throw UpdateIntegrityException(
          'Refusing to run "$name": not a Syndro installer filename.');
    }
    if (!p.equals(p.dirname(installer.path), updatesDir.path)) {
      throw const UpdateIntegrityException(
        'Refusing to run an installer located outside the Syndro updates '
        'directory.',
      );
    }

    if (!await installer.exists()) {
      throw UpdateIntegrityException('Refusing to run a missing file: $name');
    }

    final actual = await _sha256OfFile(installer);
    if (actual != expectedSha256.toLowerCase()) {
      AppLogger.error(
          'Update integrity failure: installer changed before installation.');
      throw const UpdateIntegrityException(
        'The downloaded installer no longer matches its published signature, '
        'so it was not run.',
      );
    }

    if (!Platform.isWindows) {
      AppLogger.warn('installUpdate called on non-Windows platform');
      return false;
    }

    try {
      await Process.start(installer.path, const [
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

  /// URL of the signed manifest attached to a release, or null.
  ///
  /// Matched on the exact asset name: substring matching is what let a
  /// lookalike asset be selected as the installer.
  static String? _manifestAssetUrl(List<dynamic> assets) {
    for (final a in assets) {
      if (a is! Map) continue;
      if (((a['name'] as String?)?.trim()) != UpdateTrust.manifestAssetName) {
        continue;
      }
      final url = (a['browser_download_url'] as String?)?.trim() ?? '';
      if (url.isEmpty) continue;
      final uri = Uri.tryParse(url);
      if (uri == null ||
          uri.scheme != 'https' ||
          !UpdateTrust.isTrustedAssetHost(uri.host)) {
        AppLogger.warn('Update manifest offered from an unexpected host: $url');
        continue;
      }
      return url;
    }
    return null;
  }

  /// Fetch and authenticate the release manifest, returning the signed entry
  /// for [selected] — or null when the payload cannot be authenticated.
  ///
  /// Every failure mode (no manifest, HTTP error, bad signature, version
  /// mismatch, no entry for this asset) collapses to null, which the UI reads
  /// as "no in-app install". Never downgrade a failure to a guess: an
  /// unreachable manifest must block execution, not permit it.
  static Future<UpdateManifestAsset?> _resolveTrustedAsset(
    http.Client client,
    List<dynamic> assets, {
    required ({String name, String url, int? size})? selected,
    required String version,
    Map<String, List<int>>? trustedPublicKeys,
  }) async {
    if (selected == null) return null;

    final manifestUrl = _manifestAssetUrl(assets);
    if (manifestUrl == null) {
      AppLogger.info('Update: release has no signed '
          '${UpdateTrust.manifestAssetName}; in-app install disabled.');
      return null;
    }

    try {
      final response = await client
          .get(Uri.parse(manifestUrl), headers: _githubHeaders)
          .timeout(_timeout);
      if (response.statusCode != 200) {
        AppLogger.warn('Update manifest: HTTP ${response.statusCode}');
        return null;
      }

      final manifest = trustedPublicKeys == null
          ? await UpdateManifest.verify(
              response.body,
              expectedVersion: version,
            )
          : await UpdateManifest.verifyWithTrustedPublicKeys(
              response.body,
              expectedVersion: version,
              trustedPublicKeys: trustedPublicKeys,
            );
      final entry = manifest.assetFor(selected.name);
      if (entry == null) {
        AppLogger.warn(
            'Update: manifest does not cover the selected asset ${selected.name}');
        return null;
      }
      AppLogger.info('Update: payload authenticated by key ${manifest.keyId}');
      return entry;
    } on FormatException catch (e) {
      AppLogger.warn('Update manifest rejected: ${e.message}');
      return null;
    } on TimeoutException {
      AppLogger.warn('Update manifest fetch timed out');
      return null;
    } catch (e) {
      AppLogger.warn('Update manifest could not be checked: $e');
      return null;
    }
  }

  /// Streaming SHA-256 of [file], same idiom the transfer path uses.
  static Future<String> _sha256OfFile(File file) async {
    final digest = await crypto.sha256.bind(file.openRead()).last;
    return digest.toString();
  }

  static Future<String> _currentVersion([String? override]) async {
    if (override != null) return _normalize(override);
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

  /// Platform whose assets to look for. Tests pin this through
  /// [platformOverride] because the CI runners are not Windows.
  static String _effectivePlatform([String? platformOverride]) =>
      platformOverride ??
      (Platform.isWindows
          ? 'windows'
          : Platform.isAndroid
              ? 'android'
              : Platform.isLinux
                  ? 'linux'
                  : Platform.isMacOS
                      ? 'macos'
                      : '');

  /// Selected release asset (name, download URL, size) for [platform], or null
  /// to fall back to the release page.
  static ({String name, String url, int? size})? _selectAsset(
    List<dynamic> assets,
    String platform,
  ) {
    if (platform.isEmpty) return null;
    return selectAssetForPlatform(assets, platform);
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

/// The payload could not be authenticated, so it was never executed: no signed
/// manifest, a digest that does not match, or a file that is not the installer
/// we wrote.
///
/// A subclass of [UpdateDownloadException] because callers already handle that
/// arm and the correct response is identical — stop, show the reason, and keep
/// the download from running.
class UpdateIntegrityException extends UpdateDownloadException {
  const UpdateIntegrityException(super.message);
}