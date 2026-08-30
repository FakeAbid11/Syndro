import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/device.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common/app_widgets.dart';
import 'home_device_views.dart';

/// ANDROID-ONLY home layout: single column + floating action buttons.
///
/// Rendered exclusively on Android (see `HomeScreen.build`); Windows/Linux/
/// macOS use `HomeDesktopLayout` instead, so changes here cannot affect the
/// desktop layout and vice versa. Pure presentation: all data arrives as
/// constructor params and all behavior as callbacks from the facade.
class HomeMobileLayout extends StatelessWidget {
  final dynamic currentDevice;
  final AsyncValue<List<Device>> discoveredDevicesAsync;
  final Device? selectedDevice;
  final bool isInitialized;
  final bool isRefreshing;
  final Set<Device> selectedDevices;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenShareDialog;
  final void Function(Device device) onTextCompose;
  final void Function(Device device) onSendFiles;
  final void Function(List<Device> devices) onSendToMultiple;
  final VoidCallback onClearMultiSelect;

  const HomeMobileLayout({
    super.key,
    required this.currentDevice,
    required this.discoveredDevicesAsync,
    required this.selectedDevice,
    required this.isInitialized,
    required this.isRefreshing,
    required this.selectedDevices,
    required this.onRefresh,
    required this.onOpenShareDialog,
    required this.onTextCompose,
    required this.onSendFiles,
    required this.onSendToMultiple,
    required this.onClearMultiSelect,
  });

  @override
  Widget build(BuildContext context) {
    final hasMulti = selectedDevices.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            GradientIconTile(
              icon: Icons.share,
              size: 36,
              iconSize: 20,
              radius: AppRadius.sm,
              glow: false,
            ),
            SizedBox(width: AppSpacing.md),
            Text('Syndro'),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: Stack(
          children: [
            HomeDeviceColumn(
              currentDevice: currentDevice,
              discoveredDevicesAsync: discoveredDevicesAsync,
              selectedDevice: selectedDevice,
              isInitialized: isInitialized,
              isRefreshing: isRefreshing,
              onRefresh: onRefresh,
              bottomPadding: 120,
            ),

            // Browser Share FAB
            Positioned(
              right: AppSpacing.xl,
              bottom: 110,
              child: FloatingActionButton(
                heroTag: null,
                onPressed: onOpenShareDialog,
                backgroundColor: AppTheme.surfaceContainerHigh,
                foregroundColor: AppTheme.primaryColor,
                shape: const CircleBorder(),
                child: const Icon(Icons.language, size: 30),
              ),
            ),

            // Send Text FAB (when device selected)
            if (selectedDevice != null)
              Positioned(
                right: AppSpacing.xl + 88,
                bottom: 190,
                child: FloatingActionButton(
                  heroTag: 'sendText',
                  onPressed: () => onTextCompose(selectedDevice!),
                  backgroundColor: AppTheme.surfaceContainerHigh,
                  foregroundColor: AppTheme.primaryColor,
                  shape: const CircleBorder(),
                  tooltip: 'Send text or link',
                  child: const Icon(Icons.notes, size: 24),
                ),
              ),

            // Send Files FAB (when device selected)
            if (selectedDevice != null)
              Positioned(
                right: AppSpacing.xl,
                bottom: 190,
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () => onSendFiles(selectedDevice!),
                  backgroundColor: AppTheme.surfaceContainerHigh,
                  foregroundColor: AppTheme.primaryColor,
                  icon: const Icon(Icons.send, size: 24),
                  label: const Text('Send Files'),
                ),
              ),

            // Multi-select Send FAB (when multiple devices selected)
            if (hasMulti)
              Positioned(
                right: AppSpacing.xl,
                bottom: 190,
                child: FloatingActionButton.extended(
                  heroTag: null,
                  onPressed: () => onSendToMultiple(selectedDevices.toList()),
                  icon: const Icon(Icons.send, size: 24),
                  label: Text('Send to ${selectedDevices.length}'),
                ),
              ),

            // Multi-select cancel FAB
            if (hasMulti)
              Positioned(
                left: AppSpacing.xl,
                bottom: 190,
                child: FloatingActionButton(
                  heroTag: null,
                  onPressed: onClearMultiSelect,
                  backgroundColor: AppTheme.errorContainer,
                  foregroundColor: AppTheme.onErrorContainer,
                  shape: const CircleBorder(),
                  child: const Icon(Icons.close, size: 24),
                ),
              ),
          ],
        ),
      ),
    );
  }
}