import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/device_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../widgets/device_card.dart';
import '../widgets/file_preview_widgets.dart';
import 'file_picker_screen.dart';
import '../../core/utils/byte_formatter.dart';

/// Screen for quick sending files received from right-click context menu
class QuickSendScreen extends ConsumerStatefulWidget {
  final List<TransferItem> files;
  final VoidCallback onComplete;

  const QuickSendScreen({
    super.key,
    required this.files,
    required this.onComplete,
  });

  @override
  ConsumerState<QuickSendScreen> createState() => _QuickSendScreenState();
}

class _QuickSendScreenState extends ConsumerState<QuickSendScreen> {
  @override
  void initState() {
    super.initState();
    // FIXED (Bug #11): Add error handling for device discovery
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        try {
          ref.read(deviceDiscoveryProvider.notifier).startDiscovery();
        } catch (e) {
          debugPrint('⚠️ Error starting discovery: $e');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error starting device discovery: $e'),
                backgroundColor: AppTheme.errorColor,
                behavior: SnackBarBehavior.floating,
                action: SnackBarAction(
                  label: 'Retry',
                  textColor: Colors.white,
                  onPressed: () {
                    ref.read(deviceDiscoveryProvider.notifier).startDiscovery();
                  },
                ),
              ),
            );
          }
        }
      }
    });
  }

  int get _totalSize => widget.files.fold(0, (sum, item) => sum + item.size);

  void _selectDevice(Device device) {
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
        builder: (context) => FilePickerScreen(
          recipientDevice: device,
          preselectedFiles: widget.files,
        ),
      ),
    );
  }

  void _cancel() {
    widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    final discoveredDevices = ref.watch(deviceDiscoveryProvider);
    final isScanning = ref.watch(isDiscoveryScanningProvider);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: SafeArea(
          child: Column(
            children: [
              // Header
              _buildHeader(),
              // File summary
              _buildFileSummary(),
              // Device list
              Expanded(
                child: _buildDeviceList(discoveredDevices, isScanning),
              ),
              // Cancel button
              _buildCancelButton(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Row(
        children: [
          const GradientIconTile(
            icon: Icons.send_rounded,
            size: 56,
            radius: AppRadius.lg,
          ),
          const SizedBox(width: AppSpacing.lg),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ShaderMask(
                  shaderCallback: (bounds) =>
                      AppTheme.logoGradient.createShader(bounds),
                  child: Text(
                    'Quick Send',
                    style:
                        Theme.of(context).textTheme.displaySmall?.copyWith(
                              color: Colors.white,
                            ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Select a device to send your files',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFileSummary() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Row(
          children: [
            // Show thumbnail for images/videos, icon for others
            _buildFileIcon(),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.files.length == 1
                        ? widget.files.first.name
                        : '${widget.files.length} items selected',
                    style: Theme.of(context).textTheme.titleMedium,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: AppSpacing.xs + 2),
                  Row(
                    children: [
                      const Icon(
                        Icons.storage_rounded,
                        size: 14,
                        color: AppTheme.textTertiary,
                      ),
                      const SizedBox(width: AppSpacing.xs + 2),
                      Text(
                        ByteFormatter.format(_totalSize),
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // File count badge
            if (widget.files.length > 1)
              StatusBadge(
                label: '${widget.files.length}',
                variant: BadgeVariant.primary,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildFileIcon() {
    // For single file, show thumbnail if it's an image/video
    if (widget.files.length == 1) {
      final file = widget.files.first;
      final fileName = file.name.toLowerCase();
      
      // Check if it's an image or video
      final isImage = fileName.endsWith('.jpg') || 
                      fileName.endsWith('.jpeg') || 
                      fileName.endsWith('.png') || 
                      fileName.endsWith('.gif') || 
                      fileName.endsWith('.webp') ||
                      fileName.endsWith('.heic') ||
                      fileName.endsWith('.heif');
      
      final isVideo = fileName.endsWith('.mp4') || 
                      fileName.endsWith('.mov') || 
                      fileName.endsWith('.avi') || 
                      fileName.endsWith('.mkv') ||
                      fileName.endsWith('.webm');
      
      if ((isImage || isVideo) && file.path.isNotEmpty) {
        // Show thumbnail
        return ClipRRect(
          borderRadius: AppRadius.mdAll,
          child: FilePreviewWidget(
            filePath: file.path,
            fileName: file.name,
            size: 56,
            borderRadius: AppRadius.mdAll,
          ),
        );
      }

      // Show folder icon for directories
      if (file.isDirectory) {
        return const GradientIconTile(
          icon: Icons.folder_rounded,
          size: 56,
          radius: AppRadius.md,
        );
      }
    }

    // Default icon for multiple files or non-media files
    return GradientIconTile(
      icon: widget.files.length == 1
          ? Icons.insert_drive_file_rounded
          : Icons.folder_copy_rounded,
      size: 56,
      radius: AppRadius.md,
    );
  }

  Widget _buildDeviceList(List<Device> devices, bool isScanning) {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SectionHeader(
            title: 'Available Devices',
            trailing: isScanning
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: devices.isEmpty
                ? _buildEmptyState(isScanning)
                : ListView.separated(
                    itemCount: devices.length,
                    separatorBuilder: (_, __) =>
                        const SizedBox(height: AppSpacing.md),
                    itemBuilder: (context, index) {
                      final device = devices[index];
                      return DeviceCard(
                        device: device,
                        onTap: () => _selectDevice(device),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(bool isScanning) {
    return EmptyState(
      icon: isScanning ? Icons.radar_rounded : Icons.devices_other_rounded,
      title: isScanning ? 'Scanning for devices...' : 'No devices found',
      message: 'Make sure other devices are on the same network',
      action: isScanning
          ? null
          : TextButton.icon(
              onPressed: () {
                ref.read(deviceDiscoveryProvider.notifier).startDiscovery();
              },
              icon: const Icon(Icons.refresh_rounded),
              label: const Text('Scan Again'),
            ),
    );
  }

  Widget _buildCancelButton() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: _cancel,
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}
