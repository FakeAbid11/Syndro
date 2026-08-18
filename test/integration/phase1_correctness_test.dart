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
/// defeat the real network calls in these tests.
class _RealHttpOverrides extends HttpOverrides {}

/// Phase-1 correctness regression tests against the REAL TransferService
/// HTTP server (raw-socket clients, since package:http surfaces a spurious
/// bodyless 400 against this server in the test VM):
///
///   1. Truncated uploads (declared size != received bytes) are rejected and
///      the transfer is marked failed, not completed.
///   2. A parallel finalize with a wrong file hash is rejected: the session
///      is cleaned up and the receiver transfer is marked failed.
///   3. A user cancel propagates to the receiver (session aborted, receiver
///      transfer marked cancelled) and the sender's transfer stays cancelled.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  Future<void> waitUntil(
    bool Function() condition, {
    Duration timeout = const Duration(seconds: 15),
    String reason = 'condition',
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('Timed out waiting for $reason');
      }
      await Future.delayed(const Duration(milliseconds: 50));
    }
  }

  int statusOf(String statusLine) => int.parse(statusLine.split(' ')[1]);

  /// Raw HTTP POST; returns the status line, e.g. `HTTP/1.1 400 Bad Request`.
  Future<String> rawPost(
    int port,
    String path,
    Map<String, String> headers,
    String body,
  ) async {
    final socket = await Socket.connect('127.0.0.1', port);
    final req = StringBuffer()
      ..write('POST $path HTTP/1.1\r\n')
      ..write('Host: 127.0.0.1:$port\r\n')
      ..write('Content-Length: ${utf8.encode(body).length}\r\n')
      ..write('Connection: close\r\n');
    headers.forEach((k, v) => req.write('$k: $v\r\n'));
    req
      ..write('\r\n')
      ..write(body);
    socket.write(req.toString());
    final response =
        await socket.cast<List<int>>().transform(utf8.decoder).join();
    await socket.close();
    return response.split('\r\n').first.trim();
  }

  group('Phase 1 correctness', () {
    late TransferService receiver;
    late int port;

    setUp(() async {
      receiver = TransferService(FileService());
      await receiver.initialize();
      port = 18766;
      await receiver.startServer(port);
    });

    tearDown(() async {
      await receiver.dispose();
    });

    Transfer? transferOf(String id) {
      final matching =
          receiver.activeTransfers.where((t) => t.id == id).toList();
      return matching.isEmpty ? null : matching.last;
    }

    test('truncated upload is rejected and the transfer is marked failed',
        () async {
      const transferId = 'trunc-test-1';

      final initiate = await rawPost(port, '/transfer/initiate', {
        'Content-Type': 'application/json',
        'x-device-id': 'trunc-sender',
      }, jsonEncode({
        'id': transferId,
        'senderId': 'trunc-sender',
        'senderName': 'Trunc Sender',
        'senderToken': 'trunc-token',
        'receiverId': 'this-device',
        'items': [
          {'name': 'trunc.bin', 'size': 1000}
        ],
      }));
      expect(statusOf(initiate), 200);

      await receiver.approveTransfer(transferId);

      // Declare 1000 bytes but send only 500 — a mid-stream disconnect.
      final upload = await rawPost(port, '/transfer/upload', {
        'x-transfer-id': transferId,
        'x-file-name': 'trunc.bin',
        'x-file-size': '1000',
        'x-sender-id': 'trunc-sender',
        'x-sender-token': 'trunc-token',
      }, 'x' * 500);

      expect(statusOf(upload), 400,
          reason: 'size mismatch must be rejected');

      await waitUntil(
        () => transferOf(transferId)?.status == TransferStatus.failed,
        reason: 'transfer marked failed',
      );
      expect(transferOf(transferId)!.status, TransferStatus.failed);
      expect(transferOf(transferId)!.errorMessage, contains('mismatch'));
    });

    test('parallel finalize with wrong hash is rejected and receiver marked '
        'failed', () async {
      const transferId = 'hash-mismatch-1';
      const senderId = 'hash-sender';
      const payload = 'abc';

      final initiate = await rawPost(port, '/transfer/parallel/initiate', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({
        'transferId': transferId,
        'fileName': 'hm.bin',
        'fileSize': payload.length,
        'fileHash': 'deadbeef',
        'totalChunks': 1,
        'chunkSize': 1024,
        'senderId': senderId,
        'senderName': 'Hash Sender',
        'senderToken': 'hash-token',
        'encrypted': false,
      }));
      expect(statusOf(initiate), 200);

      await receiver.approveTransfer(transferId);
      await waitUntil(
        () => transferOf(transferId)?.status == TransferStatus.transferring,
        reason: 'receiver transfer tracked after approval',
      );

      // Upload the single chunk.
      final chunk = await rawPost(port, '/transfer/chunk', {
        'X-Transfer-Id': transferId,
        'X-Chunk-Index': '0',
        'X-Original-Size': '${payload.length}',
        'X-Sender-Id': senderId,
        'X-Sender-Token': 'hash-token',
        'X-Encrypted': 'false',
      }, payload);
      expect(statusOf(chunk), 200);

      // Finalize with the wrong hash.
      final complete = await rawPost(port, '/transfer/parallel/complete', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({
        'transferId': transferId,
        'fileHash': '0000000000000000000000000000000000000000000000000000000000000000',
      }));
      expect(statusOf(complete), 400,
          reason: 'hash mismatch must be rejected');

      await waitUntil(
        () => transferOf(transferId)?.status == TransferStatus.failed,
        reason: 'receiver transfer marked failed',
      );
    });

    test('parallel cancel endpoint aborts the session and marks the receiver '
        'transfer cancelled', () async {
      const transferId = 'cancel-recv-1';
      const senderId = 'cancel-sender';

      final initiate = await rawPost(port, '/transfer/parallel/initiate', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({
        'transferId': transferId,
        'fileName': 'ca.bin',
        'fileSize': 1024,
        'fileHash': 'deadbeef',
        'totalChunks': 1,
        'chunkSize': 1024,
        'senderId': senderId,
        'senderName': 'Cancel Sender',
        'senderToken': 'cancel-token',
        'encrypted': false,
      }));
      expect(statusOf(initiate), 200);

      await receiver.approveTransfer(transferId);
      await waitUntil(
        () => transferOf(transferId)?.status == TransferStatus.transferring,
        reason: 'receiver transfer tracked after approval',
      );

      // A retried initiate while the session is active is idempotent (409).
      final retry = await rawPost(port, '/transfer/parallel/initiate', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({
        'transferId': transferId,
        'fileName': 'ca.bin',
        'fileSize': 1024,
        'fileHash': 'deadbeef',
        'totalChunks': 1,
        'chunkSize': 1024,
        'senderId': senderId,
        'senderName': 'Cancel Sender',
        'senderToken': 'cancel-token',
        'encrypted': false,
      }));
      expect(statusOf(retry), 409,
          reason: 'duplicate initiate must not create a second session');

      // Simulate the sender's cancel notification.
      final cancel = await rawPost(port, '/transfer/parallel/cancel', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({'transferId': transferId}));
      expect(statusOf(cancel), 200);

      await waitUntil(
        () => transferOf(transferId)?.status == TransferStatus.cancelled,
        reason: 'receiver transfer marked cancelled',
      );

      // The session is gone: a subsequent finalize must be unauthorized.
      final complete = await rawPost(port, '/transfer/parallel/complete', {
        'Content-Type': 'application/json',
        'x-device-id': senderId,
      }, jsonEncode({'transferId': transferId, 'fileHash': 'deadbeef'}));
      expect(statusOf(complete), 401,
          reason: 'session aborted by cancel');
    });
  });

  group('Phase 1 sender-side cancel', () {
    const int fileSize = 12 * 1024 * 1024; // 12MB — forces the parallel path
    late TransferService sender;
    late TransferService receiver;
    late File payload;

    setUp(() async {
      sender = TransferService(FileService());
      await sender.initialize();
      await sender.startServer(18767);

      receiver = TransferService(FileService());
      await receiver.initialize();
      await receiver.startServer(18766);

      payload = File(
          '${Directory.systemTemp.path}${Platform.pathSeparator}cancel-payload.bin');
      await payload.writeAsBytes(List<int>.filled(fileSize, 7));
    });

    tearDown(() async {
      await sender.dispose();
      await receiver.dispose();
      try {
        if (await payload.exists()) await payload.delete();
      } catch (_) {}
    });

    Device senderDevice() => Device(
          id: 'cancel-sender',
          name: 'Cancel Sender',
          platform: DevicePlatform.windows,
          ipAddress: '127.0.0.1',
          port: 0,
          lastSeen: DateTime.now(),
        );

    Device receiverDevice() => Device(
          id: 'cancel-receiver',
          name: 'Cancel Receiver',
          platform: DevicePlatform.windows,
          ipAddress: '127.0.0.1',
          port: 18766,
          lastSeen: DateTime.now(),
        );

    List<TransferItem> items() => [
          TransferItem(
            name: 'cancel-payload.bin',
            path: payload.path,
            size: fileSize,
          ),
        ];

    Transfer? senderTransferOf(String receiverId) {
      final matching = sender.activeTransfers
          .where((t) => t.receiverId == receiverId)
          .toList();
      return matching.isEmpty ? null : matching.last;
    }

    test('cancelling a parallel send during approval aborts and stays '
        'cancelled', () async {
      final sendFuture = sender.sendFiles(
        sender: senderDevice(),
        receiver: receiverDevice(),
        items: items(),
      );

      // The sender registers the parallel transfer before the approval
      // handshake, so it is cancelable while the receiver is still deciding.
      await waitUntil(
        () => senderTransferOf('cancel-receiver') != null,
        reason: 'sender parallel transfer registered',
      );
      final transferId = senderTransferOf('cancel-receiver')!.id;

      sender.cancelTransfer(transferId);

      await sendFuture;
      expect(senderTransferOf('cancel-receiver')!.status,
          TransferStatus.cancelled,
          reason: 'a user cancel must not be overwritten by the abort path');

      // The receiver keeps no session state: finalize is unauthorized there.
      final complete = await rawPost(18766, '/transfer/parallel/complete', {
        'Content-Type': 'application/json',
        'x-device-id': 'cancel-sender',
      }, jsonEncode({'transferId': transferId, 'fileHash': 'x'}));
      expect(statusOf(complete), 401,
          reason: 'no receive session may exist after sender cancel');
    });
  });
}
