import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart' show Size;
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:photo_manager/photo_manager.dart';

import 'attachment_image_resize.dart';
import 'attachment_media_utils.dart';

const _maxBufferedBytes = attachmentMaxBufferedBytes;
const _maxImageEdge = 4096;
const _maxImageQuality = 92;

Future<PreparedAttachmentImage> prepareAttachmentAssetImage({
  required AssetEntity asset,
  required File file,
  required String filename,
  required String? mimeType,
  bool compress = true,
}) async {
  final sourceSize = asset.size;
  if (sourceSize.width <= 0 || sourceSize.height <= 0) {
    final original = await _readFileBytes(file, '图片');
    final detectedMime =
        mimeType ??
        resolveAttachmentMime(filename, null) ??
        detectImageMime(original);
    if (detectedMime?.startsWith('image/') != true) {
      throw '无法识别图片格式';
    }
    return prepareAttachmentBufferedImage(
      original,
      filename: filename,
      mimeType: detectedMime!,
      compress: compress,
    );
  }

  if (!compress || mimeType == 'image/gif' || mimeType == 'image/webp') {
    final original = await _readFileBytes(file, '图片');
    final detectedMime =
        mimeType ??
        resolveAttachmentMime(filename, null) ??
        detectImageMime(original);
    if (detectedMime?.startsWith('image/') != true) throw '无法识别图片格式';
    return PreparedAttachmentImage(
      bytes: original,
      filename: filename,
      mimeType: detectedMime!,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }
  final target = _boundedImageSize(sourceSize);
  final shouldConvert =
      !_canSendOriginalImageMime(mimeType) ||
      sourceSize.width > _maxImageEdge ||
      sourceSize.height > _maxImageEdge;
  if (shouldConvert) {
    try {
      final compressed = await FlutterImageCompress.compressWithFile(
        file.path,
        minWidth: target.width,
        minHeight: target.height,
        quality: _maxImageQuality,
        format: CompressFormat.jpeg,
      );
      if (compressed != null && compressed.isNotEmpty) {
        return await _jpegImage(
          compressed,
          filename: filename,
          expectedSize: target,
        );
      }
    } catch (_) {
      // A correctly typed original is still safe when it is already bounded.
    }
  }

  if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
    throw '图片缩放失败';
  }
  if (mimeType?.startsWith('image/') != true) {
    throw '无法识别图片格式';
  }
  final original = await _readFileBytes(file, '图片');
  return PreparedAttachmentImage(
    bytes: original,
    filename: filename,
    mimeType: mimeType!,
    width: sourceSize.width.round(),
    height: sourceSize.height.round(),
  );
}

Future<PreparedAttachmentImage> prepareAttachmentBufferedImage(
  Uint8List original, {
  required String filename,
  required String mimeType,
  bool compress = true,
}) async {
  final sourceSize = await decodeAttachmentImageSize(original);
  if (!compress || mimeType == 'image/gif' || mimeType == 'image/webp') {
    return PreparedAttachmentImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType,
      width: sourceSize?.width.round(),
      height: sourceSize?.height.round(),
    );
  }
  if (sourceSize == null) throw '无法读取图片尺寸';
  final target = _boundedImageSize(sourceSize);
  final shouldConvert =
      !_canSendOriginalImageMime(mimeType) ||
      sourceSize.width > _maxImageEdge ||
      sourceSize.height > _maxImageEdge;
  if (!shouldConvert) {
    return PreparedAttachmentImage(
      bytes: original,
      filename: filename,
      mimeType: mimeType,
      width: sourceSize.width.round(),
      height: sourceSize.height.round(),
    );
  }

  try {
    final compressed = Platform.isLinux || Platform.isWindows
        ? await resizeAttachmentJpeg(
            original,
            width: target.width,
            height: target.height,
            quality: _maxImageQuality,
          )
        : await FlutterImageCompress.compressWithList(
            original,
            minWidth: target.width,
            minHeight: target.height,
            quality: _maxImageQuality,
            format: CompressFormat.jpeg,
          );
    if (compressed.isNotEmpty) {
      return await _jpegImage(
        compressed,
        filename: filename,
        expectedSize: target,
      );
    }
  } catch (_) {
    // Preserve a correctly typed original only when it is already bounded.
  }

  if (sourceSize.width > _maxImageEdge || sourceSize.height > _maxImageEdge) {
    throw '图片缩放失败';
  }
  return PreparedAttachmentImage(
    bytes: original,
    filename: filename,
    mimeType: mimeType,
    width: sourceSize.width.round(),
    height: sourceSize.height.round(),
  );
}

Future<PreparedAttachmentImage> _jpegImage(
  Uint8List bytes, {
  required String filename,
  required ({int width, int height}) expectedSize,
}) async {
  _ensureBufferedSize(bytes.length, '图片');
  final actual = await decodeAttachmentImageSize(bytes);
  final width = actual?.width.round() ?? expectedSize.width;
  final height = actual?.height.round() ?? expectedSize.height;
  if (width > _maxImageEdge || height > _maxImageEdge) {
    throw '图片缩放后仍超过 ${_maxImageEdge}px';
  }
  return PreparedAttachmentImage(
    bytes: bytes,
    filename: attachmentFilenameWithExtension(filename, 'jpg'),
    mimeType: 'image/jpeg',
    width: width,
    height: height,
  );
}

Future<Uint8List> _readFileBytes(File file, String label) async {
  _ensureBufferedSize(await file.length(), label);
  final bytes = await file.readAsBytes();
  _ensureBufferedSize(bytes.length, label);
  return bytes;
}

void _ensureBufferedSize(int length, String label) {
  if (length > _maxBufferedBytes) {
    throw '$label超过 ${_maxBufferedBytes ~/ 1024 ~/ 1024}MB 限制';
  }
}

class PreparedAttachmentImage {
  final Uint8List bytes;
  final String filename;
  final String mimeType;
  final int? width;
  final int? height;

  const PreparedAttachmentImage({
    required this.bytes,
    required this.filename,
    required this.mimeType,
    required this.width,
    required this.height,
  });
}

bool _canSendOriginalImageMime(String? mimeType) => const {
  'image/jpeg',
  'image/jpg',
  'image/png',
  'image/gif',
  'image/webp',
}.contains(mimeType);

({int width, int height}) _boundedImageSize(Size source) {
  if (source.width <= 0 || source.height <= 0) {
    return (width: _maxImageEdge, height: _maxImageEdge);
  }
  final longest = source.width > source.height ? source.width : source.height;
  final scale = longest > _maxImageEdge ? _maxImageEdge / longest : 1.0;
  final width = (source.width * scale).floor();
  final height = (source.height * scale).floor();
  return (width: width > 0 ? width : 1, height: height > 0 ? height : 1);
}
