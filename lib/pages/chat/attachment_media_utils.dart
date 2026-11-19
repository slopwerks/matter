import 'dart:ui' as ui;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Size;

enum AttachmentMediaKind { image, video, file }

const attachmentMaxBufferedBytes = 64 * 1024 * 1024;

String? resolveAttachmentMime(String filename, String? declaredMime) {
  final declared = declaredMime?.split(';').first.trim().toLowerCase();
  if (declared != null &&
      declared.isNotEmpty &&
      declared != 'application/octet-stream') {
    return declared;
  }
  final dot = filename.lastIndexOf('.');
  final extension = dot < 0 ? '' : filename.substring(dot + 1).toLowerCase();
  return const {
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'png': 'image/png',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'heic': 'image/heic',
        'heif': 'image/heif',
        'avif': 'image/avif',
        'tiff': 'image/tiff',
        'tif': 'image/tiff',
        'bmp': 'image/bmp',
        'mp4': 'video/mp4',
        'm4v': 'video/mp4',
        'mov': 'video/quicktime',
        'webm': 'video/webm',
        'mkv': 'video/x-matroska',
        '3gp': 'video/3gpp',
        'mp3': 'audio/mpeg',
        'm4a': 'audio/mp4',
        'aac': 'audio/aac',
        'ogg': 'audio/ogg',
        'opus': 'audio/ogg',
        'wav': 'audio/wav',
        'flac': 'audio/flac',
        'pdf': 'application/pdf',
        'txt': 'text/plain',
        'zip': 'application/zip',
      }[extension] ??
      (declared?.isEmpty == false ? declared : null);
}

AttachmentMediaKind classifyAttachmentMime(String? mimeType) {
  if (mimeType?.startsWith('image/') == true) return AttachmentMediaKind.image;
  if (mimeType?.startsWith('video/') == true) return AttachmentMediaKind.video;
  return AttachmentMediaKind.file;
}

Future<Uint8List> readAttachmentBytes(XFile file) async {
  if (await file.length() > attachmentMaxBufferedBytes) throw '文件超过 64MB 限制';
  final bytes = await file.readAsBytes();
  if (bytes.length > attachmentMaxBufferedBytes) throw '文件超过 64MB 限制';
  return bytes;
}

String? detectImageMime(Uint8List bytes) {
  bool matches(int offset, List<int> signature) {
    if (bytes.length < offset + signature.length) return false;
    for (var index = 0; index < signature.length; index++) {
      if (bytes[offset + index] != signature[index]) return false;
    }
    return true;
  }

  if (matches(0, const [0xff, 0xd8, 0xff])) return 'image/jpeg';
  if (matches(0, const [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) {
    return 'image/png';
  }
  if (matches(0, 'GIF87a'.codeUnits) || matches(0, 'GIF89a'.codeUnits)) {
    return 'image/gif';
  }
  if (matches(0, 'RIFF'.codeUnits) && matches(8, 'WEBP'.codeUnits)) {
    return 'image/webp';
  }
  if (matches(0, 'BM'.codeUnits)) return 'image/bmp';
  if (matches(0, const [0x49, 0x49, 0x2a, 0x00]) ||
      matches(0, const [0x4d, 0x4d, 0x00, 0x2a])) {
    return 'image/tiff';
  }
  if (matches(4, 'ftyp'.codeUnits) && bytes.length >= 12) {
    final brand = String.fromCharCodes(bytes.sublist(8, 12)).toLowerCase();
    if (brand == 'avif' || brand == 'avis') return 'image/avif';
    if ({'heic', 'heix', 'hevc', 'hevx'}.contains(brand)) return 'image/heic';
    if ({'heif', 'mif1', 'msf1'}.contains(brand)) return 'image/heif';
  }
  return null;
}

String attachmentImageExtension(String mimeType) =>
    const {
      'image/jpeg': 'jpg',
      'image/jpg': 'jpg',
      'image/png': 'png',
      'image/gif': 'gif',
      'image/webp': 'webp',
      'image/heic': 'heic',
      'image/heif': 'heif',
      'image/avif': 'avif',
      'image/tiff': 'tiff',
      'image/bmp': 'bmp',
    }[mimeType.toLowerCase()] ??
    'jpg';

String attachmentFilenameWithExtension(String name, String extension) {
  final dot = name.lastIndexOf('.');
  return dot > 0 ? '${name.substring(0, dot)}.$extension' : '$name.$extension';
}

Future<Size?> decodeAttachmentImageSize(Uint8List bytes) async {
  ui.ImmutableBuffer? buffer;
  ui.ImageDescriptor? descriptor;
  try {
    buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
    descriptor = await ui.ImageDescriptor.encoded(buffer);
    return Size(descriptor.width.toDouble(), descriptor.height.toDouble());
  } catch (_) {
    return null;
  } finally {
    descriptor?.dispose();
    buffer?.dispose();
  }
}
