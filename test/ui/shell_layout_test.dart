import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/ui/screens/main_navigation_screen.dart';

import 'harness.dart';

/// Layout-contract tests for the whole app shell.
///
/// Neither the Windows nor the Android target can be built or run on this
/// machine, so these are the substitute for "open the app and look": the real
/// `MainNavigationScreen` is pumped at each window size the design has to
/// support, and any framework-reported layout error (overflow, unbounded
/// constraints) fails the test. See [LayoutErrorRecorder] for why the check is
/// not `tester.takeException()`.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installUiChannelStubs);
  tearDown(uninstallUiChannelStubs);

  Future<void> shellAt(WidgetTester tester, WindowSize window,
          {Future<void> Function(WidgetTester)? interact}) =>
      pumpAndExpectCleanLayout(
        tester,
        window,
        const MainNavigationScreen(),
        overrides: [...staticNetwork(), ...seededHistory()],
        interact: interact,
      );

  testWidgets('the layout check is not vacuous: it sees a real overflow',
      (tester) async {
    // Two 90px children in a 120px box: the framework calls this out, so a
    // "renders clean" pass is evidence and not just an absent assertion.
    const deliberatelyBroken = Scaffold(
      body: SizedBox(
        width: 120,
        child: Row(
          children: [
            SizedBox(width: 90, height: 24),
            SizedBox(width: 90, height: 24),
          ],
        ),
      ),
    );

    final messages = await pumpAndCollectLayoutErrors(
      tester,
      desktopWindows.first,
      deliberatelyBroken,
    );
    expect(messages, isNotEmpty,
        reason: 'a screen this obviously overflows must be caught, or every '
            '"renders clean" test below is meaningless');
    expect(messages.first, contains('overflowed'));
  });

  for (final window in desktopWindows) {
    testWidgets('Devices renders clean at ${window.label}', (tester) async {
      var sawRail = false;
      await shellAt(tester, window, interact: (t) async {
        // Guards the whole suite: these tests only mean anything if the
        // desktop branch is what actually rendered.
        sawRail = find.byType(NavigationRail).evaluate().isNotEmpty;
      });
      expect(sawRail, isTrue,
          reason: 'desktop window sizes must render the rail-based shell');
    });

    testWidgets('History renders clean at ${window.label}', (tester) async {
      await shellAt(tester, window, interact: (t) async {
        await t.tap(find.byIcon(Icons.history_outlined));
      });
    });

    testWidgets('Settings renders clean at ${window.label}', (tester) async {
      await shellAt(tester, window, interact: (t) async {
        await t.tap(find.byIcon(Icons.settings_outlined));
      });
    });
  }
}
