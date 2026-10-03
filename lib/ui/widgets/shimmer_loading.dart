import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';

/// Fill for a skeleton placeholder block.
///
/// These were `Colors.white`, which is invisible against a light surface — a
/// skeleton in light mode rendered as blank space with no shape at all, so the
/// loading state looked like an empty list rather than a pending one. Derive
/// from the active color scheme so it reads on both surfaces.
Color _skeletonFill(BuildContext context) =>
    Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.10);

/// Shimmer loading effect for skeleton screens
class ShimmerLoading extends StatelessWidget {
  final Widget child;
  final bool isLoading;

  const ShimmerLoading({
    super.key,
    required this.child,
    this.isLoading = true,
  });

  @override
  Widget build(BuildContext context) {
    if (!isLoading) {
      return child;
    }

    return Shimmer.fromColors(
      baseColor: AppTheme.surfaceContainer,
      highlightColor: AppTheme.surfaceContainerHigh,
      child: child,
    );
  }
}

/// Skeleton device card for loading state
class DeviceCardSkeleton extends StatelessWidget {
  const DeviceCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              // Icon skeleton
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: _skeletonFill(context),
                  borderRadius: AppRadius.mdAll,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              // Text skeleton
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 20,
                      decoration: BoxDecoration(
                        color: _skeletonFill(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 100,
                      height: 14,
                      decoration: BoxDecoration(
                        color: _skeletonFill(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      width: 120,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _skeletonFill(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
              // Status skeleton
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: _skeletonFill(context),
                  shape: BoxShape.circle,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Skeleton for history item
class HistoryItemSkeleton extends StatelessWidget {
  const HistoryItemSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    return ShimmerLoading(
      child: Card(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: _skeletonFill(context),
                  borderRadius: AppRadius.smAll,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: double.infinity,
                      height: 16,
                      decoration: BoxDecoration(
                        color: _skeletonFill(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Container(
                      width: 80,
                      height: 12,
                      decoration: BoxDecoration(
                        color: _skeletonFill(context),
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
