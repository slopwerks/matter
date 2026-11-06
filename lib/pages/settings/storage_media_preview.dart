import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../features/storage/storage_local_media.dart';
import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_registry.dart';
import '../../theme/storage_visual_theme.dart';
import '../../widgets/floating_app_bar.dart';
import '../chat/media_playback.dart';
import '../chat/video_controls.dart';

bool canPreviewStorageFile(StorageFile file) =>
    file.cleanable &&
    [
      StorageKind.image,
      StorageKind.video,
      StorageKind.audio,
    ].contains(file.kind);
IconData storageFileIcon(StorageKind kind) => switch (kind) {
  StorageKind.image => Icons.image_outlined,
  StorageKind.video => Icons.play_circle_outline,
  StorageKind.audio => Icons.graphic_eq,
  StorageKind.database => Icons.lock_outline,
  StorageKind.document => Icons.description_outlined,
  StorageKind.update => Icons.system_update_outlined,
  _ => Icons.insert_drive_file_outlined,
};

class StorageMediaThumbnail extends StatefulWidget {
  final StorageFile file;
  const StorageMediaThumbnail({super.key, required this.file});
  @override
  State<StorageMediaThumbnail> createState() => _StorageMediaThumbnailState();
}

class _StorageMediaThumbnailState extends State<StorageMediaThumbnail> {
  late Future<Uint8List?> _image;
  Future<Uint8List?> _load() async {
    if (!canPreviewStorageFile(widget.file) ||
        widget.file.kind == StorageKind.audio) {
      return null;
    }
    final lease = await openStorageMedia(widget.file);
    try {
      return await lease.preview();
    } finally {
      await lease.close();
    }
  }

  @override
  void initState() {
    super.initState();
    _image = _load();
  }

  @override
  void didUpdateWidget(covariant StorageMediaThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.file.path != widget.file.path ||
        oldWidget.file.modified != widget.file.modified ||
        oldWidget.file.bytes != widget.file.bytes) {
      _image = _load();
    }
  }

  @override
  Widget build(BuildContext context) {
    final visuals = StorageVisualTheme.of(context);
    return ClipPath(
      clipper: ShapeBorderClipper(shape: visuals.previewShape),
      child: ColoredBox(
        color: visuals.chartTrack,
        child: SizedBox.square(
          dimension: 64,
          child: FutureBuilder<Uint8List?>(
            future: _image,
            builder: (context, result) {
              final data = result.data;
              return Stack(
                fit: StackFit.expand,
                children: [
                  if (data != null)
                    Image.memory(
                      data,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) =>
                          Icon(storageFileIcon(widget.file.kind)),
                    )
                  else
                    Center(
                      child: Icon(
                        storageFileIcon(widget.file.kind),
                        color: visuals.scheme.onSurfaceVariant,
                      ),
                    ),
                  if (widget.file.kind == StorageKind.video && data != null)
                    Align(
                      alignment: Alignment.bottomRight,
                      child: Icon(
                        Icons.play_circle,
                        color: visuals.scheme.primaryContainer,
                      ),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class StorageMediaPreviewPage extends StatefulWidget {
  final StorageFile file;
  const StorageMediaPreviewPage({super.key, required this.file});
  @override
  State<StorageMediaPreviewPage> createState() =>
      _StorageMediaPreviewPageState();
}

class _StorageMediaPreviewPageState extends State<StorageMediaPreviewPage> {
  StorageMediaLease? _lease;
  MediaPlayback? _playback;
  VideoController? _video;
  Uint8List? _image;
  String? _error;
  bool _ready = false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final lease = await openStorageMedia(widget.file);
      if (!mounted) {
        await lease.close();
        return;
      }
      _lease = lease;
      if (widget.file.kind == StorageKind.image) {
        _image = await lease.preview(edge: 2048);
        if (_image == null) throw StateError('图片无法解码');
      } else {
        final playback = MediaPlayback();
        _playback = playback;
        if (widget.file.kind == StorageKind.video) {
          _video = VideoController(playback.player);
        }
        await playback.open(Media(Uri.file(lease.path).toString()));
      }
      if (mounted) {
        try {
          await storageRegistry.record(lease.path, widget.file.kind);
        } catch (error) {
          debugPrint('Preview usage update failed: $error');
        }
        if (mounted) setState(() => _ready = true);
      }
    } catch (_) {
      if (mounted) setState(() => _error = '无法预览此本地文件，可能已被清理、损坏或格式暂不支持。');
    }
  }

  @override
  void dispose() {
    final playback = _playback;
    final lease = _lease;
    unawaited(() async {
      try {
        await playback?.close();
      } finally {
        await lease?.close();
      }
    }());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: buildFloatingAppBar(title: Text(widget.file.name)),
    body: _error != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(_error!, textAlign: TextAlign.center),
            ),
          )
        : !_ready
        ? const Center(child: CircularProgressIndicator())
        : widget.file.kind == StorageKind.image
        ? InteractiveViewer(
            minScale: 1,
            maxScale: 5,
            child: Center(child: Image.memory(_image!, fit: BoxFit.contain)),
          )
        : VideoControls(
            playback: _playback!,
            onClose: () => Navigator.pop(context),
            videoBuilder: (context, fit) => _video == null
                ? const Center(child: Icon(Icons.graphic_eq, size: 64))
                : Video(
                    controller: _video!,
                    fit: fit,
                    controls: NoVideoControls,
                  ),
          ),
  );
}
