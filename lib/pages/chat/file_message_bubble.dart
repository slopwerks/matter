import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

/// Converts an untrusted attachment name into a portable suggested filename.
@visibleForTesting
String sanitizeAttachmentFilename(String filename) {
  var name = filename.replaceAll('\\', '/').split('/').last.trim();
  name = name.replaceAll(RegExp(r'[\x00-\x1f<>:"|?*]'), '_');
  name = name.replaceAll(
    RegExp(r'[\u061C\u200E\u200F\u202A-\u202E\u2066-\u2069]'),
    '',
  );
  name = name.replaceAll(RegExp(r'[. ]+$'), '');
  if (name.isEmpty || name == '.' || name == '..') name = 'attachment.bin';

  final stem = name.split('.').first.toUpperCase();
  const reserved = {
    'CON',
    'PRN',
    'AUX',
    'NUL',
    'COM1',
    'COM2',
    'COM3',
    'COM4',
    'COM5',
    'COM6',
    'COM7',
    'COM8',
    'COM9',
    'LPT1',
    'LPT2',
    'LPT3',
    'LPT4',
    'LPT5',
    'LPT6',
    'LPT7',
    'LPT8',
    'LPT9',
  };
  if (reserved.contains(stem)) name = '_$name';

  if (name.length <= 120) return name;
  final dot = name.lastIndexOf('.');
  final extension = dot > 0 && name.length - dot <= 16
      ? name.substring(dot)
      : '';
  return '${name.substring(0, 120 - extension.length)}$extension';
}

/// Displays a generic document / audio attachment with a download action.
class FileMessageBubble extends StatefulWidget {
  final String filename;
  final String? caption;
  final int? fileSize;

  /// Serialized Matrix MediaSource ([rust.ChatMessage.mediaSourceJson]);
  /// preferred because it also works for encrypted media.
  final String? mediaSourceJson;
  final String? imageUrl;
  final bool isMe;
  final Widget metadata;
  final double maxWidth;

  const FileMessageBubble({
    super.key,
    required this.filename,
    this.caption,
    this.fileSize,
    this.mediaSourceJson,
    this.imageUrl,
    required this.isMe,
    required this.metadata,
    this.maxWidth = 260,
  });

  @override
  State<FileMessageBubble> createState() => _FileMessageBubbleState();
}

class _FileMessageBubbleState extends State<FileMessageBubble> {
  static const _largeDownloadWarningBytes = 64 * 1024 * 1024;
  static const _maximumManualDownloadBytes = 128 * 1024 * 1024;
  bool _downloading = false;

  String get _safeFilename => sanitizeAttachmentFilename(widget.filename);

  Future<void> _download() async {
    if (_downloading) return;
    final fileSize = widget.fileSize;
    var maxSizeBytes = _largeDownloadWarningBytes;
    if (fileSize != null &&
        fileSize > _largeDownloadWarningBytes &&
        !await _confirmLargeDownload(fileSize)) {
      return;
    }
    if (fileSize != null && fileSize > _largeDownloadWarningBytes) {
      maxSizeBytes = fileSize
          .clamp(_largeDownloadWarningBytes, _maximumManualDownloadBytes)
          .toInt();
    }
    if (!mounted) return;
    setState(() => _downloading = true);
    try {
      final location = await getSaveLocation(suggestedName: _safeFilename);
      if (location == null) return;
      final bytes = widget.mediaSourceJson != null
          ? await rust.downloadMediaSourceBytes(
              mediaSourceJson: widget.mediaSourceJson!,
              maxSizeBytes: maxSizeBytes,
            )
          : widget.imageUrl != null
          ? await rust.downloadMediaBytes(mxcUrl: widget.imageUrl!)
          : null;
      if (bytes == null || bytes.isEmpty) throw Exception('文件不可用');

      final file = XFile.fromData(
        bytes,
        name: _safeFilename,
        mimeType: 'application/octet-stream',
      );
      await file.saveTo(location.path);
      if (!mounted) return;
      _showMessage('文件已保存');
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败: $error'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<bool> _confirmLargeDownload(int fileSize) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('下载大文件？'),
            content: Text('文件大小约 ${_formatFileSize(fileSize)}，下载时会占用较多内存和流量。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('取消'),
              ),
              FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(true),
                icon: const Icon(Icons.download_rounded, size: 18),
                label: const Text('继续下载'),
              ),
            ],
          ),
        ) ??
        false;
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final caption = widget.caption?.trim();
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AppRadii.content),
        child: Stack(
          children: [
            Material(
              color: widget.isMe
                  ? AppColors.primary.withValues(alpha: 0.22)
                  : AppColors.surfaceVariant,
              child: InkWell(
                onTap: _downloading ? null : _download,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _downloading
                                ? Icons.downloading_rounded
                                : Icons.insert_drive_file_rounded,
                            size: 30,
                            color: AppColors.onBackground,
                          ),
                          const SizedBox(width: 10),
                          Flexible(
                            child: Text(
                              _safeFilename,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: AppColors.onBackground,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.download_rounded,
                            size: 18,
                            color: AppColors.onSurfaceVariant,
                          ),
                        ],
                      ),
                      if (caption != null && caption.isNotEmpty) ...[
                        const SizedBox(height: 8),
                        Text(
                          caption,
                          style: const TextStyle(
                            color: AppColors.onBackground,
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            widget.metadata,
          ],
        ),
      ),
    );
  }
}

String _formatFileSize(int bytes) {
  const megabyte = 1024 * 1024;
  const gigabyte = 1024 * megabyte;
  if (bytes >= gigabyte) return '${(bytes / gigabyte).toStringAsFixed(1)} GB';
  return '${(bytes / megabyte).toStringAsFixed(1)} MB';
}
