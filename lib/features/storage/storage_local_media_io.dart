import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/services.dart';

import 'storage_models.dart';
import 'storage_registry.dart';

/// A scan-confirmed local file. Previews never resolve a URL or start a download.
Future<StorageMediaLease> openStorageMedia(StorageFile entry) async {
  if (!entry.cleanable ||
      ![
        StorageKind.image,
        StorageKind.video,
        StorageKind.audio,
      ].contains(entry.kind)) {
    throw StateError('此文件不支持媒体预览');
  }
  final release = storageRegistry.pin(entry.path);
  try {
    final file = File(entry.path);
    if (await FileSystemEntity.type(entry.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await file.resolveSymbolicLinks() != file.absolute.path) {
      throw StateError('文件已变化，请刷新列表');
    }
    final stat = await file.stat();
    if (stat.size != entry.bytes || stat.modified != entry.modified) {
      throw StateError('文件已变化，请刷新列表');
    }
    return StorageMediaLease._(file.path, entry.kind, release);
  } catch (_) {
    release();
    rethrow;
  }
}

class StorageMediaLease {
  final String path;
  final StorageKind _kind;
  final void Function() _release;
  Future<Uint8List?>? _preview;
  bool _closed = false;
  StorageMediaLease._(this.path, this._kind, this._release);

  Future<Uint8List?> preview({int edge = 320}) =>
      _preview ??= _read(edge.clamp(64, 2048));
  Future<Uint8List?> _read(int edge) async {
    if (_kind == StorageKind.video) {
      if (!Platform.isAndroid) return null;
      return const MethodChannel('moe.aks.matter/storage')
          .invokeMethod<Uint8List>('videoThumbnail', {'path': path});
    }
    if (_kind != StorageKind.image) return null;
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    final codec = await ui.instantiateImageCodecWithSize(
      buffer,
      getTargetSize: (width, height) {
        final scale = math.min(1.0, edge / math.max(width, height));
        return ui.TargetImageSize(
          width: math.max(1, (width * scale).round()),
          height: math.max(1, (height * scale).round()),
        );
      },
    );
    try {
      final frame = await codec.getNextFrame();
      try {
        final data = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        return data?.buffer.asUint8List();
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    try {
      await _preview;
    } catch (_) {
    } finally {
      _release();
    }
  }
}
