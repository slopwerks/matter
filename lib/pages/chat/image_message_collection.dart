import 'dart:math' as math;

import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';

import '../../providers/chat_visual_settings_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import 'image_mosaic_layout.dart';
import 'image_stack_layout.dart';
import 'timeline/timeline_bubble_frame.dart';

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
  late String _selectedId = widget.selected.id;
  bool _expanded = false;
  bool _transitioning = false;
  double _dragX = 0;

  @override
  void didUpdateWidget(covariant ImageMessageCollection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.selected.id != oldWidget.selected.id ||
        !widget.messages.any((message) => message.id == _selectedId)) {
      _selectedId = widget.selected.id;
    }
  }

  int get _selectedIndex {
    final index = widget.messages.indexWhere(
      (message) => message.id == _selectedId,
    );
    return index >= 0 ? index : widget.messages.length - 1;
  }

  rust.ChatMessage get _activeMessage => widget.messages[_selectedIndex];

  void _stepSelected(int delta) {
    if (widget.messages.length <= 1) return;
    final length = widget.messages.length;
    final next = (_selectedIndex + delta % length + length) % length;
    setState(() {
      _selectedId = widget.messages[next].id;
      _dragX = 0;
    });
  }

  void _toggleExpanded() {
    setState(() {
      _expanded = !_expanded;
      _dragX = 0;
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
        builder: (context, opacity, child) =>
            Opacity(opacity: opacity, child: child),
      ),
    );
  }

  Widget _collapsed(BuildContext context) {
    return widget.collapsedBuilder(
      LayoutBuilder(
        builder: (context, constraints) {
          final maxWidth = math.min(
            widget.album
                ? TimelineBubbleFrame.maxWidth(context)
                : MediaQuery.sizeOf(context).width,
            constraints.maxWidth,
          );
          final mosaic = widget.album;
          final activeIndex = _selectedIndex;
          final captionMessage = widget.album
              ? widget.messages.lastWhere(
                  (message) => message.caption?.trim().isNotEmpty == true,
                  orElse: () => widget.messages.last,
                )
              : _activeMessage;
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
            final count = widget.messages.length;
            final layerCount = math.min(count, 3);
            final pictures = [
              for (var depth = 0; depth < layerCount; depth++)
                widget.messages[(activeIndex - depth + count) % count],
            ];
            final layout = imageStackLayout(
              pictures.length,
              maxWidth,
              aspectRatio: _ratio(widget.messages.last),
            );
            width = layout.size.width;
            final front = layout.layers.first.rect;
            final bottomPeek = math.max(0.0, layout.size.height - front.bottom);
            final shown = pictures.map((message) => message.id).toSet();
            final frontCard = _stackPhoto(
              context,
              pictures.first,
              layout.layers.first,
              layout.scale,
              front: true,
              caption: caption,
              activeIndex: activeIndex,
            );
            final interactiveFront = count > 1
                ? GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onHorizontalDragStart: (_) {
                      if (_dragX != 0) setState(() => _dragX = 0);
                    },
                    onHorizontalDragUpdate: (details) => setState(
                      () => _dragX = (_dragX + details.delta.dx).clamp(
                        -64.0,
                        64.0,
                      ),
                    ),
                    onHorizontalDragEnd: (details) {
                      final velocity = details.primaryVelocity ?? 0;
                      if (_dragX <= -28 || velocity < -260) {
                        _stepSelected(1);
                      } else if (_dragX >= 28 || velocity > 260) {
                        _stepSelected(-1);
                      } else if (_dragX != 0) {
                        setState(() => _dragX = 0);
                      }
                    },
                    onHorizontalDragCancel: () {
                      if (_dragX != 0 && mounted) setState(() => _dragX = 0);
                    },
                    child: Transform.translate(
                      offset: Offset(_dragX * 0.35, 0),
                      child: frontCard,
                    ),
                  )
                : frontCard;
            images = Padding(
              padding: EdgeInsets.only(bottom: bottomPeek),
              child: SizedBox(
                key: const ValueKey('image-stack'),
                width: width,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    for (var depth = pictures.length - 1; depth > 0; depth--)
                      Positioned(
                        left: layout.layers[depth].rect.left,
                        right: width - layout.layers[depth].rect.right,
                        bottom:
                            -(layout.layers[depth].rect.bottom - front.bottom),
                        height: layout.layers[depth].rect.height,
                        child: _stackPhoto(
                          context,
                          pictures[depth],
                          layout.layers[depth],
                          layout.scale,
                          front: false,
                        ),
                      ),
                    interactiveFront,
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
              ),
            );
          }
          return SizedBox(
            width: width,
            child: Container(
              clipBehavior: mosaic ? Clip.antiAlias : Clip.none,
              decoration: BoxDecoration(
                color: mosaic
                    ? messageBubbleFill(context, isMe: widget.isMe)
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
    int? activeIndex,
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
                        if (front && widget.messages.length > 1)
                          _switcher(context, activeIndex!),
                      ],
                    ),
                  ),
                  if (caption != null)
                    ColoredBox(
                      color: messageBubbleFill(context, isMe: widget.isMe),
                      child: caption,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _switcher(BuildContext context, int activeIndex) {
    final theme = Theme.of(context);
    final material = context.isMaterial;
    final colors = material
        ? materialImageControlColors(theme, overPhoto: true)
        : (
            fill: const Color(0xff18241c).withValues(alpha: .73),
            foreground: Colors.white,
          );
    final labelStyle = material
        ? theme.textTheme.labelMedium!.copyWith(
            color: colors.foreground,
            fontFeatures: const [FontFeature.tabularFigures()],
          )
        : TextStyle(
            color: colors.foreground,
            fontSize: 12,
            fontWeight: FontWeight.w700,
            fontFeatures: const [FontFeature.tabularFigures()],
          );
    Widget arrow({
      required Key key,
      required String tooltip,
      required IconData icon,
      required VoidCallback onPressed,
    }) => SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        key: key,
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 28, height: 28),
        style: IconButton.styleFrom(
          foregroundColor: colors.foreground,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        icon: Icon(icon, size: 16),
      ),
    );
    return Positioned(
      right: 9,
      top: 8,
      child: Material(
        key: const ValueKey('image-stack-switcher'),
        color: colors.fill,
        shape: material
            ? const StadiumBorder()
            : RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          height: 28,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              arrow(
                key: ValueKey('image-stack-prev:${widget.messages.first.id}'),
                tooltip: '上一张',
                icon: material
                    ? Icons.chevron_left_rounded
                    : CupertinoIcons.chevron_left,
                onPressed: () => _stepSelected(-1),
              ),
              Text(
                '${activeIndex + 1}/${widget.messages.length}',
                key: const ValueKey('image-stack-page'),
                style: labelStyle,
              ),
              arrow(
                key: ValueKey('image-stack-next:${widget.messages.first.id}'),
                tooltip: '下一张',
                icon: material
                    ? Icons.chevron_right_rounded
                    : CupertinoIcons.chevron_right,
                onPressed: () => _stepSelected(1),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _toggle(BuildContext context) =>
      Positioned(left: 9, bottom: 8, child: _toggleButton(context));

  Widget _toggleButton(BuildContext context) {
    final theme = Theme.of(context);
    final material = context.isMaterial;
    final colors = material
        ? materialImageControlColors(theme, overPhoto: !_expanded)
        : (
            fill: _expanded
                ? context.neu.card
                : const Color(0xff18241c).withValues(alpha: .73),
            foreground: _expanded ? context.neu.text : Colors.white,
          );
    return SizedBox(
      height: _expanded ? 36 : 32,
      child: IconButton(
        key: ValueKey('image-stack-toggle:${widget.messages.first.id}'),
        tooltip: _expanded
            ? '收起图片，共${widget.messages.length}张'
            : '展开全部${widget.messages.length}张图片',
        style: IconButton.styleFrom(
          backgroundColor: colors.fill,
          foregroundColor: colors.foreground,
          padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
          shape: material
              ? const StadiumBorder()
              : RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        ),
        onPressed: _toggleExpanded,
        icon: DefaultTextStyle.merge(
          style: material
              ? theme.textTheme.labelMedium!.copyWith(color: colors.foreground)
              : TextStyle(
                  color: colors.foreground,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _expanded
                    ? (material
                          ? Icons.expand_more_rounded
                          : CupertinoIcons.chevron_down)
                    : (material
                          ? Icons.layers_outlined
                          : CupertinoIcons.square_stack),
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
}
