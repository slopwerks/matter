import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../features/downloads/download_notification.dart';
import '../../features/markdown/markdown_composer.dart';
import '../../widgets/neu_surface.dart';
import 'file_download_saver.dart';
import 'message_reader_page.dart';

/// Attachment actions reuse the downloaded bytes rather than fetching the media again.
class MarkdownAttachmentPage extends StatefulWidget {
  final String filename;
  final Uint8List bytes;
  final String html;

  MarkdownAttachmentPage({
    super.key,
    required this.filename,
    required this.bytes,
  }) : html = _renderMarkdown(bytes);

  @override
  State<MarkdownAttachmentPage> createState() => _MarkdownAttachmentPageState();
}

String _renderMarkdown(Uint8List bytes) {
  final compiled = const MarkdownComposer().compile(utf8.decode(bytes));
  return compiled.formattedBody ??
      '<p>${htmlEscape.convert(compiled.body)}</p>';
}

class _MarkdownAttachmentPageState extends State<MarkdownAttachmentPage> {
  bool _busy = false;

  Future<void> _save({bool chooseLocation = false}) async {
    setState(() => _busy = true);
    DownloadNotification? notification;
    try {
      notification = await DownloadNotification.start(widget.filename);
      final saved = await saveDownloadedFile(
        filename: widget.filename,
        bytes: widget.bytes,
        chooseLocation: chooseLocation,
      );
      if (saved) {
        await notification.complete();
        _showMessage('文件已保存');
      } else {
        await notification.cancel();
      }
    } catch (error) {
      await notification?.fail(error);
      _showMessage('保存失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openExternal() async {
    setState(() => _busy = true);
    try {
      final opened = await openDownloadedFile(
        filename: widget.filename,
        bytes: widget.bytes,
      );
      if (!opened) _showMessage('没有可用的应用，请先下载文件后再打开');
    } catch (error) {
      _showMessage('打开失败：$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showMessage(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) => MessageReaderPage(
    title: widget.filename,
    html: widget.html,
    actions: [
      NeuIconButton(
        icon: Icons.download_rounded,
        tooltip: '下载文件',
        size: 40,
        onPressed: _busy ? null : _save,
      ),
      if (supportsSaveAs)
        NeuIconButton(
          icon: Icons.save_alt,
          tooltip: '另存为',
          size: 40,
          onPressed: _busy ? null : () => _save(chooseLocation: true),
        ),
      NeuIconButton(
        icon: Icons.open_in_new_rounded,
        tooltip: kIsWeb ? '下载后用其他应用打开' : '用其他应用打开',
        size: 40,
        onPressed: _busy ? null : _openExternal,
      ),
    ],
  );
}
