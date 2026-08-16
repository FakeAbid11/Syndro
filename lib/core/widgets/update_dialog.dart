import 'package:flutter/material.dart';

import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_dimens.dart';
import '../services/update_service.dart';

/// Shared "update available" dialog used by both the manual Settings check and
/// the silent startup check. Returns nothing; handles its own actions.
///
/// [allowSkip] adds a "Skip this version" action (used by the startup check) so
/// the user isn't nagged about the same release again.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  bool allowSkip = false,
}) {
  return showDialog<void>(
    context: context,
    builder: (context) {
      return AlertDialog(
        icon: const Icon(
          Icons.system_update,
          color: AppTheme.primaryColor,
          size: 32,
        ),
        title: Text('Update available — v${info.version}'),
        content: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 320, maxWidth: 420),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'A newer version of Syndro is available.',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                if (info.notes.isNotEmpty) ...[
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    "What's new",
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Text(
                    info.notes,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                ],
              ],
            ),
          ),
        ),
        actions: [
          if (allowSkip)
            TextButton(
              onPressed: () {
                UpdateService.skipVersion(info.version);
                Navigator.of(context).pop();
              },
              child: const Text('Skip this version'),
            ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Later'),
          ),
          FilledButton.icon(
            onPressed: () {
              UpdateService.openDownload(info);
              Navigator.of(context).pop();
            },
            icon: const Icon(Icons.download, size: 18),
            label: const Text('Download'),
          ),
        ],
      );
    },
  );
}
