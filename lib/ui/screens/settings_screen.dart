import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../theme/app_theme.dart';
import '../theme/app_dimens.dart';
import '../widgets/common/app_widgets.dart';
import '../../core/providers/device_provider.dart';
import '../../core/providers/transfer_provider.dart';
import '../../core/providers/theme_provider.dart';
import '../../core/services/app_settings_service.dart';
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
  bool _autoAcceptTrusted = false;
  bool _checkingUpdate = false;
  final AppSettingsService _settingsService = AppSettingsService();

  @override
  void initState() {
    super.initState();
    _loadVersion();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final autoAccept = await _settingsService.getAutoAcceptTrusted();
    if (mounted) {
      setState(() {
        _autoAcceptTrusted = autoAccept;
      });
    }
  }

  Future<void> _handleCheckForUpdates() async {
    setState(() => _checkingUpdate = true);
    UpdateInfo? info;
    var failed = false;
    try {
      info = await UpdateService.checkForUpdate();
    } catch (_) {
      failed = true;
    }
    if (!mounted) return;
    setState(() => _checkingUpdate = false);

    final messenger = ScaffoldMessenger.of(context);
    if (failed) {
      messenger.showSnackBar(
        const SnackBar(content: Text("Couldn't check for updates")),
      );
    } else if (info != null) {
      await showUpdateDialog(context, info);
    } else {
      messenger.showSnackBar(
        const SnackBar(content: Text("You're on the latest version")),
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

    final displayName = customNickname ?? currentDevice.name;
    final hasCustomNickname =
        customNickname != null && customNickname.isNotEmpty;

    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(AppSpacing.sm),
              decoration: BoxDecoration(
                gradient: AppTheme.logoGradient,
                borderRadius: AppRadius.smAll,
              ),
              child: const Icon(
                Icons.settings,
                color: Colors.white,
                size: 20,
              ),
            ),
            const SizedBox(width: AppSpacing.md),
            const Text('Settings'),
          ],
        ),
      ),
      body: Container(
        decoration: BoxDecoration(
          gradient: AppTheme.backgroundGradient,
        ),
        child: ListView(
          padding: const EdgeInsets.all(AppSpacing.lg),
          children: [
            // ============================================
            // DEVICE SECTION
            // ============================================
            _buildSectionHeader('Device'),
            const SizedBox(height: AppSpacing.md),

            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _buildSettingsTile(
                    icon: Icons.devices_rounded,
                    iconColor: AppTheme.primaryColor,
                    iconBgColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    title: Row(
                      children: [
                        const Text('Device Name'),
                        if (hasCustomNickname) ...[
                          const SizedBox(width: AppSpacing.sm),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: AppSpacing.sm,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: AppTheme.logoGradient,
                              borderRadius: AppRadius.smAll,
                            ),
                            child: const Text(
                              'Custom',
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    subtitle: Text(displayName),
                    trailing: IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceColor.withValues(alpha: 0.5),
                          borderRadius: AppRadius.smAll,
                        ),
                        child: const Icon(Icons.edit_rounded, size: 18),
                      ),
                      onPressed: _showEditNicknameDialog,
                      tooltip: 'Edit device name',
                    ),
                    onTap: _showEditNicknameDialog,
                  ),
                  const Divider(height: 1, indent: 60),
                  _buildSettingsTile(
                    icon: Icons.wifi_rounded,
                    iconColor: AppTheme.secondaryColor,
                    iconBgColor: AppTheme.secondaryColor.withValues(alpha: 0.15),
                    title: const Text('IP Address'),
                    subtitle: Text(currentDevice.ipAddress),
                    trailing: IconButton(
                      icon: Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: AppTheme.surfaceColor.withValues(alpha: 0.5),
                          borderRadius: AppRadius.smAll,
                        ),
                        child: const Icon(Icons.copy_rounded, size: 18),
                      ),
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
                      tooltip: 'Copy IP address',
                    ),
                  ),
                  const Divider(height: 1, indent: 60),
                  SwitchListTile(
                    secondary: Container(
                      padding: const EdgeInsets.all(AppSpacing.sm),
                      decoration: BoxDecoration(
                        color: AppTheme.successColor.withValues(alpha: 0.15),
                        borderRadius: AppRadius.mdAll,
                      ),
                      child: const Icon(
                        Icons.check_circle_outline,
                        color: AppTheme.successColor,
                        size: 24,
                      ),
                    ),
                    title: const Text('Auto-accept from trusted devices'),
                    subtitle: const Text(
                      'Automatically accept transfers from devices you trust',
                      style: TextStyle(fontSize: 12),
                    ),
                    value: _autoAcceptTrusted,
                    onChanged: (value) async {
                      // FIXED: Capture ScaffoldMessenger before async gap
                      final messenger = ScaffoldMessenger.of(context);
                      
                      await _settingsService.setAutoAcceptTrusted(value);
                      
                      if (mounted) {
                        setState(() {
                          _autoAcceptTrusted = value;
                        });
                        
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
                      }
                    },
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xxxl),

            // ============================================
            // APPEARANCE SECTION
            // ============================================
            _buildSectionHeader('Appearance'),
            const SizedBox(height: AppSpacing.md),

            AppCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(AppSpacing.sm),
                        decoration: BoxDecoration(
                          color: AppTheme.primaryColor.withValues(alpha: 0.15),
                          borderRadius: AppRadius.mdAll,
                        ),
                        child: const Icon(
                          Icons.palette_outlined,
                          color: AppTheme.primaryColor,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: AppSpacing.md),
                      Text(
                        'Theme',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.lg),
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
                    onSelectionChanged: (Set<ThemeMode> selected) {
                      ref.read(themeModeProvider.notifier).setThemeMode(selected.first);
                    },
                    style: ButtonStyle(
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return AppTheme.primaryColor;
                        }
                        return Colors.transparent;
                      }),
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return Colors.white;
                        }
                        return AppTheme.textSecondary;
                      }),
                      side: WidgetStateProperty.all(
                        BorderSide(color: AppTheme.borderColor),
                      ),
                      shape: WidgetStateProperty.all(
                        const RoundedRectangleBorder(
                          borderRadius: AppRadius.mdAll,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xxxl),

            // ============================================
            // TRUSTED DEVICES SECTION
            // ============================================
            _buildSectionHeader('Trusted Devices'),
            const SizedBox(height: AppSpacing.md),

            _buildTrustedDevicesSection(),

            const SizedBox(height: AppSpacing.xxxl),

            // ============================================
            // ABOUT SECTION
            // ============================================
            _buildSectionHeader('About'),
            const SizedBox(height: AppSpacing.md),

            AppCard(
              padding: EdgeInsets.zero,
              child: Column(
                children: [
                  _buildSettingsTile(
                    icon: Icons.info_outline,
                    iconColor: AppTheme.primaryColor,
                    iconBgColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    title: const Text('Version'),
                    subtitle: Text(_version),
                  ),
                  const Divider(height: 1, indent: 60),
                  _buildSettingsTile(
                    icon: Icons.system_update,
                    iconColor: AppTheme.primaryColor,
                    iconBgColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    title: const Text('Check for updates'),
                    subtitle: Text(
                      _checkingUpdate ? 'Checking…' : 'Get the latest version',
                    ),
                    trailing: _checkingUpdate
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Icon(Icons.chevron_right,
                            color: AppTheme.textTertiary),
                    onTap: _checkingUpdate ? null : _handleCheckForUpdates,
                  ),
                  const Divider(height: 1, indent: 60),
                  _buildSettingsTile(
                    icon: Icons.share,
                    iconColor: AppTheme.primaryColor,
                    iconBgColor: AppTheme.primaryColor.withValues(alpha: 0.15),
                    title: const Text('Syndro'),
                    subtitle: const Text('Fast & secure file sharing'),
                  ),
                ],
              ),
            ),

            const SizedBox(height: AppSpacing.xxxl),

            // Developer Credit
            Center(
              child: Column(
                children: [
                  const Divider(),
                  const SizedBox(height: AppSpacing.lg),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        'Made by ',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.textTertiary,
                            ),
                      ),
                      Text(
                        AppConfig.developerName,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: AppTheme.primaryColor,
                              fontWeight: FontWeight.w600,
                            ),
                      ),
                    ],
                  ),
                  const SizedBox(height: AppSpacing.md),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: AppSpacing.lg,
                      vertical: AppSpacing.sm,
                    ),
                    decoration: BoxDecoration(
                      gradient: AppTheme.logoGradient,
                      borderRadius: AppRadius.xlAll,
                      // ignore: prefer_const_literals_to_create_immutables
                      boxShadow: [
                        BoxShadow(
                          color: AppTheme.primaryColor.withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.favorite,
                          color: Colors.white,
                          size: 16,
                        ),
                        SizedBox(width: AppSpacing.sm),
                        Text(
                          'Built with Flutter',
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 100),
          ],
        ),
      ),
    );
  }

  Widget _buildTrustedDevicesSection() {
    final trustedDevices = ref.watch(trustedDevicesProvider);
    final transferService = ref.read(transferServiceProvider);

    if (trustedDevices.isEmpty) {
      return AppCard(
        padding: EdgeInsets.zero,
        child: _buildSettingsTile(
          icon: Icons.shield_outlined,
          iconColor: AppTheme.textTertiary,
          iconBgColor: AppTheme.textTertiary.withValues(alpha: 0.15),
          title: const Text('No trusted devices'),
          subtitle: const Text(
            'Devices you approve for transfer will appear here',
            style: TextStyle(fontSize: 12),
          ),
        ),
      );
    }

    return AppCard(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (int i = 0; i < trustedDevices.length; i++) ...[
            if (i > 0) const Divider(height: 1, indent: 60),
            _buildTrustedDeviceTile(trustedDevices[i], transferService),
          ],
        ],
      ),
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
      iconBgColor: (hasPin ? AppTheme.successColor : AppTheme.secondaryColor)
          .withValues(alpha: 0.15),
      title: Text(device.senderName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            hasPin ? 'Pinned \u2022 $timeAgo' : 'No pin \u2022 $timeAgo',
            style: const TextStyle(fontSize: 12),
          ),
        ],
      ),
      trailing: PopupMenuButton<String>(
        icon: Container(
          padding: const EdgeInsets.all(AppSpacing.sm),
          decoration: BoxDecoration(
            color: AppTheme.surfaceColor.withValues(alpha: 0.5),
            borderRadius: AppRadius.smAll,
          ),
          child: const Icon(Icons.more_vert_rounded, size: 18),
        ),
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

  Widget _buildSettingsTile({
    required IconData icon,
    required Color iconColor,
    required Color iconBgColor,
    required Widget title,
    required Widget subtitle,
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
              Container(
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      iconColor.withValues(alpha: 0.2),
                      iconColor.withValues(alpha: 0.1),
                    ],
                  ),
                  borderRadius: AppRadius.mdAll,
                  border: Border.all(
                    color: iconColor.withValues(alpha: 0.3),
                    width: 1,
                  ),
                ),
                child: Icon(
                  icon,
                  color: iconColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    title,
                    const SizedBox(height: AppSpacing.xs),
                    subtitle,
                  ],
                ),
              ),
              if (trailing != null) trailing,
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return SectionHeader(title: title);
  }
} 
