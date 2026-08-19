import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app_dimens.dart';

class AppTheme {
  // Primary Colors (Matching Logo Gradient)
  static const Color primaryColor = Color(0xFF7B5EF2); // Purple from logo
  static const Color secondaryColor = Color(0xFF5B8DEF); // Blue from logo
  static const Color accentColor = Color(0xFF06B6D4); // Cyan for highlights

  // Status Colors (same in both modes)
  static const Color successColor = Color(0xFF22C55E); // Green
  static const Color errorColor = Color(0xFFEF4444); // Red
  static const Color warningColor = Color(0xFFF59E0B); // Amber

  // ────────────────────────────────────────────────────────────────────
  // Dark palette (default)
  // ────────────────────────────────────────────────────────────────────
  static const Color _darkBackground = Color(0xFF0A0A0F); // Near black
  static const Color _darkSurface = Color(0xFF141420); // Dark purple-gray
  static const Color _darkCard = Color(0xFF1E1E2E); // Card background

  static const Color _darkTextPrimary = Color(0xFFF8FAFC); // White
  static const Color _darkTextSecondary = Color(0xFFCBD5E1); // Light gray
  static const Color _darkTextTertiary = Color(0xFF94A3B8); // Muted gray
  static const Color _darkBorder = Color(0xFF2D2D3D); // Subtle border

  // Material 3 tonal surfaces (dark purple-gray family).
  static const Color _darkSurfaceContainerLowest = Color(0xFF08080C);
  static const Color _darkSurfaceContainerLow = Color(0xFF141420);
  static const Color _darkSurfaceContainer = Color(0xFF1A1A28);
  static const Color _darkSurfaceContainerHigh = Color(0xFF232334);
  static const Color _darkSurfaceContainerHighest = Color(0xFF2A2A3C);
  static const Color _darkOutlineVariant = Color(0xFF24242F);

  // Tonal "container" roles for the brand colors (dark-tinted backgrounds
  // with light foregrounds).
  static const Color _darkPrimaryContainer = Color(0xFF2A2350);
  static const Color _darkOnPrimaryContainer = Color(0xFFD9CCFF);
  static const Color _darkSecondaryContainer = Color(0xFF1E2E4D);
  static const Color _darkOnSecondaryContainer = Color(0xFFCBDCFF);
  static const Color _darkTertiaryContainer = Color(0xFF06333B);
  static const Color _darkOnTertiaryContainer = Color(0xFF9FEAF5);
  static const Color _darkErrorContainer = Color(0xFF4A1D1D);
  static const Color _darkOnErrorContainer = Color(0xFFFFD6D6);

  // ────────────────────────────────────────────────────────────────────
  // Light palette
  // ────────────────────────────────────────────────────────────────────
  static const Color _lightBackground = Color(0xFFF6F7FB); // Soft blue-gray
  static const Color _lightSurface = Color(0xFFFFFFFF); // White
  static const Color _lightCard = Color(0xFFF1F3F9); // Card background

  static const Color _lightTextPrimary = Color(0xFF0F172A); // Slate-900
  static const Color _lightTextSecondary = Color(0xFF334155); // Slate-700
  static const Color _lightTextTertiary = Color(0xFF64748B); // Slate-500
  static const Color _lightBorder = Color(0xFFE2E8F0); // Subtle border

  // Material 3 tonal surfaces (light slate family).
  static const Color _lightSurfaceContainerLowest = Color(0xFFFFFFFF);
  static const Color _lightSurfaceContainerLow = Color(0xFFF8FAFC);
  static const Color _lightSurfaceContainer = Color(0xFFF1F5F9);
  static const Color _lightSurfaceContainerHigh = Color(0xFFE9EDF5);
  static const Color _lightSurfaceContainerHighest = Color(0xFFE2E8F0);
  static const Color _lightOutlineVariant = Color(0xFFE2E8F0);

  // Tonal "container" roles for the brand colors (light-tinted backgrounds
  // with dark foregrounds).
  static const Color _lightPrimaryContainer = Color(0xFFE4DBFF);
  static const Color _lightOnPrimaryContainer = Color(0xFF3B2A75);
  static const Color _lightSecondaryContainer = Color(0xFFD8E4FF);
  static const Color _lightOnSecondaryContainer = Color(0xFF1E3A5F);
  static const Color _lightTertiaryContainer = Color(0xFFC9F0F5);
  static const Color _lightOnTertiaryContainer = Color(0xFF044A54);
  static const Color _lightErrorContainer = Color(0xFFFFDADA);
  static const Color _lightOnErrorContainer = Color(0xFF7F1D1D);

  // ────────────────────────────────────────────────────────────────────
  // Active palette — swapped by [applyMode]. Defaults to dark. These are the
  // non-const tokens referenced by the (legacy) hardcoded call sites across
  // the UI; keeping the same names means those call sites are theme-aware
  // once [applyMode] has run, without threading BuildContext everywhere.
  // ────────────────────────────────────────────────────────────────────
  static Color backgroundColor = _darkBackground;
  static Color surfaceColor = _darkSurface;
  static Color cardColor = _darkCard;

  static Color textPrimary = _darkTextPrimary;
  static Color textSecondary = _darkTextSecondary;
  static Color textTertiary = _darkTextTertiary;
  static Color borderColor = _darkBorder;

  static Color surfaceContainerLowest = _darkSurfaceContainerLowest;
  static Color surfaceContainerLow = _darkSurfaceContainerLow;
  static Color surfaceContainer = _darkSurfaceContainer;
  static Color surfaceContainerHigh = _darkSurfaceContainerHigh;
  static Color surfaceContainerHighest = _darkSurfaceContainerHighest;
  static Color outlineVariant = _darkOutlineVariant;

  static Color primaryContainer = _darkPrimaryContainer;
  static Color onPrimaryContainer = _darkOnPrimaryContainer;
  static Color secondaryContainer = _darkSecondaryContainer;
  static Color onSecondaryContainer = _darkOnSecondaryContainer;
  static Color tertiaryContainer = _darkTertiaryContainer;
  static Color onTertiaryContainer = _darkOnTertiaryContainer;
  static Color errorContainer = _darkErrorContainer;
  static Color onErrorContainer = _darkOnErrorContainer;

  static const LinearGradient _darkBackgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFF0A0A0F),
      Color(0xFF141420),
      Color(0xFF1E1E2E),
    ],
  );

  static const LinearGradient _lightBackgroundGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [
      Color(0xFFF6F7FB),
      Color(0xFFFFFFFF),
      Color(0xFFEDF0F7),
    ],
  );

  /// Whether the active palette is the dark one.
  static bool get isDarkActive => backgroundColor == _darkBackground;

  /// Swap the active palette to match [mode]. Resolves `ThemeMode.system`
  /// from the platform's current brightness. Call before building the widget
  /// tree so hardcoded call sites render the correct colors.
  static void applyMode(ThemeMode mode) {
    final dark = mode == ThemeMode.dark ||
        (mode == ThemeMode.system &&
            PlatformDispatcher.instance.platformBrightness == Brightness.dark);

    backgroundColor = dark ? _darkBackground : _lightBackground;
    surfaceColor = dark ? _darkSurface : _lightSurface;
    cardColor = dark ? _darkCard : _lightCard;

    textPrimary = dark ? _darkTextPrimary : _lightTextPrimary;
    textSecondary = dark ? _darkTextSecondary : _lightTextSecondary;
    textTertiary = dark ? _darkTextTertiary : _lightTextTertiary;
    borderColor = dark ? _darkBorder : _lightBorder;

    surfaceContainerLowest =
        dark ? _darkSurfaceContainerLowest : _lightSurfaceContainerLowest;
    surfaceContainerLow =
        dark ? _darkSurfaceContainerLow : _lightSurfaceContainerLow;
    surfaceContainer = dark ? _darkSurfaceContainer : _lightSurfaceContainer;
    surfaceContainerHigh =
        dark ? _darkSurfaceContainerHigh : _lightSurfaceContainerHigh;
    surfaceContainerHighest =
        dark ? _darkSurfaceContainerHighest : _lightSurfaceContainerHighest;
    outlineVariant = dark ? _darkOutlineVariant : _lightOutlineVariant;

    primaryContainer = dark ? _darkPrimaryContainer : _lightPrimaryContainer;
    onPrimaryContainer =
        dark ? _darkOnPrimaryContainer : _lightOnPrimaryContainer;
    secondaryContainer =
        dark ? _darkSecondaryContainer : _lightSecondaryContainer;
    onSecondaryContainer =
        dark ? _darkOnSecondaryContainer : _lightOnSecondaryContainer;
    tertiaryContainer =
        dark ? _darkTertiaryContainer : _lightTertiaryContainer;
    onTertiaryContainer =
        dark ? _darkOnTertiaryContainer : _lightOnTertiaryContainer;
    errorContainer = dark ? _darkErrorContainer : _lightErrorContainer;
    onErrorContainer = dark ? _darkOnErrorContainer : _lightOnErrorContainer;
  }

  // ────────────────────────────────────────────────────────────────────
  // ThemeData
  // ────────────────────────────────────────────────────────────────────
  static ThemeData get darkTheme {
    return _buildTheme(
      brightness: Brightness.dark,
      scaffold: _darkBackground,
      surface: _darkSurface,
      card: _darkCard,
      textPrimary: _darkTextPrimary,
      textSecondary: _darkTextSecondary,
      textTertiary: _darkTextTertiary,
      border: _darkBorder,
      containerLowest: _darkSurfaceContainerLowest,
      containerLow: _darkSurfaceContainerLow,
      container: _darkSurfaceContainer,
      containerHigh: _darkSurfaceContainerHigh,
      containerHighest: _darkSurfaceContainerHighest,
      outlineVariant: _darkOutlineVariant,
      primaryContainer: _darkPrimaryContainer,
      onPrimaryContainer: _darkOnPrimaryContainer,
      secondaryContainer: _darkSecondaryContainer,
      onSecondaryContainer: _darkOnSecondaryContainer,
      tertiaryContainer: _darkTertiaryContainer,
      onTertiaryContainer: _darkOnTertiaryContainer,
      errorContainer: _darkErrorContainer,
      onErrorContainer: _darkOnErrorContainer,
    );
  }

  /// Light theme — full mirror of [darkTheme] with the light palette.
  static ThemeData get lightTheme {
    return _buildTheme(
      brightness: Brightness.light,
      scaffold: _lightBackground,
      surface: _lightSurface,
      card: _lightCard,
      textPrimary: _lightTextPrimary,
      textSecondary: _lightTextSecondary,
      textTertiary: _lightTextTertiary,
      border: _lightBorder,
      containerLowest: _lightSurfaceContainerLowest,
      containerLow: _lightSurfaceContainerLow,
      container: _lightSurfaceContainer,
      containerHigh: _lightSurfaceContainerHigh,
      containerHighest: _lightSurfaceContainerHighest,
      outlineVariant: _lightOutlineVariant,
      primaryContainer: _lightPrimaryContainer,
      onPrimaryContainer: _lightOnPrimaryContainer,
      secondaryContainer: _lightSecondaryContainer,
      onSecondaryContainer: _lightOnSecondaryContainer,
      tertiaryContainer: _lightTertiaryContainer,
      onTertiaryContainer: _lightOnTertiaryContainer,
      errorContainer: _lightErrorContainer,
      onErrorContainer: _lightOnErrorContainer,
    );
  }

  static ThemeData _buildTheme({
    required Brightness brightness,
    required Color scaffold,
    required Color surface,
    required Color card,
    required Color textPrimary,
    required Color textSecondary,
    required Color textTertiary,
    required Color border,
    required Color containerLowest,
    required Color containerLow,
    required Color container,
    required Color containerHigh,
    required Color containerHighest,
    required Color outlineVariant,
    required Color primaryContainer,
    required Color onPrimaryContainer,
    required Color secondaryContainer,
    required Color onSecondaryContainer,
    required Color tertiaryContainer,
    required Color onTertiaryContainer,
    required Color errorContainer,
    required Color onErrorContainer,
  }) {
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: primaryColor,
        onPrimary: Colors.white,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondaryColor,
        onSecondary: Colors.white,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        tertiary: accentColor,
        onTertiary: const Color(0xFF00272E),
        tertiaryContainer: tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer,
        error: errorColor,
        onError: Colors.white,
        errorContainer: errorContainer,
        onErrorContainer: onErrorContainer,
        surface: surface,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        surfaceContainerLowest: containerLowest,
        surfaceContainerLow: containerLow,
        surfaceContainer: container,
        surfaceContainerHigh: containerHigh,
        surfaceContainerHighest: containerHighest,
        surfaceTint: primaryColor,
        outline: border,
        outlineVariant: outlineVariant,
        inverseSurface: textPrimary,
        onInverseSurface: scaffold,
        shadow: Colors.black,
        scrim: Colors.black,
      ),
      scaffoldBackgroundColor: scaffold,
      splashFactory: InkSparkle.splashFactory,

      // AppBar Theme — transparent so the scaffold gradient shows through.
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 22,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.2,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),

      // Card Theme — tonal surface, clipped, gentle radius (M3).
      cardTheme: CardThemeData(
        color: container,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        clipBehavior: Clip.antiAlias,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.lgAll,
          side: BorderSide(color: outlineVariant, width: 1),
        ),
      ),

      // Filled Button (primary M3 action).
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),

      // Elevated Button Theme
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Outlined Button Theme
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primaryColor,
          side: BorderSide(color: border, width: 1.5),
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Text Button Theme
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primaryColor,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          shape: const StadiumBorder(),
          textStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),

      // Floating Action Button Theme
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: primaryColor,
        foregroundColor: Colors.white,
        elevation: 3,
        highlightElevation: 6,
        shape: RoundedRectangleBorder(borderRadius: AppRadius.lgAll),
        extendedTextStyle: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),

      // ListTile
      listTileTheme: ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
        contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),

      // Icon Theme
      iconTheme: IconThemeData(
        color: textSecondary,
        size: 24,
      ),

      // Text Theme (Material 3 scale)
      textTheme: TextTheme(
        displayLarge: TextStyle(
          color: textPrimary,
          fontSize: 34,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.5,
        ),
        displayMedium: TextStyle(
          color: textPrimary,
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.4,
        ),
        displaySmall: TextStyle(
          color: textPrimary,
          fontSize: 24,
          fontWeight: FontWeight.w700,
          letterSpacing: -0.3,
        ),
        headlineMedium: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
        headlineSmall: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        titleLarge: TextStyle(
          color: textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
        titleMedium: TextStyle(
          color: textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.w600,
        ),
        titleSmall: TextStyle(
          color: textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        bodyLarge: TextStyle(
          color: textSecondary,
          fontSize: 15,
          height: 1.4,
        ),
        bodyMedium: TextStyle(
          color: textSecondary,
          fontSize: 14,
          height: 1.4,
        ),
        bodySmall: TextStyle(
          color: textTertiary,
          fontSize: 12,
          height: 1.35,
        ),
        labelLarge: TextStyle(
          color: textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        labelMedium: TextStyle(
          color: textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
        ),
        labelSmall: TextStyle(
          color: textTertiary,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
        ),
      ),

      // Input Decoration Theme
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: container,
        hintStyle: TextStyle(color: textTertiary),
        border: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: outlineVariant, width: 1),
        ),
        focusedBorder: const OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),

      // Progress Indicator Theme
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: primaryColor,
        linearTrackColor: containerHighest,
        circularTrackColor: containerHighest,
        linearMinHeight: 6,
      ),

      // Snackbar Theme
      snackBarTheme: SnackBarThemeData(
        backgroundColor: containerHighest,
        contentTextStyle: TextStyle(color: textPrimary),
        actionTextColor: primaryColor,
        elevation: 4,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: border,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
      ),

      // Dialog Theme
      dialogTheme: DialogThemeData(
        backgroundColor: containerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: const RoundedRectangleBorder(
          borderRadius: AppRadius.xlAll,
        ),
      ),

      // Divider Theme
      dividerTheme: DividerThemeData(
        color: outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // Chip Theme
      chipTheme: ChipThemeData(
        backgroundColor: container,
        selectedColor: primaryContainer,
        secondarySelectedColor: primaryContainer,
        checkmarkColor: onPrimaryContainer,
        labelStyle: TextStyle(
            color: textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
        side: BorderSide(color: outlineVariant, width: 1),
        shape: const StadiumBorder(),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),

      // Tooltip
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: containerHighest,
          borderRadius: AppRadius.smAll,
        ),
        textStyle: TextStyle(color: textPrimary, fontSize: 12),
      ),

      // Segmented button (used for mode pickers)
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: ButtonStyle(
          backgroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return primaryContainer;
            return Colors.transparent;
          }),
          foregroundColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) return onPrimaryContainer;
            return textSecondary;
          }),
          side: WidgetStateProperty.all(BorderSide(color: outlineVariant, width: 1)),
        ),
      ),

      // Switch Theme
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return textTertiary;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor.withValues(alpha: 0.5);
          }
          return card;
        }),
      ),

      // Checkbox Theme
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return Colors.transparent;
        }),
        checkColor: WidgetStateProperty.all(Colors.white),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(4),
        ),
      ),

      // Radio Theme
      radioTheme: RadioThemeData(
        fillColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return primaryColor;
          }
          return textTertiary;
        }),
      ),

      // Slider Theme
      sliderTheme: SliderThemeData(
        activeTrackColor: primaryColor,
        inactiveTrackColor: card,
        thumbColor: primaryColor,
        overlayColor: primaryColor.withValues(alpha: 0.2),
      ),

      // Navigation Bar Theme (Android / mobile)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: container,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primaryContainer,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: AppRadius.pillAll,
        ),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return IconThemeData(color: onPrimaryContainer, size: 24);
          }
          return IconThemeData(color: textTertiary, size: 24);
        }),
        labelTextStyle: WidgetStateProperty.resolveWith((states) {
          final selected = states.contains(WidgetState.selected);
          return TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? textPrimary : textTertiary,
          );
        }),
      ),

      // Navigation Rail Theme (Desktop)
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: containerLow,
        selectedIconTheme: IconThemeData(color: onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: textTertiary),
        selectedLabelTextStyle: TextStyle(
            color: textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
        unselectedLabelTextStyle: TextStyle(color: textTertiary, fontSize: 13),
        indicatorColor: primaryContainer,
        indicatorShape: const RoundedRectangleBorder(
          borderRadius: AppRadius.pillAll,
        ),
        useIndicator: true,
      ),
    );
  }

  // Glassmorphism effect
  static BoxDecoration glassmorphicDecoration({
    Color? color,
    double blur = 10,
    double opacity = 0.1,
  }) {
    return BoxDecoration(
      color: (color ?? Colors.white).withValues(alpha: opacity),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: Colors.white.withValues(alpha: 0.1),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: blur,
          offset: const Offset(0, 4),
        ),
      ],
    );
  }

  // Gradient background (follows the active palette)
  static LinearGradient get backgroundGradient {
    return isDarkActive ? _darkBackgroundGradient : _lightBackgroundGradient;
  }

  // Logo gradient
  static LinearGradient get logoGradient {
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF5B8DEF),
        Color(0xFF7B5EF2),
      ],
    );
  }

  // Primary button gradient
  static LinearGradient get primaryGradient {
    return const LinearGradient(
      begin: Alignment.centerLeft,
      end: Alignment.centerRight,
      colors: [
        Color(0xFF5B8DEF),
        Color(0xFF7B5EF2),
      ],
    );
  }

  // Gradient text style helper
  static ShaderCallback get gradientShader {
    return (bounds) => logoGradient.createShader(
          Rect.fromLTWH(0, 0, bounds.width, bounds.height),
        );
  }
}