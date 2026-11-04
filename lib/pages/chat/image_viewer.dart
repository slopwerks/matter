import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../providers/message_ordering.dart';
import '../../providers/image_view_history.dart';
import '../../providers/message_cache_persistence.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import 'file_download_saver.dart';
import 'file_message_bubble.dart' show sanitizeAttachmentFilename;
import 'forward_message_sheet.dart';
import 'image_loading_policy.dart';
import 'image_media.dart';
import 'image_placeholders.dart';
import 'image_viewer_media.dart';
import 'image_zoom_frame.dart';

export 'image_viewer_media.dart' show ImageHistoryLoader, ImageViewerSource;

class ChatImageViewer extends ConsumerStatefulWidget {
  final ImageViewerSource initialSource;
  final Iterable<rust.ChatMessage> messages;
  final Animation<double> animation;
  final String? roomId;
  final ValueChanged<String>? onMessageJumpRequested;
  final ValueChanged<rust.ChatMessage>? onMessageReplyRequested;
  final ValueChanged<rust.ChatRoom>? onMessageForwarded;
  final ImageHistoryLoader? loadOlderImages;

  const ChatImageViewer({
    super.key,
    required this.initialSource,
    required this.animation,
    this.messages = const [],
    this.roomId,
    this.onMessageJumpRequested,
    this.onMessageReplyRequested,
    this.onMessageForwarded,
    this.loadOlderImages,
  });

  @override
  ConsumerState<ChatImageViewer> createState() => _ChatImageViewerState();
}

class _ChatImageViewerState extends ConsumerState<ChatImageViewer> {
  late List<ImageViewerSource> _sources;
  late final PageController _pages;
  late final String? _account;
  late int _index;
  bool _zoomed = false;
  bool _loadingOlder = false;
  late bool _hasMore;
  final _mediaById = <String, ImageViewerMedia>{};
  final _downloading = <String>{};
  final _forwarding = <String>{};
  ImageViewerMedia? _menuMedia;
  final _albumCaptions = <String, String?>{};
  final _captionLoading = <String>{};
  final _captionErrors = <String>{};

  ImageViewerMedia _mediaFor(ImageViewerSource source) =>
      _mediaById.putIfAbsent(source.id, () => ImageViewerMedia(source, ref));

  void _releaseMedia(ImageViewerMedia media) {
    if (identical(_mediaById[media.source.id], media)) {
      _mediaById.remove(media.source.id);
    }
    media.dispose();
  }

  List<ImageViewerSource> _imageSources(Iterable<rust.ChatMessage> messages) {
    final images =
        messages
            .where(
              (message) =>
                  message.msgType == rust.MessageType.image &&
                  (message.imageUrl != null || message.mediaSourceJson != null),
            )
            .toList()
          ..sort(compareChatMessages);
    return images
        .map(
          (message) => message.id == widget.initialSource.id
              ? widget.initialSource
              : ImageViewerSource.fromMessage(message, roomId: widget.roomId),
        )
        .toList();
  }

  @override
  void initState() {
    super.initState();
    _account = ref.read(activeUserIdProvider);
    _sources = _imageSources(widget.messages);
    if (!_sources.any((source) => source.id == widget.initialSource.id)) {
      _sources.add(widget.initialSource);
    }
    _index = _sources.indexWhere(
      (source) => source.id == widget.initialSource.id,
    );
    _pages = PageController(initialPage: _index);
    _hasMore = widget.loadOlderImages != null;
    _rememberViewed();
  }

  @override
  void dispose() {
    _pages.dispose();
    for (final media in _mediaById.values) {
      media.dispose();
    }
    _mediaById.clear();
    super.dispose();
  }

  void _rememberViewed() {
    final source = _sources[_index];
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          ref.read(activeUserIdProvider) != _account ||
          widget.roomId == null) {
        return;
      }
      final hidden =
          _mediaById[source.id]?.spoilerHidden ??
          (source.message?.imageMetadata?.spoiler == true &&
              !source.spoilerRevealed);
      if (hidden) return;
      ref
          .read(
            imageViewHistoryProvider((
              account: _account ?? 'anonymous',
              room: widget.roomId!,
            )).notifier,
          )
          .viewed(source.id);
    });
  }

  String _albumRoot(ImageViewerSource source) =>
      source.message?.imageMetadata?.albumRoot ?? source.id;

  String? _description(ImageViewerSource source) {
    if (source.description?.trim().isNotEmpty == true) {
      return source.description;
    }
    final root = _albumRoot(source);
    for (final candidate in _sources.reversed) {
      if (_albumRoot(candidate) == root &&
          candidate.description?.trim().isNotEmpty == true) {
        return candidate.description;
      }
    }
    return _albumCaptions[root];
  }

  Future<void> _loadCaption(ImageViewerSource source) async {
    final root = _albumRoot(source);
    if (widget.roomId == null ||
        _account == null ||
        !root.startsWith('\$') ||
        _captionLoading.contains(root) ||
        _albumCaptions.containsKey(root)) {
      return;
    }
    _captionLoading.add(root);
    _captionErrors.remove(root);
    try {
      final caption = await rust.getImageAlbumCaption(
        accountUserId: _account,
        roomId: widget.roomId!,
        rootEventId: root,
      );
      if (mounted && ref.read(activeUserIdProvider) == _account) {
        setState(() => _albumCaptions[root] = caption);
      }
    } catch (_) {
      if (mounted) setState(() => _captionErrors.add(root));
    } finally {
      _captionLoading.remove(root);
    }
  }

  Future<void> _previous() async {
    if (_loadingOlder || _zoomed) return;
    if (_index > 0) {
      await _pages.previousPage(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
      return;
    }
    final loader = widget.loadOlderImages;
    if (loader == null || !_hasMore) return;
    setState(() => _loadingOlder = true);
    try {
      final currentId = _sources[_index].id;
      final history = await loader();
      if (!mounted || ref.read(activeUserIdProvider) != _account) return;
      final byId = {for (final source in _sources) source.id: source};
      for (final source in _imageSources(history.messages)) {
        byId.putIfAbsent(source.id, () => source);
      }
      final sources = byId.values.toList()
        ..sort((a, b) {
          if (a.message == null || b.message == null) return 0;
          return compareChatMessages(a.message!, b.message!);
        });
      final nextIndex = sources.indexWhere((source) => source.id == currentId);
      setState(() {
        _sources = sources;
        _index = nextIndex;
        _hasMore = history.hasMore;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      _pages.jumpToPage(nextIndex);
      if (nextIndex > 0) {
        await _pages.previousPage(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else if (_hasMore) {
        _notify('这页没有图片，可继续加载更早消息');
      }
    } catch (error) {
      if (mounted) _notify('加载更早图片失败: $error');
    } finally {
      if (mounted) setState(() => _loadingOlder = false);
    }
  }

  Future<void> _download(ImageViewerMedia media, {bool saveAs = false}) async {
    final source = media.source;
    if (_downloading.contains(source.id)) return;
    setState(() => _downloading.add(source.id));
    final account = ref.read(activeUserIdProvider);
    try {
      final bytes =
          media.bytes ??
          (source.mediaSourceJson != null
              ? await rust.downloadMediaSourceBytes(
                  mediaSourceJson: source.mediaSourceJson!,
                  maxSizeBytes: 128 * 1024 * 1024,
                )
              : source.imageUrl != null
              ? await rust.downloadMediaBytes(mxcUrl: source.imageUrl!)
              : null);
      if (!mounted || ref.read(activeUserIdProvider) != account) return;
      if (bytes == null || bytes.isEmpty) throw StateError('图片不可用');
      final filename = sanitizeAttachmentFilename(
        source.filename ?? 'image.png',
      );
      final saved = await saveDownloadedFile(
        filename: filename,
        bytes: bytes,
        chooseLocation: saveAs,
      );
      if (mounted && saved) _notify('图片已保存');
    } catch (error) {
      if (mounted) _notify('下载失败: $error');
    } finally {
      if (mounted) setState(() => _downloading.remove(source.id));
    }
  }

  Future<void> _forward(ImageViewerMedia media) async {
    final source = media.source;
    if (_forwarding.contains(source.id)) return;
    setState(() => _forwarding.add(source.id));
    try {
      final room = await showForwardMessageSheet(
        context: context,
        sourceRoomId: widget.roomId!,
        message: _description(source) == null
            ? source.message!
            : chatMessageFromMap({
                ...chatMessageToMap(source.message!),
                'caption': _description(source),
              }),
      );
      if (mounted && room != null) {
        _notify('已转发到 ${room.name}');
        widget.onMessageForwarded?.call(room);
      }
    } finally {
      if (mounted) setState(() => _forwarding.remove(source.id));
    }
  }

  void _jump(ImageViewerMedia media) {
    Navigator.of(context).pop();
    widget.onMessageJumpRequested?.call(media.source.id);
  }

  void _reply(ImageViewerMedia media) {
    Navigator.of(context).pop();
    widget.onMessageReplyRequested?.call(media.source.message!);
  }

  void _notify(String text) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));

  Widget _buildToolbar(BuildContext context, ImageViewerMedia media) {
    final colors = context.neu;
    final source = media.source;
    final busy =
        media.original == OriginalImageState.resolving ||
        media.original == OriginalImageState.loading;
    final label = switch (media.original) {
      OriginalImageState.thumbnail => '原图',
      OriginalImageState.resolving || OriginalImageState.loading => '加载',
      OriginalImageState.loaded => '高清',
      OriginalImageState.failed => '重试',
    };
    final originalTooltip = switch (media.original) {
      OriginalImageState.thumbnail => '查看原图',
      OriginalImageState.resolving || OriginalImageState.loading => '正在加载原图',
      OriginalImageState.loaded => '已加载原图',
      OriginalImageState.failed => '原图加载失败，点击重试',
    };
    final showOriginal =
        source.imageUrl?.startsWith('mxc://') == true &&
        !shouldAutoLoadOriginal(
          fileSize: source.fileSize,
          mimeType: source.mimeType,
          filename: source.filename,
        );
    final canForward =
        widget.roomId != null &&
        source.message != null &&
        !isLocalOutgoingMessage(source.id);
    final canJump =
        widget.onMessageJumpRequested != null && source.message != null;
    final canReply =
        widget.onMessageReplyRequested != null &&
        source.message != null &&
        !isLocalOutgoingMessage(source.id);
    return AppBar(
      backgroundColor: colors.base.withValues(alpha: 1),
      foregroundColor: colors.text,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      leading: IconButton(
        tooltip: '关闭',
        onPressed: () => Navigator.of(context).pop(),
        icon: const Icon(CupertinoIcons.chevron_back, size: 22),
      ),
      actions: [
        if (showOriginal)
          Tooltip(
            message: originalTooltip,
            child: SizedBox(
              width: 56,
              height: 48,
              child: TextButton(
                style: TextButton.styleFrom(
                  padding: EdgeInsets.zero,
                  foregroundColor: media.original == OriginalImageState.failed
                      ? colors.error
                      : colors.text,
                  disabledForegroundColor: colors.textSecondary,
                ),
                onPressed:
                    media.spoilerHidden ||
                        busy ||
                        media.original == OriginalImageState.loaded
                    ? null
                    : media.loadOriginal,
                child: busy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: colors.text,
                          strokeWidth: 2,
                        ),
                      )
                    : Text(label),
              ),
            ),
          ),
        IconButton(
          tooltip: '下载',
          onPressed: _downloading.contains(source.id)
              ? null
              : () => _download(media),
          icon: _downloading.contains(source.id)
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    color: colors.text,
                    strokeWidth: 2,
                  ),
                )
              : const Icon(CupertinoIcons.arrow_down_to_line, size: 22),
        ),
        if (supportsSaveAs ||
            canReply ||
            canForward ||
            canJump ||
            _menuMedia != null)
          PopupMenuButton<_ViewerAction>(
            key: const ValueKey('image-viewer-more'),
            tooltip: '更多操作',
            icon: const Icon(CupertinoIcons.ellipsis, size: 22),
            onOpened: () => _menuMedia = media,
            onCanceled: () => setState(() => _menuMedia = null),
            onSelected: (action) {
              final target = _menuMedia ?? media;
              setState(() => _menuMedia = null);
              switch (action) {
                case _ViewerAction.saveAs:
                  unawaited(_download(target, saveAs: true));
                case _ViewerAction.reply:
                  _reply(target);
                case _ViewerAction.forward:
                  unawaited(_forward(target));
                case _ViewerAction.jump:
                  _jump(target);
              }
            },
            itemBuilder: (context) => [
              if (supportsSaveAs)
                PopupMenuItem(
                  value: _ViewerAction.saveAs,
                  enabled: !_downloading.contains(source.id),
                  child: const Text('另存为…'),
                ),
              if (canReply)
                const PopupMenuItem(
                  value: _ViewerAction.reply,
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.arrowshape_turn_up_left, size: 20),
                      SizedBox(width: 12),
                      Text('回复'),
                    ],
                  ),
                ),
              if (canForward)
                PopupMenuItem(
                  value: _ViewerAction.forward,
                  enabled: !_forwarding.contains(source.id),
                  child: const Row(
                    children: [
                      Icon(CupertinoIcons.arrowshape_turn_up_right, size: 20),
                      SizedBox(width: 12),
                      Text('转发'),
                    ],
                  ),
                ),
              if (canJump)
                const PopupMenuItem(
                  value: _ViewerAction.jump,
                  child: Row(
                    children: [
                      Icon(CupertinoIcons.chat_bubble_text, size: 20),
                      SizedBox(width: 12),
                      Text('转到消息'),
                    ],
                  ),
                ),
            ],
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(activeUserIdProvider, (_, next) {
      if (next != _account) Navigator.of(context).pop();
    });
    ref.listen(connectionProvider, (previous, next) {
      if (previous != AppConnectionState.connected &&
          next == AppConnectionState.connected &&
          ref.read(activeUserIdProvider) == _account) {
        for (final media in _mediaById.values) {
          if (media.resolveFailed ||
              (media.original == OriginalImageState.failed &&
                  media.url == null)) {
            unawaited(media.resolveImage());
          }
        }
      }
    });
    final media = _mediaFor(_sources[_index]);
    final description = _description(media.source);
    final captionRoot = _albumRoot(media.source);
    if (description == null && !_captionErrors.contains(captionRoot)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_loadCaption(media.source));
      });
    }
    final toolbarHeight = MediaQuery.paddingOf(context).top + kToolbarHeight;
    return AnimatedBuilder(
      animation: widget.animation,
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.black.withValues(
          alpha: Curves.easeOut.transform(widget.animation.value),
        ),
        body: Stack(
          children: [
            Positioned.fill(
              top: toolbarHeight,
              child: DismissibleImageGallery(
                enabled: !_zoomed,
                onClose: () => Navigator.of(context).pop(),
                child: NotificationListener<OverscrollNotification>(
                  onNotification: (notification) {
                    if (notification.overscroll < -10 &&
                        notification.dragDetails != null &&
                        _index == 0 &&
                        _hasMore) {
                      unawaited(_previous());
                    }
                    return false;
                  },
                  child: PageView.builder(
                    controller: _pages,
                    physics: _zoomed
                        ? const NeverScrollableScrollPhysics()
                        : const PageScrollPhysics(),
                    itemCount: _sources.length,
                    findChildIndexCallback: (key) {
                      final index = _sources.indexWhere(
                        (source) => ValueKey(source.id) == key,
                      );
                      return index < 0 ? null : index;
                    },
                    onPageChanged: (index) {
                      setState(() {
                        _index = index;
                        _zoomed = false;
                      });
                      _rememberViewed();
                    },
                    itemBuilder: (context, index) {
                      final pageMedia = _mediaFor(_sources[index]);
                      return _ImageViewerPage(
                        key: ValueKey(_sources[index].id),
                        media: pageMedia,
                        active: index == _index,
                        onDispose: () => _releaseMedia(pageMedia),
                        onZoomChanged: (zoomed) {
                          if (index == _index && _zoomed != zoomed) {
                            setState(() => _zoomed = zoomed);
                          }
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
            Positioned(
              key: const ValueKey('image-viewer-toolbar'),
              top: 0,
              left: 0,
              right: 0,
              height: toolbarHeight,
              child: ListenableBuilder(
                listenable: media,
                builder: (context, _) => _buildToolbar(context, media),
              ),
            ),
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.paddingOf(context).bottom + 12,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (description?.trim().isNotEmpty == true)
                    Container(
                      key: const ValueKey('image-viewer-caption'),
                      margin: const EdgeInsets.symmetric(horizontal: 16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.sizeOf(context).height * .25,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: .75),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: SingleChildScrollView(
                        child: SelectableText(
                          description!,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                        ),
                      ),
                    ),
                  if (_captionErrors.contains(captionRoot) &&
                      media.source.message?.imageMetadata?.albumRoot != null)
                    IconButton(
                      tooltip: '重试描述',
                      color: Colors.white,
                      onPressed: () => _loadCaption(media.source),
                      icon: const Icon(CupertinoIcons.arrow_clockwise),
                    ),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      IconButton(
                        tooltip: _index == 0 && _hasMore ? '加载更早图片' : '上一张',
                        onPressed:
                            !_zoomed &&
                                !_loadingOlder &&
                                (_index > 0 || _hasMore)
                            ? _previous
                            : null,
                        icon: _loadingOlder
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(
                                CupertinoIcons.chevron_left,
                                color: Colors.white,
                                size: 22,
                              ),
                      ),

                      IconButton(
                        tooltip: '下一张',
                        onPressed: !_zoomed && _index < _sources.length - 1
                            ? () => _pages.nextPage(
                                duration: const Duration(milliseconds: 220),
                                curve: Curves.easeOut,
                              )
                            : null,
                        icon: const Icon(
                          CupertinoIcons.chevron_right,
                          color: Colors.white,
                          size: 22,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

enum _ViewerAction { reply, forward, jump, saveAs }

class _ImageViewerPage extends StatefulWidget {
  final ImageViewerMedia media;
  final bool active;
  final ValueChanged<bool> onZoomChanged;
  final VoidCallback onDispose;

  const _ImageViewerPage({
    super.key,
    required this.media,
    required this.active,
    required this.onZoomChanged,
    required this.onDispose,
  });

  @override
  State<_ImageViewerPage> createState() => _ImageViewerPageState();
}

class _ImageViewerPageState extends State<_ImageViewerPage> {
  @override
  void dispose() {
    widget.onDispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.media,
    builder: (context, _) {
      final media = widget.media;
      final source = media.source;
      final displayedUrl = media.url;
      if (media.spoilerHidden) {
        return SizedBox.expand(
          child: SpoilerImageCover(
            hash: source.message?.imageMetadata?.blurhash,
            reason: source.message?.imageMetadata?.spoilerReason,
            color: Colors.black,
            onReveal: media.revealSpoiler,
          ),
        );
      }
      return Stack(
        children: [
          Positioned.fill(
            child: ZoomableImageFrame(
              active: widget.active,
              onZoomChanged: widget.onZoomChanged,
              child: SizedBox.expand(
                child: Center(
                  child: AspectRatio(
                    aspectRatio: source.aspectRatio,
                    child: HeroMode(
                      enabled: widget.active,
                      child: Hero(
                        tag: source.heroTag,
                        createRectTween: (begin, end) =>
                            RectTween(begin: begin, end: end),
                        flightShuttleBuilder: roundedImageFlightShuttle,
                        child: HeroImageClip(
                          borderRadius: BorderRadius.zero,
                          child: ChatMediaImage(
                            imageUrl: displayedUrl,
                            imageBytes: media.bytes,
                            blurhash: source.message?.imageMetadata?.blurhash,
                            fit: BoxFit.contain,
                            onLoaded: () => media.markLoaded(displayedUrl),
                            onError: () => media.markFailed(displayedUrl),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          if (media.url == null && media.bytes == null)
            Positioned.fill(
              child: Center(
                child:
                    media.resolveFailed ||
                        media.original == OriginalImageState.failed
                    ? TextButton.icon(
                        onPressed: media.resolveImage,
                        icon: const Icon(
                          CupertinoIcons.arrow_clockwise,
                          color: Colors.white,
                          size: 22,
                        ),
                        label: const Text(
                          '重新加载图片',
                          style: TextStyle(color: Colors.white),
                        ),
                      )
                    : source.message?.imageMetadata?.blurhash != null
                    ? SizedBox.expand(
                        child: BlurhashPlaceholder(
                          hash: source.message!.imageMetadata!.blurhash,
                          color: Colors.black,
                        ),
                      )
                    : const CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
              ),
            ),
        ],
      );
    },
  );
}
