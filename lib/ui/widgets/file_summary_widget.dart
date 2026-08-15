import 'package:flutter/material.dart';
import '../theme/app_dimens.dart';
import '../theme/app_theme.dart';
import 'common/app_widgets.dart';
import 'file_preview_widgets.dart';

/// Widget showing summary of multiple files
class FileSummaryWidget extends StatelessWidget {
  final List<String> filePaths;
  final bool showFileList;

  const FileSummaryWidget({
    super.key,
    required this.filePaths,
    this.showFileList = false,
  });

  @override
  Widget build(BuildContext context) {
    if (filePaths.isEmpty) {
      return const SizedBox.shrink();
    }

    final totalSize = filePaths.fold<int>(
      0,
      (sum, path) => sum + FileTypeHelper.getFileSize(path),
    );

    // Count files by type
    final typeCount = <FileType, int>{};
    for (final path in filePaths) {
      final type = FileTypeHelper.getFileType(path);
      typeCount[type] = (typeCount[type] ?? 0) + 1;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Summary card
        AppCard(
          color: AppTheme.primaryContainer,
          child: Row(
            children: [
              const Icon(
                Icons.folder_open,
                color: AppTheme.onPrimaryContainer,
                size: 32,
              ),
              const SizedBox(width: AppSpacing.lg),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${filePaths.length} ${filePaths.length == 1 ? 'file' : 'files'} selected',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            color: AppTheme.onPrimaryContainer,
                          ),
                    ),
                    const SizedBox(height: AppSpacing.xs),
                    Text(
                      'Total size: ${FileTypeHelper.formatFileSize(totalSize)}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: AppTheme.onPrimaryContainer
                                .withValues(alpha: 0.8),
                          ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),

        // File type breakdown
        if (typeCount.isNotEmpty) ...[
          const SizedBox(height: AppSpacing.md),
          Wrap(
            spacing: AppSpacing.sm,
            runSpacing: AppSpacing.sm,
            children: typeCount.entries.map((entry) {
              final type = entry.key;
              final count = entry.value;
              final icon = FileTypeHelper.getIcon(type);
              final color = FileTypeHelper.getColor(type);

              return Chip(
                avatar: Icon(icon, size: 16, color: color),
                label: Text('$count ${_getTypeName(type)}'),
                backgroundColor: color.withValues(alpha: 0.1),
                side: BorderSide(color: color.withValues(alpha: 0.3)),
              );
            }).toList(),
          ),
        ],

        // File list (if enabled)
        if (showFileList && filePaths.length <= 5) ...[
          const SizedBox(height: AppSpacing.md),
          ...filePaths.map((path) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: FilePreviewCard(filePath: path),
              )),
        ],

        // Show "+X more" if many files
        if (showFileList && filePaths.length > 5) ...[
          const SizedBox(height: AppSpacing.md),
          ...filePaths.take(3).map((path) => Padding(
                padding: const EdgeInsets.only(bottom: AppSpacing.sm),
                child: FilePreviewCard(filePath: path),
              )),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: Center(
                child: Text(
                  '+${filePaths.length - 3} more files',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: AppTheme.primaryColor,
                        fontWeight: FontWeight.w500,
                      ),
                ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  String _getTypeName(FileType type) {
    switch (type) {
      case FileType.image:
        return 'images';
      case FileType.video:
        return 'videos';
      case FileType.audio:
        return 'audio';
      case FileType.document:
        return 'docs';
      case FileType.archive:
        return 'archives';
      case FileType.code:
        return 'code';
      case FileType.pdf:
        return 'PDFs';
      case FileType.unknown:
        return 'files';
    }
  }
}
