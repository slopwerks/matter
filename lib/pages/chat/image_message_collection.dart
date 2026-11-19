import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../providers/chat_visual_settings_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import 'image_mosaic_layout.dart';
import 'image_stack_layout.dart';

typedef ImageCollectionTileBuilder = Widget Function(
  rust.ChatMessage message,
  Size size,
  BorderRadius radius,
);

class ImageMessageCollection extends StatefulWidget {
  final List<rust.ChatMessage> messages;
  final rust.ChatMessage selected;
  final bool album;
  final bool isMe;
  final BorderRadius borderRadius;
  final List<BoxShadow> shadows;
  final Map<String, GlobalKey> anchors;
  final ImageCollectionTileBuilder tileBuilder;
  final Widget? Function(rust.ChatMessage) captionBuilder;
  final Widget metadata;
  final Widget Function(Widget content) collapsedBuilder;
  final Widget Function(Widget collapseButton) expandedBuilder;

  const ImageMessageCollection({
    super.key,
    required this.messages,
    required this.selected,
    required this.album,
    required this.isMe,
    required this.borderRadius,
    required this.shadows,
    required this.anchors,
    required this.tileBuilder,
    required this.captionBuilder,
    required this.metadata,
    required this.collapsedBuilder,
    required this.expandedBuilder,
  });

  @override
  State<ImageMessageCollection> createState() => _ImageMessageCollectionState();
}

class _ImageMessageCollectionState extends State<ImageMessageCollection> {
  bool _expanded = false;
  bool _transitioning = false;

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      _transitioning = !MediaQuery.disableAnimationsOf(context);
    });
  }

  double _ratio(rust.ChatMessage message) =>
      (message.imageWidth ?? 0) > 0 && (message.imageHeight ?? 0) > 0
      ? message.imageWidth! / message.imageHeight!
      : 1;

  Widget _tile(rust.ChatMessage message, Size size, BorderRadius radius) =>
      KeyedSubtree(
        key:
            widget.anchors[message.id] ??
            ValueKey('collection-tile:${message.id}'),
        child: widget.tileBuilder(message, size, radius),
      );

  @override
  Widget build(BuildContext context) {
    final reducedMotion = MediaQuery.disableAnimationsOf(context);
    final content = _expanded && !widget.album
        ? widget.expandedBuilder(_toggleButton(context))
        : _collapsed(context);
    if (reducedMotion) return content;
    return AnimatedSize(
      key: const ValueKey('image-collection-transition'),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOutCubic,
      alignment: widget.isMe ? Alignment.topRight : Alignment.topLeft,
      clipBehavior: _transitioning ? Clip.hardEdge : Clip.none,
      onEnd: () {
        if (mounted && _transitioning) setState(() => _transitioning = false);
      },
      child: TweenAnimationBuilder<double>(
        key: ValueKey('image-presentation:${widget.album}:$_expanded'),
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOutCubic,
        tween: Tween(begin: _transitioning ? .65 : 1, end: 1),
        child: content,
        builder: (context, opacity, child) => Opacity(
          opacity: opacity,
          child: Transform.translate(
            offset: Offset(0, 6 * (1 - opacity) / .35),
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _collapsed(BuildContext context) {
    return widget.collapsedBuilder(
      LayoutBuilder(
        builder: (context, constraints) {
          final colors = context.neu;
          final maxWidth = math.min(
            widget.album
                ? math.min(MediaQuery.sizeOf(context).width * .68, 520.0)
                : MediaQuery.sizeOf(context).width,
            constraints.maxWidth,
          );
          final mosaic = widget.album;
          final captionMessage = widget.album
              ? widget.messages.lastWhere(
                  (message) => message.caption?.trim().isNotEmpty == true,
                  orElse: () => widget.messages.last,
                )
              : widget.selected;
          final caption = widget.captionBuilder(captionMessage);
          late final double width;
          late final Widget images;
          if (mosaic) {
            width = maxWidth;
            final layout = imageMosaicLayout(
              widget.messages.map(_ratio).toList(),
              width,
            );
            images = SizedBox(
              key: const ValueKey('image-mosaic'),
              width: width,
              height: layout.height,
              child: Stack(
                children: [
                  for (var index = 0; index < widget.messages.length; index++)
                    Positioned.fromRect(
                      rect: layout.tiles[index],
                      child: _tile(
                        widget.messages[index],
                        layout.tiles[index].size,
                        BorderRadius.zero,
                      ),
                    ),
                  widget.metadata,
                ],
              ),
            );
          } else {
            final pictures = [
              widget.selected,
              ...widget.messages
                  .where((message) => message.id != widget.selected.id)
                  .toList()
                  .reversed
                  .take(2),
            ];
            final layout = imageStackLayout(pictures.length, maxWidth);
            width = layout.size.width;
            final front = layout.layers.first.rect;
            final shown = pictures.map((message) => message.id).toSet();
            images = SizedBox(
              key: const ValueKey('image-stack'),
              width: width,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  for (var depth = pictures.length - 1; depth > 0; depth--)
                    Positioned.fromRect(
                      rect: layout.layers[depth].rect,
                      child: _stackPhoto(
                        context,
                        pictures[depth],
                        layout.layers[depth],
                        layout.scale,
                        front: false,
                      ),
                    ),
                  Padding(
                    padding: EdgeInsets.only(
                      left: front.left,
                      right: width - front.right,
                      top: front.top,
                    ),
                    child: _stackPhoto(
                      context,
                      pictures.first,
                      layout.layers.first,
                      layout.scale,
                      front: true,
                      caption: caption,
                    ),
                  ),
                  for (final message in widget.messages)
                    if (!shown.contains(message.id) &&
                        widget.anchors[message.id] != null)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: SizedBox.expand(
                            key: widget.anchors[message.id],
                          ),
                        ),
                      ),
                ],
              ),
            );
          }
          return SizedBox(
            width: width,
            child: Container(
              clipBehavior: mosaic ? Clip.antiAlias : Clip.none,
              decoration: BoxDecoration(
                color: mosaic
                    ? (widget.isMe ? colors.accent : colors.card)
                    : Colors.transparent,
                borderRadius: widget.borderRadius,
                boxShadow: mosaic ? widget.shadows : null,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [images, if (mosaic && caption != null) caption],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _stackPhoto(
    BuildContext context,
    rust.ChatMessage message,
    ImageStackLayer layer,
    double scale, {
    required bool front,
    Widget? caption,
  }) {
    final radius = BorderRadius.circular(16 * scale);
    final mediaRadius = caption == null
        ? radius
        : BorderRadius.vertical(top: Radius.circular(16 * scale));
    return IgnorePointer(
      ignoring: !front,
      child: ExcludeSemantics(
        excluding: !front,
        child: Opacity(
          opacity: layer.opacity,
          child: Transform.rotate(
            angle: layer.rotation,
            child: DecoratedBox(
              key: ValueKey('image-stack-card:${message.id}'),
              decoration: BoxDecoration(
                borderRadius: radius,
                boxShadow:
                    ChatVisualSettingsScope.of(context).bubbleShadowsEnabled
                    ? [
                        BoxShadow(
                          color: const Color(0xff0c1c14).withValues(alpha: .22),
                          offset: Offset(0, 3 * scale),
                          blurRadius: 12 * scale,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: radius,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: layer.rect.width,
                      height: layer.rect.height,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          _tile(message, layer.rect.size, mediaRadius),
                          if (front) widget.metadata,
                          if (front) _toggle(context),
                        ],
                      ),
                    ),
                    if (caption != null)
                      ColoredBox(
                        color: widget.isMe
                            ? context.neu.accent
                            : context.neu.card,
                        child: caption,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _toggle(BuildContext context) =>
      Positioned(left: 9, bottom: 8, child: _toggleButton(context));

  Widget _toggleButton(BuildContext context) => SizedBox(
    height: _expanded ? 36 : 32,
    child: IconButton(
      key: ValueKey('image-stack-toggle:${widget.messages.first.id}'),
      tooltip: _expanded
          ? '收起图片，共${widget.messages.length}张'
          : '展开全部${widget.messages.length}张图片',
      style: IconButton.styleFrom(
        backgroundColor: _expanded
            ? context.neu.card
            : const Color(0xff18241c).withValues(alpha: .73),
        foregroundColor: _expanded ? context.neu.text : Colors.white,
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      onPressed: _toggleExpanded,
      icon: DefaultTextStyle.merge(
        style: TextStyle(
          color: _expanded ? context.neu.text : Colors.white,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _expanded
                  ? CupertinoIcons.chevron_down
                  : CupertinoIcons.square_stack,
              size: 16,
            ),
            const SizedBox(width: 5),
            if (_expanded) const Text('收起 ·'),
            if (_expanded) const SizedBox(width: 5),
            Text(
              '${widget.messages.length}',
              key: const ValueKey('image-stack-count'),
            ),
            if (_expanded) const Text(' 张'),
          ],
        ),
      ),
    ),
  );
}
