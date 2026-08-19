import 'dart:io';

import 'package:flutter/material.dart';

import '../../ui/theme/app_theme.dart';
import '../../ui/theme/app_dimens.dart';
import '../services/update_service.dart';

/// Shared "update available" dialog used by both the manual Settings check and
/// the silent startup check. Returns nothing; handles its own actions.
///
/// [allowSkip] adds a "Skip this version" action (used by the startup check) so
/// the user isn't nagged about the same release again.
///
/// On Windows with an installer asset, the primary action becomes "Update now":
/// the asset is downloaded in-app with live progress and the Inno Setup
/// installer is then run silently, which relaunches the updated app. Pass
/// [useInstaller] explicitly in tests; by default it is derived from the
/// platform and the available asset.
Future<void> showUpdateDialog(
  BuildContext context,
  UpdateInfo info, {
  bool allowSkip = false,
  bool? useInstaller,
}) {
  final installer = useInstaller ?? (Platform.isWindows && info.isWindowsInstaller);
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
          child: _UpdateDialogBody(
            info: info,
            allowSkip: allowSkip,
            installer: installer,
          ),
        ),
      );
    },
  );
}

enum _UpdatePhase { idle, downloading, installing, error }

class _UpdateDialogBody extends StatefulWidget {
  const _UpdateDialogBody({
    required this.info,
    required this.allowSkip,
    required this.installer,
  });

  final UpdateInfo info;
  final bool allowSkip;
  final bool installer;

  @override
  State<_UpdateDialogBody> createState() => _UpdateDialogBodyState();
}

class _UpdateDialogBodyState extends State<_UpdateDialogBody> {
  _UpdatePhase _phase = _UpdatePhase.idle;
  String? _errorMessage;
  int _receivedBytes = 0;
  int? _totalBytes;

  String get _progressLabel {
    if (_phase != _UpdatePhase.downloading) return '';
    final received = _receivedBytes;
    final total = _totalBytes;
    if (total == null || total <= 0) {
      return 'Downloading v${widget.info.version}… '
          '(${_fmtBytes(received)} so far)';
    }
    final percent = (received / total * 100).clamp(0, 100).toStringAsFixed(0);
    return 'Downloading v${widget.info.version}… $percent% '
        '(${_fmtBytes(received)} / ${_fmtBytes(total)})';
  }

  static String _fmtBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _startUpdate() async {
    setState(() {
      _phase = _UpdatePhase.downloading;
      _errorMessage = null;
      _receivedBytes = 0;
      _totalBytes = widget.info.assetSize;
    });

    String? installerPath;
    try {
      installerPath = await UpdateService.downloadUpdate(
        widget.info,
        onProgress: (received, total) {
          if (!mounted) return;
          setState(() {
            _receivedBytes = received;
            _totalBytes = total;
          });
        },
      );
    } on UpdateDownloadException catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.error;
        _errorMessage = e.message;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _phase = _UpdatePhase.error;
        _errorMessage = 'Unexpected error: $e';
      });
      return;
    }
    if (!mounted) return;

    setState(() => _phase = _UpdatePhase.installing);

    final started = await UpdateService.installUpdate(installerPath);
    if (!mounted) return;
    if (!started) {
      setState(() {
        _phase = _UpdatePhase.error;
        _errorMessage = 'Could not start the installer. You can download it '
            'manually from the release page.';
      });
      return;
    }

    // The installer now takes over (it relaunches Syndro after replacing the
    // files). Exit so the running exe does not lock the installation folder.
    exit(0);
  }

  @override
  Widget build(BuildContext context) {
    final info = widget.info;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_phase == _UpdatePhase.idle) ...[
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
        ] else if (_phase == _UpdatePhase.downloading) ...[
          Text(_progressLabel, style: Theme.of(context).textTheme.bodyMedium),
          const SizedBox(height: AppSpacing.md),
          LinearProgressIndicator(
            value: _totalBytes != null && _totalBytes! > 0
                ? (_receivedBytes / _totalBytes!).clamp(0.0, 1.0)
                : null,
            minHeight: 6,
            borderRadius: BorderRadius.circular(3),
          ),
        ] else if (_phase == _UpdatePhase.installing) ...[
          Text(
            'Installing update…',
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: AppSpacing.md),
          Text(
            'Syndro will close and restart automatically with the new version.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
          const SizedBox(height: AppSpacing.md),
          const LinearProgressIndicator(
            minHeight: 6,
            borderRadius: BorderRadius.all(Radius.circular(3)),
          ),
        ] else ...[
          Text(
            'Update failed',
            style: Theme.of(context).textTheme.titleSmall,
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            _errorMessage ?? 'Something went wrong.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: AppTheme.textSecondary,
                ),
          ),
        ],
        const SizedBox(height: AppSpacing.lg),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (_phase == _UpdatePhase.idle) ...[
              if (widget.allowSkip)
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
              if (widget.installer)
                FilledButton.icon(
                  onPressed: _startUpdate,
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Update now'),
                )
              else
                FilledButton.icon(
                  onPressed: () {
                    UpdateService.openDownload(info);
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(Icons.download, size: 18),
                  label: const Text('Download'),
                ),
            ] else if (_phase == _UpdatePhase.downloading ||
                _phase == _UpdatePhase.installing) ...[
              if (_phase == _UpdatePhase.downloading)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Background'),
                ),
            ] else ...[
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
              TextButton(
                onPressed: () {
                  UpdateService.openDownload(info);
                  Navigator.of(context).pop();
                },
                child: const Text('Open in browser'),
              ),
              FilledButton.icon(
                onPressed: _startUpdate,
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ],
        ),
      ],
    );
  }
}