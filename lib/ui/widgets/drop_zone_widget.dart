import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../core/models/transfer.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';

import '../../core/utils/app_logger.dart';

/// Turns the files a desktop drag delivered into transfer items.
///
/// Shared by every drop target in the app: a folder has to be walked for its
/// size here and nowhere else, and the two copies of this loop that used to
/// exist had already started to differ.
Future<List<TransferItem>> transferItemsFromDrop(DropDoneDetails drop) async {
  final items = <TransferItem>[];
  for (final xFile in drop.files) {
    try {
      final path = xFile.path;
      final file = File(path);
      final directory = Directory(path);

      if (await file.exists()) {
        final stat = await file.stat();
        items.add(TransferItem(
          name: xFile.name,
          path: path,
          size: stat.size,
          isDirectory: false,
        ));
      } else if (await directory.exists()) {
        var folderSize = 0;
        await for (final entity in directory.list(recursive: true)) {
          if (entity is File) folderSize += await entity.length();
        }
        items.add(TransferItem(
          name: xFile.name,
          path: path,
          size: folderSize,
          isDirectory: true,
        ));
      }
    } catch (e) {
      AppLogger.info('Error processing dropped file: $e');
    }
  }
  return items;
}

/// A simple drop zone for empty states
class EmptyDropZone extends StatefulWidget {
  final Function(List<TransferItem> items) onFilesDropped;
  final VoidCallback onPickFiles;
  final VoidCallback onPickFolder;

  /// True while a drag is anywhere over the window, so the target the user is
  /// aiming at lights up before the cursor reaches it.
  final bool dragOverWindow;

  /// False when an ancestor already registers the window as a drop target.
  /// Both would otherwise fire for one drop and ask twice.
  final bool handlesOwnDrop;

  const EmptyDropZone({
    super.key,
    required this.onFilesDropped,
    required this.onPickFiles,
    required this.onPickFolder,
    this.dragOverWindow = false,
    this.handlesOwnDrop = true,
  });

  @override
  State<EmptyDropZone> createState() => _EmptyDropZoneState();
}

class _EmptyDropZoneState extends State<EmptyDropZone> {
  bool _isDragging = false;

  Future<void> _handleDrop(DropDoneDetails details) async {
    final items = await transferItemsFromDrop(details);
    if (items.isNotEmpty) widget.onFilesDropped(items);
    if (mounted) setState(() => _isDragging = false);
  }

  @override
  Widget build(BuildContext context) {
    final isDesktop =
        Platform.isWindows || Platform.isLinux || Platform.isMacOS;
    final active = _isDragging || widget.dragOverWindow;

    Widget content = AnimatedContainer(
      duration: AppMotion.fast,
      // Centres the prompt when the caller gives the zone room to fill, and
      // is a no-op when it is only as tall as its own content.
      alignment: Alignment.center,
      padding: const EdgeInsets.all(AppSpacing.xxxl),
      decoration: BoxDecoration(
        // The framed target appears only while a drag is actually in progress.
        //
        // Idle, this used to paint a filled, bordered rectangle across the whole
        // pane. On a two-pane desktop layout that made an empty state the
        // largest object on screen — a big empty box competing with the device
        // list for attention, which is the opposite of the design direction
        // ("glow and gradient are accents, not a surface treatment"; "interaction
        // speed matters more than visual spectacle"). The prompt now recedes to
        // plain content on the scaffold's base colour, and lights up exactly
        // when it becomes a real drop target.
        color: active
            ? AppTheme.primaryColor.withValues(alpha: 0.08)
            : Colors.transparent,
        borderRadius: AppRadius.xxlAll,
        border: Border.all(
          color: active ? AppTheme.primaryColor : Colors.transparent,
          width: active ? 2 : 1,
          strokeAlign: BorderSide.strokeAlignInside,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // A static icon, deliberately: the previous 1500ms pulse looped
          // forever on a screen the user is reading, not waiting on.
          Container(
            padding: const EdgeInsets.all(AppSpacing.xl),
            decoration: BoxDecoration(
              color: AppTheme.primaryColor.withValues(
                alpha: (active ? 0.2 : 0.1),
              ),
              shape: BoxShape.circle,
            ),
            child: Icon(
              active
                  ? Icons.file_download_rounded
                  : Icons.folder_open_rounded,
              size: 48,
              color: AppTheme.primaryColor,
            ),
          ),
          const SizedBox(height: AppSpacing.xxl),
          Text(
            active ? 'Drop files to send' : 'No files selected',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                  color: _isDragging
                      ? AppTheme.primaryColor
                      : AppTheme.textPrimary,
                ),
          ),
          const SizedBox(height: AppSpacing.sm),
          Text(
            isDesktop
                ? 'Drag & drop files here, or use the buttons below'
                : 'Select files or folders to send',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: AppTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.xxl),
          // Wrap, not Row: two labelled buttons do not fit a narrow detail
          // pane, and this is the one place the drop zone has to say so.
          Wrap(
            alignment: WrapAlignment.center,
            spacing: AppSpacing.lg,
            runSpacing: AppSpacing.md,
            children: [
              _ActionButton(
                icon: Icons.insert_drive_file_rounded,
                label: 'Files',
                onTap: widget.onPickFiles,
              ),
              _ActionButton(
                icon: Icons.folder_rounded,
                label: 'Folder',
                onTap: widget.onPickFolder,
              ),
            ],
          ),
        ],
      ),
    );

    if (isDesktop && widget.handlesOwnDrop) {
      return DropTarget(
        onDragDone: _handleDrop,
        onDragEntered: (_) {
          if (mounted) setState(() => _isDragging = true);
        },
        onDragExited: (_) {
          if (mounted) setState(() => _isDragging = false);
        },
        child: content,
      );
    }

    return content;
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onTap,
      icon: Icon(icon, size: 20),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.primaryContainer,
        foregroundColor: AppTheme.onPrimaryContainer,
        padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.xl,
          vertical: AppSpacing.md,
        ),
      ),
    );
  }
}
