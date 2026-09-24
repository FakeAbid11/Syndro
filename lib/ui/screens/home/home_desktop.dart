import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/device.dart';
import '../../../core/models/transfer.dart';
import '../../theme/app_dimens.dart';
import '../../theme/app_theme.dart';
import '../../widgets/common/app_widgets.dart';
import '../../widgets/drop_zone_widget.dart';
import 'home_device_views.dart';

/// WINDOWS/LINUX/MACOS-ONLY home layout: two-pane master–detail with a
/// drag-and-drop send pane.
///
/// Rendered exclusively on desktop (see `HomeScreen.build`); Android uses
/// `HomeMobileLayout` instead, so changes here cannot affect the mobile
/// layout and vice versa. Pure presentation: all data arrives as constructor
/// params and all behavior as callbacks from the facade.
class HomeDesktopLayout extends StatelessWidget {
  final Device currentDevice;
  final AsyncValue<List<Device>> discoveredDevicesAsync;
  final Device? selectedDevice;
  final bool isInitialized;
  final bool isRefreshing;
  final Set<Device> selectedDevices;
  final Future<void> Function() onRefresh;
  final VoidCallback onOpenShareDialog;
  final VoidCallback onSendText;
  final VoidCallback onOpenPicker;

  /// Opens the picker already aimed at one device, from that card's hover
  /// action or right-click menu.
  final void Function(Device device) onSendFilesTo;
  final void Function(List<TransferItem> items) onFilesDropped;
  final void Function(List<Device> devices) onSendToMultiple;
  final VoidCallback onClearMultiSelect;

  const HomeDesktopLayout({
    super.key,
    required this.currentDevice,
    required this.discoveredDevicesAsync,
    required this.selectedDevice,
    required this.isInitialized,
    required this.isRefreshing,
    required this.selectedDevices,
    required this.onRefresh,
    required this.onOpenShareDialog,
    required this.onSendText,
    required this.onOpenPicker,
    required this.onSendFilesTo,
    required this.onFilesDropped,
    required this.onSendToMultiple,
    required this.onClearMultiSelect,
  });

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    final compactActions = width < 720;
    final hasMulti = selectedDevices.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        // The shell's brand bar owns the logo and app name, so this header
        // names the screen instead of repeating the brand.
        titleSpacing: AppSpacing.lg,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('Devices'),
            Text(
              'Your devices on this network',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                    fontWeight: FontWeight.w400,
                  ),
            ),
          ],
        ),
        actions: _buildAppBarActions(compactActions),
      ),
      // No gradient pane here: the Scaffold background is already the palette
      // base, and a gradient under the largest surface is what made the old
      // desktop UI read as heavy.
      body: LayoutBuilder(
          builder: (context, constraints) {
            final masterWidth = (constraints.maxWidth * 0.42)
                .clamp(300.0, 380.0)
                .toDouble();
            final deviceColumn = HomeDeviceColumn(
              currentDevice: currentDevice,
              discoveredDevicesAsync: discoveredDevicesAsync,
              selectedDevice: selectedDevice,
              isInitialized: isInitialized,
              isRefreshing: isRefreshing,
              onRefresh: onRefresh,
              onSendFilesTo: onSendFilesTo,
            );

            // Wide window: two-pane master–detail.
            if (constraints.maxWidth >= 700) {
              return Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    width: masterWidth,
                    child: deviceColumn,
                  ),
                  VerticalDivider(width: 1, color: AppTheme.outlineVariant),
                  Expanded(child: _buildSendPane(context)),
                ],
              );
            }

            // Narrow desktop window: master column full width; the send
            // actions live in the app bar plus contextual FABs below.
            return Stack(
              children: [
                deviceColumn,
                if (selectedDevice != null)
                  Positioned(
                    right: AppSpacing.xl,
                    // The desktop shell navigates from the rail, so unlike the
                    // mobile layout nothing has to be cleared at the bottom.
                    bottom: AppSpacing.xl,
                    child: FloatingActionButton.extended(
                      heroTag: null,
                      onPressed: onOpenPicker,
                      backgroundColor: AppTheme.surfaceContainerHigh,
                      foregroundColor: AppTheme.primaryColor,
                      icon: const Icon(Icons.send, size: 24),
                      label: const Text('Send Files'),
                    ),
                  ),
                if (hasMulti)
                  Positioned(
                    right: AppSpacing.xl,
                    bottom: AppSpacing.xl,
                    child: FloatingActionButton.extended(
                      heroTag: null,
                      onPressed: () => onSendToMultiple(selectedDevices.toList()),
                      icon: const Icon(Icons.send, size: 24),
                      label: Text('Send to ${selectedDevices.length}'),
                    ),
                  ),
                if (hasMulti)
                  Positioned(
                    left: AppSpacing.xl,
                    bottom: AppSpacing.xl,
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
            );
          },
        ),
    );
  }

  /// App-bar actions (replace the two always-on FABs): Browser Share and
  /// Send Text. Compact (< 720px window) collapses them to icon buttons.
  List<Widget> _buildAppBarActions(bool compact) {
    // Narrow window: icon-only buttons with tooltips (labels will not fit).
    if (compact) {
      return [
        IconButton(
          tooltip: 'Browser Share',
          onPressed: onOpenShareDialog,
          icon: const Icon(Icons.language),
        ),
        IconButton(
          tooltip: 'Send text or link',
          onPressed: onSendText,
          icon: const Icon(Icons.notes),
        ),
        const SizedBox(width: AppSpacing.sm),
      ];
    }
    return [
      TextButton.icon(
        onPressed: onOpenShareDialog,
        icon: const Icon(Icons.language, size: 18),
        label: const Text('Browser Share'),
      ),
      const SizedBox(width: AppSpacing.xs),
      TextButton.icon(
        onPressed: onSendText,
        icon: const Icon(Icons.notes, size: 18),
        label: const Text('Send Text'),
      ),
      const SizedBox(width: AppSpacing.md),
    ];
  }

  /// The send pane — a drag-and-drop target for the selected device(s).
  /// This is the primary Windows interaction: drag files onto the window,
  /// pick files/folders, and send — no FAB hunting required.
  Widget _buildSendPane(BuildContext context) {
    final hasMulti = selectedDevices.isNotEmpty;
    // Local copy so the null-check below promotes the type (fields don't).
    final device = selectedDevice;

    final Widget header;
    if (hasMulti) {
      header = SectionHeader(
        title: 'Send to ${selectedDevices.length} devices',
        trailing: TextButton(
          onPressed: onClearMultiSelect,
          child: const Text('Clear selection'),
        ),
      );
    } else if (device != null) {
      header = SectionHeader(title: 'Send to ${device.name}');
    } else {
      header = const SectionHeader(title: 'Send Files');
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 860),
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              header,
              const SizedBox(height: AppSpacing.lg),
              // The drop target is the point of this pane, so it takes the
              // height it is given instead of floating as a fixed box in a
              // mostly empty column — but still scrolls when the window is
              // shorter than the prompt needs.
              Expanded(
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    return SingleChildScrollView(
                      child: ConstrainedBox(
                        constraints:
                            BoxConstraints(minHeight: constraints.maxHeight),
                        child: EmptyDropZone(
                          onFilesDropped: onFilesDropped,
                          onPickFiles: onOpenPicker,
                          onPickFolder: onOpenPicker,
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}