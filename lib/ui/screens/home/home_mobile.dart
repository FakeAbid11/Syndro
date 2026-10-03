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
  final Device currentDevice;
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

    // PLATFORM: the floating nav pill is anchored to the real system inset
    // (see main_navigation_screen), so the FABs must clear that same inset
    // plus the pill's height. Fixed offsets overlapped it on a 3-button nav
    // bar, and the overlap grew with the accessibility text scale because
    // the pill's height is intrinsic.
    final bottomInset = MediaQuery.paddingOf(context).bottom;

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
            ),
            SizedBox(width: AppSpacing.md),
            Text('Syndro'),
          ],
        ),
      ),
      body: Container(
        // Flat base colour, not the three-stop background gradient.
        //
        // The design direction is that "body panes sit on the scaffold's flat
        // base colour" and that "the three-stop background gradient is no longer
        // painted under the largest surface in the app". Desktop already does
        // this; Android still painted it, so the phone shell had a soft tinted
        // wash that the desktop shell did not, for the same content.
        color: AppTheme.backgroundColor,
        // PLATFORM: the floating nav pill is anchored to the real system inset
        // (see main_navigation_screen), so the FABs have to clear that same
        // inset plus the pill's height. Fixed offsets used to overlap it on a
        // 3-button nav bar, and the overlap grew with the accessibility text
        // scale because the pill's height is intrinsic.
        child: Stack(
          children: [
            HomeDeviceColumn(
              currentDevice: currentDevice,
              discoveredDevicesAsync: discoveredDevicesAsync,
              selectedDevice: selectedDevice,
              isInitialized: isInitialized,
              isRefreshing: isRefreshing,
              onRefresh: onRefresh,
              bottomPadding: bottomInset + 190,
            ),

            // Browser Share FAB
            Positioned(
              right: AppSpacing.xl,
              bottom: bottomInset + 96,
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
                bottom: bottomInset + 176,
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
                bottom: bottomInset + 176,
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
