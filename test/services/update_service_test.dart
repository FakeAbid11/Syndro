import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:syndro/core/services/update_service.dart';
import 'package:syndro/core/utils/update_manifest.dart';
import 'package:syndro/core/utils/update_trust.dart';

/// Update-check behaviour against a mocked GitHub `releases/latest` response.
///
/// The installed version is injected via `currentVersionOverride` so no
/// platform channel (PackageInfo) is touched.
void main() {
  const releaseUrl =
      'https://github.com/FakeAbid11/Syndro/releases/tag/v1.2.0';
  const installerDigest = '1111111111111111111111111111111111111111111111111111111111111111';
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

  Map<String, dynamic> manifestAssetFrom(String url) => {
        'name': UpdateTrust.manifestAssetName,
        'browser_download_url': url,
        'size': 512,
      };

  final requested = <String>[];

  Map<String, dynamic> releaseJson({
    String tag = 'v1.2.0',
    bool draft = false,
    bool prerelease = false,
    List<Map<String, dynamic>> assets = const [setupAsset, apkAsset],
  }) =>
      {
        'tag_name': tag,
        'html_url': releaseUrl,
        'body': 'Release notes',
        'draft': draft,
        'prerelease': prerelease,
        'assets': assets,
      };

  /// Routes by path: the release object for the API call, [manifestBody] for
  /// the signed manifest. A null [manifestBody] answers the manifest with 404,
  /// which is what a release with no manifest attached looks like.
  http.Client mockGitHub(
    int status,
    String body, {
    String? manifestBody,
    int manifestStatus = 200,
  }) =>
      MockClient((request) async {
        requested.add(request.url.toString());
        if (request.url.path.endsWith(UpdateTrust.manifestAssetName)) {
          return manifestBody == null
              ? http.Response('{"message":"Not Found"}', 404)
              : http.Response(manifestBody, manifestStatus);
        }
        return http.Response(body, status);
      });

  /// A manifest signed by a throwaway key, for use with `trustedPublicKeys`.
  Future<({String envelope, List<int> publicKeyBytes})> signedManifest(
    List<UpdateManifestAsset> assets, {
    String version = '1.2.0',
    String keyId = 'test-key',
  }) async {
    final keyPair = await Ed25519().newKeyPair();
    final payload =
        UpdateManifest.canonicalPayload(version: version, assets: assets);
    final signature =
        await Ed25519().sign(utf8.encode(payload), keyPair: keyPair);
    return (
      envelope: jsonEncode(<String, Object?>{
        'schema': UpdateTrust.manifestSchema,
        'keyId': keyId,
        'payload': payload,
        'sig': base64Url.encode(signature.bytes),
      }),
      publicKeyBytes: (await keyPair.extractPublicKey()).bytes,
    );
  }

  setUp(() => requested.clear());

  test('newer release yields UpdateAvailable with the Windows installer asset',
      () async {
    final result = await UpdateService.checkForUpdate(
      client: mockGitHub(200, jsonEncode(releaseJson())),
      currentVersionOverride: '1.0.2+17',
      // Pin the platform: CI runs on Linux, where the real platform
      // dispatch would pick linux assets and find none.
      platformOverride: 'windows',
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
    // A release with no manifest is still offered — but only for the browser
    // path, never the in-app installer.
    expect(info.hasVerifiedPayload, isFalse);
    expect(info.trustedSha256, isNull);
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
      platformOverride: 'windows',
    );

    expect(result, isA<UpdateAvailable>());
    final info = (result as UpdateAvailable).info;
    expect(info.version, '1.2.0');
    expect(info.assetUrl, isNull);
    expect(info.downloadUrl, releaseUrl);
  });

  group('signed manifest resolution', () {
    Map<String, dynamic> releaseWithManifest(String url) =>
        releaseJson(assets: [setupAsset, apkAsset, manifestAssetFrom(url)]);

    const goodUrl =
        'https://github.com/FakeAbid11/Syndro/releases/download/v1.2.0/update-manifest.json';

    UpdateInfo availableFrom(UpdateCheckResult result) {
      expect(result, isA<UpdateAvailable>());
      return (result as UpdateAvailable).info;
    }

    test('a verified manifest populates the trusted digest', () async {
      final signed = await signedManifest([
        const UpdateManifestAsset(
          name: 'Syndro-Setup-1.2.0.exe',
          sha256Hex: installerDigest,
          size: 13738329,
        ),
      ]);

      final info = availableFrom(await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseWithManifest(goodUrl)),
          manifestBody: signed.envelope,
        ),
        currentVersionOverride: '1.0.2+17',
        platformOverride: 'windows',
        trustedPublicKeys: {'test-key': signed.publicKeyBytes},
      ));

      expect(info.trustedSha256, installerDigest);
      expect(info.manifestSize, 13738329);
      expect(info.hasVerifiedPayload, isTrue);
    });

    test('an asset list is fetched only from an allowed https host', () async {
      for (final url in [
        'http://github.com/FakeAbid11/Syndro/releases/download/v1.2.0/'
            'update-manifest.json',
        'https://evil.example/update-manifest.json',
        'https://github.com.evil.example/update-manifest.json',
      ]) {
        final info = availableFrom(await UpdateService.checkForUpdate(
          client: mockGitHub(
            200,
            jsonEncode(releaseWithManifest(url)),
            manifestBody: '{"schema":1}',
          ),
          currentVersionOverride: '1.0.2',
          platformOverride: 'windows',
        ));

        expect(info.trustedSha256, isNull, reason: 'url: $url');
        expect(requested.any((u) => u.contains('update-manifest.json')),
            isFalse,
            reason: 'must not even request $url');
      }
    });

    test('an allowed manifest is requested and then rejected when it cannot '
        'be authenticated', () async {
      final signed = await signedManifest([
        const UpdateManifestAsset(
            name: 'Syndro-Setup-1.2.0.exe', sha256Hex: installerDigest, size: 1),
      ]);

      for (final body in [
        'not json',
        '{"schema":1,"keyId":"nope","payload":"{}","sig":"____"}',
      ]) {
        requested.clear();
        final info = availableFrom(await UpdateService.checkForUpdate(
          client: mockGitHub(
            200,
            jsonEncode(releaseWithManifest(goodUrl)),
            manifestBody: body,
          ),
          currentVersionOverride: '1.0.2',
          platformOverride: 'windows',
        ));
        expect(info.trustedSha256, isNull, reason: 'body: $body');
        expect(requested.any((u) => u.contains('update-manifest.json')), isTrue);
      }

      // Signed, but not by a key the shipped build trusts.
      requested.clear();
      final untrusted = availableFrom(await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseWithManifest(goodUrl)),
          manifestBody: signed.envelope,
        ),
        currentVersionOverride: '1.0.2',
        platformOverride: 'windows',
      ));
      expect(untrusted.trustedSha256, isNull,
          reason: 'a test key must not authenticate anything for real clients');
      expect(requested.any((u) => u.contains('update-manifest.json')), isTrue);
    });

    test('a 404 manifest degrades to the browser path', () async {
      final info = availableFrom(await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseWithManifest(goodUrl)),
        ),
        currentVersionOverride: '1.0.2',
        platformOverride: 'windows',
      ));
      expect(info.assetUrl, isNotNull);
      expect(info.hasVerifiedPayload, isFalse);
    });

    test('a manifest that does not cover the selected asset is refused',
        () async {
      final signed = await signedManifest([
        const UpdateManifestAsset(
          name: 'Syndro-Other-1.2.0.exe',
          sha256Hex: installerDigest,
          size: 13738329,
        ),
      ]);

      final info = availableFrom(await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseWithManifest(goodUrl)),
          manifestBody: signed.envelope,
        ),
        currentVersionOverride: '1.0.2',
        platformOverride: 'windows',
        trustedPublicKeys: {'test-key': signed.publicKeyBytes},
      ));
      expect(info.trustedSha256, isNull);
    });

    test('a manifest signed for another version cannot authorise this one',
        () async {
      final signed = await signedManifest(
        [
          const UpdateManifestAsset(
            name: 'Syndro-Setup-1.2.0.exe',
            sha256Hex: installerDigest,
            size: 13738329,
          ),
        ],
        version: '1.1.0',
      );

      final info = availableFrom(await UpdateService.checkForUpdate(
        client: mockGitHub(
          200,
          jsonEncode(releaseWithManifest(goodUrl)),
          manifestBody: signed.envelope,
        ),
        currentVersionOverride: '1.0.2',
        platformOverride: 'windows',
        trustedPublicKeys: {'test-key': signed.publicKeyBytes},
      ));
      expect(info.trustedSha256, isNull);
    });
  });
}