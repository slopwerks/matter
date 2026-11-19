import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';
import 'attachment_caption_composer.dart';
import 'attachment_media_draft.dart';

const attachmentMediaOrder = <OrderOption>[
  OrderOption(type: OrderOptionType.createDate, asc: false),
];

class AttachmentGalleryTab extends StatefulWidget {
  final AttachmentMediaDraft draft;
  final ScrollController? scrollController;
  final Future<void> Function(
    AttachmentMediaItem item,
    List<AttachmentMediaItem> images,
  )
  onPreview;

  const AttachmentGalleryTab({
    super.key,
    required this.draft,
    required this.scrollController,
    required this.onPreview,
  });

  @override
  State<AttachmentGalleryTab> createState() => _AttachmentGalleryTabState();
}

class _AttachmentGalleryTabState extends State<AttachmentGalleryTab> {
  AssetPathEntity? _album;
  final _assets = <AssetEntity>[];
  bool _loading = true;
  String? _error;
  bool _fetchingMore = false;

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      final permission = await PhotoManager.requestPermissionExtend();
      if (!mounted) return;
      if (!permission.hasAccess) {
        setState(() {
          _loading = false;
          _error = '没有相册访问权限';
        });
        return;
      }
      final albums = await PhotoManager.getAssetPathList(
        type: RequestType.common,
        hasAll: true,
        filterOption: FilterOptionGroup(orders: attachmentMediaOrder),
      );
      if (!mounted) return;
      if (albums.isEmpty) {
        setState(() => _loading = false);
        return;
      }
      final album = albums.firstWhere(
        (album) => album.isAll,
        orElse: () => albums.first,
      );
      final assets = await album.getAssetListPaged(page: 0, size: 100);
      if (!mounted) return;
      setState(() {
        _album = album;
        _assets.addAll(assets);
        _loading = false;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = '$error';
        });
      }
    }
  }

  Future<void> _fetchMore() async {
    final album = _album;
    if (_fetchingMore || album == null || !mounted) return;
    setState(() => _fetchingMore = true);
    try {
      final total = await album.assetCountAsync;
      if (!mounted || _assets.length >= total) return;
      final next = await album.getAssetListPaged(
        page: _assets.length ~/ 100,
        size: 100,
      );
      if (mounted) setState(() => _assets.addAll(next));
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('加载更多媒体失败: $error')));
      }
    } finally {
      if (mounted) setState(() => _fetchingMore = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.draft,
    builder: (context, _) {
      final colors = context.neu;
      if (_loading) {
        return Center(child: CircularProgressIndicator(color: colors.accent));
      }
      if (_error != null) {
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(_error!),
          ),
        );
      }
      if (_assets.isEmpty) return const Center(child: Text('没有可用的图片或视频'));
      return NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification &&
              notification.metrics.extentAfter < 240) {
            unawaited(_fetchMore());
          }
          return false;
        },
        child: GridView.builder(
          controller: widget.scrollController,
          padding: EdgeInsets.fromLTRB(
            2,
            2,
            2,
            widget.draft.selected.isEmpty ? 80 : attachmentCaptionClearance,
          ),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 2,
            crossAxisSpacing: 2,
          ),
          itemCount: _assets.length + (_fetchingMore ? 1 : 0),
          itemBuilder: (context, index) {
            if (index == _assets.length) {
              return Center(
                child: CircularProgressIndicator(color: colors.accent),
              );
            }
            final asset = _assets[index];
            final item = widget.draft.forAsset(asset);
            final order = widget.draft.order(item);
            final selected = order > 0;
            return GestureDetector(
              key: ValueKey(asset.id),
              onTap: widget.draft.isSending
                  ? null
                  : () {
                      if (!item.isImage) {
                        widget.draft.toggle(item);
                        return;
                      }
                      unawaited(
                        widget.onPreview(
                          item,
                          _assets
                              .where((asset) => asset.type == AssetType.image)
                              .map(widget.draft.forAsset)
                              .toList(),
                        ),
                      );
                    },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    color: selected ? colors.base : Colors.transparent,
                    padding: selected
                        ? const EdgeInsets.all(6)
                        : EdgeInsets.zero,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(
                        selected ? NeuRadius.tag - 2 : 0,
                      ),
                      child: item.editedBytes != null
                          ? Image.memory(
                              item.editedBytes!,
                              fit: BoxFit.cover,
                              cacheWidth: 256,
                            )
                          : _AssetThumbnail(
                              key: ValueKey('thumbnail_${asset.id}'),
                              asset: asset,
                            ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    right: 4,
                    child: GestureDetector(
                      key: ValueKey('attachment-select-${item.id}'),
                      onTap: widget.draft.isSending
                          ? null
                          : () => widget.draft.toggle(item),
                      child: AttachmentSelectionBadge(
                        selected: selected,
                        order: order,
                      ),
                    ),
                  ),
                  if (asset.type == AssetType.video)
                    const Positioned(
                      bottom: 4,
                      left: 4,
                      child: Icon(
                        Icons.play_circle_fill,
                        color: Colors.white70,
                        size: 18,
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      );
    },
  );
}

class _AssetThumbnail extends StatefulWidget {
  final AssetEntity asset;
  const _AssetThumbnail({super.key, required this.asset});
  @override
  State<_AssetThumbnail> createState() => _AssetThumbnailState();
}

class _AssetThumbnailState extends State<_AssetThumbnail> {
  late Future<Uint8List?> _thumbnail;
  @override
  void initState() {
    super.initState();
    _thumbnail = _load();
  }

  @override
  void didUpdateWidget(covariant _AssetThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.asset.id != widget.asset.id) _thumbnail = _load();
  }

  Future<Uint8List?> _load() =>
      widget.asset.thumbnailDataWithSize(const ThumbnailSize.square(256));
  @override
  Widget build(BuildContext context) => FutureBuilder<Uint8List?>(
    future: _thumbnail,
    builder: (context, snapshot) {
      if (snapshot.data == null) return ColoredBox(color: context.neu.card);
      return Image.memory(
        snapshot.data!,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
    },
  );
}

class AttachmentSelectionBadge extends StatelessWidget {
  final bool selected;
  final int order;
  const AttachmentSelectionBadge({
    super.key,
    required this.selected,
    required this.order,
  });
  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 22,
      height: 22,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? colors.accent : Colors.black.withValues(alpha: .35),
        border: Border.all(
          color: Colors.white.withValues(alpha: selected ? 0 : .7),
          width: 1.5,
        ),
      ),
      alignment: Alignment.center,
      child: selected
          ? Text(
              '$order',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                color: colors.onAccent,
                fontWeight: FontWeight.w600,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}

class AttachmentMediaFallback extends StatefulWidget {
  final AttachmentMediaDraft draft;
  final ScrollController? scrollController;
  final Future<void> Function(
    AttachmentMediaItem item,
    List<AttachmentMediaItem> images,
  )
  onPreview;
  const AttachmentMediaFallback({
    super.key,
    required this.draft,
    required this.scrollController,
    required this.onPreview,
  });
  @override
  State<AttachmentMediaFallback> createState() =>
      _AttachmentMediaFallbackState();
}

class _AttachmentMediaFallbackState extends State<AttachmentMediaFallback> {
  final _picked = <AttachmentMediaItem>[];
  static const _groups = [
    XTypeGroup(
      label: '图片 / 视频',
      extensions: [
        'jpg',
        'jpeg',
        'png',
        'gif',
        'webp',
        'heic',
        'heif',
        'avif',
        'tiff',
        'tif',
        'bmp',
        'mp4',
        'mov',
        'm4v',
        'webm',
        'mkv',
        '3gp',
      ],
    ),
  ];

  Future<void> _pick() async {
    if (widget.draft.isSending) return;
    try {
      final files = await openFiles(acceptedTypeGroups: _groups);
      if (!mounted || widget.draft.isSending) return;
      for (final file in files) {
        final item = widget.draft.forFile(file);
        if (_picked.contains(item)) continue;
        _picked.add(item);
        widget.draft.toggle(item);
      }
      if (mounted) setState(() {});
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('选择媒体失败: $error')));
      }
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.draft,
    builder: (context, _) {
      final colors = context.neu;
      return ListView(
        controller: widget.scrollController,
        padding: EdgeInsets.fromLTRB(
          24,
          32,
          24,
          widget.draft.selected.isEmpty ? 80 : attachmentCaptionClearance,
        ),
        children: [
          if (_picked.isEmpty) ...[
            Icon(
              Icons.photo_library_outlined,
              size: 48,
              color: colors.textTertiary,
            ),
            const SizedBox(height: 12),
            const Text('此平台的相册网格不可用，请选择图片或视频', textAlign: TextAlign.center),
            const SizedBox(height: 16),
          ],
          Center(
            child: NeuButton(
              onPressed: widget.draft.isSending ? null : _pick,
              child: const Text('选择图片 / 视频'),
            ),
          ),
          const SizedBox(height: 12),
          for (final item in _picked)
            ListTile(
              key: ValueKey('attachment-media-${item.id}'),
              contentPadding: EdgeInsets.zero,
              leading: Icon(
                item.isImage ? Icons.photo_outlined : Icons.movie_outlined,
                color: colors.textSecondary,
              ),
              title: Text(
                item.editedFilename ?? item.file!.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: widget.draft.isSending
                  ? null
                  : () {
                      if (item.isImage) {
                        unawaited(
                          widget.onPreview(
                            item,
                            _picked.where((item) => item.isImage).toList(),
                          ),
                        );
                      } else {
                        widget.draft.toggle(item);
                      }
                    },
              trailing: IconButton(
                key: ValueKey('attachment-select-${item.id}'),
                tooltip: widget.draft.order(item) == 0 ? '选中' : '取消选择',
                onPressed: widget.draft.isSending
                    ? null
                    : () => widget.draft.toggle(item),
                icon: AttachmentSelectionBadge(
                  selected: widget.draft.order(item) > 0,
                  order: widget.draft.order(item),
                ),
              ),
            ),
        ],
      );
    },
  );
}
