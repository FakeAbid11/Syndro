import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/device.dart';
import '../../../core/providers/device_provider.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_theme.dart';
import '../../animations/pulse_animation.dart';
import '../../widgets/common/app_widgets.dart';
import '../../widgets/device_card.dart';
import '../../widgets/shimmer_loading.dart';
import '../home_screen_strings.dart';

/// The master device column: "This Device" card, the nearby-devices header
/// and the device list (skeletons / empty state / cards).
///
/// PLATFORM-NEUTRAL: rendered by both the Android mobile layout and the
/// Windows/Linux/macOS desktop layout. All provider interactions (selection,
/// subnet filtering) live here; only refresh is delegated to the parent.
class HomeDeviceColumn extends ConsumerWidget {
  final dynamic currentDevice;
  final AsyncValue<List<Device>> discoveredDevicesAsync;
  final Device? selectedDevice;
  final bool isInitialized;
  final bool isRefreshing;
  final double bottomPadding;
  final Future<void> Function() onRefresh;

  const HomeDeviceColumn({
    super.key,
    required this.currentDevice,
    required this.discoveredDevicesAsync,
    required this.selectedDevice,
    required this.isInitialized,
    required this.isRefreshing,
    required this.onRefresh,
    this.bottomPadding = 0,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: _buildCurrentDeviceCard(context, ref),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          child: SectionHeader(
            title: 'Nearby Devices',
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildDeviceCountBadge(),
                if (isRefreshing) ...[
                  const SizedBox(width: AppSpacing.md),
                  const SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primaryColor,
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Text(
                    'Scanning...',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: AppTheme.textTertiary),
                  ),
                ],
              ],
            ),
          ),
        ),
        Expanded(
          child: Padding(
            padding: EdgeInsets.only(bottom: bottomPadding),
            child: _buildDeviceList(context, ref),
          ),
        ),
      ],
    );
  }

  Widget _buildCurrentDeviceCard(BuildContext context, WidgetRef ref) {
    // Get custom nickname if available
    final customNickname = ref.watch(currentDeviceNicknameProvider);
    final displayName = customNickname ?? currentDevice.name;

    return AppCard(
      child: Row(
        children: [
          const GradientIconTile(
            icon: Icons.devices,
            size: 52,
            radius: AppRadius.lg,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      'This Device',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    const StatusBadge(
                      label: 'Online',
                      variant: BadgeVariant.success,
                      showDot: true,
                    ),
                  ],
                ),
                const SizedBox(height: AppSpacing.xs + 2),
                Text(
                  displayName,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Row(
                  children: [
                    Icon(
                      Icons.wifi_rounded,
                      size: 14,
                      color: AppTheme.textTertiary,
                    ),
                    const SizedBox(width: AppSpacing.xs),
                    Text(
                      currentDevice.ipAddress,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.textTertiary,
                          ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildDeviceCountBadge() {
    return discoveredDevicesAsync.when(
      data: (devices) => StatusBadge(
        label: '${devices.length}',
        variant: BadgeVariant.primary,
      ),
      loading: () => const StatusBadge(
        label: '...',
        variant: BadgeVariant.neutral,
      ),
      error: (_, __) => const StatusBadge(
        label: '!',
        variant: BadgeVariant.error,
      ),
    );
  }

  Widget _buildDeviceList(BuildContext context, WidgetRef ref) {
    if (!isInitialized) {
      // Skeleton loaders match the card layout the list will settle into,
      // instead of a bare spinner (the discovery service takes a moment).
      return const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            DeviceCardSkeleton(),
            SizedBox(height: AppSpacing.md),
            DeviceCardSkeleton(),
            SizedBox(height: AppSpacing.md),
            DeviceCardSkeleton(),
          ],
        ),
      );
    }

    return discoveredDevicesAsync.when(
      data: (devices) {
        // Filter to only show devices on the same subnet
        final localIps = ref.watch(localIpsProvider);
        final sameSubnetDevices = devices.where((device) {
          // Allow current device to always show
          if (device.id == ref.read(currentDeviceProvider).id) return true;
          // Check if device is on same subnet as any of our local IPs
          for (final localIp in localIps) {
            if (device.isOnSameSubnetAs(localIp)) {
              return true;
            }
          }
          return false;
        }).toList();

        if (sameSubnetDevices.isEmpty) {
          return RefreshIndicator(
            onRefresh: onRefresh,
            child: LayoutBuilder(
              builder: (context, constraints) {
                final screenHeight = MediaQuery.of(context).size.height;
                final isSmallScreen = screenHeight < 600;
                final emptyStateHeight = isSmallScreen
                    ? (screenHeight * 0.6).clamp(300.0, 500.0)
                    : (screenHeight * 0.4).clamp(350.0, 600.0);

                return SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: emptyStateHeight,
                    child: Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          PulseAnimation(
                            child: Icon(
                              Icons.radar,
                              size: 72,
                              color: AppTheme.primaryColor.withValues(alpha: 0.4),
                            ),
                          ),
                          const SizedBox(height: AppSpacing.xxl),
                          Text(
                            'Scanning for devices...',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                          ),
                          const SizedBox(height: AppSpacing.sm),
                          Text(
                            'Make sure other devices are on the\nsame Wi-Fi network and have Syndro open.',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(
                                  color: AppTheme.textTertiary,
                                ),
                            textAlign: TextAlign.center,
                          ),
                          const SizedBox(height: AppSpacing.xxxl),
                          OutlinedButton.icon(
                            onPressed: isRefreshing ? null : onRefresh,
                            icon: const Icon(Icons.refresh),
                            label: const Text(HomeScreenStrings.scanAgain),
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          );
        }

        return RefreshIndicator(
          onRefresh: onRefresh,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
            itemCount: sameSubnetDevices.length,
            itemBuilder: (context, index) {
              final device = sameSubnetDevices[index];
              final selectedDevices = ref.watch(selectedDevicesProvider);
              final isMultiSelectMode = selectedDevices.isNotEmpty;
              final isSelected = selectedDevices.any((d) => d.id == device.id) ||
                  (!isMultiSelectMode && selectedDevice?.id == device.id);

              return Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.md),
                child: DeviceCard(
                  device: device,
                  isSelected: isSelected,
                  onTap: () {
                    if (isMultiSelectMode) {
                      // Multi-select mode: toggle device in selection
                      final currentSelection = Set<Device>.from(selectedDevices);
                      if (currentSelection.any((d) => d.id == device.id)) {
                        currentSelection.removeWhere((d) => d.id == device.id);
                      } else {
                        currentSelection.add(device);
                      }
                      ref.read(selectedDevicesProvider.notifier).state = currentSelection;
                      // Clear single selection when in multi-select mode
                      ref.read(selectedDeviceProvider.notifier).state = null;
                    } else {
                      // Single-select mode
                      ref.read(selectedDeviceProvider.notifier).state = device;
                    }
                  },
                  onLongPress: () {
                    // Enter multi-select mode on long press
                    if (!isMultiSelectMode) {
                      ref.read(selectedDevicesProvider.notifier).state = {device};
                      ref.read(selectedDeviceProvider.notifier).state = null;
                    }
                  },
                ),
              );
            },
          ),
        );
      },
      loading: () => const Padding(
        padding: EdgeInsets.all(AppSpacing.lg),
        child: Column(
          children: [
            DeviceCardSkeleton(),
            SizedBox(height: AppSpacing.md),
            DeviceCardSkeleton(),
            SizedBox(height: AppSpacing.md),
            DeviceCardSkeleton(),
          ],
        ),
      ),
      error: (error, stack) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.error_outline,
              size: 64,
              color: AppTheme.errorColor,
            ),
            const SizedBox(height: AppSpacing.lg),
            Text(
              HomeScreenStrings.errorDiscoveringDevices,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: AppSpacing.sm),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxxl),
              child: Text(
                error.toString(),
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              onPressed: onRefresh,
              icon: const Icon(Icons.refresh),
              label: const Text(HomeScreenStrings.retry),
            ),
          ],
        ),
      ),
    );
  }
}