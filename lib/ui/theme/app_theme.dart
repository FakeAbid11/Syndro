import 'package:flutter/material.dart';

import 'app_dimens.dart';

class AppTheme {
  // Primary Colors (Matching Logo Gradient)
  static const Color primaryColor = Color(0xFF7B5EF2); // Purple from logo
  static const Color secondaryColor = Color(0xFF5B8DEF); // Blue from logo
  static const Color accentColor = Color(0xFF06B6D4); // Cyan for highlights

  // Background Colors
  static const Color backgroundColor = Color(0xFF0A0A0F); // Near black
  static const Color surfaceColor = Color(0xFF141420); // Dark purple-gray
  static const Color cardColor = Color(0xFF1E1E2E); // Card background

  // Status Colors
  static const Color successColor = Color(0xFF22C55E); // Green
  static const Color errorColor = Color(0xFFEF4444); // Red
  static const Color warningColor = Color(0xFFF59E0B); // Amber

  // Text Colors
  static const Color textPrimary = Color(0xFFF8FAFC); // White
  static const Color textSecondary = Color(0xFFCBD5E1); // Light gray
  static const Color textTertiary = Color(0xFF94A3B8); // Muted gray

  // ✅ ADD THIS LINE - Border Color (was missing!)
  static const Color borderColor = Color(0xFF2D2D3D); // Subtle border

  // --- Material 3 tonal surfaces (derived from the brand palette) ---
  // A ramp of increasingly light surfaces so M3 components read as layered
  // depth instead of flat panels. Kept on-brand (dark purple-gray family).
  static const Color surfaceContainerLowest = Color(0xFF08080C);
  static const Color surfaceContainerLow = Color(0xFF141420);
  static const Color surfaceContainer = Color(0xFF1A1A28);
  static const Color surfaceContainerHigh = Color(0xFF232334);
  static const Color surfaceContainerHighest = Color(0xFF2A2A3C);
  static const Color outlineVariant = Color(0xFF24242F);

  // Tonal "container" roles for the brand colors (used by chips, badges,
  // tonal buttons, selected states) — muted, dark-tinted backgrounds with
  // light foregrounds.
  static const Color primaryContainer = Color(0xFF2A2350);
  static const Color onPrimaryContainer = Color(0xFFD9CCFF);
  static const Color secondaryContainer = Color(0xFF1E2E4D);
  static const Color onSecondaryContainer = Color(0xFFCBDCFF);
  static const Color tertiaryContainer = Color(0xFF06333B);
  static const Color onTertiaryContainer = Color(0xFF9FEAF5);
  static const Color errorContainer = Color(0xFF4A1D1D);
  static const Color onErrorContainer = Color(0xFFFFD6D6);

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme(
        brightness: Brightness.dark,
        primary: primaryColor,
        onPrimary: Colors.white,
        primaryContainer: primaryContainer,
        onPrimaryContainer: onPrimaryContainer,
        secondary: secondaryColor,
        onSecondary: Colors.white,
        secondaryContainer: secondaryContainer,
        onSecondaryContainer: onSecondaryContainer,
        tertiary: accentColor,
        onTertiary: Color(0xFF00272E),
        tertiaryContainer: tertiaryContainer,
        onTertiaryContainer: onTertiaryContainer,
        error: errorColor,
        onError: Colors.white,
        errorContainer: errorContainer,
        onErrorContainer: onErrorContainer,
        surface: surfaceColor,
        onSurface: textPrimary,
        onSurfaceVariant: textSecondary,
        surfaceContainerLowest: surfaceContainerLowest,
        surfaceContainerLow: surfaceContainerLow,
        surfaceContainer: surfaceContainer,
        surfaceContainerHigh: surfaceContainerHigh,
        surfaceContainerHighest: surfaceContainerHighest,
        surfaceTint: primaryColor,
        outline: borderColor,
        outlineVariant: outlineVariant,
        inverseSurface: textPrimary,
        onInverseSurface: backgroundColor,
        shadow: Colors.black,
        scrim: Colors.black,
      ),
      scaffoldBackgroundColor: backgroundColor,
      splashFactory: InkSparkle.splashFactory,

      // AppBar Theme — transparent so the scaffold gradient shows through;
      // a subtle tint appears once content scrolls under it (M3).
      appBarTheme: const AppBarTheme(
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
      cardTheme: const CardThemeData(
        color: surfaceContainer,
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
          side: const BorderSide(color: borderColor, width: 1.5),
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
        extendedTextStyle:
            TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),

      // ListTile
      listTileTheme: const ListTileThemeData(
        iconColor: textSecondary,
        textColor: textPrimary,
        contentPadding: EdgeInsets.symmetric(horizontal: AppSpacing.lg),
      ),

      // Icon Theme
      iconTheme: const IconThemeData(
        color: textSecondary,
        size: 24,
      ),

      // Text Theme (Material 3 scale)
      textTheme: const TextTheme(
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
      inputDecorationTheme: const InputDecorationTheme(
        filled: true,
        fillColor: surfaceContainer,
        hintStyle: TextStyle(color: textTertiary),
        border: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: outlineVariant, width: 1),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: AppRadius.mdAll,
          borderSide: BorderSide(color: primaryColor, width: 2),
        ),
        contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 16),
      ),

      // Progress Indicator Theme
      progressIndicatorTheme: const ProgressIndicatorThemeData(
        color: primaryColor,
        linearTrackColor: surfaceContainerHighest,
        circularTrackColor: surfaceContainerHighest,
        linearMinHeight: 6,
      ),

      // Snackbar Theme
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: surfaceContainerHighest,
        contentTextStyle: TextStyle(color: textPrimary),
        actionTextColor: primaryColor,
        elevation: 4,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.mdAll,
        ),
        behavior: SnackBarBehavior.floating,
      ),

      // Bottom Sheet Theme
      bottomSheetTheme: const BottomSheetThemeData(
        backgroundColor: surfaceColor,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: borderColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
        ),
      ),

      // Dialog Theme
      dialogTheme: const DialogThemeData(
        backgroundColor: surfaceContainerHigh,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: AppRadius.xlAll,
        ),
      ),

      // Divider Theme
      dividerTheme: const DividerThemeData(
        color: outlineVariant,
        thickness: 1,
        space: 1,
      ),

      // Chip Theme
      chipTheme: const ChipThemeData(
        backgroundColor: surfaceContainer,
        selectedColor: primaryContainer,
        secondarySelectedColor: primaryContainer,
        checkmarkColor: onPrimaryContainer,
        labelStyle: TextStyle(
            color: textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
        side: BorderSide(color: outlineVariant, width: 1),
        shape: StadiumBorder(),
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),

      // Tooltip
      tooltipTheme: const TooltipThemeData(
        decoration: BoxDecoration(
          color: surfaceContainerHighest,
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
          side: WidgetStateProperty.all(
              const BorderSide(color: outlineVariant, width: 1)),
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
          return cardColor;
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
        inactiveTrackColor: cardColor,
        thumbColor: primaryColor,
        overlayColor: primaryColor.withValues(alpha: 0.2),
      ),

      // Navigation Bar Theme (Android / mobile)
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: surfaceContainer,
        surfaceTintColor: Colors.transparent,
        indicatorColor: primaryContainer,
        elevation: 0,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        indicatorShape:
            const RoundedRectangleBorder(borderRadius: AppRadius.pillAll),
        iconTheme: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return const IconThemeData(color: onPrimaryContainer, size: 24);
          }
          return const IconThemeData(color: textTertiary, size: 24);
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
      navigationRailTheme: const NavigationRailThemeData(
        backgroundColor: surfaceContainerLow,
        selectedIconTheme: IconThemeData(color: onPrimaryContainer),
        unselectedIconTheme: IconThemeData(color: textTertiary),
        selectedLabelTextStyle: TextStyle(
            color: textPrimary, fontWeight: FontWeight.w600, fontSize: 13),
        unselectedLabelTextStyle:
            TextStyle(color: textTertiary, fontSize: 13),
        indicatorColor: primaryContainer,
        indicatorShape:
            RoundedRectangleBorder(borderRadius: AppRadius.pillAll),
        useIndicator: true,
      ),
    );
  }

  // Light theme
  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: primaryColor,
        secondary: secondaryColor,
        surface: Color(0xFFF8FAFC),
        error: errorColor,
      ),
      scaffoldBackgroundColor: const Color(0xFFFFFFFF),

      appBarTheme: const AppBarTheme(
        backgroundColor: Color(0xFFFFFFFF),
        elevation: 0,
        centerTitle: true,
        iconTheme: IconThemeData(color: Color(0xFF1E1E2E)),
        titleTextStyle: TextStyle(
          color: Color(0xFF1E1E2E),
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),

      cardTheme: CardThemeData(
        color: const Color(0xFFF8FAFC),
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
      ),

      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primaryColor,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),

      textTheme: const TextTheme(
        displayLarge: TextStyle(color: Color(0xFF0F172A), fontSize: 32, fontWeight: FontWeight.bold),
        bodyLarge: TextStyle(color: Color(0xFF475569), fontSize: 16),
        bodyMedium: TextStyle(color: Color(0xFF475569), fontSize: 14),
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

  // Gradient background
  static LinearGradient get backgroundGradient {
    return const LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color(0xFF0A0A0F),
        Color(0xFF141420),
        Color(0xFF1E1E2E),
      ],
    );
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
