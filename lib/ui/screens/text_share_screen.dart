import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/device_provider.dart';
import '../../core/providers/transfer_provider.dart';
import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../widgets/device_card.dart';
import 'transfer_progress_screen.dart';

/// Device-picker for text shared into Syndro from another app
/// (Android text/plain share intents). Lets the user choose a target device
/// and sends the message through the same approval pipeline as file sends.
class TextShareScreen extends ConsumerStatefulWidget {
  final String text;
  final VoidCallback onComplete;

  const TextShareScreen({
    super.key,
    required this.text,
    required this.onComplete,
  });

  @override
  ConsumerState<TextShareScreen> createState() => _TextShareScreenState();
}

class _TextShareScreenState extends ConsumerState<TextShareScreen> {
  bool _isSending = false;

  @override
  void dispose() {
    try {
      ref.read(deviceDiscoveryProvider.notifier).stopDiscovery();
    } catch (_) {}
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      try {
        ref.read(deviceDiscoveryProvider.notifier).startDiscovery();
      } catch (e) {
        debugPrint('⚠️ Error starting discovery: $e');
      }
    });
  }

  Future<void> _selectDevice(Device device) async {
    if (_isSending || !mounted) return;
    setState(() => _isSending = true);

    final transferService = ref.read(transferServiceProvider);
    final transferId =
        'text-${DateTime.now().microsecondsSinceEpoch}-${device.id}';

    try {
      final sendFuture = transferService.sendText(
        device,
        widget.text,
        transferId: transferId,
      );

      if (!mounted) return;
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (routeContext) => TransferProgressScreen(
            transferId: transferId,
            remoteDevice: device,
            isSender: true,
            items: const [
              TransferItem(
                name: 'Message',
                path: '',
                size: 0,
              ),
            ],
          ),
        ),
      );

      await sendFuture;
      if (!mounted) return;
      widget.onComplete();
    } catch (e) {
      debugPrint('Error sending text: $e');
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Message failed: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      setState(() => _isSending = false);
    }
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
              _buildHeader(),
              _buildTextPreview(),
              Expanded(
                child: _buildDeviceList(discoveredDevices, isScanning),
              ),
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
            icon: Icons.chat_bubble_rounded,
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
                    'Share Text',
                    style:
                        Theme.of(context).textTheme.displaySmall?.copyWith(
                              color: Colors.white,
                            ),
                  ),
                ),
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Select a device to send your message',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTextPreview() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
      child: AppCard(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.notes_rounded,
              size: 20,
              color: AppTheme.primaryColor,
            ),
            const SizedBox(width: AppSpacing.md),
            Expanded(
              child: Text(
                widget.text,
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
          ],
        ),
      ),
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
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primaryColor,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: AppSpacing.lg),
          Expanded(
            child: devices.isEmpty && !isScanning
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.devices_other_rounded,
                          size: 48,
                          color: AppTheme.textTertiary,
                        ),
                        const SizedBox(height: AppSpacing.lg),
                        Text(
                          'No devices found',
                          style: Theme.of(context).textTheme.bodyLarge,
                        ),
                        const SizedBox(height: AppSpacing.xs),
                        Text(
                          'Make sure the target device is on the same network',
                          style: Theme.of(context)
                              .textTheme
                              .bodySmall
                              ?.copyWith(color: AppTheme.textTertiary),
                        ),
                      ],
                    ),
                  )
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

  Widget _buildCancelButton() {
    return Padding(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      child: SizedBox(
        width: double.infinity,
        child: OutlinedButton(
          onPressed: _isSending ? null : _cancel,
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.errorColor,
            side: const BorderSide(color: AppTheme.errorColor),
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.lg),
          ),
          child: const Text('Cancel'),
        ),
      ),
    );
  }
}