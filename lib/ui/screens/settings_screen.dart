import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/providers/device_provider.dart';
import '../../core/providers/settings_provider.dart';
import '../../core/providers/transfer_provider.dart';
import '../../core/providers/theme_provider.dart';
import '../../core/services/update_service.dart';
import '../../core/utils/app_logger.dart';
import '../../core/widgets/update_dialog.dart';
import '../../core/services/transfer_service/models.dart';
import '../../core/services/transfer_service/transfer_service_impl.dart';
import '../../core/config/app_config.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _version = 'Loading...';
  bool _checkingUpdate = false;
  String? _downloadDirectory;

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadDownloadDirectory();
  }

  /// Where received files land. Read-only: the app picks it per platform and
  /// there is no override to edit, so the row reports rather than pretends.
  Future<void> _loadDownloadDirectory() async {
    try {
      final dir = await ref.read(fileServiceProvider).getDownloadDirectory();
      if (mounted) setState(() => _downloadDirectory = dir);
    } catch (e) {
      AppLogger.info('Download directory unavailable: $e');
      if (mounted) setState(() => _downloadDirectory = 'Not available');
    }
  }

  Future<void> _handleCheckForUpdates() async {
    setState(() => _checkingUpdate = true);
    UpdateCheckResult result;
    try {
      result = await UpdateService.checkForUpdate();
    } catch (e) {
      // checkForUpdate never throws; stay defensive anyway.
      result = UpdateCheckFailed('Unexpected error: $e');
    }
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    final messenger = ScaffoldMessenger.of(context);
    if (result is UpdateAvailable) {
      await showUpdateDialog(context, result.info);
    } else if (result is UpToDate) {
      final current = result.currentVersion;
      if (result.localNewerThanLatest) {
        // The install predates a repo reset or the newer release was deleted;
        // explain instead of the misleading "latest version".
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              'Your installed version (v$current) is newer than the latest '
              'release (v${result.latestVersion}) — nothing to update to.',
            ),
          ),
        );
      } else if (result.latestVersion.isEmpty) {
        messenger.showSnackBar(
          SnackBar(content: Text("You're on version v$current.")),
        );
      } else {
        messenger.showSnackBar(
          SnackBar(content: Text("You're on the latest version (v$current).")),
        );
      }
    } else if (result is UpdateCheckFailed) {
      messenger.showSnackBar(
        SnackBar(
          content: Text("Couldn't check for updates — ${result.reason}"),
        ),
      );
    }
  }

  Future<void> _loadVersion() async {
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      if (mounted) {
        setState(() {
          final build = packageInfo.buildNumber;
          // Windows reports a "0" build number; hide it for a clean display.
          _version = (build.isEmpty || build == '0')
              ? packageInfo.version
              : '${packageInfo.version} ($build)';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _version = 'Unknown';
        });
      }
    }
  }

  void _showEditNicknameDialog() {
    final currentDevice = ref.read(currentDeviceProvider);
    final currentNickname = ref.read(currentDeviceNicknameProvider);

    final controller = TextEditingController(
      text: currentNickname ?? currentDevice.name,
    );

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                color: AppTheme.primaryColor.withValues(alpha: 0.2),
                borderRadius: AppRadius.smAll,
              ),
              child: const Icon(
                Icons.edit_rounded,
                color: AppTheme.primaryColor,
                size: 24,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const Text('Edit Device Name'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'This name will be visible to other devices on the network.',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                  ),
            ),
            const SizedBox(height: AppSpacing.lg),
            TextField(
              controller: controller,
              autofocus: false, // FIXED (Bug #14): Disable autofocus to prevent keyboard trap
              maxLength: 30,
              textInputAction: TextInputAction.done, // FIXED (Bug #13): Add text input action
              inputFormatters: [
                FilteringTextInputFormatter.deny(RegExp(r'[<>:"/\\|?*]')),
              ],
              decoration: InputDecoration(
                labelText: 'Device Name',
                hintText: 'Enter a custom name',
                prefixIcon: const Icon(Icons.devices_rounded),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => controller.clear(),
                ),
                border: const OutlineInputBorder(
                  borderRadius: AppRadius.mdAll,
                ),
              ),
              onSubmitted: (_) {
                // FIXED (Bug #13): Dismiss keyboard on submit
                FocusScope.of(dialogContext).unfocus();
                _saveNickname(dialogContext, controller.text);
              },
            ),
            const SizedBox(height: AppSpacing.sm),
            Text(
              'Original name: ${currentDevice.name}',
              style: Theme.of(dialogContext).textTheme.bodySmall?.copyWith(
                    color: AppTheme.textTertiary,
                    fontStyle: FontStyle.italic,
                  ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              await ref
                  .read(currentDeviceNicknameProvider.notifier)
                  .clearNickname();
              if (dialogContext.mounted) {
                Navigator.pop(dialogContext);
              }
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Device name reset to default'),
                    backgroundColor: AppTheme.successColor,
                  ),
                );
              }
            },
            child: const Text('Reset'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => _saveNickname(dialogContext, controller.text),
            child: const Text('Save'),
          ),
        ],
      ),
    ).whenComplete(() {
      // FIXED (Bug #12): Dispose controller when dialog closes
      controller.dispose();
    });
  }

  Future<void> _saveNickname(
      BuildContext dialogContext, String nickname) async {
    final trimmedName = nickname.trim();

    if (trimmedName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device name cannot be empty'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    if (trimmedName.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Device name must be at least 2 characters'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
      return;
    }

    final success = await ref
        .read(currentDeviceNicknameProvider.notifier)
        .setNickname(trimmedName);

    if (dialogContext.mounted) {
      Navigator.pop(dialogContext);
    }

    if (mounted) {
      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Device name changed to "$trimmedName"'),
            backgroundColor: AppTheme.successColor,
          ),
        );
        ref.read(deviceDiscoveryServiceProvider).refreshDevices();
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to save device name'),
            backgroundColor: AppTheme.errorColor,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentDevice = ref.watch(currentDeviceProvider);
    final customNickname = ref.watch(currentDeviceNicknameProvider);
    final trustedCount = ref.watch(trustedDevicesProvider).length;

    final displayName = customNickname ?? currentDevice.name;
    final hasCustomNickname =
        customNickname != null && customNickname.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        titleSpacing: AppSpacing.lg,
        title: const Text('Settings'),
      ),
      body: ResponsiveCenter(
        maxWidth: 760,
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // ── GENERAL ────────────────────────────────────────────────
            _buildSectionHeader('General'),
            const SizedBox(height: AppSpacing.md),
            _Group(
              children: [
                _buildSettingsTile(
                  icon: Icons.devices_rounded,
                  title: 'Device name',
                  subtitle: displayName,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (hasCustomNickname)
                        const Padding(
                          padding: EdgeInsets.only(right: AppSpacing.sm),
                          child: StatusBadge(
                            label: 'Renamed',
                            variant: BadgeVariant.primary,
                          ),
                        ),
                      Icon(Icons.edit_outlined,
                          size: 18, color: AppTheme.textTertiary),
                    ],
                  ),
                  onTap: _showEditNicknameDialog,
                ),
                const Divider(height: 1, indent: 60),
                Padding(
                  padding: const EdgeInsets.all(AppSpacing.lg),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.palette_outlined,
                              size: 20, color: AppTheme.textSecondary),
                          const SizedBox(width: AppSpacing.md),
                          Text('Appearance',
                              style: Theme.of(context).textTheme.titleSmall),
                        ],
                      ),
                      const SizedBox(height: AppSpacing.md),
                      // The theme's own SegmentedButtonTheme already carries
                      // the selected state; the old inline style overrode it
                      // with a solid purple fill on every segment.
                      SegmentedButton<ThemeMode>(
                        segments: const [
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.dark,
                            icon: Icon(Icons.dark_mode_outlined, size: 18),
                            label: Text('Dark'),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.light,
                            icon: Icon(Icons.light_mode_outlined, size: 18),
                            label: Text('Light'),
                          ),
                          ButtonSegment<ThemeMode>(
                            value: ThemeMode.system,
                            icon: Icon(Icons.brightness_auto_outlined, size: 18),
                            label: Text('System'),
                          ),
                        ],
                        selected: {ref.watch(themeModeProvider)},
                        onSelectionChanged: (Set<ThemeMode> selected) => ref
                            .read(themeModeProvider.notifier)
                            .setThemeMode(selected.first),
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: AppSpacing.xxl),

            // ── TRANSFER ───────────────────────────────────────────────
            _buildSectionHeader('Transfer'),
            const SizedBox(height: AppSpacing.md),
            _Group(
              children: [
                SwitchListTile(
                  secondary: const _TileIcon(Icons.check_circle_outline),
                  title: const Text('Auto-accept from trusted devices'),
                  subtitle: const Text(
                    'Automatically accept transfers from devices you trust',
                  ),
                  value: ref.watch(autoAcceptTrustedProvider),
                  onChanged: (value) async {
                    // FIXED: Capture ScaffoldMessenger before async gap
                    final messenger = ScaffoldMessenger.of(context);

                    await ref
                        .read(autoAcceptTrustedProvider.notifier)
                        .set(value);

                    if (!mounted) return;
                    messenger.showSnackBar(
                      SnackBar(
                        content: Text(
                          value
                              ? 'Auto-accept enabled for trusted devices'
                              : 'Will always ask for approval',
                        ),
                        duration: const Duration(seconds: 2),
                      ),
                    );
                  },
                ),
                const Divider(height: 1, indent: 60),
                _buildSettingsTile(
                  icon: Icons.download_outlined,
                  title: 'Download location',
                  subtitle: _downloadDirectory ?? 'Loading…',
                ),
              ],
            ),

            const SizedBox(height: AppSpacing.xxl),

            // ── NETWORK ────────────────────────────────────────────────
            _buildSectionHeader('Network'),
            const SizedBox(height: AppSpacing.md),
            _Group(
              children: [
                _buildSettingsTile(
                  icon: Icons.wifi_rounded,
                  title: 'IP address',
                  subtitle: currentDevice.ipAddress,
                  trailing: IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 18),
                    tooltip: 'Copy IP address',
                    onPressed: () {
                      Clipboard.setData(
                        ClipboardData(text: currentDevice.ipAddress),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('IP address copied to clipboard'),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                  ),
                ),
                const Divider(height: 1, indent: 60),
                _buildSettingsTile(
                  icon: Icons.numbers_outlined,
                  title: 'Transfer port',
                  subtitle: '${AppConfig.defaultTransferPort}–'
                      '${AppConfig.defaultTransferPort + 5}',
                  // The service binds the first free port in that range at
                  // startup, so this is where to look when a peer is missing —
                  // not a field the user can change.
                  note: 'First free port in the range',
                ),
              ],
            ),

            const SizedBox(height: AppSpacing.xxl),

            // ── SECURITY ───────────────────────────────────────────────
            _buildSectionHeader('Security'),
            const SizedBox(height: AppSpacing.md),
            _Group(
              children: [
                _buildSettingsTile(
                  icon: Icons.lock_outline,
                  title: 'Encryption',
                  subtitle: _encryptionSummary,
                ),
                const Divider(height: 1, indent: 60),
                _buildSettingsTile(
                  icon: Icons.shield_outlined,
                  title: 'Trusted devices',
                  subtitle: trustedCount == 0
                      ? 'Devices you approve for transfer will appear here'
                      : '$trustedCount device'
                          '${trustedCount == 1 ? '' : 's'} can send without asking',
                ),
                const Divider(height: 1, indent: 60),
                _buildTrustedDevicesBody(),
              ],
            ),

            const SizedBox(height: AppSpacing.xxl),

            // ── ABOUT ──────────────────────────────────────────────────
            _buildSectionHeader('About'),
            const SizedBox(height: AppSpacing.md),
            _Group(
              children: [
                _buildSettingsTile(
                  icon: Icons.info_outline,
                  title: 'Version',
                  subtitle: _version,
                ),
                const Divider(height: 1, indent: 60),
                _buildSettingsTile(
                  icon: Icons.system_update_alt,
                  title: 'Check for updates',
                  subtitle: 'Get the latest version',
                  trailing: _checkingUpdate
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.chevron_right, size: 18),
                  onTap: _checkingUpdate ? null : _handleCheckForUpdates,
                ),
                const Divider(height: 1, indent: 60),
                _buildSettingsTile(
                  icon: Icons.code,
                  title: 'GitHub',
                  subtitle: 'Source, issues and releases',
                  trailing: const Icon(Icons.open_in_new, size: 18),
                  onTap: _openRepository,
                ),
              ],
            ),

            const SizedBox(height: AppSpacing.xxl),

            Center(
              child: Text(
                'Made by ${AppConfig.developerName} · built with Flutter',
                style: Theme.of(context).textTheme.bodySmall,
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: AppSpacing.xxxl),
          ],
        ),
      ),
    );
  }

  Future<void> _openRepository() async {
    final uri = Uri.parse(AppConfig.repositoryUrl);
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open the repository: $e'),
          backgroundColor: AppTheme.errorColor,
        ),
      );
    }
  }

  /// What the transfer service will actually do with an incoming payload.
  ///
  /// Reports the service's current setting rather than a promise: the desktop
  /// build can run with encryption off, and the row would otherwise lie.
  String get _encryptionSummary {
    final enabled = ref.watch(transferServiceProvider).encryptionEnabled;
    return enabled
        ? 'Transfers between devices are encrypted'
        : 'Disabled on this build — transfers are not encrypted';
  }

  /// The trusted-device list, inline under its own heading in the Security
  /// group.
  Widget _buildTrustedDevicesBody() {
    final trustedDevices = ref.watch(trustedDevicesProvider);
    if (trustedDevices.isEmpty) return const SizedBox.shrink();

    return Column(
      children: [
        for (int i = 0; i < trustedDevices.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 60),
          _buildTrustedDeviceTile(trustedDevices[i], ref.read(transferServiceProvider)),
        ],
      ],
    );
  }

  Widget _buildTrustedDeviceTile(
      TrustedDevice device, TransferService transferService) {
    final hasPin = device.hasActivePin;
    final lastTrusted = device.trustedAt;
    final timeAgo = _formatTimeAgo(lastTrusted);

    return _buildSettingsTile(
      icon: hasPin ? Icons.verified_user : Icons.person_outline,
      iconColor: hasPin ? AppTheme.successColor : AppTheme.secondaryColor,
      title: device.senderName,
      subtitle: hasPin
          ? 'Key pinned • trusted $timeAgo'
          : 'No key pinned • trusted $timeAgo',
      trailing: PopupMenuButton<String>(
        tooltip: 'Trust options',
        icon: const Icon(Icons.more_vert_rounded, size: 20),
        onSelected: (value) async {
          if (value == 'rotate') {
            try {
              await transferService.rotatePinnedKey(device.senderId);
              if (mounted) {
                ref.invalidate(trustedDevicesProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                        'Pin reset for ${device.senderName} \u2014 re-pair on next transfer'),
                    backgroundColor: AppTheme.secondaryColor,
                  ),
                );
              }
            } catch (e) {
              AppLogger.error('Error resetting pin for ${device.senderId}: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to reset pin: $e'),
                    backgroundColor: AppTheme.errorColor,
                  ),
                );
              }
            }
          } else if (value == 'revoke') {
            try {
              await transferService.revokeTrust(device.senderId);
              if (mounted) {
                ref.invalidate(trustedDevicesProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Trust revoked for ${device.senderName}'),
                    backgroundColor: AppTheme.errorColor,
                  ),
                );
              }
            } catch (e) {
              AppLogger.error('Error revoking trust for ${device.senderId}: $e');
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Failed to revoke trust: $e'),
                    backgroundColor: AppTheme.errorColor,
                  ),
                );
              }
            }
          }
        },
        itemBuilder: (context) => [
          const PopupMenuItem(
            value: 'rotate',
            child: Row(
              children: [
                Icon(Icons.refresh, size: 18),
                SizedBox(width: AppSpacing.sm),
                Text('Reset trust'),
              ],
            ),
          ),
          const PopupMenuItem(
            value: 'revoke',
            child: Row(
              children: [
                Icon(Icons.delete_outline, size: 18, color: AppTheme.errorColor),
                SizedBox(width: AppSpacing.sm),
                Text('Revoke trust',
                    style: TextStyle(color: AppTheme.errorColor)),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _formatTimeAgo(DateTime dateTime) {
    final diff = DateTime.now().difference(dateTime);
    if (diff.inDays > 30) return '${(diff.inDays / 30).floor()}mo ago';
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    if (diff.inMinutes > 0) return '${diff.inMinutes}m ago';
    return 'Just now';
  }

  /// One row in a settings group: icon, label, current value, optional control.
  ///
  /// Read-only rows get no chevron and no ink response, so a value that cannot
  /// be changed does not look like one that can.
  Widget _buildSettingsTile({
    required IconData icon,
    required String title,
    String? subtitle,
    String? note,
    Color? iconColor,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: AppRadius.lgAll,
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.lg),
          child: Row(
            children: [
              _TileIcon(icon, color: iconColor),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(title, style: Theme.of(context).textTheme.titleSmall),
                    if (subtitle != null) ...[
                      const SizedBox(height: AppSpacing.xs),
                      Text(
                        subtitle,
                        style: Theme.of(context).textTheme.bodySmall,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    if (note != null) ...[
                      const SizedBox(height: 2),
                      Text(
                        note,
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: AppSpacing.md),
                trailing,
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.only(left: AppSpacing.xs),
      child: Text(
        title.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              letterSpacing: 1.1,
            ),
      ),
    );
  }
}

/// A settings group: one flat container holding rows split by hairlines.
///
/// The [Material] is not decoration — a [ListTile] inside a plain [Container]
/// reports that its own ink and background may be invisible, because it looks
/// for a surrounding Material that actually paints the group's colour.
class _Group extends StatelessWidget {
  const _Group({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppTheme.surfaceContainer,
      borderRadius: AppRadius.lgAll,
      clipBehavior: Clip.antiAlias,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: AppRadius.lgAll,
          border: Border.all(color: AppTheme.outlineVariant, width: 1),
        ),
        child: Column(children: children),
      ),
    );
  }
}

/// Leading glyph for a settings row. Tonal, not gradient: a screen where every
/// icon glows is a screen where none of them mean anything.
class _TileIcon extends StatelessWidget {
  const _TileIcon(this.icon, {this.color});

  final IconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final tone = color ?? AppTheme.textSecondary;
    return Container(
      width: 32,
      height: 32,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: AppRadius.smAll,
      ),
      child: Icon(icon, size: 18, color: tone),
    );
  }
}
