/// Shared Material 3 building blocks for the Syndro redesign.
///
/// These wrap the recurring visual motifs (gradient icon tiles, tonal cards,
/// section headers, pill badges, empty states) so every screen composes from
/// the same vocabulary and stays consistent. They reuse [AppTheme] colors and
/// the [AppSpacing]/[AppRadius] tokens — no new palette is introduced.
library;

import 'package:flutter/material.dart';

import '../../theme/app_dimens.dart';
import '../../theme/app_theme.dart';

/// A rounded-square icon tile filled with the brand logo gradient and a soft
/// purple glow. The signature Syndro accent used for logos, section markers
/// and prominent leading icons.
class GradientIconTile extends StatelessWidget {
  const GradientIconTile({
    super.key,
    required this.icon,
    this.size = 44,
    this.iconSize,
    this.radius = AppRadius.md,
    this.gradient,
    this.glow = true,
  });

  final IconData icon;
  final double size;
  final double? iconSize;
  final double radius;
  final Gradient? gradient;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        gradient: gradient ?? AppTheme.logoGradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: glow
            ? [
                BoxShadow(
                  color: AppTheme.primaryColor.withValues(alpha: 0.35),
                  blurRadius: 16,
                  offset: const Offset(0, 6),
                ),
              ]
            : null,
      ),
      child: Icon(icon, color: Colors.white, size: iconSize ?? size * 0.5),
    );
  }
}

/// A tonal surface card with the standard radius, hairline outline and inner
/// padding. Optionally tappable (adds an ink ripple). Use this instead of raw
/// [Container]/[Card] so every card matches the theme.
class AppCard extends StatelessWidget {
  const AppCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppSpacing.lg),
    this.onTap,
    this.color,
    this.border = true,
    this.radius = AppRadius.lg,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final VoidCallback? onTap;
  final Color? color;
  final bool border;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final borderRadius = BorderRadius.circular(radius);
    return Material(
      color: color ?? AppTheme.surfaceContainer,
      borderRadius: borderRadius,
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: borderRadius,
            border: border
                ? Border.all(color: AppTheme.outlineVariant, width: 1)
                : null,
          ),
          padding: padding,
          child: child,
        ),
      ),
    );
  }
}

/// Section header: a small gradient accent bar + title, with an optional
/// trailing widget (e.g. an action or count). Marks the start of a content
/// group on a screen.
class SectionHeader extends StatelessWidget {
  const SectionHeader({
    super.key,
    required this.title,
    this.trailing,
    this.padding = const EdgeInsets.symmetric(
      horizontal: AppSpacing.xs,
      vertical: AppSpacing.sm,
    ),
  });

  final String title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Row(
        children: [
          Container(
            width: 4,
            height: 18,
            decoration: BoxDecoration(
              gradient: AppTheme.logoGradient,
              borderRadius: BorderRadius.circular(AppRadius.pill),
            ),
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              title,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

/// Visual intent for a [StatusBadge]. Maps to a tonal container/on-color pair
/// from [AppTheme] so badges read as part of the M3 palette.
enum BadgeVariant { neutral, primary, success, warning, error, info }

/// A tonal pill badge: rounded container-tinted background with a light
/// foreground label, an optional leading dot or icon. Use for statuses
/// ("Online", "Encrypted", "Failed"), counts and small tags.
class StatusBadge extends StatelessWidget {
  const StatusBadge({
    super.key,
    required this.label,
    this.variant = BadgeVariant.neutral,
    this.icon,
    this.showDot = false,
  });

  final String label;
  final BadgeVariant variant;
  final IconData? icon;
  final bool showDot;

  ({Color bg, Color fg}) _colors() {
    switch (variant) {
      case BadgeVariant.primary:
        return (bg: AppTheme.primaryContainer, fg: AppTheme.onPrimaryContainer);
      case BadgeVariant.info:
        return (
          bg: AppTheme.secondaryContainer,
          fg: AppTheme.onSecondaryContainer
        );
      case BadgeVariant.success:
        return (
          bg: AppTheme.successColor.withValues(alpha: 0.18),
          fg: AppTheme.successColor
        );
      case BadgeVariant.warning:
        return (
          bg: AppTheme.warningColor.withValues(alpha: 0.18),
          fg: AppTheme.warningColor
        );
      case BadgeVariant.error:
        return (bg: AppTheme.errorContainer, fg: AppTheme.onErrorContainer);
      case BadgeVariant.neutral:
        return (bg: AppTheme.surfaceContainerHigh, fg: AppTheme.textSecondary);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = _colors();
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.md,
        vertical: AppSpacing.xs + 2,
      ),
      decoration: BoxDecoration(
        color: c.bg,
        borderRadius: BorderRadius.circular(AppRadius.pill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (showDot) ...[
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: c.fg, shape: BoxShape.circle),
            ),
            const SizedBox(width: AppSpacing.sm),
          ] else if (icon != null) ...[
            Icon(icon, size: 14, color: c.fg),
            const SizedBox(width: AppSpacing.xs + 2),
          ],
          Text(
            label,
            style: TextStyle(
              color: c.fg,
              fontSize: 12,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// A centered empty / placeholder state: a gradient icon tile, a title, an
/// optional supporting line and an optional action button. Use whenever a list
/// or screen has nothing to show yet (no devices found, empty history, etc.).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.message,
    this.action,
    this.padding = const EdgeInsets.all(AppSpacing.xxl),
  });

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: Padding(
        padding: padding,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            GradientIconTile(icon: icon, size: 72, radius: AppRadius.xl),
            const SizedBox(height: AppSpacing.xl),
            Text(
              title,
              textAlign: TextAlign.center,
              style: textTheme.titleLarge,
            ),
            if (message != null) ...[
              const SizedBox(height: AppSpacing.sm),
              Text(
                message!,
                textAlign: TextAlign.center,
                style: textTheme.bodyMedium
                    ?.copyWith(color: AppTheme.textTertiary),
              ),
            ],
            if (action != null) ...[
              const SizedBox(height: AppSpacing.xl),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
