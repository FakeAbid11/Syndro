import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/models/device.dart';
import '../../core/models/transfer.dart';
import '../../core/providers/device_nickname_provider.dart';
import '../../core/providers/device_provider.dart';
import '../../core/utils/byte_formatter.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';

/// Asks who should receive the files that were just dropped.
///
/// A drop arrives without any intent attached to it — the user may have three
/// peers on the network and mean one of them — so the drop is confirmed rather
/// than assumed. Returns the chosen recipients, or null if the user backed out.
Future<List<Device>?> pickDropRecipients(
  BuildContext context,
  List<TransferItem> items,
) {
  return showDialog<List<Device>>(
    context: context,
    builder: (_) => DropRecipientDialog(items: items),
  );
}

class DropRecipientDialog extends ConsumerStatefulWidget {
  const DropRecipientDialog({super.key, required this.items});

  final List<TransferItem> items;

  @override
  ConsumerState<DropRecipientDialog> createState() =>
      _DropRecipientDialogState();
}

class _DropRecipientDialogState extends ConsumerState<DropRecipientDialog> {
  final Set<String> _chosen = {};

  int get _totalBytes =>
      widget.items.fold(0, (sum, item) => sum + item.size);

  @override
  Widget build(BuildContext context) {
    final selfId = ref.watch(currentDeviceProvider).id;
    final peers = (ref.watch(discoveredDevicesProvider).valueOrNull ?? [])
        .where((d) => d.id != selfId)
        .toList();
    // Nothing to send to yet: hand the decision back rather than opening a
    // dialog whose only button is Cancel.
    final onlinePeers = peers.where((d) => d.isOnline).toList();
    final nicknames = ref.watch(deviceNicknameProvider);

    final fileWord =
        widget.items.length == 1 ? 'file selected' : 'files selected';

    return AlertDialog(
      backgroundColor: AppTheme.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
      title: Row(
        children: [
          const Icon(Icons.download_rounded,
              size: 20, color: AppTheme.primaryColor),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              '${widget.items.length} $fileWord',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          Text(
            ByteFormatter.format(_totalBytes),
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  color: AppTheme.primaryColor,
                ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (onlinePeers.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: AppSpacing.md),
                child: Text('No other device is reachable on this network.'),
              )
            else ...[
              Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: Text(
                  'Send to',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final device in onlinePeers)
                    _RecipientChip(
                      device: device,
                      label: nicknames[device.id] ?? device.name,
                      selected: _chosen.contains(device.id),
                      onToggle: () => setState(() {
                        if (!_chosen.remove(device.id)) _chosen.add(device.id);
                      }),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton.icon(
          onPressed: onlinePeers.isEmpty || _chosen.isEmpty
              ? null
              : () => Navigator.of(context).pop(
                    onlinePeers
                        .where((d) => _chosen.contains(d.id))
                        .toList(),
                  ),
          icon: const Icon(Icons.send_rounded, size: 18),
          label: const Text('Send'),
        ),
      ],
    );
  }
}

class _RecipientChip extends StatelessWidget {
  const _RecipientChip({
    required this.device,
    required this.label,
    required this.selected,
    required this.onToggle,
  });

  final Device device;
  final String label;
  final bool selected;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      // A11Y: the tick and the fill both change, and the state is announced, so
      // the choice is not carried by colour alone.
      button: true,
      label: '$label, ${selected ? "selected" : "not selected"}',
      child: FilterChip(
        selected: selected,
        onSelected: (_) => onToggle(),
        avatar: Icon(device.platform.icon,
            size: 16, color: device.platform.iconColor),
        label: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(label, overflow: TextOverflow.ellipsis),
        ),
        showCheckmark: true,
        checkmarkColor: AppTheme.onPrimaryContainer,
      ),
    );
  }
}
