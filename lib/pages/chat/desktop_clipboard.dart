import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:pasteboard/pasteboard.dart';

import 'attachment_media_utils.dart';

/// Null leaves ordinary text paste to EditableText, including its selection.
Future<XFile?> readClipboardImage() async {
  final Uint8List? bytes;
  try {
    bytes = await Pasteboard.image;
  } on MissingPluginException {
    return null;
  }
  if (bytes == null || bytes.isEmpty) return null;
  if (bytes.length > attachmentMaxBufferedBytes) {
    throw StateError('图片超过 64MB 限制');
  }
  final mime = detectImageMime(bytes);
  if (mime == null) throw StateError('无法识别剪贴板图片格式');
  final filename =
      'clipboard_${DateTime.now().millisecondsSinceEpoch}.${attachmentImageExtension(mime)}';
  return XFile.fromData(bytes, path: filename, name: filename, mimeType: mime);
}
