import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/core/models/transfer.dart';
import 'package:syndro/core/services/file_service.dart';
import 'package:syndro/core/services/transfer_service/transfer_service_impl.dart';
import 'package:syndro/ui/screens/multi_transfer_progress_screen.dart';
import 'package:syndro/ui/screens/transfer_progress_screen.dart';

import 'harness.dart';

/// Layout contract for the transfer progress UI.
///
/// Driven through a real `TransferService` on loopback rather than a stub, so
/// the screen is opened the way the app opens it: against a transfer the
/// service has actually been offered over HTTP.
///
/// The completed / failed / cancelled / paused cards are not covered here.
/// Reaching them needs a transfer that moves bytes and then stops for a
/// specific reason, and cancelling a request that never started does not
/// exercise the same card as one interrupted mid-flight. The acceptance suite
/// covers those transitions; this file covers layout.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const port = 18901;
  late TransferService service;

  final recipient = testDevice(
    id: 'layout-peer',
    name: 'Layout Peer',
    platform: DevicePlatform.android,
    ip: '127.0.0.1',
  );

  setUpAll(() async {
    installUiChannelStubs();
    service = TransferService(FileService());
    await service.initialize();
    await service.startServer(port);
  });

  tearDownAll(() => service.dispose());

  tearDown(() {
    // A request left pending would raise its approval dialog in the next test.
    for (final pending in service.pendingRequests.toList()) {
      service.rejectTransfer(pending.requestId);
    }
  });

  /// Offers a transfer to the running service over real HTTP.
  ///
  /// Runs inside `tester.runAsync`: the widget-test zone fakes out the event
  /// loop, so a real socket never completes inside it.
  Future<void> offerTransfer(WidgetTester tester, String id) =>
      tester.runAsync(() async {
        final body = jsonEncode({
          'id': id,
          'senderId': 'layout-peer',
          'senderName': 'Layout Peer',
          'senderToken': 'layout-token',
          'receiverId': 'this-device',
          'items': [
            {'name': 'holiday-photos.zip', 'size': 780 * 1024 * 1024},
          ],
        });
        final socket = await Socket.connect('127.0.0.1', port);
        socket.write('POST /transfer/initiate HTTP/1.1\r\n'
            'Host: 127.0.0.1:$port\r\n'
            'Content-Type: application/json\r\n'
            'x-device-id: layout-peer\r\n'
            'Content-Length: ${utf8.encode(body).length}\r\n'
            'Connection: close\r\n'
            '\r\n'
            '$body');
        await socket.cast<List<int>>().transform(utf8.decoder).join();
        await socket.close();
      });

  for (final window in [...desktopWindows, ...mobileWindows]) {
    testWidgets('an incoming transfer opens a clean layout at ${window.label}',
        (tester) async {
      final id = 'layout-${window.label}';
      await offerTransfer(tester, id);
      await pumpAndExpectCleanLayout(
        tester,
        window,
        TransferProgressScreen(
          transferId: id,
          remoteDevice: recipient,
          isSender: false,
          items: const [
            TransferItem(name: 'holiday-photos.zip', path: '', size: 0),
          ],
        ),
        service: service,
      );
      // Guards against a clean render of nothing at all.
      expect(find.byType(TransferProgressScreen), findsOneWidget);
      expect(find.text('Receiving Files'), findsOneWidget);
      expect(find.text('Receiving from'), findsOneWidget);
      expect(find.text('Layout Peer'), findsOneWidget);
      // The screen samples speed once a second; leaving that timer running
      // fails the test, and `flutter_test` checks before it tears the tree down.
      await unmountTree(tester);
    });
  }

  testWidgets('the multi-recipient screen renders clean for an unknown id',
      (tester) async {
    for (final window in desktopWindows) {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        MultiTransferProgressScreen(
          transferIds: const ['never-created'],
          recipients: [recipient],
          items: const [TransferItem(name: 'a.bin', path: '', size: 10)],
        ),
        service: service,
      );
    }
    expect(find.byType(MultiTransferProgressScreen), findsOneWidget);
    await unmountTree(tester);
  });
}
