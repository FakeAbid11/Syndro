import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:syndro/ui/theme/app_theme.dart';

void main() {
  tearDown(() {
    // Restore the default (dark) palette so other tests are unaffected.
    AppTheme.applyMode(ThemeMode.dark);
  });

  group('AppTheme.applyMode', () {
    test('swaps the legacy palette between dark and light', () {
      AppTheme.applyMode(ThemeMode.dark);
      expect(AppTheme.isDarkActive, isTrue);
      expect(AppTheme.textPrimary, const Color(0xFFF8FAFC));
      expect(AppTheme.textSecondary, const Color(0xFFCBD5E1));
      expect(AppTheme.surfaceColor, const Color(0xFF141420));
      expect(AppTheme.backgroundGradient.colors.first,
          const Color(0xFF0A0A0F));

      AppTheme.applyMode(ThemeMode.light);
      expect(AppTheme.isDarkActive, isFalse);
      expect(AppTheme.textPrimary, const Color(0xFF0F172A));
      expect(AppTheme.textSecondary, const Color(0xFF334155));
      expect(AppTheme.textTertiary, const Color(0xFF64748B));
      expect(AppTheme.surfaceColor, const Color(0xFFFFFFFF));
      expect(AppTheme.backgroundColor, const Color(0xFFF6F7FB));
      expect(AppTheme.cardColor, const Color(0xFFF1F3F9));
      expect(AppTheme.borderColor, const Color(0xFFE2E8F0));
      expect(AppTheme.primaryContainer, const Color(0xFFE4DBFF));
      expect(AppTheme.onPrimaryContainer, const Color(0xFF3B2A75));
      expect(AppTheme.surfaceContainerHigh, const Color(0xFFE9EDF5));
      expect(AppTheme.backgroundGradient.colors.first,
          const Color(0xFFF6F7FB));
    });

    test('ThemeMode.system resolves the platform brightness', () {
      final platformDark =
          PlatformDispatcher.instance.platformBrightness == Brightness.dark;
      AppTheme.applyMode(ThemeMode.system);
      expect(AppTheme.isDarkActive, platformDark);
    });
  });

  group('ThemeData', () {
    testWidgets('light theme renders light surfaces and readable text',
        (tester) async {
      AppTheme.applyMode(ThemeMode.light);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.lightTheme,
        home: Scaffold(
          body: Text(
            'Hello',
            style: TextStyle(color: AppTheme.textPrimary),
          ),
        ),
      ));

      final context = tester.element(find.byType(Scaffold));
      final theme = Theme.of(context);
      expect(theme.brightness, Brightness.light);
      expect(theme.scaffoldBackgroundColor, const Color(0xFFF6F7FB));
      expect(theme.colorScheme.surface, const Color(0xFFFFFFFF));
      expect(theme.colorScheme.onSurface, const Color(0xFF0F172A));
      expect(theme.colorScheme.surfaceContainerHigh, const Color(0xFFE9EDF5));
      expect(theme.colorScheme.primaryContainer, const Color(0xFFE4DBFF));
      expect(theme.textTheme.bodyLarge!.color, const Color(0xFF334155));
      expect(theme.appBarTheme.iconTheme!.color, const Color(0xFF0F172A));
      expect(theme.snackBarTheme.backgroundColor,
          const Color(0xFFE2E8F0));

      final text = tester.widget<Text>(find.text('Hello'));
      expect(text.style!.color, const Color(0xFF0F172A));
    });

    testWidgets('dark theme keeps the dark palette', (tester) async {
      AppTheme.applyMode(ThemeMode.dark);
      await tester.pumpWidget(MaterialApp(
        theme: AppTheme.darkTheme,
        home: const Scaffold(body: SizedBox()),
      ));

      final context = tester.element(find.byType(Scaffold));
      final theme = Theme.of(context);
      expect(theme.brightness, Brightness.dark);
      expect(theme.scaffoldBackgroundColor, const Color(0xFF0A0A0F));
      expect(theme.colorScheme.surface, const Color(0xFF141420));
      expect(theme.colorScheme.onSurface, const Color(0xFFF8FAFC));
      expect(theme.colorScheme.primaryContainer, const Color(0xFF2A2350));
      expect(theme.textTheme.bodyLarge!.color, const Color(0xFFCBD5E1));
      expect(theme.appBarTheme.iconTheme!.color, const Color(0xFFF8FAFC));
      expect(theme.snackBarTheme.backgroundColor, const Color(0xFF2A2A3C));
    });
  });
}