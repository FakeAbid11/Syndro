import 'package:flutter/material.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'common/app_widgets.dart';

class ShareIntentDialog extends StatefulWidget {
  final VoidCallback onAppToApp;
  final VoidCallback onBrowserShare;
  final int fileCount;

  const ShareIntentDialog({
    super.key,
    required this.onAppToApp,
    required this.onBrowserShare,
    required this.fileCount,
  });

  @override
  State<ShareIntentDialog> createState() => _ShareIntentDialogState();
}

class _ShareIntentDialogState extends State<ShareIntentDialog> {
  bool _isProcessing = false;

  void _handleOptionTap(VoidCallback callback) async {
    setState(() {
      _isProcessing = true;
    });
    
    // Close dialog first
    if (mounted) {
      Navigator.of(context).pop();
    }
    
    // Then call the callback
    callback();
  }

  @override
  Widget build(BuildContext context) {
    if (_isProcessing) {
      return Dialog(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xxxl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: AppSpacing.xxl),
              Text(
                'Preparing files...',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                'Please wait',
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: AppTheme.textSecondary,
                    ),
              ),
            ],
          ),
        ),
      );
    }

    return Dialog(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xxl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Header
            const GradientIconTile(
              icon: Icons.share,
              size: 72,
              iconSize: 36,
              radius: AppRadius.xl,
            ),
            const SizedBox(height: AppSpacing.lg),

            // Title
            Text(
              'Share with Syndro',
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: AppSpacing.sm),

            // Subtitle
            Text(
              widget.fileCount == 1
                  ? '1 file selected'
                  : '${widget.fileCount} files selected',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppTheme.textSecondary,
                  ),
            ),
            const SizedBox(height: AppSpacing.xxl),

            // Option 1: App to App
            _ShareOption(
              icon: Icons.phone_android,
              title: 'App to App',
              subtitle: 'Direct transfer to nearby devices',
              onTap: () => _handleOptionTap(widget.onAppToApp),
            ),
            const SizedBox(height: AppSpacing.md),

            // Option 2: Browser Share
            _ShareOption(
              icon: Icons.language,
              title: 'Browser Share',
              subtitle: 'Share via web browser',
              onTap: () => _handleOptionTap(widget.onBrowserShare),
            ),
            const SizedBox(height: AppSpacing.lg),

            // Cancel button
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text(
                'Cancel',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ShareOption extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ShareOption({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: AppRadius.mdAll,
      child: Container(
        padding: const EdgeInsets.all(AppSpacing.lg),
        decoration: BoxDecoration(
          color: AppTheme.surfaceContainer,
          borderRadius: AppRadius.mdAll,
          border: Border.all(
            color: AppTheme.outlineVariant,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm + 2),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.1),
                borderRadius: AppRadius.smAll,
              ),
              child: Icon(
                icon,
                color: AppTheme.primaryColor,
                size: 24,
              ),
            ),
            const SizedBox(width: AppSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppTheme.textSecondary,
                        ),
                  ),
                ],
              ),
            ),
            const Icon(
              Icons.chevron_right,
              color: AppTheme.textSecondary,
            ),
          ],
        ),
      ),
    );
  }
}
