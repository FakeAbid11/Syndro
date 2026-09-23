import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/database/database_helper.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';

/// Runtime feature-acceptance harness.
///
/// Boots two REAL [TransferService] nodes in one VM — each with its own HTTP
/// server on loopback and its own temporary downloads directory — and moves
/// actual files between them. Existing tests cover the receive-side handlers
/// with raw-socket clients and the send side against hand-rolled fakes; none of
/// them ever lands a real payload in the real receiver, which is the gap this
/// harness exists to close.
///
/// ## Isolation contract
///
/// Every node MUST be built through [SyndroNode.start], which injects a
/// [TempDirFileService]. That is not defensive tidiness:
/// `FileService.getDownloadDirectory()` on Windows resolves and *creates*
/// `%USERPROFILE%\Downloads\Syndro`, so an unprepared node writes received
/// files into the developer's real Downloads folder — and a collision test
/// would delete whatever is already there. `getDownloadDirectory()` is the only
/// absolute user path in `FileService`, so overriding it isolates everything.

/// flutter_test installs a mock HttpClient that answers every request with a
/// bodyless 400. The sender uses `package:http` for real, so it must be able to
/// open real sockets.
class _RealHttpOverrides extends HttpOverrides {}

const MethodChannel _secureStorageChannel =
    MethodChannel('plugins.it_nomads.com/flutter_secure_storage');

bool _bootstrapInstalled = false;

/// One-time VM bootstrap: SQLite over FFI, in-memory preferences, a secure
/// storage stub. Safe to call from every test file's `setUpAll`.
void installAcceptanceBootstrap() {
  TestWidgetsFlutterBinding.ensureInitialized();
  if (_bootstrapInstalled) return;
  _bootstrapInstalled = true;

  HttpOverrides.global = _RealHttpOverrides();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  SharedPreferences.setMockInitialValues({});
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, (call) async {
    if (call.method == 'readAll') return <String, String>{};
    return null;
  });
}

/// Undoes [installAcceptanceBootstrap]. Each test file runs in its own isolate,
/// so this is hygiene rather than a requirement, and it mirrors what
/// `phase1_correctness_test.dart` does.
void uninstallAcceptanceBootstrap() {
  HttpOverrides.global = null;
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_secureStorageChannel, null);
  _bootstrapInstalled = false;
}

/// A [FileService] whose received files land in a throwaway directory.
class TempDirFileService extends FileService {
  TempDirFileService(this.downloadDir);

  final Directory downloadDir;

  @override
  Future<String> getDownloadDirectory() async => downloadDir.path;
}

/// One participant: a real service, a real listener, a temp downloads dir.
class SyndroNode {
  SyndroNode._({
    required this.deviceId,
    required this.displayName,
    required this.platform,
    required this.service,
    required this.downloadDir,
    required this.workDir,
    required this.port,
  });

  final String deviceId;
  final String displayName;
  final DevicePlatform platform;
  final TransferService service;
  final Directory downloadDir;

  /// Scratch space for payload files this node sends.
  final Directory workDir;
  final int port;

  /// How a peer addresses this node.
  Device asDevice() => Device(
        id: deviceId,
        name: displayName,
        platform: platform,
        ipAddress: InternetAddress.loopbackIPv4.address,
        port: port,
        lastSeen: DateTime.now(),
      );

  File downloaded(String name) => File(p.join(downloadDir.path, name));

  /// Immediate filenames present in this node's downloads dir.
  Future<List<String>> downloadedNames() async {
    if (!await downloadDir.exists()) return const [];
    final names = await downloadDir
        .list()
        .where((e) => e is File)
        .map((e) => p.basename(e.path))
        .toList();
    return names..sort();
  }

  Future<void> dispose() => service.dispose();

  /// Starts a node on a freshly reserved loopback port.
  static Future<SyndroNode> start({
    required String deviceId,
    required String displayName,
    DevicePlatform platform = DevicePlatform.windows,
    bool encryptionEnabled = true,
  }) async {
    final downloadDir =
        await Directory.systemTemp.createTemp('syndro-fa-$deviceId-dl');
    final workDir =
        await Directory.systemTemp.createTemp('syndro-fa-$deviceId-work');

    TransferService? service;
    int? port;
    try {
      service = TransferService(TempDirFileService(downloadDir));
      service.encryptionEnabled = encryptionEnabled;
      await service.initialize();

      port = await _reserveLoopbackPort();
      await service.startServer(port);
      // startServer retries upward through port..port+5 and exposes no port
      // getter, so confirm where it actually landed rather than assume.
      final bound = await _findBoundPort(port);
      return SyndroNode._(
        deviceId: deviceId,
        displayName: displayName,
        platform: platform,
        service: service,
        downloadDir: downloadDir,
        workDir: workDir,
        port: bound,
      );
    } catch (e) {
      await _quietDispose(service);
      await _deleteDir(downloadDir);
      await _deleteDir(workDir);
      rethrow;
    }
  }
}

/// A paired sender and receiver, both real, plus their shared teardown.
class TwoNodeHarness {
  TwoNodeHarness._(this.sender, this.receiver);

  final SyndroNode sender;
  final SyndroNode receiver;

  static Future<TwoNodeHarness> start({
    bool senderEncryption = true,
    bool receiverEncryption = true,
    String senderId = 'fa-sender',
    String receiverId = 'fa-receiver',
  }) async {
    final sender = await SyndroNode.start(
      deviceId: senderId,
      displayName: 'FA Sender',
      encryptionEnabled: senderEncryption,
    );
    try {
      final receiver = await SyndroNode.start(
        deviceId: receiverId,
        displayName: 'FA Receiver',
        encryptionEnabled: receiverEncryption,
      );
      return TwoNodeHarness._(sender, receiver);
    } catch (_) {
      await sender.dispose();
      rethrow;
    }
  }

  Future<void> dispose() async {
    await _quietDispose(sender.service);
    await _quietDispose(receiver.service);
    await _deleteDir(sender.downloadDir);
    await _deleteDir(sender.workDir);
    await _deleteDir(receiver.downloadDir);
    await _deleteDir(receiver.workDir);
  }

  /// The sender's transfer record for this peer, newest match.
  Transfer? senderTransfer(String receiverId) => _latest(
        sender.service.activeTransfers,
        (t) => t.receiverId == receiverId,
      );

  Transfer? receiverTransfer(String senderId) => _latest(
        receiver.service.activeTransfers,
        (t) => t.senderId == senderId,
      );

  /// Waits until the receiver has a pending request and approves it.
  ///
  /// Returns the request id, which is the same id the sender assigned to the
  /// transfer. Throws if none appears, rather than hanging: a missing request
  /// is itself a feature failure worth reporting.
  Future<String> approveNextPending({
    Duration timeout = const Duration(seconds: 20),
    bool trustSender = false,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final pending = receiver.service.pendingRequests;
      if (pending.isNotEmpty) {
        final id = pending.first.requestId;
        await receiver.service.approveTransfer(id, trustSender: trustSender);
        return id;
      }
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    throw StateError(
      'receiver never produced a pending transfer request within $timeout — '
      'the approval handshake did not run',
    );
  }
}

// ── Payload helpers ────────────────────────────────────────────────────────

/// Writes a deterministic payload of [size] bytes. Deterministic so a hash
/// mismatch can only mean the transfer changed the bytes, not that the fixture
/// was random to begin with.
Future<File> writePayload(Directory dir, String name, int size) async {
  final file = File(p.join(dir.path, name));
  await file.parent.create(recursive: true);
  final bytes = Uint8List(size);
  for (var i = 0; i < size; i++) {
    bytes[i] = (i * 31 + name.hashCode) & 0xFF;
  }
  await file.writeAsBytes(bytes, flush: true);
  return file;
}

TransferItem itemFor(File file, {String? name}) => TransferItem(
      name: name ?? p.basename(file.path),
      path: file.path,
      size: file.lengthSync(),
    );

Future<String> sha256OfFile(String path) async {
  final digest = await crypto.sha256.bind(File(path).openRead()).last;
  return digest.toString();
}

Future<String> sha256OfBytes(List<int> bytes) async =>
    crypto.sha256.convert(bytes).toString();

/// Polls [condition] until true or the deadline passes.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 30),
  required String reason,
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('timed out waiting for $reason', timeout);
    }
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

/// Posts [body] over a raw socket and returns the response status code.
///
/// Raw sockets rather than `package:http` because that is what the existing
/// receive-path tests use against this server (`phase1_correctness_test.dart`
/// notes package:http surfaces a spurious bodyless 400 here in the test VM).
Future<int> rawPost(
  int port,
  String path,
  Map<String, String> headers,
  List<int> body,
) async {
  final socket = await Socket.connect(InternetAddress.loopbackIPv4.address, port);
  try {
    final head = StringBuffer()
      ..write('POST $path HTTP/1.1\r\n')
      ..write('Host: 127.0.0.1:$port\r\n')
      ..write('Content-Length: ${body.length}\r\n')
      ..write('Connection: close\r\n');
    headers.forEach((k, v) => head.write('$k: $v\r\n'));
    head.write('\r\n');
    socket.add(utf8.encode(head.toString()));
    socket.add(body);
    await socket.flush();

    final response = <int>[];
    await for (final chunk in socket) {
      response.addAll(chunk);
      final asText = utf8.decode(response, allowMalformed: true);
      final headerEnd = asText.indexOf('\r\n\r\n');
      final contentLengthMatch =
          RegExp(r'content-length: (\d+)', caseSensitive: false)
              .firstMatch(asText);
      if (headerEnd != -1 &&
          contentLengthMatch != null &&
          asText.length - headerEnd - 4 >=
              int.parse(contentLengthMatch.group(1)!)) {
        break;
      }
      if (response.length > 64 * 1024) break;
    }
    final statusLine =
        utf8.decode(response, allowMalformed: true).split('\r\n').first;
    return int.parse(statusLine.split(' ')[1]);
  } finally {
    socket.destroy();
  }
}

Future<int> rawPostJson(
  int port,
  String path,
  Map<String, String> headers,
  Object body,
) =>
    rawPost(port, path, {'Content-Type': 'application/json', ...headers},
        utf8.encode(jsonEncode(body)));

/// The `transfer_items` rows persisted for [transferId], via DatabaseHelper.
///
/// Used to check that whatever the app recorded for a transfer describes the
/// file that actually exists. Note both nodes share one filesystem here, so
/// "the recorded path exists" is a weak assertion — compare against the
/// receiver's own downloads directory instead.
Future<List<Map<String, Object?>>> recordedItems(String transferId) async {
  final row = await DatabaseHelper.instance.getTransferById(transferId);
  final items = row?['items'];
  if (items is! List) return const [];
  return items
      .whereType<Map<String, Object?>>()
      .toList(growable: false);
}

/// Waits for [future] and converts any error into a readable test failure that
/// still names the artefacts on disk, instead of an opaque unhandled error.
Future<void> settle(
  Future<void> future, {
  required String what,
}) async {
  try {
    await future;
  } on Object catch (e, st) {
    fail('$what threw: $e\n$st');
  }
}

T? _latest<T>(Iterable<T> source, bool Function(T) match) {
  T? found;
  for (final item in source) {
    if (match(item)) found = item;
  }
  return found;
}

Future<int> _reserveLoopbackPort() async {
  final socket =
      await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

/// `startServer` picks the port internally and only logs the result, so probe
/// the candidate range to learn where it actually listens.
Future<int> _findBoundPort(int from) async {
  for (var candidate = from; candidate <= from + 5; candidate++) {
    try {
      final socket = await Socket.connect(
        InternetAddress.loopbackIPv4.address,
        candidate,
        timeout: const Duration(milliseconds: 250),
      );
      await socket.close();
      return candidate;
    } on SocketException {
      continue;
    } on TimeoutException {
      continue;
    }
  }
  throw StateError(
    'transfer server is not listening on any port in $from..${from + 5}',
  );
}

Future<void> _quietDispose(TransferService? service) async {
  if (service == null) return;
  try {
    await service.dispose();
  } on Object {
    // Teardown noise must not mask the actual assertion failure.
  }
}

Future<void> _deleteDir(Directory dir) async {
  try {
    if (await dir.exists()) await dir.delete(recursive: true);
  } on FileSystemException {
    // Best effort; systemTemp is reclaimed by the OS.
  }
}

/// Encodes a filename the way the wire does, so a test can assert what a peer
/// actually receives rather than what the sender intended.
String asciiRenderedFileName(String name) {
  final buffer = StringBuffer();
  for (final unit in name.codeUnits) {
    buffer.writeCharCode(unit >= 0x20 && unit <= 0x7E ? unit : 0x5F);
  }
  return buffer.toString();
}
