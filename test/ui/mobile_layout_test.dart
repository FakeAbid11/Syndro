import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/models/device.dart';
import 'package:syndro/ui/screens/home/home_mobile.dart';
import 'package:syndro/ui/widgets/device_card.dart';

import 'harness.dart';

/// Android-side layout contract.
///
/// `MainNavigationScreen` chooses its shell from `dart:io Platform`, which a
/// test running on Windows cannot flip — so the mobile home layout is pumped
/// directly here. It is the same widget the phone renders, with the same
/// provider overrides, so an overflow on 412x915 fails the build.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installUiChannelStubs);
  tearDown(uninstallUiChannelStubs);

  Widget mobileHome(List<Device> devices, {Device? selected}) {
    return HomeMobileLayout(
      currentDevice: testDevice(id: 'self', name: "Abid's Laptop"),
      discoveredDevicesAsync: AsyncValue<List<Device>>.data(devices),
      selectedDevice: selected,
      isInitialized: true,
      isRefreshing: false,
      selectedDevices: const {},
      onRefresh: () async {},
      onOpenShareDialog: () {},
      onTextCompose: (_) {},
      onSendFiles: (_) {},
      onSendToMultiple: (_) {},
      onClearMultiSelect: () {},
    );
  }

  for (final window in mobileWindows) {
    testWidgets('mobile home renders clean at ${window.label}',
        (tester) async {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        mobileHome(twoDevices, selected: twoDevices.first),
        overrides: staticNetwork(),
      );
    });

    testWidgets('mobile home renders clean with no devices at ${window.label}',
        (tester) async {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        mobileHome(const []),
        overrides: staticNetwork(),
      );
    });

    testWidgets('a peer name cannot break ${window.label}', (tester) async {
      // Device names come from the network, so the UI has to survive anything
      // a stranger broadcasts.
      final hostile = [
        testDevice(
          id: 'long',
          name: 'A really long broadcast device name that keeps going on',
          ip: '192.168.31.200',
        ),
      ];
      await pumpAndExpectCleanLayout(
        tester,
        window,
        mobileHome(hostile, selected: hostile.first),
        overrides: staticNetwork(),
      );
    });
  }

  testWidgets('DeviceCard renders offline peers without overflowing',
      (tester) async {
    for (final window in [...mobileWindows, ...desktopWindows]) {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        Center(
          child: SizedBox(
            width: window.size.width > 600 ? 300 : 260,
            child: DeviceCard(
              device: testDevice(
                id: 'off',
                name: 'Kitchen Display',
                platform: DevicePlatform.linux,
                ip: '10.0.0.24',
                online: false,
              ),
            ),
          ),
        ),
      );
    }
  });

  testWidgets('DeviceCard says Offline in words, not only in colour',
      (tester) async {
    await pumpAndExpectCleanLayout(
      tester,
      desktopWindows[1],
      DeviceCard(
        device: testDevice(id: 'off', name: 'Kitchen Display', online: false),
      ),
    );
    expect(find.text('Offline'), findsOneWidget);
  });
}
