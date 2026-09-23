import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syndro/core/services/update_service.dart';

/// Restores real socket behavior (flutter_test's default HttpClient answers
/// every request with a spurious 400).
class _RealHttpOverrides extends HttpOverrides {}

void main() {
  setUp(() {
    HttpOverrides.global = _RealHttpOverrides();
  });

  group('UpdateService.selectAssetForPlatform', () {
    List<Map<String, dynamic>> asset(String name, {String? url, int? size}) => [
          {
            'name': name,
            'browser_download_url': url ?? 'https://example.com/$name',
            if (size != null) 'size': size,
          },
        ];

    test('Windows prefers the Inno Setup installer over the portable ZIP', () {
      final assets = [
        ...asset('Syndro-Setup-2.0.0.exe', size: 42),
        ...asset('Syndro-Windows-2.0.0.zip', size: 24),
        ...asset('Syndro-2.0.0.apk'),
      ];
      final picked = UpdateService.selectAssetForPlatform(assets, 'windows');
      expect(picked, isNotNull);
      expect(picked!.name, 'Syndro-Setup-2.0.0.exe');
      expect(picked.url, 'https://example.com/Syndro-Setup-2.0.0.exe');
      expect(picked.size, 42);
    });

    test('Windows falls back to the portable ZIP when no installer exists', () {
      final assets = [
        ...asset('Syndro-Windows-2.0.0.zip', size: 24),
        ...asset('Syndro-2.0.0.apk'),
      ];
      final picked = UpdateService.selectAssetForPlatform(assets, 'windows');
      expect(picked!.name, 'Syndro-Windows-2.0.0.zip');
    });

    test('Windows returns null when no matching asset exists', () {
      final picked = UpdateService.selectAssetForPlatform(
        [...asset('README.md'), ...asset('Syndro-2.0.0.apk')],
        'windows',
      );
      expect(picked, isNull);
    });

    test('Android picks the APK even when Windows assets are present', () {
      final assets = [
        ...asset('Syndro-Setup-2.0.0.exe'),
        ...asset('Syndro-Windows-2.0.0.zip'),
        ...asset('Syndro-2.0.0.apk', size: 99),
      ];
      final picked = UpdateService.selectAssetForPlatform(assets, 'android');
      expect(picked!.name, 'Syndro-2.0.0.apk');
      expect(picked.size, 99);
    });

    test('Linux and macOS pick their platform needles', () {
      final linux = UpdateService.selectAssetForPlatform(
        [...asset('Syndro-2.0.0.apk'), ...asset('Syndro-2.0.0.AppImage')],
        'linux',
      );
      expect(linux!.name, 'Syndro-2.0.0.AppImage');

      final macos = UpdateService.selectAssetForPlatform(
        [...asset('Syndro-2.0.0.apk'), ...asset('Syndro-2.0.0.dmg')],
        'macos',
      );
      expect(macos!.name, 'Syndro-2.0.0.dmg');
    });

    test('Unknown platform returns null', () {
      expect(UpdateService.selectAssetForPlatform([], 'symbian'), isNull);
    });

    test('Malformed asset entries are ignored', () {
      final picked = UpdateService.selectAssetForPlatform(
        [
          {'name': 'x', 'url': ''},
          'garbage',
          42,
        ],
        'windows',
      );
      expect(picked, isNull);
    });
  });

  group('UpdateInfo.isWindowsInstaller', () {
    test('matches Syndro-Setup-*.exe names', () {
      const info = UpdateInfo(
        version: '2.0.0',
        releaseUrl: 'https://example.com',
        notes: '',
        assetUrl: 'https://example.com/Syndro-Setup-2.0.0.exe',
        assetName: 'Syndro-Setup-2.0.0.exe',
      );
      expect(info.isWindowsInstaller, isTrue);
    });

    test('rejects ZIP, APK and missing asset names', () {
      const zip = UpdateInfo(
        version: '2.0.0',
        releaseUrl: 'https://example.com',
        notes: '',
        assetName: 'Syndro-Windows-2.0.0.zip',
      );
      expect(zip.isWindowsInstaller, isFalse);

      const apk = UpdateInfo(
        version: '2.0.0',
        releaseUrl: 'https://example.com',
        notes: '',
        assetName: 'Syndro-2.0.0.apk',
      );
      expect(apk.isWindowsInstaller, isFalse);

      const none = UpdateInfo(
        version: '2.0.0',
        releaseUrl: 'https://example.com',
        notes: '',
      );
      expect(none.isWindowsInstaller, isFalse);
    });
  });

  group('UpdateService.downloadUpdate', () {
    late HttpServer server;
    late Directory targetDir;
    late int requests;

    setUp(() async {
      requests = 0;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      targetDir = await Directory.systemTemp.createTemp('syndro-update-test');
    });

    tearDown(() async {
      await server.close(force: true);
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
    });

    void serve(List<int> bytes, {int status = 200}) {
      server.listen((req) {
        requests++;
        if (status != 200) {
          req.response.statusCode = status;
          req.response.close();
          return;
        }
        req.response.headers.contentLength = bytes.length;
        req.response.add(bytes);
        req.response.close();
      });
    }

    /// Points at the loopback server. [digest] is what the publisher signed and
    /// defaults to the true hash of [served]; pass a different one to model a
    /// payload that is not what the manifest vouched for.
    UpdateInfo infoFor({
      required List<int> served,
      String? digest,
      int? advertisedAssetSize,
      int? signedSize,
    }) {
      return UpdateInfo(
        version: '9.9.9',
        releaseUrl: 'https://example.com',
        notes: '',
        assetUrl: 'http://127.0.0.1:${server.port}/Syndro-Setup-9.9.9.exe',
        assetName: 'Syndro-Setup-9.9.9.exe',
        assetSize: advertisedAssetSize ?? served.length,
        trustedSha256: digest ?? crypto.sha256.convert(served).toString(),
        manifestSize: signedSize,
      );
    }

    String installerPath() => '${targetDir.path}${Platform.pathSeparator}'
        'Syndro-Setup-9.9.9.exe';

    test('downloads the asset and reports progress', () async {
      final payload = List<int>.generate(200000, (i) => i % 251);
      serve(payload);

      final progress = <(int, int?)>[];
      final path = await UpdateService.downloadUpdate(
        infoFor(served: payload),
        targetDir: targetDir,
        onProgress: (received, total) => progress.add((received, total)),
      );

      expect(path, endsWith('Syndro-Setup-9.9.9.exe'));
      final file = File(path);
      expect(await file.exists(), isTrue);
      expect(await file.length(), payload.length);
      expect(await file.readAsBytes(), payload);
      expect(progress, isNotEmpty);
      expect(progress.last.$1, payload.length);
      expect(progress.last.$2, payload.length);
    });

    test('rejects a payload that differs from the signed digest even at the '
        'advertised length', () async {
      // The regression that matters: the old gate compared the received byte
      // count against a figure from the same unsigned response, so swapping the
      // payload for something else of identical length passed straight
      // through to Process.start.
      final signed = utf8.encode('SYNDRO-INSTALLER-ORIGINAL-BYTES');
      final served = List<int>.of(signed);
      served[0] = served[0] == 0x58 ? 0x59 : 0x58; // same length, new bytes
      expect(served.length, signed.length);
      serve(served);

      await expectLater(
        UpdateService.downloadUpdate(
          infoFor(served: served, digest: crypto.sha256.convert(signed).toString()),
          targetDir: targetDir,
        ),
        throwsA(isA<UpdateIntegrityException>()),
      );
      expect(await File(installerPath()).exists(), isFalse,
          reason: 'an unauthenticated payload must not survive on disk');
    });

    test('refuses an unsigned release without contacting the server', () async {
      final payload = utf8.encode('whatever');
      serve(payload);

      final info = UpdateInfo(
        version: '9.9.9',
        releaseUrl: 'https://example.com',
        notes: '',
        assetUrl: 'http://127.0.0.1:${server.port}/Syndro-Setup-9.9.9.exe',
        assetName: 'Syndro-Setup-9.9.9.exe',
        assetSize: payload.length,
      );

      await expectLater(
        UpdateService.downloadUpdate(info, targetDir: targetDir),
        throwsA(isA<UpdateIntegrityException>()),
      );
      expect(requests, 0, reason: 'refuse before downloading anything');
      expect(await targetDir.list().toList(), isEmpty);
    });

    test('prefers the signed size over the release object\'s claim', () async {
      final payload = utf8.encode('installer bytes');
      serve(payload);

      // assetSize understates the truth, but the signed size is authoritative,
      // so the download must still be accepted.
      final path = await UpdateService.downloadUpdate(
        infoFor(
          served: payload,
          advertisedAssetSize: 1,
          signedSize: payload.length,
        ),
        targetDir: targetDir,
      );
      expect(await File(path).length(), payload.length);
    });

    test('throws and deletes the file when the size does not match', () async {
      final payload = utf8.encode('this payload is shorter than advertised');
      serve(payload);

      await expectLater(
        UpdateService.downloadUpdate(
          infoFor(
            served: payload,
            advertisedAssetSize: payload.length + 10,
            digest: 'f' * 64,
          ),
          targetDir: targetDir,
        ),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await File(installerPath()).exists(), isFalse);
    });

    test('throws when the server returns a non-200 status', () async {
      serve(const [], status: 404);

      await expectLater(
        UpdateService.downloadUpdate(
          infoFor(served: const [], digest: 'e' * 64),
          targetDir: targetDir,
        ),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await targetDir.list().toList(), isEmpty);
    });

    test('rejects non-installer assets', () async {
      const info = UpdateInfo(
        version: '9.9.9',
        releaseUrl: 'https://example.com',
        notes: '',
        assetUrl: 'https://example.com/Syndro-Windows-9.9.9.zip',
        assetName: 'Syndro-Windows-9.9.9.zip',
      );
      await expectLater(
        UpdateService.downloadUpdate(info, targetDir: targetDir),
        throwsA(isA<UpdateDownloadException>()),
      );
    });
  });

  group('UpdateService.installUpdate', () {
    late Directory updatesDir;
    late List<int> payload;

    setUp(() async {
      updatesDir =
          await Directory.systemTemp.createTemp('syndro-install-updates');
      payload = utf8.encode('installer-payload-bytes');
    });

    tearDown(() async {
      if (await updatesDir.exists()) {
        await updatesDir.delete(recursive: true);
      }
    });

    Future<String> writeInstaller({
      String name = 'Syndro-Setup-9.9.9.exe',
      List<int>? bytes,
      Directory? dir,
    }) async {
      final target = dir ?? updatesDir;
      final file = File('${target.path}${Platform.pathSeparator}$name');
      await file.writeAsBytes(bytes ?? payload, flush: true);
      return file.path;
    }

    String trueDigest() => crypto.sha256.convert(payload).toString();

    test('refuses to run anything with no authenticated digest', () async {
      final path = await writeInstaller();
      await expectLater(
        UpdateService.installUpdate(path, targetDir: updatesDir),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('refuses an installer whose bytes changed after verification',
        () async {
      // Narrows the swap window between downloadUpdate and Process.start.
      final path = await writeInstaller(bytes: utf8.encode('substituted-payload'));
      await expectLater(
        UpdateService.installUpdate(
          path,
          expectedSha256: trueDigest(),
          targetDir: updatesDir,
        ),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('refuses a path outside the updates directory', () async {
      final elsewhere =
          await Directory.systemTemp.createTemp('syndro-install-elsewhere');
      try {
        final path = await writeInstaller(dir: elsewhere);
        await expectLater(
          UpdateService.installUpdate(
            path,
            expectedSha256: crypto.sha256.convert(payload).toString(),
            targetDir: updatesDir,
          ),
          throwsA(isA<UpdateIntegrityException>()),
        );
      } finally {
        await elsewhere.delete(recursive: true);
      }
    });

    test('refuses a correctly-placed file that is not a setup binary', () async {
      final path = await writeInstaller(name: 'notepad.exe');
      await expectLater(
        UpdateService.installUpdate(
          path,
          expectedSha256: trueDigest(),
          targetDir: updatesDir,
        ),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('refuses a file that has gone missing', () async {
      final path = await writeInstaller();
      await File(path).delete();
      await expectLater(
        UpdateService.installUpdate(
          path,
          expectedSha256: trueDigest(),
          targetDir: updatesDir,
        ),
        throwsA(isA<UpdateIntegrityException>()),
      );
    });

    test('runs every integrity check on a matching installer', () async {
      // What this asserts is that nothing was *refused*: the call reaches the
      // launch attempt instead of throwing. The result is false on every
      // platform — on the CI runner the Windows guard stops it, on Windows a
      // placeholder binary is not a runnable PE. Both outcomes prove the policy
      // passed without executing anything.
      final path = await writeInstaller();
      final started = await UpdateService.installUpdate(
        path,
        expectedSha256: trueDigest(),
        targetDir: updatesDir,
      );
      expect(started, isFalse);
    });
  });

  group('UpdateService.shouldAutoCheck', () {
    test('allows the first check and then applies a 24h cooldown', () async {
      final now = DateTime(2026, 8, 19, 12);
      SharedPreferences.setMockInitialValues({});

      expect(await UpdateService.shouldAutoCheck(now: now), isTrue);
      expect(await UpdateService.shouldAutoCheck(now: now), isFalse);
      expect(
        await UpdateService.shouldAutoCheck(now: now.add(const Duration(hours: 23))),
        isFalse,
      );
      expect(
        await UpdateService.shouldAutoCheck(now: now.add(const Duration(hours: 25))),
        isTrue,
      );
    });

    test('respects a previous check stored before the cooldown elapsed', () async {
      final now = DateTime(2026, 8, 19, 12);
      SharedPreferences.setMockInitialValues({
        'syndro.update.lastCheckAt': now
            .subtract(const Duration(hours: 1))
            .millisecondsSinceEpoch,
      });
      expect(await UpdateService.shouldAutoCheck(now: now), isFalse);

      SharedPreferences.setMockInitialValues({
        'syndro.update.lastCheckAt': now
            .subtract(const Duration(hours: 25))
            .millisecondsSinceEpoch,
      });
      expect(await UpdateService.shouldAutoCheck(now: now), isTrue);
    });
  });
}