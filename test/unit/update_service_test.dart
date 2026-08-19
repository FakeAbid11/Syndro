import 'dart:convert';
import 'dart:io';

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

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      targetDir = await Directory.systemTemp.createTemp('syndro-update-test');
    });

    tearDown(() async {
      await server.close(force: true);
      if (await targetDir.exists()) {
        await targetDir.delete(recursive: true);
      }
    });

    UpdateInfo infoFor(String payload, {int? assetSize}) {
      return UpdateInfo(
        version: '9.9.9',
        releaseUrl: 'https://example.com',
        notes: '',
        assetUrl: 'http://127.0.0.1:${server.port}/Syndro-Setup-9.9.9.exe',
        assetName: 'Syndro-Setup-9.9.9.exe',
        assetSize: assetSize ?? utf8.encode(payload).length,
      );
    }

    test('downloads the asset and reports progress', () async {
      final payload = List<int>.generate(200000, (i) => i % 251);
      server.listen((req) {
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
        req.response.close();
      });

      final progress = <(int, int?)>[];
      final path = await UpdateService.downloadUpdate(
        infoFor('', assetSize: payload.length),
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

    test('throws and deletes the file when the size does not match', () async {
      final payload = utf8.encode('this payload is shorter than advertised');
      server.listen((req) {
        req.response.headers.contentLength = payload.length;
        req.response.add(payload);
        req.response.close();
      });

      await expectLater(
        UpdateService.downloadUpdate(
          infoFor('', assetSize: payload.length + 10),
          targetDir: targetDir,
        ),
        throwsA(isA<UpdateDownloadException>()),
      );
      expect(await File('${targetDir.path}${Platform.pathSeparator}'
          'Syndro-Setup-9.9.9.exe').exists(), isFalse);
    });

    test('throws when the server returns a non-200 status', () async {
      server.listen((req) {
        req.response.statusCode = 404;
        req.response.close();
      });

      await expectLater(
        UpdateService.downloadUpdate(infoFor(''), targetDir: targetDir),
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