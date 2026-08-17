import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// Restores real HTTP clients: TestWidgetsFlutterBinding installs a mock
/// HttpClient that answers every request with a bodyless 400, which would
/// defeat the sender's real network calls in these tests.
class _RealHttpOverrides extends HttpOverrides {}

/// Proves the pause/resume state machine against a real send to a throttled
/// loopback receiver (which forces socket backpressure so the transfer stays
/// in flight while we pause it):
///   1. Pause freezes bytesTransferred and flips the status to paused.
///   2. Resume continues the transfer and it completes with full bytes.
///   3. Cancelling while paused aborts cleanly and the transfer stays
///      cancelled (not overwritten with "failed").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Stub flutter_secure_storage (identity/token persistence no-ops in VM).
  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  setUpAll(() {
    HttpOverrides.global = _RealHttpOverrides();
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
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

  group('Pause/Resume', () {
    const int fileSize = 5 * 1024 * 1024; // 5MB
    late TransferService service;
    late HttpServer slowServer;
    late int port;
    late File payload;

    setUp(() async {
      service = TransferService(FileService());
      await service.initialize();

      payload = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}slow-payload.bin');
      await payload.writeAsBytes(List<int>.filled(fileSize, 7));

      port = 18768;
      slowServer = await _startSlowReceiver(port);
    });

    tearDown(() async {
      await slowServer.close(force: true);
      await service.dispose();
      try {
        if (await payload.exists()) await payload.delete();
      } catch (_) {}
    });

    Device senderDevice() => Device(
          id: 'pause-sender',
          name: 'Pause Sender',
          platform: DevicePlatform.windows,
          ipAddress: '127.0.0.1',
          port: 0,
          lastSeen: DateTime.now(),
        );

    Device receiverDevice() => Device(
          id: 'pause-receiver',
          name: 'Pause Receiver',
          platform: DevicePlatform.windows,
          ipAddress: '127.0.0.1',
          port: port,
          lastSeen: DateTime.now(),
        );

    List<TransferItem> items() => [
          TransferItem(
            name: 'slow-payload.bin',
            path: payload.path,
            size: fileSize,
          ),
        ];

    Transfer? transferOf(String receiverId) {
      final matching = service.activeTransfers
          .where((t) => t.receiverId == receiverId)
          .toList();
      return matching.isEmpty ? null : matching.last;
    }

    Future<void> waitUntil(bool Function() condition,
        {Duration timeout = const Duration(seconds: 20)}) async {
      final deadline = DateTime.now().add(timeout);
      while (!condition()) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Condition not met within $timeout');
        }
        await Future.delayed(const Duration(milliseconds: 50));
      }
    }

    test('pause freezes progress, resume completes the transfer', () async {
      final sendFuture = service.sendFiles(
        sender: senderDevice(),
        receiver: receiverDevice(),
        items: items(),
      );

      // Wait until the transfer is actively transferring and some bytes
      // have moved.
      await waitUntil(() {
        final t = transferOf('pause-receiver');
        return t != null &&
            t.status == TransferStatus.transferring &&
            t.progress.bytesTransferred > 0;
      });
      final transferId = transferOf('pause-receiver')!.id;

      service.pauseTransfer(transferId);
      await waitUntil(() =>
          transferOf('pause-receiver')?.status == TransferStatus.paused);

      final frozenBytes =
          transferOf('pause-receiver')!.progress.bytesTransferred;
      await Future.delayed(const Duration(milliseconds: 400));
      expect(transferOf('pause-receiver')!.progress.bytesTransferred,
          frozenBytes,
          reason: 'Bytes must not advance while paused');
      await Future.delayed(const Duration(milliseconds: 400));
      expect(transferOf('pause-receiver')!.progress.bytesTransferred,
          frozenBytes,
          reason: 'Bytes must stay frozen while paused');

      service.resumeTransfer(transferId);
      await waitUntil(() =>
          transferOf('pause-receiver')?.status == TransferStatus.completed);

      final done = transferOf('pause-receiver')!;
      expect(done.progress.bytesTransferred, fileSize);
      expect(done.progress.totalBytes, fileSize);

      await sendFuture;
    });

    test('cancelling while paused aborts and stays cancelled', () async {
      final sendFuture = service.sendFiles(
        sender: senderDevice(),
        receiver: receiverDevice(),
        items: items(),
      );

      await waitUntil(() {
        final t = transferOf('pause-receiver');
        return t != null && t.progress.bytesTransferred > 0;
      });
      final transferId = transferOf('pause-receiver')!.id;

      service.pauseTransfer(transferId);
      await waitUntil(() =>
          transferOf('pause-receiver')?.status == TransferStatus.paused);

      service.cancelTransfer(transferId);

      // The send loop must wake from the pause gate and abort without
      // overwriting the cancelled state.
      await sendFuture;
      expect(transferOf('pause-receiver')!.status, TransferStatus.cancelled);
    });

    test('pause is a no-op for transfers that do not exist', () {
      expect(() => service.pauseTransfer('does-not-exist'), returnsNormally);
      expect(() => service.resumeTransfer('does-not-exist'), returnsNormally);
    });
  });
}

/// A receiver that accepts `/transfer/initiate` (replying "accepted", no
/// encryption) and then reads the upload body very slowly, forcing the
/// sender's socket to backpressure so the transfer stays in flight.
Future<HttpServer> _startSlowReceiver(int port) async {
  final server = await HttpServer.bind('127.0.0.1', port);
  server.listen((request) async {
    try {
      final path = request.uri.path;
      if (path == '/transfer/initiate') {
        await utf8.decoder.bind(request).join();
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json;
        request.response.write(jsonEncode({'status': 'accepted'}));
        await request.response.close();
      } else if (path == '/transfer/upload') {
        var remaining =
            int.tryParse(request.headers.value('x-file-size') ?? '') ?? 0;
        await for (final chunk in request) {
          remaining -= chunk.length;
          if (remaining > 0) {
            await Future.delayed(const Duration(milliseconds: 40));
          }
        }
        request.response
          ..statusCode = 200
          ..headers.set(HttpHeaders.contentLengthHeader, 0);
        await request.response.close();
      } else {
        request.response.statusCode = 404;
        await request.response.close();
      }
    } catch (_) {
      // The sender may abort mid-upload (cancel); nothing to do.
    }
  });
  return server;
}