import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syndro/core/services/update_service.dart';

/// Update-check behaviour against a mocked GitHub `releases/latest` response.
///
/// The installed version is injected via `currentVersionOverride` so no
/// platform channel (PackageInfo) is touched.
void main() {
  const releaseUrl =
      'https://github.com/FakeAbid11/Syndro/releases/tag/v1.2.0';
  const setupAsset = {
    'name': 'Syndro-Setup-1.2.0.exe',
    'browser_download_url':
        'https://github.com/FakeAbid11/Syndro/releases/download/v1.2.0/Syndro-Setup-1.2.0.exe',
    'size': 13738329,
  };
  const apkAsset = {
    'name': 'Syndro-1.2.0.apk',
    'browser_download_url':
        'https://github.com/FakeAbid11/Syndro/releases/download/v1.2.0/Syndro-1.2.0.apk',
    'size': 82167012,
  };

  Map<String, dynamic> releaseJson({
    String tag = 'v1.2.0',
    bool draft = false,
    bool prerelease = false,
    List<Map<String, Object>> assets = const [setupAsset, apkAsset],
  }) =>
      {
        'tag_name': tag,
        'html_url': releaseUrl,
        'body': 'Release notes',
        'draft': draft,
        'prerelease': prerelease,
        'assets': assets,
      };

  http.Client mockGitHub(
    int status,
    String body,
  ) =>
      MockClient((request) async => http.Response(body, status));

  test('newer release yields UpdateAvailable with the Windows installer asset',
      () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, jsonEncode(releaseJson())),
      currentVersionOverride: '1.0.2+17',
    );

    expect(result, isA<UpdateAvailable>());
    final info = (result as UpdateAvailable).info;
    expect(info.version, '1.2.0');
    expect(info.releaseUrl, releaseUrl);
    expect(info.notes, 'Release notes');
    expect(info.assetName, 'Syndro-Setup-1.2.0.exe');
    expect(info.assetSize, 13738329);
    expect(info.isWindowsInstaller, isTrue);
    expect(info.downloadUrl, setupAsset['browser_download_url']);
  });

  test('equal version yields UpToDate (not newer)', () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, jsonEncode(releaseJson())),
      currentVersionOverride: '1.2.0',
    );

    expect(result, isA<UpToDate>());
    final upToDate = result as UpToDate;
    expect(upToDate.currentVersion, '1.2.0');
    expect(upToDate.latestVersion, '1.2.0');
    expect(upToDate.localNewerThanLatest, isFalse);
  });

  test('installed version newer than latest flags localNewerThanLatest',
      () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, jsonEncode(releaseJson(tag: 'v1.0.2'))),
      currentVersionOverride: '1.1.0',
    );

    expect(result, isA<UpToDate>());
    final upToDate = result as UpToDate;
    expect(upToDate.currentVersion, '1.1.0');
    expect(upToDate.latestVersion, '1.0.2');
    expect(upToDate.localNewerThanLatest, isTrue);
  });

  test('HTTP 403 yields UpdateCheckFailed with the status', () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(403, '{"message": "API rate limit exceeded"}'),
      currentVersionOverride: '1.0.2',
    );

    expect(result, isA<UpdateCheckFailed>());
    final failure = result as UpdateCheckFailed;
    expect(failure.httpStatus, 403);
    expect(failure.reason, contains('403'));
  });

  test('HTTP 500 yields UpdateCheckFailed with the status', () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(500, 'server error'),
      currentVersionOverride: '1.0.2',
    );

    expect(result, isA<UpdateCheckFailed>());
    expect((result as UpdateCheckFailed).httpStatus, 500);
  });

  test('malformed body yields UpdateCheckFailed', () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, 'not json at all'),
      currentVersionOverride: '1.0.2',
    );

    expect(result, isA<UpdateCheckFailed>());
    expect((result as UpdateCheckFailed).reason, isNotEmpty);
  });

  test('draft or prerelease yields UpToDate without a latest version',
      () async {
    for (final flag in {'draft': true, 'prerelease': true}.entries) {
      final result = await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseJson(draft: flag.key == 'draft', prerelease: flag.key == 'prerelease')),
        ),
        currentVersionOverride: '1.0.2',
      );

      expect(result, isA<UpToDate>(), reason: 'flag: ${flag.key}');
      final upToDate = result as UpToDate;
      expect(upToDate.currentVersion, '1.0.2');
      expect(upToDate.latestVersion, isEmpty);
      expect(upToDate.localNewerThanLatest, isFalse);
    }
  });

  test('release without a Windows asset falls back to the release page',
      () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, jsonEncode(releaseJson(assets: [apkAsset]))),
      currentVersionOverride: '1.0.2',
    );

    expect(result, isA<UpdateAvailable>());
    final info = (result as UpdateAvailable).info;
    expect(info.version, '1.2.0');
    expect(info.assetUrl, isNull);
    expect(info.downloadUrl, releaseUrl);
  });
}