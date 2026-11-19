import 'dart:typed_data';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import 'attachment_caption_composer.dart';
import 'attachment_media_draft.dart';
import 'attachment_media_gallery.dart';
import 'attachment_media_utils.dart';
import 'chat_image_editor_page.dart';
import 'image_zoom_frame.dart';

/// Previewing is separate from editing and sending. All pages share the
/// selection and description owned by the attachment picker.
class AttachmentImagePreviewPage extends StatefulWidget {
  final AttachmentMediaDraft draft;
  final List<AttachmentMediaItem> images;
  final AttachmentMediaItem initialImage;
  final Future<bool> Function() onSend;
  final VoidCallback onCaptionFocus;

  const AttachmentImagePreviewPage({
    super.key,
    required this.draft,
    required this.images,
    required this.initialImage,
    required this.onSend,
    required this.onCaptionFocus,
  });

  @override
  State<AttachmentImagePreviewPage> createState() =>
      _AttachmentImagePreviewPageState();
}

class _AttachmentImagePreviewPageState
    extends State<AttachmentImagePreviewPage> {
  late int _index;
  late final PageController _pages;
  final _previews = <String, Future<Uint8List>>{};
  bool _editing = false;
  bool _zoomed = false;

  AttachmentMediaItem get _current => widget.images[_index];

  @override
  void initState() {
    super.initState();
    _index = widget.images.indexOf(widget.initialImage);
    _pages = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  Future<Uint8List> _loadPreview(AttachmentMediaItem item) async {
    try {
      return await item.readImageBytes();
    } finally {
      if (mounted) setState(() {});
    }
  }

  Future<void> _edit(ChatImageEditorTool? tool) async {
    if (_editing || widget.draft.isSending) return;
    final item = _current;
    setState(() => _editing = true);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final original = await item.original;
      final imageBytes =
          item.editedBytes ??
          await _previews.putIfAbsent(item.id, () => _loadPreview(item));
      if (!mounted) return;
      final bytes = await Navigator.of(context).push<Uint8List>(
        MaterialPageRoute(
          fullscreenDialog: true,
          builder: (_) => ChatImageEditorPage(
            imagePath: original.file.path,
            imageBytes: imageBytes,
            mimeType:
                item.editedMimeType ??
                resolveAttachmentMime(
                  original.filename,
                  original.file.mimeType,
                ),
            initialTool: tool,
          ),
        ),
      );
      if (!mounted || bytes == null) return;
      widget.draft.applyEdit(item, bytes, original.filename);
      setState(() => _zoomed = false);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('编辑图片失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _editing = false);
    }
  }

  Future<void> _send() async {
    if (_editing || widget.draft.isSending) return;
    if (widget.draft.selected.isEmpty) widget.draft.toggle(_current);
    FocusManager.instance.primaryFocus?.unfocus();
    try {
      final sent = await widget.onSend();
      if (mounted && sent) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.draft,
    builder: (context, _) {
      final colors = context.neu;
      final order = widget.draft.order(_current);
      final busy = _editing || widget.draft.isSending;
      return PopScope(
        canPop: !widget.draft.isSending,
        child: Scaffold(
          backgroundColor: Colors.black,
          appBar: AppBar(
            backgroundColor: colors.base,
            foregroundColor: colors.text,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: IconButton(
              tooltip: '返回选图',
              onPressed: busy ? null : () => Navigator.of(context).pop(),
              icon: const Icon(CupertinoIcons.chevron_back, size: 22),
            ),
            title: Text('${_index + 1} / ${widget.images.length}'),
            actions: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: IconButton(
                  key: const ValueKey('attachment-preview-selection'),
                  tooltip: order == 0 ? '选中图片' : '取消选择',
                  onPressed: busy ? null : () => widget.draft.toggle(_current),
                  icon: AttachmentSelectionBadge(
                    selected: order > 0,
                    order: order,
                  ),
                ),
              ),
            ],
          ),
          body: Column(
            children: [
              Expanded(
                child: PageView.builder(
                  controller: _pages,
                  physics: busy || _zoomed
                      ? const NeverScrollableScrollPhysics()
                      : const PageScrollPhysics(),
                  itemCount: widget.images.length,
                  onPageChanged: (index) => setState(() {
                    _index = index;
                    _zoomed = false;
                    final nearby = <String>{
                      for (var page = index - 1; page <= index + 1; page++)
                        if (page >= 0 && page < widget.images.length)
                          widget.images[page].id,
                    };
                    _previews.removeWhere((id, _) => !nearby.contains(id));
                  }),
                  itemBuilder: (context, index) {
                    final item = widget.images[index];
                    final future = item.editedBytes != null
                        ? Future.value(item.editedBytes!)
                        : _previews.putIfAbsent(
                            item.id,
                            () => _loadPreview(item),
                          );
                    return ZoomableImageFrame(
                      key: ValueKey((item.id, item.editedBytes)),
                      active: index == _index,
                      onZoomChanged: (zoomed) {
                        if (index == _index && _zoomed != zoomed) {
                          setState(() => _zoomed = zoomed);
                        }
                      },
                      child: SizedBox.expand(
                        child: FutureBuilder<Uint8List>(
                          future: future,
                          builder: (context, snapshot) {
                            if (snapshot.hasError) {
                              return const Center(
                                child: Text(
                                  '无法预览图片',
                                  style: TextStyle(color: Colors.white),
                                ),
                              );
                            }
                            if (!snapshot.hasData) {
                              return const Center(
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                ),
                              );
                            }
                            return Center(
                              child: Image.memory(
                                snapshot.data!,
                                fit: BoxFit.contain,
                                cacheWidth: 2048,
                                errorBuilder: (_, _, _) => const Icon(
                                  CupertinoIcons.photo,
                                  color: Colors.white,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    );
                  },
                ),
              ),
              ColoredBox(
                color: colors.base,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (MediaQuery.viewInsetsOf(context).bottom == 0)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                        children: [
                          IconButton(
                            tooltip: '裁剪',
                            onPressed: busy
                                ? null
                                : () => _edit(ChatImageEditorTool.crop),
                            icon: const Icon(CupertinoIcons.crop, size: 24),
                          ),
                          IconButton(
                            tooltip: '笔刷',
                            onPressed: busy
                                ? null
                                : () => _edit(ChatImageEditorTool.paint),
                            icon: const Icon(
                              CupertinoIcons.paintbrush,
                              size: 24,
                            ),
                          ),
                          IconButton(
                            tooltip: _current.mimeType == null
                                ? '正在识别图片格式'
                                : !_current.canCompress
                                ? 'GIF / WebP 保留原文件发送'
                                : _current.compress
                                ? '自动压缩'
                                : '发送原图',
                            onPressed: busy || !_current.canCompress
                                ? null
                                : () =>
                                      widget.draft.toggleCompression(_current),
                            icon: Icon(
                              _current.compress
                                  ? Icons.sd_outlined
                                  : Icons.raw_on_outlined,
                              size: 28,
                            ),
                          ),
                          IconButton(
                            key: const ValueKey('attachment-spoiler-toggle'),
                            tooltip: _current.spoiler ? '取消隐藏图片' : '隐藏图片',
                            onPressed: busy
                                ? null
                                : () => widget.draft.toggleSpoiler(_current),
                            color: _current.spoiler ? colors.accent : null,
                            icon: Icon(
                              _current.spoiler
                                  ? CupertinoIcons.eye_slash
                                  : CupertinoIcons.eye,
                              size: 24,
                            ),
                          ),
                          IconButton(
                            tooltip: '更多调整',
                            onPressed: busy ? null : () => _edit(null),
                            icon: const Icon(
                              CupertinoIcons.slider_horizontal_3,
                              size: 24,
                            ),
                          ),
                        ],
                      ),
                    AttachmentCaptionComposer(
                      draft: widget.draft,
                      sendCount: widget.draft.selected.isEmpty
                          ? 1
                          : widget.draft.selected.length,
                      onFocus: widget.onCaptionFocus,
                      onSend: _send,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
