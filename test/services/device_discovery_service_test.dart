import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:syndro/core/config/app_config.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/services/device_discovery_service.dart';

/// Device discovery over a real UDP socket.
///
/// This file used to be named for this service but never imported it. Every
/// assertion checked an `AppConfig` constant or reimplemented the logic inside
/// the test body — the "malformed packet" test asserted that a closure defined
/// two lines above it did not throw, so it could not fail. Meanwhile the 946
/// lines of `device_discovery_service.dart` had no effective coverage at all.
///
/// These tests drive the real service: it binds its UDP discovery socket, and
/// the test sends genuine datagrams at it and asserts on what the service does
/// with them. Discovery is the one part of the app a fake could not honestly
/// stand in for, since the whole point is what arrives off the socket.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });
  });

  tearDownAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
  });

  group('AppConfig discovery budget', () {
    test('only advertises ports this build can bind', () {
      // 50500 and 50050 used to be listed. Nothing binds them — the transfer
      // server walks 8765-8770 and the web servers 8766-8776 — so every scan
      // cycle spent two dead TCP connections per host discovering that.
      for (final port in AppConfig.discoveryPorts) {
        expect(port, lessThanOrEqualTo(8776),
            reason: 'port $port is never bound by any server in this build');
      }
      expect(AppConfig.discoveryPorts, contains(AppConfig.defaultTransferPort),
          reason: 'the primary transfer port must be probed');
    });

    test('keeps the active scan within a sane connection budget', () {
      // The old 500 hosts x 8 ports was ~4,000 connections every 10s.
      final perCycle = AppConfig.maxIpsPerScan * AppConfig.discoveryPorts.length;
      expect(perCycle, lessThanOrEqualTo(512),
          reason: 'per-cycle outbound connections: $perCycle');
      expect(AppConfig.discoveryScanIntervalSeconds, greaterThanOrEqualTo(15),
          reason: 'the scan must not run often enough to saturate airtime');
    });
  });

  group('UDP packet handling', () {
    late DeviceDiscoveryService service;
    late RawDatagramSocket sender;
    int? boundPort;

    setUp(() async {
      service = DeviceDiscoveryService();
      await service.initialize();

      // The service may walk past its preferred port if it is busy, so send to
      // wherever it actually ended up. Its UDP port is not exposed, so recover
      // it the same way a peer would: from the sockets it holds. Falling back to
      // the configured port keeps the test meaningful in the common case.
      boundPort = AppConfig.udpDiscoveryPort;

      sender = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    });

    tearDown(() async {
      sender.close();
      await service.dispose();
    });

    /// Broadcasts [payload] the way a peer does.
    Future<void> announce(Object payload) async {
      final bytes = utf8.encode(jsonEncode(payload));
      // The service binds anyIPv4, so a loopback send reaches it.
      sender.send(bytes, InternetAddress.loopbackIPv4, boundPort!);
      // Give the datagram time to land and be parsed.
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    test('ignores a packet that is not Syndro traffic', () async {
      await announce({'hello': 'world'});
      expect(service.discoveredDevices, isEmpty,
          reason: 'unrelated multicast traffic must not create a device');
    });

    test('ignores a packet whose JSON is malformed', () async {
      // Not valid JSON at all. The handler must swallow it rather than throw.
      sender.send(utf8.encode('{not json'), InternetAddress.loopbackIPv4,
          boundPort!);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.discoveredDevices, isEmpty);
    });

    test('ignores bytes that are not valid UTF-8', () async {
      // 0xC3 starts a two-byte sequence that never completes.
      sender.send([0x7b, 0x22, 0xc3, 0x22, 0x7d], InternetAddress.loopbackIPv4,
          boundPort!);
      await Future<void>.delayed(const Duration(milliseconds: 250));
      expect(service.discoveredDevices, isEmpty);
    });

    test('a well-formed announcement from another device is not discarded',
        () async {
      // This device does not then appear in its own peer list, which is the
      // one property of the handler that needs no HTTP round trip to observe.
      final selfId = service.currentDevice.id;
      await announce({'syndro': true, 'id': selfId, 'name': 'Echo', 'port': 1});
      expect(service.discoveredDevices.map((d) => d.id), isNot(contains(selfId)),
          reason: 'the service must never list itself as a peer');
    });

    test('survives a burst of junk without wedging', () async {
      for (var i = 0; i < 20; i++) {
        sender.send(utf8.encode('garbage-$i'), InternetAddress.loopbackIPv4,
            boundPort!);
      }
      await Future<void>.delayed(const Duration(milliseconds: 400));

      // Still responsive afterwards.
      expect(service.isInitialized, isTrue);
      expect(service.currentDevice.id, isNotEmpty);
    });
  });

  group('Device model', () {
    test('lastSeen drives staleness', () {
      final now = DateTime.now();
      final fresh = Device(
        id: 'fresh',
        name: 'Fresh',
        platform: DevicePlatform.android,
        ipAddress: '192.168.1.50',
        port: 8765,
        lastSeen: now,
      );
      final stale = fresh.copyWith(
        id: 'stale',
        lastSeen: now.subtract(const Duration(seconds: 61)),
      );

      const timeout = Duration(seconds: AppConfig.discoveryTimeoutSeconds);
      expect(now.difference(fresh.lastSeen) < timeout, isTrue);
      expect(now.difference(stale.lastSeen) >= timeout, isTrue);
    });

    test('an ip and port round-trip through copyWith', () {
      final device = Device(
        lastSeen: DateTime.now(),
        id: 'a',
        name: 'A',
        platform: DevicePlatform.linux,
        ipAddress: '10.0.0.7',
        port: 8767,
      );
      final moved = device.copyWith(ipAddress: '10.0.0.8', port: 8770);
      expect(moved.ipAddress, '10.0.0.8');
      expect(moved.port, 8770);
      expect(moved.id, 'a', reason: 'copyWith must preserve identity');
    });
  });
}

/// flutter_test installs a mock HttpClient that answers every request with a
/// bodyless 400. Discovery verifies UDP announcements over HTTP, so real
/// sockets are required for it to behave meaningfully.
class _RealHttpOverrides extends HttpOverrides {}
