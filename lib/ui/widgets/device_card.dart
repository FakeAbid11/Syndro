import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import '../../core/models/device.dart';
import '../../core/providers/device_nickname_provider.dart';
import '../../core/providers/transfer_provider.dart';
import 'device_nickname_dialog.dart';

/// Device card: name, then `Platform • IP address`, then connection status.
///
/// On desktop the card is also a right-click target (send, rename, details,
/// trust) and reveals a trailing send affordance on hover. On touch the
/// long-press keeps its meaning — the parent decides whether that is
/// multi-select or the rename dialog — and nothing hovers.
class DeviceCard extends ConsumerStatefulWidget {
  final Device device;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Sends files to this device specifically. When null, the hover send
  /// affordance and the context-menu entry are both omitted, which is how the
  /// mobile and quick-send callers keep their existing behaviour.
  final VoidCallback? onSendFiles;
  final bool isSelected;

  const DeviceCard({
    super.key,
    required this.device,
    this.onTap,
    this.onLongPress,
    this.onSendFiles,
    this.isSelected = false,
  });

  @override
  ConsumerState<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<DeviceCard> {
  bool _isTapped = false;
  bool _isHovered = false;
  bool _hasFocus = false;
  Timer? _tapDebounceTimer;

  static final bool _showsPointerActions =
      !Platform.isAndroid && !Platform.isIOS;

  void _handleTap() {
    if (widget.onTap == null || _isTapped) return;
    HapticFeedback.selectionClick();

    setState(() => _isTapped = true);

    _tapDebounceTimer?.cancel();
    _tapDebounceTimer = Timer(const Duration(milliseconds: 100), () {
      if (mounted) {
        setState(() => _isTapped = false);
        widget.onTap?.call();
      }
    });
  }

  void _handleLongPress() {
    // If onLongPress callback is provided, use it (for multi-select)
    if (widget.onLongPress != null) {
      widget.onLongPress!();
      return;
    }
    // Otherwise show nickname dialog (default behavior)
    _rename();
  }

  @override
  void dispose() {
    _tapDebounceTimer?.cancel();
    super.dispose();
  }

  bool get _isTrusted => ref
      .read(trustedDevicesProvider)
      .any((trusted) => trusted.senderId == widget.device.id);

  Future<void> _rename() async {
    await showDialog<void>(
      context: context,
      builder: (context) {
        final nickname = ref.read(deviceNicknameProvider)[widget.device.id];
        return DeviceNicknameDialog(
          deviceName: widget.device.name,
          currentNickname: nickname,
          onSave: (newNickname) async {
            await ref
                .read(deviceNicknameProvider.notifier)
                .setNickname(widget.device.id, newNickname ?? '');
          },
        );
      },
    );
  }

  Future<void> _revokeTrust() async {
    final service = ref.read(transferServiceProvider);
    await service.revokeTrust(widget.device.id);
    if (!mounted) return;
    ref.invalidate(trustedDevicesProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${widget.device.name} is no longer trusted'),
        backgroundColor: AppTheme.warningColor,
      ),
    );
  }

  /// Right-click menu. Every entry maps to a capability the app already has;
  /// there is deliberately no "trust this device", because trust is granted
  /// during a transfer approval (with a key pin), not from a browse result.
  Future<void> _showContextMenu(Offset globalPosition) async {
    final send = widget.onSendFiles;
    final trusted = _isTrusted;
    final selected = await showMenu<String>(
      context: context,
      position: _menuPosition(globalPosition),
      color: AppTheme.surfaceContainerHigh,
      items: [
        if (send != null)
          const PopupMenuItem(
            value: 'send',
            child: _MenuRow(icon: Icons.upload_rounded, label: 'Send files'),
          ),
        const PopupMenuItem(
          value: 'rename',
          child: _MenuRow(icon: Icons.edit_rounded, label: 'Rename device'),
        ),
        const PopupMenuItem(
          value: 'details',
          child: _MenuRow(icon: Icons.info_outline_rounded, label: 'View details'),
        ),
        if (trusted)
          const PopupMenuItem(
            value: 'untrust',
            child: _MenuRow(
              icon: Icons.gpp_bad_outlined,
              label: 'Remove trust',
              foreground: AppTheme.errorColor,
            ),
          ),
      ],
    );
    if (!mounted || selected == null) return;
    switch (selected) {
      case 'send':
        send?.call();
      case 'rename':
        await _rename();
      case 'details':
        await showDialog<void>(
          context: context,
          builder: (_) => DeviceDetailsDialog(device: widget.device),
        );
      case 'untrust':
        await _revokeTrust();
    }
  }

  /// Anchors the menu at the cursor and keeps it inside the window.
  RelativeRect _menuPosition(Offset globalPosition) {
    final view = View.of(context);
    final size = view.physicalSize / view.devicePixelRatio;
    return RelativeRect.fromLTRB(
      globalPosition.dx,
      globalPosition.dy,
      size.width - globalPosition.dx,
      size.height - globalPosition.dy,
    );
  }

  @override
  Widget build(BuildContext context) {
    final nickname = ref.watch(deviceNicknameProvider)[widget.device.id];
    final displayName = nickname ?? widget.device.name;
    final hasNickname = nickname != null;
    final device = widget.device;
    final iconColor = device.platform.iconColor;
    final online = device.isOnline;

    return Semantics(
      label:
          '$displayName, ${device.platform.displayName}, ${online ? "Online" : "Offline"}',
      button: true,
      child: MouseRegion(
        cursor: widget.onTap == null
            ? MouseCursor.defer
            : SystemMouseCursors.click,
        onEnter: (_) {
          if (mounted) setState(() => _isHovered = true);
        },
        onExit: (_) {
          if (mounted) setState(() => _isHovered = false);
        },
        child: AnimatedContainer(
          duration: AppMotion.fast,
          curve: AppMotion.standard,
          transform: Matrix4.diagonal3Values(
            _isTapped ? 0.98 : 1.0,
            _isTapped ? 0.98 : 1.0,
            1.0,
          ),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.primaryContainer
                : _isHovered
                    ? AppTheme.surfaceContainerHigh
                    : AppTheme.surfaceContainer,
            borderRadius: AppRadius.xlAll,
            // Selection is carried by fill plus border weight, not by a glow:
            // a shadowed card next to a shadowed card stops meaning anything.
            // Keyboard focus gets its own weight so Tab is visible without
            // having to guess which card the ink ring is on.
            border: Border.all(
              color: widget.isSelected || _hasFocus
                  ? AppTheme.primaryColor
                  : AppTheme.outlineVariant,
              width: _hasFocus ? 2.5 : (widget.isSelected ? 1.6 : 1),
            ),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _handleTap,
              onFocusChange: (focused) {
                if (mounted) setState(() => _hasFocus = focused);
              },
              onLongPress: _handleLongPress,
              onSecondaryTapDown: _showsPointerActions
                  ? (event) => _showContextMenu(event.globalPosition)
                  : null,
              borderRadius: AppRadius.xlAll,
              splashColor: AppTheme.primaryColor.withValues(alpha: 0.15),
              highlightColor: AppTheme.primaryColor.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.md),
                child: Row(
                  children: [
                    // Platform icon tile — tonal, keeps the platform tint.
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.14),
                        borderRadius: AppRadius.mdAll,
                        border: Border.all(
                          color: iconColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          device.platform.icon,
                          size: 20,
                          color: iconColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            displayName,
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 2),
                          // Platform and address on one line, so the card is
                          // three rows of information instead of five.
                          Row(
                            children: [
                              Flexible(
                                child: Text(
                                  device.platform.displayName,
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                ' • ',
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                              Flexible(
                                child: Text(
                                  device.ipAddress,
                                  style:
                                      Theme.of(context).textTheme.bodySmall,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (hasNickname) ...[
                                const SizedBox(width: AppSpacing.xs),
                                Icon(
                                  Icons.edit_rounded,
                                  size: 11,
                                  color: AppTheme.textTertiary,
                                  // The original broadcast name stays readable
                                  // to screen readers and to a hover tooltip.
                                  semanticLabel:
                                      'Renamed from ${device.name}',
                                ),
                              ],
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: AppSpacing.sm),
                    // The trailing slot keeps a stable width: status normally,
                    // send on hover, so nothing reflows under the cursor.
                    AnimatedSwitcher(
                      duration: AppMotion.fast,
                      child: _isHovered && widget.onSendFiles != null
                          ? IconButton(
                              key: const ValueKey('send'),
                              icon: const Icon(Icons.arrow_forward_rounded),
                              color: AppTheme.primaryColor,
                              tooltip: 'Send files',
                              onPressed: widget.onSendFiles,
                            )
                          : _ConnectionLabel(
                              key: const ValueKey('status'),
                              online: online,
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Connection state as a dot plus a word, never as a colour alone.
class _ConnectionLabel extends StatelessWidget {
  const _ConnectionLabel({super.key, required this.online});

  final bool online;

  @override
  Widget build(BuildContext context) {
    final color = online ? AppTheme.successColor : AppTheme.textTertiary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: AppSpacing.sm - 2),
        Text(
          online ? 'Online' : 'Offline',
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: color,
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({
    required this.icon,
    required this.label,
    this.foreground,
  });

  final IconData icon;
  final String label;
  final Color? foreground;

  @override
  Widget build(BuildContext context) {
    final color = foreground ?? AppTheme.textPrimary;
    return Row(
      children: [
        Icon(icon, size: 18, color: color),
        const SizedBox(width: AppSpacing.md),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: color, fontSize: 14),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}

/// Everything discovery actually knows about a peer.
///
/// Reports only fields the [Device] model carries — no guessed hardware or
/// battery information.
class DeviceDetailsDialog extends StatelessWidget {
  const DeviceDetailsDialog({super.key, required this.device});

  final Device device;

  @override
  Widget build(BuildContext context) {
    final seen = device.lastSeen;
    final age = DateTime.now().difference(seen);
    final lastSeen = age.isNegative || age.inMinutes < 1
        ? 'Just now'
        : age.inMinutes < 60
            ? '${age.inMinutes} min ago'
            : '${seen.day}/${seen.month}/${seen.year} '
                '${seen.hour.toString().padLeft(2, '0')}:'
                '${seen.minute.toString().padLeft(2, '0')}';

    return AlertDialog(
      backgroundColor: AppTheme.surfaceColor,
      shape: const RoundedRectangleBorder(borderRadius: AppRadius.xlAll),
      title: Row(
        children: [
          Icon(device.platform.icon, color: device.platform.iconColor),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Text(
              device.name,
              style: Theme.of(context).textTheme.titleLarge,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _DetailRow(label: 'Platform', value: device.platform.displayName),
          _DetailRow(label: 'Address', value: '${device.ipAddress}:${device.port}'),
          _DetailRow(
            label: 'Connection',
            value: device.isOnline ? 'Online' : 'Offline',
          ),
          _DetailRow(
            label: 'Same subnet',
            value: device.subnet == null ? 'Unknown' : 'Yes',
          ),
          _DetailRow(
            label: 'Private network',
            value: device.isOnPrivateNetwork ? 'Yes' : 'No',
          ),
          _DetailRow(label: 'Last seen', value: lastSeen),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs + 1),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(context).textTheme.bodyMedium,
              textAlign: TextAlign.end,
            ),
          ),
        ],
      ),
    );
  }
}
