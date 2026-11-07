import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/downloads/download_notification.dart';
import '../../features/storage/automatic_attachment_cache.dart';
import '../../features/storage/managed_media.dart';
import '../../features/storage/storage_models.dart';
import '../../providers/auth_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/sheets.dart';
import 'attachment_media_utils.dart';
import 'audio_attachment_player.dart';
import 'file_download_saver.dart';
import 'markdown_attachment_page.dart';
import 'timeline/timeline_bubble_frame.dart'
    show enabledNeuBubbleShadows, neuBubbleShape;

/// Converts an untrusted attachment name into a portable suggested filename.
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
  final String? mimeType;
  final int? durationMs;
  final String? roomId;
  final String? messageId;

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
    this.mimeType,
    this.durationMs,
    this.roomId,
    this.messageId,
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
  static const _maximumMarkdownPreviewBytes = 2 * 1024 * 1024;
  bool _downloading = false;

  String get _safeFilename => sanitizeAttachmentFilename(widget.filename);
  bool get _isAudio =>
      resolveAttachmentMime(
        widget.filename,
        widget.mimeType,
      )?.startsWith('audio/') ==
      true;
  bool get _isMarkdown {
    final name = _safeFilename.toLowerCase();
    return name.endsWith('.md') || name.endsWith('.markdown');
  }

  Future<void> _download({bool preview = false, bool saveAs = false}) async {
    if (_downloading) return;
    final fileSize = widget.fileSize;
    if (preview &&
        fileSize != null &&
        fileSize > _maximumMarkdownPreviewBytes) {
      _showMessage('文件超过 2 MB，请点击下载按钮保存后用其他应用打开');
      return;
    }
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
    DownloadNotification? notification;
    try {
      if (!preview) {
        notification = await DownloadNotification.start(_safeFilename);
      }
      final cached = await _cachedBytes(
        preview ? _maximumMarkdownPreviewBytes : maxSizeBytes,
      );
      final bytes =
          cached ??
          (widget.mediaSourceJson != null
              ? await rust.downloadMediaSourceBytes(
                  mediaSourceJson: widget.mediaSourceJson!,
                  maxSizeBytes: preview
                      ? _maximumMarkdownPreviewBytes
                      : maxSizeBytes,
                )
              : widget.imageUrl != null
              ? await rust.downloadMediaBytes(mxcUrl: widget.imageUrl!)
              : null);
      if (bytes == null || bytes.isEmpty) throw Exception('文件不可用');
      if (preview) {
        if (bytes.length > _maximumMarkdownPreviewBytes) {
          throw Exception('文件超过 2 MB，请点击下载按钮保存后用其他应用打开');
        }
        if (!mounted) return;
        final page = MarkdownAttachmentPage(
          filename: _safeFilename,
          bytes: bytes,
        );
        Navigator.of(context, rootNavigator: true).push(
          MaterialPageRoute<void>(fullscreenDialog: true, builder: (_) => page),
        );
        return;
      }

      if (!await saveDownloadedFile(
        filename: _safeFilename,
        bytes: bytes,
        chooseLocation: saveAs,
      )) {
        await notification?.cancel();
        return;
      }
      await notification?.complete();
      if (!mounted) return;
      _showMessage('文件已保存');
    } catch (error) {
      await notification?.fail(error);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${preview ? '预览' : '下载'}失败: $error'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _downloading = false);
    }
  }

  Future<bool> _confirmLargeDownload(int fileSize) {
    return showNeuConfirm(
      context,
      title: '下载大文件？',
      message: '文件大小约 ${_formatFileSize(fileSize)}，下载时会占用较多内存和流量。',
      confirmLabel: '继续下载',
    );
  }

  Future<Uint8List?> _cachedBytes(int maxBytes) async {
    if (widget.roomId == null) return null;
    final account = ProviderScope.containerOf(
      context,
      listen: false,
    ).read(currentUserProvider);
    if (account == null) return null;
    final key = storageAccountKey(account.id, account.homeserver);
    return readManagedMediaBytes(
      account: key,
      key: widget.mediaSourceJson ?? widget.imageUrl ?? '',
      filename: _safeFilename,
      kind: _isAudio ? StorageKind.audio : StorageKind.document,
      owner: StorageOwner(key, widget.roomId!),
      maxBytes: maxBytes,
    );
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final caption = widget.caption?.trim();
    final foreground = widget.isMe ? colors.onAccent : colors.text;
    final secondary = widget.isMe
        ? colors.onAccent.withValues(alpha: 0.7)
        : colors.textTertiary;
    final shape = neuBubbleShape(
      context,
      BorderRadius.circular(NeuRadius.content),
    );
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: widget.maxWidth),
      child: Container(
        decoration: ShapeDecoration(
          shape: shape,
          color: widget.isMe ? colors.accent : colors.card,
          shadows: enabledNeuBubbleShadows(context, colors),
        ),
        child: ClipPath.shape(
          shape: shape,
          child: Stack(
            children: [
              Material(
                type: MaterialType.transparency,
                child: InkWell(
                  onTap: _downloading
                      ? null
                      : () => _download(preview: _isMarkdown),
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
                              color: widget.isMe
                                  ? colors.onAccent
                                  : colors.accent,
                            ),
                            const SizedBox(width: 10),
                            Flexible(
                              child: Text(
                                _safeFilename,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: Theme.of(context).textTheme.bodyMedium
                                    ?.copyWith(color: foreground),
                              ),
                            ),
                            const SizedBox(width: 8),
                            if (supportsSaveAs)
                              IconButton(
                                tooltip: '另存为',
                                onPressed: _downloading
                                    ? null
                                    : () => _download(saveAs: true),
                                icon: Icon(
                                  Icons.save_alt,
                                  size: 18,
                                  color: secondary,
                                ),
                              ),
                            if (_isMarkdown)
                              IconButton(
                                tooltip: '下载文件',
                                onPressed: _downloading ? null : _download,
                                icon: Icon(
                                  Icons.download_rounded,
                                  size: 18,
                                  color: secondary,
                                ),
                              )
                            else
                              Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: secondary,
                              ),
                          ],
                        ),
                        if (_isAudio)
                          AudioAttachmentPlayer(
                            url: widget.imageUrl,
                            mediaSourceJson: widget.mediaSourceJson,
                            filename: _safeFilename,
                            durationMs: widget.durationMs,
                            roomId: widget.roomId,
                            messageId: widget.messageId,
                            foreground: foreground,
                          ),
                        if (caption != null && caption.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Text(
                            caption,
                            style: Theme.of(context).textTheme.bodyMedium
                                ?.copyWith(color: foreground),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
              if (widget.roomId != null)
                AutomaticAttachmentCache(
                  filename: _safeFilename,
                  url: widget.imageUrl,
                  source: widget.mediaSourceJson,
                  roomId: widget.roomId!,
                  bytes: widget.fileSize,
                  kind: _isAudio ? StorageKind.audio : StorageKind.document,
                ),
              widget.metadata,
            ],
          ),
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
