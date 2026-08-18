import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';
import 'package:syndro/core/providers/transfer_provider.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';
import 'package:syndro/ui/screens/multi_transfer_progress_screen.dart';

class _RealHttpOverrides extends HttpOverrides {}

/// Widget smoke test for the Phase-2 multi-transfer fix: a cancelled transfer
/// must count toward completion (Done button appears, "Cancelled" badge) and
/// must not leave the screen stuck on "Sending...".
///
/// Real I/O (sockets) runs inside `tester.runAsync` — the widget-test
/// fake-async zone never delivers those completions on its own.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorage =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  // BackgroundTransferService listens on this EventChannel for native
  // cancel/resume events; stub it so widget tests don't throw
  // MissingPluginException.
  const transferEvents = EventChannel('com.syndro.app/transfer_events');
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(
      transferEvents,
      MockStreamHandler.inline(
        onListen: (arguments, events) {},
        onCancel: (arguments) {},
      ),
    );
  });

  tearDownAll(() {
    HttpOverrides.global = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorage, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockStreamHandler(transferEvents, null);
  });

  Device recipient() => Device(
        id: 'widget-recipient',
        name: 'Widget Recipient',
        platform: DevicePlatform.windows,
        ipAddress: '127.0.0.1',
        port: 18766,
        lastSeen: DateTime.now(),
      );

  /// Bounded pump: pumpAndSettle hangs on screens that show an indefinitely
  /// animating progress indicator.
  Future<void> settle(WidgetTester tester,
      {Duration duration = const Duration(milliseconds: 300)}) async {
    await tester.pump();
    await tester.pump(duration);
  }

  testWidgets('cancelled transfer shows Done + Cancelled badge',
      (tester) async {
    final service = TransferService(FileService());
    await tester.runAsync(() async {
      await service.initialize();
      await service.startServer(18766);

      final socket = await Socket.connect('127.0.0.1', 18766);
      final body = jsonEncode({
        'id': 'widget-cancel-1',
        'senderId': 'widget-sender',
        'senderName': 'Widget Sender',
        'senderToken': 'widget-token',
        'receiverId': 'this-device',
        'items': [
          {'name': 'w.bin', 'size': 100}
        ],
      });
      socket.write('POST /transfer/initiate HTTP/1.1\r\n'
          'Host: 127.0.0.1:18766\r\n'
          'Content-Type: application/json\r\n'
          'x-device-id: widget-sender\r\n'
          'Content-Length: ${utf8.encode(body).length}\r\n'
          'Connection: close\r\n'
          '\r\n'
          '$body');
      await socket.cast<List<int>>().transform(utf8.decoder).join();
      await socket.close();
    });

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          transferServiceProvider.overrideWithValue(service),
        ],
        child: MaterialApp(
          home: MultiTransferProgressScreen(
            transferIds: const ['widget-cancel-1'],
            recipients: [recipient()],
            items: const [
              TransferItem(name: 'w.bin', path: '', size: 100),
            ],
          ),
        ),
      ),
    );

    // Approve (sequential path is pure microtasks — safe under fake async).
    await tester.runAsync(() => service.approveTransfer('widget-cancel-1'));
    await settle(tester);
    expect(find.text('Sending...'), findsOneWidget);

    // Cancel the transfer: it must flip the screen to done, not leave it
    // stuck (the Phase-2 bug: cancelled was never counted as completed).
    service.cancelTransfer('widget-cancel-1');
    await settle(tester);

    // The badge and the per-recipient card both read "Cancelled".
    expect(find.text('Cancelled'), findsNWidgets(2));
    expect(find.text('Done'), findsOneWidget);
    expect(find.text('Sending...'), findsNothing);

    await tester.runAsync(service.dispose);
  });
}