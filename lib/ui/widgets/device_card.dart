import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import '../../core/models/device.dart';
import '../../core/providers/device_nickname_provider.dart';
import 'common/app_widgets.dart';
import 'device_nickname_dialog.dart';

/// Device card with nickname support
class DeviceCard extends ConsumerStatefulWidget {
  final Device device;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool isSelected;

  const DeviceCard({
    super.key,
    required this.device,
    this.onTap,
    this.onLongPress,
    this.isSelected = false,
  });

  @override
  ConsumerState<DeviceCard> createState() => _DeviceCardState();
}

class _DeviceCardState extends ConsumerState<DeviceCard> {
  bool _isTapped = false;
  Timer? _tapDebounceTimer; // FIXED (Bug #8): Add timer for cleanup

  void _handleTap() {
    if (widget.onTap == null || _isTapped) return;
    HapticFeedback.selectionClick();

    setState(() => _isTapped = true);

    // FIXED (Bug #8): Cancel existing timer to prevent conflicts
    _tapDebounceTimer?.cancel();
    
    // FIXED (Bug #8): Reduce delay from 150ms to 100ms for better UX
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
    showDialog(
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

  // FIXED (Bug #8): Cleanup timer on dispose
  @override
  void dispose() {
    _tapDebounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final nickname = ref.watch(deviceNicknameProvider)[widget.device.id];
    final displayName = nickname ?? widget.device.name;
    final hasNickname = nickname != null;

    final iconColor = widget.device.platform.iconColor;

    return Semantics(
      label:
          '$displayName, ${widget.device.platform.displayName}, ${widget.device.isOnline ? "Online" : "Offline"}',
      button: true,
      child: AnimatedContainer(
        duration: AppMotion.fast,
        transform: Matrix4.diagonal3Values(_isTapped ? 0.97 : 1.0, _isTapped ? 0.97 : 1.0, 1.0),
        child: Container(
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.primaryContainer
                : AppTheme.surfaceContainer,
            borderRadius: AppRadius.xlAll,
            border: Border.all(
              color: widget.isSelected
                  ? AppTheme.primaryColor
                  : AppTheme.outlineVariant,
              width: widget.isSelected ? 2 : 1,
            ),
            boxShadow: widget.isSelected
                ? [
                    BoxShadow(
                      color: AppTheme.primaryColor.withValues(alpha: 0.25),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ]
                : null,
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _handleTap,
              onLongPress: _handleLongPress,
              borderRadius: AppRadius.xlAll,
              splashColor: AppTheme.primaryColor.withValues(alpha: 0.15),
              highlightColor: AppTheme.primaryColor.withValues(alpha: 0.08),
              child: Padding(
                padding: const EdgeInsets.all(AppSpacing.lg),
                child: Row(
                  children: [
                    // Platform icon tile — tonal, keeps the platform tint.
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.14),
                        borderRadius: AppRadius.lgAll,
                        border: Border.all(
                          color: iconColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Center(
                        child: Icon(
                          widget.device.platform.icon,
                          size: 30,
                          color: iconColor,
                        ),
                      ),
                    ),
                    const SizedBox(width: AppSpacing.lg),
                    // Device Info with nickname support
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Display name (nickname or original)
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayName,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        fontWeight: FontWeight.w700,
                                      ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              if (hasNickname)
                                Container(
                                  margin: const EdgeInsets.only(left: AppSpacing.sm),
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: AppSpacing.xs + 2,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primaryColor.withValues(alpha: 0.15),
                                    borderRadius: AppRadius.smAll,
                                  ),
                                  child: const Icon(
                                    Icons.edit,
                                    size: 12,
                                    color: AppTheme.primaryColor,
                                  ),
                                ),
                            ],
                          ),
                          // Show original name if nickname exists
                          if (hasNickname) ...[
                            const SizedBox(height: AppSpacing.xs),
                            Text(
                              widget.device.name,
                              style:
                                  Theme.of(context).textTheme.bodySmall?.copyWith(
                                        color: AppTheme.textTertiary,
                                        fontSize: 11,
                                      ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                          const SizedBox(height: AppSpacing.sm - 2),
                          // Platform name with icon
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.all(AppSpacing.xs),
                                decoration: BoxDecoration(
                                  color: AppTheme.surfaceContainerHigh,
                                  borderRadius: AppRadius.smAll,
                                ),
                                child: Icon(
                                  widget.device.platform.icon,
                                  size: 14,
                                  color: iconColor,
                                ),
                              ),
                              const SizedBox(width: AppSpacing.sm - 2),
                              Text(
                                widget.device.platform.displayName,
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: AppTheme.textSecondary,
                                    ),
                              ),
                            ],
                          ),
                          const SizedBox(height: AppSpacing.xs),
                          Row(
                            children: [
                              Icon(
                                Icons.router_rounded,
                                size: 12,
                                color: AppTheme.textTertiary,
                              ),
                              const SizedBox(width: AppSpacing.xs),
                              Text(
                                widget.device.ipAddress,
                                style:
                                    Theme.of(context).textTheme.bodySmall?.copyWith(
                                          color: AppTheme.textTertiary,
                                        ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Online / offline status
                    StatusBadge(
                      label: widget.device.isOnline ? 'Online' : 'Offline',
                      variant: widget.device.isOnline
                          ? BadgeVariant.success
                          : BadgeVariant.neutral,
                      showDot: true,
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
