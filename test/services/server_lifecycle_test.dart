import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/models/transfer_checkpoint.dart';
import 'package:syndro/core/services/checkpoint_manager.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/models.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// P1-2: transfer-server lifecycle invariants under service recreation.
///
/// Android can recreate `TransferService` without going through the app, and a
/// Dart-side retry of startup can call `startServer` again. Neither may end up
/// with two listeners, and neither may report a healthy server that is not
/// actually accepting.
///
/// The invariant asserted here: no live server -> bind exactly one; live
/// server -> reuse it; disposed -> refuse, and a fresh service rebinds cleanly.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  const pathProvider = MethodChannel('plugins.flutter.io/path_provider');

  late Directory sandbox;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    SharedPreferences.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('syndro-lifecycle-test');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, (call) async {
      if (call.method == 'readAll') return <String, String>{};
      return null;
    });

    // path_provider has no implementation in a VM test, and without a stub
    // CheckpointManager silently no-ops every save ("Could not acquire lock"),
    // which would make the checkpoint assertions below vacuous. Answer both the
    // legacy and the current method names with a throwaway directory.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, (call) async {
      final method = call.method;
      if (method.contains('ApplicationDocuments') ||
          method == 'getPathDirectory') {
        return sandbox.path;
      }
      return null;
    });
  });

  tearDownAll(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProvider, null);
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  /// A free loopback port, released immediately. `startServer` retries
  /// port..port+5, so a freshly reserved port is bound exactly as asked.
  Future<int> reservePort() async {
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    return port;
  }

  /// Raw-socket GET returning the first response line, e.g.
  /// `HTTP/1.1 200 OK`.
  Future<String> get(int port, String path) async {
    final socket = await Socket.connect(
      InternetAddress.loopbackIPv4.address,
      port,
      timeout: const Duration(seconds: 3),
    );
    try {
      socket.write('GET $path HTTP/1.1\r\n'
          'Host: 127.0.0.1:$port\r\n'
          'Connection: close\r\n\r\n');
      await socket.flush();
      final response =
          await socket.cast<List<int>>().transform(utf8.decoder).join();
      return response.split('\r\n').first.trim();
    } finally {
      socket.destroy();
    }
  }

  Future<bool> isBindable(int port) async {
    try {
      final probe = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
      await probe.close();
      return true;
    } on SocketException {
      return false;
    }
  }

  TransferService newService() {
    // FileService is only used for storage paths here; no receive happens, so
    // nothing can land in the developer's downloads directory.
    final service = TransferService(FileService());
    addTearDown(() async {
      try {
        await service.dispose();
      } catch (_) {
        // Teardown noise must not mask the assertion under test.
      }
    });
    return service;
  }

  group('server startup', () {
    test('test 1: startServer binds a listener that actually answers',
        () async {
      final service = newService();
      await service.initialize();
      final port = await reservePort();

      expect(service.isServerRunning, isFalse,
          reason: 'a fresh service must not claim to be listening');

      await service.startServer(port);

      expect(service.isServerRunning, isTrue);
      final status = await get(port, '/syndro.json');
      expect(status, contains('200'),
          reason: 'the announced server did not answer on port $port');
    });

    test('test 2: a second startServer does not create a second listener',
        () async {
      final service = newService();
      await service.initialize();
      final first = await reservePort();
      final second = first + 1;

      await service.startServer(first);
      expect(await isBindable(second), isTrue,
          reason: 'sanity: the second port starts out free');

      // A retry / recreated service calling in again must reuse, not rebind.
      await service.startServer(second);

      expect(service.isServerRunning, isTrue);
      expect(
        await isBindable(second),
        isTrue,
        reason: 'nothing may hold $second: startServer must reuse the '
            'listener on $first instead of binding a second socket',
      );
      expect(await get(first, '/syndro.json'), contains('200'),
          reason: 'the original listener must still be the one in service');
    });

    test('test 2b: a disposed service refuses to bind an unserved socket',
        () async {
      final service = newService();
      await service.initialize();
      final port = await reservePort();
      await service.startServer(port);
      await service.dispose();

      expect(service.isServerRunning, isFalse);
      await expectLater(
        service.startServer(port),
        throwsA(
          isA<TransferException>().having(
            (e) => e.code,
            'code',
            'SERVICE_DISPOSED',
          ),
        ),
        reason: 'binding after dispose would hold a port that answers nothing',
      );
    });

    test('test 3: after shutdown a new service recreates exactly one listener',
        () async {
      final first = newService();
      await first.initialize();
      final port = await reservePort();
      await first.startServer(port);
      await first.dispose();

      expect(await isBindable(port), isTrue,
          reason: 'dispose must release the port for the next listener');

      final second = newService();
      await second.initialize();
      await second.startServer(port);

      expect(second.isServerRunning, isTrue);
      expect(await get(port, '/syndro.json'), contains('200'));
      expect(await isBindable(port), isFalse,
          reason: 'exactly one listener should now own the port');
    });
  });

  group('checkpoint preservation across recreation', () {
    late CheckpointManager checkpoints;

    setUp(() {
      checkpoints = CheckpointManager();
    });

    TransferCheckpoint sample(String id,
            {int index = 2, int bytes = 5000000}) =>
        TransferCheckpoint(
          transferId: id,
          fileId: 'file-$id',
          bytesTransferred: bytes,
          timestamp: DateTime.now(),
          currentFileIndex: index,
          totalFiles: 5,
        );

    test('test 4: server recreation does not delete stored checkpoints',
        () async {
      final checkpoint = sample('keep-me');
      await checkpoints.saveCheckpoint(checkpoint);

      // Prove the stub works, otherwise this test would pass vacuously.
      expect(await checkpoints.loadCheckpoint('keep-me'), isNotNull,
          reason: 'checkpoint save must actually persist for this test to mean '
              'anything');

      final service = newService();
      await service.initialize();
      final port = await reservePort();
      await service.startServer(port);
      await service.dispose();

      final survivor = await checkpoints.loadCheckpoint('keep-me');
      expect(survivor, isNotNull,
          reason: 'recreating the transfer service must not clear checkpoints');
      expect(survivor!.transferId, 'keep-me');
      expect(survivor.currentFileIndex, checkpoint.currentFileIndex);
      expect(survivor.bytesTransferred, checkpoint.bytesTransferred);
      expect(survivor.totalFiles, checkpoint.totalFiles);
    });

    test('test 5: an interrupted transfer stays recoverable', () async {
      // Documents the state the next recovery layer needs: the checkpoint of a
      // transfer that never reported completion survives, untouched, across a
      // full service lifecycle. Note the honest limit — the existing resume
      // path restarts the current file from byte 0 (the send loop always opens
      // the file from the start), so "recoverable" here means the progress
      // record is preserved, not that the byte offset is resumed. Claiming more
      // than that would be a fake recovery.
      final interrupted = sample('interrupted', index: 3);
      await checkpoints.saveCheckpoint(interrupted);

      final service = newService();
      await service.initialize();
      await service.startServer(await reservePort());
      await service.dispose();

      final loaded = await checkpoints.loadCheckpoint('interrupted');
      expect(loaded, isNotNull);
      expect(loaded!.currentFileIndex, 3,
          reason: 'the interrupted position must be preserved for recovery');
      expect(loaded.bytesTransferred, 5000000);
    });
  });
}
