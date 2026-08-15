import 'package:flutter/material.dart';

/// Design tokens for the Syndro redesign.
///
/// Centralises the spacing, radius and motion values that used to be inlined
/// throughout the UI (recurring 12/16/20/24 radii, ad-hoc paddings). Screens
/// and widgets should reference these instead of hard-coding numbers so the
/// Material 3 redesign stays consistent.
class AppSpacing {
  AppSpacing._();

  /// 4 — hairline gaps, icon/label spacing.
  static const double xs = 4;

  /// 8 — tight gaps inside a component.
  static const double sm = 8;

  /// 12 — default gap between related elements.
  static const double md = 12;

  /// 16 — standard content padding / gap between cards.
  static const double lg = 16;

  /// 20 — section padding.
  static const double xl = 20;

  /// 24 — screen edge padding, gaps between sections.
  static const double xxl = 24;

  /// 32 — large separations, empty-state breathing room.
  static const double xxxl = 32;

  /// Standard screen edge padding.
  static const EdgeInsets screenPadding = EdgeInsets.all(lg);

  /// Standard horizontal screen padding.
  static const EdgeInsets screenPaddingH = EdgeInsets.symmetric(horizontal: lg);
}

/// Corner-radius scale. Material 3 leans on rounded, expressive shapes.
class AppRadius {
  AppRadius._();

  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 28;

  /// Fully rounded (pills, avatars, FAB-like chips).
  static const double pill = 999;

  static const BorderRadius smAll = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius mdAll = BorderRadius.all(Radius.circular(md));
  static const BorderRadius lgAll = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius xlAll = BorderRadius.all(Radius.circular(xl));
  static const BorderRadius xxlAll = BorderRadius.all(Radius.circular(xxl));
  static const BorderRadius pillAll = BorderRadius.all(Radius.circular(pill));
}

/// Motion tokens. Keep transitions short and consistent.
class AppMotion {
  AppMotion._();

  static const Duration fast = Duration(milliseconds: 150);
  static const Duration normal = Duration(milliseconds: 250);
  static const Duration slow = Duration(milliseconds: 400);

  static const Curve standard = Curves.easeInOutCubic;
  static const Curve emphasized = Curves.easeOutBack;
}
