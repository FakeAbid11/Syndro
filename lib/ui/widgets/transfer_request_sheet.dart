import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/models/device.dart';
import '../../core/services/transfer_service.dart';
import '../../core/providers/transfer_provider.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import '../screens/transfer_progress_screen.dart';
import 'common/app_widgets.dart';
import 'transfer_request_strings.dart';
import '../../core/utils/byte_formatter.dart';

class TransferRequestSheet extends ConsumerWidget {
  final PendingTransferRequest request;
  final VoidCallback onDismiss;

  const TransferRequestSheet({
    super.key,
    required this.request,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final totalSize =
        request.items.fold<int>(0, (sum, item) => sum + item.size);

    return Container(
      padding: const EdgeInsets.all(AppSpacing.xxl),
      decoration: const BoxDecoration(
        color: AppTheme.surfaceColor,
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadius.xxl)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle bar
          Container(
            width: 40,
            height: 4,
            decoration: const BoxDecoration(
              color: AppTheme.outlineVariant,
              borderRadius: AppRadius.pillAll,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),

          // Incoming icon
          const GradientIconTile(
            icon: Icons.download,
            size: 80,
            iconSize: 44,
            radius: AppRadius.xl,
          ),
          const SizedBox(height: AppSpacing.lg),

          // Title
          Text(
            TransferRequestStrings.incomingTransfer,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: AppSpacing.sm),

          // Sender info with trusted badge
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  '${request.senderName} ${TransferRequestStrings.senderWantsToSend}',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.textSecondary,
                      ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (request.isTrusted) ...[
                const SizedBox(width: AppSpacing.sm),
                const StatusBadge(
                  label: 'Trusted',
                  variant: BadgeVariant.success,
                  icon: Icons.verified_user,
                ),
              ],
            ],
          ),
          const SizedBox(height: AppSpacing.lg),

          // File details
          Container(
            padding: const EdgeInsets.all(AppSpacing.lg),
            decoration: BoxDecoration(
              color: AppTheme.surfaceContainer,
              borderRadius: AppRadius.mdAll,
              border: Border.all(color: AppTheme.outlineVariant, width: 1),
            ),
            child: Row(
              children: [
                Icon(
                  request.items.length == 1
                      ? Icons.insert_drive_file
                      : Icons.folder,
                  color: AppTheme.primaryColor,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        request.items.length == 1
                            ? request.items.first.name
                            : TransferRequestStrings.fileCount(request.items.length),
                        style: Theme.of(context).textTheme.titleSmall,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        ByteFormatter.format(totalSize),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // File list if multiple files
          if (request.items.length > 1) ...[
            const SizedBox(height: AppSpacing.md),
            Container(
              constraints: const BoxConstraints(maxHeight: 150),
              decoration: BoxDecoration(
                color: AppTheme.surfaceContainerLow,
                borderRadius: AppRadius.mdAll,
                border: Border.all(color: AppTheme.outlineVariant, width: 1),
              ),
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: request.items.length,
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
                itemBuilder: (context, index) {
                  final item = request.items[index];
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.insert_drive_file,
                          size: 16,
                          color: AppTheme.textTertiary,
                        ),
                        const SizedBox(width: AppSpacing.sm),
                        Expanded(
                          child: Text(
                            item.name,
                            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                                  color: AppTheme.textSecondary,
                                ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          ByteFormatter.format(item.size),
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
          ],
          const SizedBox(height: AppSpacing.xxl),

          // Action buttons
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () {
                    final transferService = ref.read(transferServiceProvider);
                    transferService.rejectTransfer(request.requestId);
                    onDismiss();
                  },
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.errorColor,
                    side: const BorderSide(color: AppTheme.errorColor),
                  ),
                  child: const Text(TransferRequestStrings.decline),
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: FilledButton(
                  onPressed: () {
                    _acceptTransfer(context, ref, false);
                  },
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.successColor,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text(TransferRequestStrings.accept),
                ),
              ),
            ],
          ),
          const SizedBox(height: AppSpacing.sm),

          // Trust option - warning label
          Text(
            '⚠ This will permanently trust this device',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.sm),

          // Trust option - full width OutlinedButton
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                _acceptTransfer(context, ref, true);
              },
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.warningColor,
                side: BorderSide(
                  color: AppTheme.warningColor.withValues(alpha: 0.6),
                ),
                backgroundColor: AppTheme.warningColor.withValues(alpha: 0.08),
              ),
              icon: const Icon(Icons.verified_user_outlined, size: 16),
              label: const Text(TransferRequestStrings.acceptAndTrust),
            ),
          ),
        ],
      ),
    );
  }

  void _acceptTransfer(BuildContext context, WidgetRef ref, bool trustSender) {
    // Approve the transfer
    final transferService = ref.read(transferServiceProvider);
    transferService.approveTransfer(request.requestId, trustSender: trustSender);

    // Close the bottom sheet
    onDismiss();

    // Navigate to progress screen for receiver
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => TransferProgressScreen(
          transferId: request.requestId,
          remoteDevice: Device(
            id: request.senderId,
            name: request.senderName,
            platform: DevicePlatform.unknown,
            ipAddress: '',
            port: 0,
            lastSeen: DateTime.now(),
          ),
          isSender: false,
          items: request.items,
        ),
      ),
    );
  }
}
