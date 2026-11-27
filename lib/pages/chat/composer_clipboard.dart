import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:mime/mime.dart';
import 'package:pasteboard/pasteboard.dart';

import 'attachment_media_utils.dart';

const _clipboardChannel = MethodChannel('moe.aks.matter/clipboard');

Future<List<XFile>> readClipboardAttachments() async {
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    try {
      final items = await _clipboardChannel.invokeListMethod<dynamic>(
        'readFiles',
      );
      if (items != null && items.isNotEmpty) {
        return items.map((item) {
          final values = Map<String, dynamic>.from(item as Map);
          final bytes = values['bytes'] as Uint8List;
          final suggestedName = values['name'] as String;
          final mime = resolveAttachmentMime(
            suggestedName,
            lookupMimeType('', headerBytes: bytes) ?? values['mime'] as String?,
          );
          final extension = mime == null ? null : extensionFromMime(mime);
          final name = !suggestedName.contains('.') && extension != null
              ? '$suggestedName.$extension'
              : suggestedName;
          if (bytes.length > attachmentMaxBufferedBytes) {
            throw StateError('文件超过 64MB 限制');
          }
          return XFile.fromData(bytes, name: name, path: name, mimeType: mime);
        }).toList();
      }
    } on MissingPluginException {
      final image = await _readClipboardImage();
      return image == null ? const [] : [image];
    }
  } else if (!kIsWeb) {
    final paths = await Pasteboard.files();
    if (paths.isNotEmpty) {
      final files = <XFile>[];
      for (final value in paths.toSet()) {
        final uri = Uri.tryParse(value);
        final path = uri?.scheme == 'file' ? uri!.toFilePath() : value;
        final source = File(path);
        if (await FileSystemEntity.type(path) ==
            FileSystemEntityType.directory) {
          throw StateError('暂不支持发送文件夹，请选择文件');
        }
        if (await source.length() > attachmentMaxBufferedBytes) {
          throw StateError('文件超过 64MB 限制');
        }
        final header = await source.open();
        final Uint8List bytes;
        try {
          bytes = await header.read(defaultMagicNumbersMaxLength);
        } finally {
          await header.close();
        }
        files.add(
          XFile(path, mimeType: lookupMimeType(path, headerBytes: bytes)),
        );
      }
      return files;
    }
  }
  final image = await _readClipboardImage();
  return image == null ? const [] : [image];
}

Future<XFile?> _readClipboardImage() async {
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
