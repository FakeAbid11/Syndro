import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/ui/screens/browser_receive_screen.dart';

import 'harness.dart';

/// Layout contract for the browser receive screen.
///
/// This screen had no test at all: at 1,600 lines it is one of the largest
/// files in the app, and nothing ever rendered it, so an overflow could not fail
/// a build. It is also the screen that owns the upload-approval prompt added
/// alongside the receive flow, so the prompt's two presentations (mobile sheet,
/// desktop dialog) are worth pumping here too.
///
/// The screen takes an optional `WebShareService`; this exercises the default
/// construction path, which is what production uses.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installUiChannelStubs);
  tearDown(uninstallUiChannelStubs);

  for (final window in [...desktopWindows, ...mobileWindows]) {
    testWidgets('receive screen renders clean at ${window.label}',
        (tester) async {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        const MaterialApp(home: BrowserReceiveScreen()),
      );
    });
  }

  testWidgets('receive screen survives a large text scale', (tester) async {
    // Settings offers no text-size control today, but Android users can set a
    // system font scale, and this screen stacks a QR code, a monospace URL and
    // a file list in one scroll view.
    await pumpAndExpectCleanLayout(
      tester,
      desktopWindows.first,
      const MaterialApp(home: BrowserReceiveScreen()),
      textScale: 1.4,
    );
  });
}
