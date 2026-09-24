import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'harness.dart';

/// Screenshots of the desktop shell, for human review only.
///
/// This machine cannot build the Windows target, so a rasterised widget tree is
/// the only way to actually look at the redesign. Skipped unless
/// `SYNDRO_GOLDENS=1`, because the PNGs are rendered with the test toolchain's
/// font and reviewed by hand — committing them would make CI on Linux and macOS
/// fail over pixel differences that mean nothing.
///
///     SYNDRO_GOLDENS=1 flutter test test/ui/desktop_goldens_test.dart --update-goldens
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final enabled = Platform.environment['SYNDRO_GOLDENS'] == '1';

  setUp(installUiChannelStubs);
  tearDown(uninstallUiChannelStubs);  for (final window in desktopWindows) {
    for (final theme in [Brightness.dark, Brightness.light]) {
      final slug = window.label.split(' ').first;
      testWidgets(
        'capture ${window.label} ${theme.name}',
        (tester) async {
          await pumpShellForScreenshot(
            tester,
            window,
            brightness: theme,
            overrides: [...staticNetwork(), ...seededHistory()],
          );
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/desktop_${slug}_${theme.name}.png'),
          );
        },
        skip: !enabled,
      );
    }
  }

  testWidgets('capture the empty network state', (tester) async {
    await pumpShellForScreenshot(
      tester,
      desktopWindows[1],
      overrides: [...staticNetwork(devices: const []), ...seededHistory()],
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_empty_network.png'),
    );
  }, skip: !enabled);

  testWidgets('capture long broadcast device names', (tester) async {
    final loud = [
      testDevice(
        id: 'self',
        name: "Abid's Laptop",
        ip: '192.168.178.24',
      ),
      testDevice(
        id: 'loud',
        name: 'Acer Nitro 5 AN515-57 Gaming Rig (2)',
        ip: '192.168.178.129',
      ),
    ];
    await pumpShellForScreenshot(
      tester,
      desktopWindows[1],
      overrides: [
        ...staticNetwork(devices: loud, selected: loud.last),
        ...seededHistory(),
      ],
    );
    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/desktop_long_names.png'),
    );
  }, skip: !enabled);

  testWidgets('capture History and Settings', (tester) async {
    const tabs = {
      'history': Icons.history_outlined,
      'settings': Icons.settings_outlined,
    };
    for (final entry in tabs.entries) {
      await pumpShellForScreenshot(
        tester,
        desktopWindows[1],
        overrides: [...staticNetwork(), ...seededHistory()],
        interact: (t) async => t.tap(find.byIcon(entry.value)),
      );
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/desktop_tab_${entry.key}.png'),
      );
    }
  }, skip: !enabled);
}
