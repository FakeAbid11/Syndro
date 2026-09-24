import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/ui/screens/main_navigation_screen.dart';
import 'package:syndro/ui/widgets/device_card.dart';
import 'package:syndro/ui/widgets/drop_send_sheet.dart';

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

    testWidgets('the drop confirmation renders clean at ${window.label}',
        (tester) async {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => pickDropRecipients(context, droppedFiles),
                child: const Text('open'),
              ),
            ),
          ),
        ),
        overrides: staticNetwork(),
        interact: (t) async {
          await t.tap(find.text('open'));
        },
      );
      expect(find.text('Send to'), findsOneWidget);
      expect(find.text('2 files selected'), findsOneWidget);
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

  // §12: large system text must not cost the user a control. The framework's
  // test font is already about twice as wide as the real one per glyph, so
  // this is a deliberately harsh version of the accessibility setting rather
  // than a literal 1.3x — a pass here means the layout flexes, and a failure
  // names the row that does not.
  testWidgets('a device card can be focused and activated from the keyboard',
      (tester) async {
    var taps = 0;
    await pumpAndExpectCleanLayout(
      tester,
      desktopWindows[1],
      Center(
        child: SizedBox(
          width: 320,
          child: DeviceCard(
            device: testDevice(),
            onTap: () => taps++,
            onSendFiles: () {},
          ),
        ),
      ),
      interact: (t) async {
        // Tab from nowhere rather than grabbing the node directly: the point is
        // that the traversal order reaches the card, which is what a person on
        // a keyboard actually does.
        await t.sendKeyDownEvent(LogicalKeyboardKey.tab);
        await t.pump();
        expect(FocusManager.instance.primaryFocus?.hasFocus, isTrue,
            reason: 'Tab must land somewhere in the card');
        await t.sendKeyEvent(LogicalKeyboardKey.enter);
      },
    );
    expect(taps, 1, reason: 'Enter should activate the card it focuses');
  });

  for (final window in desktopWindows) {
    testWidgets('Devices survives enlarged text at ${window.label}',
        (tester) async {
      await pumpAndExpectCleanLayout(
        tester,
        window,
        const MainNavigationScreen(),
        overrides: [...staticNetwork(), ...seededHistory()],
        textScale: 1.4,
      );
    });
  }
}
