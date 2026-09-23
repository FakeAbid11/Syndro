import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/core/services/update_service.dart';
import 'package:syndro/core/widgets/update_dialog.dart';

void main() {
  const info = UpdateInfo(
    version: '2.0.0',
    releaseUrl: 'https://github.com/FakeAbid11/Syndro/releases/tag/v2.0.0',
    notes: 'Bug fixes and performance improvements.',
    assetUrl: 'https://example.com/Syndro-Setup-2.0.0.exe',
    assetName: 'Syndro-Setup-2.0.0.exe',
    assetSize: 12345,
  );

  const verifiedInfo = UpdateInfo(
    version: '2.0.0',
    releaseUrl: 'https://github.com/FakeAbid11/Syndro/releases/tag/v2.0.0',
    notes: 'Bug fixes and performance improvements.',
    assetUrl: 'https://example.com/Syndro-Setup-2.0.0.exe',
    assetName: 'Syndro-Setup-2.0.0.exe',
    assetSize: 12345,
    trustedSha256:
        '2222222222222222222222222222222222222222222222222222222222222222',
    manifestSize: 12345,
  );

  Future<void> pumpDialog(
    WidgetTester tester, {
    bool? useInstaller,
    bool allowSkip = false,
    UpdateInfo info = verifiedInfo,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () => showUpdateDialog(
                context,
                info,
                allowSkip: allowSkip,
                useInstaller: useInstaller,
              ),
              child: const Text('check'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('check'));
    await tester.pumpAndSettle();
  }

  testWidgets('an unverifiable release is never offered for in-app install',
      (tester) async {
    // The derived default: no trusted digest, so the app must fall back to the
    // browser regardless of platform. `info` above has no trustedSha256.
    await pumpDialog(tester, info: info);

    expect(find.text('Update now'), findsNothing);
    expect(find.text('Download'), findsOneWidget);
  });

  testWidgets('mentions signature checking when the in-app path is offered',
      (tester) async {
    await pumpDialog(tester, useInstaller: true);

    expect(
      find.text('The installer is checked against Syndro\'s published '
          'signature before it runs.'),
      findsOneWidget,
    );
  });

  testWidgets('shows Update now on Windows with an installer asset',
      (tester) async {
    await pumpDialog(tester, useInstaller: true);

    expect(find.text('Update available — v2.0.0'), findsOneWidget);
    expect(find.text('Update now'), findsOneWidget);
    expect(find.text('Download'), findsNothing);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('falls back to browser Download when no installer is used',
      (tester) async {
    await pumpDialog(tester, useInstaller: false);

    expect(find.text('Download'), findsOneWidget);
    expect(find.text('Update now'), findsNothing);
    expect(find.text('Later'), findsOneWidget);
  });

  testWidgets('shows Skip this version only when allowSkip is set',
      (tester) async {
    await pumpDialog(tester, useInstaller: true, allowSkip: true);
    expect(find.text('Skip this version'), findsOneWidget);

    await tester.tap(find.text('Later'));
    await tester.pumpAndSettle();
    expect(find.text('Update available — v2.0.0'), findsNothing);
  });

  testWidgets('renders the release notes', (tester) async {
    await pumpDialog(tester, useInstaller: true);
    expect(find.text("What's new"), findsOneWidget);
    expect(
      find.text('Bug fixes and performance improvements.'),
      findsOneWidget,
    );
  });
}