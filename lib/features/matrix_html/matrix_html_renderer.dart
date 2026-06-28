import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'matrix_html_node.dart';
import 'matrix_html_parser.dart';
import 'matrix_link_router.dart';

class MatrixHtmlMessage extends StatefulWidget {
  final String html;
  final TextStyle style;
  final Color accentColor;
  final MatrixLinkHandler? onLinkTap;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;
  final Widget? trailingMetadata;
  final double minWidth;

  const MatrixHtmlMessage({
    super.key,
    required this.html,
    required this.style,
    required this.accentColor,
    this.onLinkTap,
    this.mentionDisplayNames = const {},
    this.onMentionTap,
    this.trailingMetadata,
    this.minWidth = 0,
  });

  @override
  State<MatrixHtmlMessage> createState() => _MatrixHtmlMessageState();
}

class _MatrixHtmlMessageState extends State<MatrixHtmlMessage> {
  static const _parser = MatrixHtmlParser();
  late List<MatrixHtmlNode> _nodes;
  List<TapGestureRecognizer> _recognizers = [];

  @override
  void initState() {
    super.initState();
    _nodes = _parser.parse(widget.html);
  }

  @override
  void didUpdateWidget(covariant MatrixHtmlMessage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.html != widget.html) {
      _nodes = _parser.parse(widget.html);
    }
  }

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previousRecognizers = _recognizers;
    final recognizers = <TapGestureRecognizer>[];
    final renderer = _MatrixNodeRenderer(
      context: context,
      baseStyle: widget.style,
      accentColor: widget.accentColor,
      onLinkTap: widget.onLinkTap ?? const MatrixLinkRouter().open,
      mentionDisplayNames: widget.mentionDisplayNames,
      onMentionTap: widget.onMentionTap,
      gestureRecognizers: recognizers,
    );
    _recognizers = recognizers;
    if (previousRecognizers.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final recognizer in previousRecognizers) {
          recognizer.dispose();
        }
      });
    }
    final trailingMetadata = widget.trailingMetadata;
    if (trailingMetadata != null) {
      final inline = renderer.singleInlineBlock(_nodes);
      if (inline != null) {
        return SelectionArea(
          child: _InlineRichTextMetadata(
            text: inline.span,
            metadata: trailingMetadata,
            minWidth: widget.minWidth,
          ),
        );
      }

      final blocks = renderer.renderBlocksWithTrailing(
        _nodes,
        trailingMetadata,
      );
      if (blocks.isEmpty) return trailingMetadata;
      return LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth.isFinite
              ? constraints.maxWidth
              : MediaQuery.sizeOf(context).width;
          return SizedBox(
            width: width,
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: blocks,
              ),
            ),
          );
        },
      );
    }

    final blocks = renderer.renderBlocks(_nodes);
    if (blocks.isEmpty) return const SizedBox.shrink();
    return SelectionArea(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: blocks,
      ),
    );
  }
}

class _MatrixNodeRenderer {
  final BuildContext context;
  final TextStyle baseStyle;
  final Color accentColor;
  final MatrixLinkHandler onLinkTap;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;
  final List<TapGestureRecognizer> gestureRecognizers;

  const _MatrixNodeRenderer({
    required this.context,
    required this.baseStyle,
    required this.accentColor,
    required this.onLinkTap,
    required this.mentionDisplayNames,
    required this.onMentionTap,
    required this.gestureRecognizers,
  });

  List<Widget> renderBlocks(List<MatrixHtmlNode> nodes) {
    final widgets = <Widget>[];
    final inlineNodes = <MatrixHtmlNode>[];

    void addWidget(Widget? widget) {
      if (widget == null) return;
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 7));
      widgets.add(widget);
    }

    void flushInlineNodes() {
      if (inlineNodes.isEmpty) return;
      final hasContent = inlineNodes.any(
        (node) => node is! MatrixTextNode || node.text.trim().isNotEmpty,
      );
      if (hasContent) {
        addWidget(_richText(List.of(inlineNodes), baseStyle));
      }
      inlineNodes.clear();
    }

    for (final node in nodes) {
      if (_isRootInlineNode(node)) {
        inlineNodes.add(node);
      } else {
        flushInlineNodes();
        addWidget(_renderBlock(node));
      }
    }
    flushInlineNodes();
    return widgets;
  }

  _InlineBlock? singleInlineBlock(List<MatrixHtmlNode> nodes) {
    final meaningful = nodes
        .where((node) => node is! MatrixTextNode || node.text.trim().isNotEmpty)
        .toList();
    if (meaningful.isEmpty) return null;
    if (meaningful.every(_isRootInlineNode)) {
      return _inlineBlock(meaningful, baseStyle);
    }
    if (meaningful.length != 1) return null;
    return _inlineBlockForNode(meaningful.single);
  }

  bool _isRootInlineNode(MatrixHtmlNode node) {
    if (node is MatrixTextNode) return true;
    final tag = (node as MatrixElementNode).tag;
    return !const {
      'p',
      'h1',
      'h2',
      'h3',
      'h4',
      'h5',
      'h6',
      'blockquote',
      'ul',
      'ol',
      'li',
      'pre',
      'hr',
    }.contains(tag);
  }

  List<Widget> renderBlocksWithTrailing(
    List<MatrixHtmlNode> nodes,
    Widget metadata,
  ) {
    final renderable = <(MatrixHtmlNode, Widget)>[];
    for (final node in nodes) {
      final widget = _renderBlock(node);
      if (widget != null) renderable.add((node, widget));
    }
    if (renderable.isEmpty) {
      return [Align(alignment: Alignment.centerRight, child: metadata)];
    }

    final widgets = <Widget>[];
    for (final entry in renderable.indexed) {
      if (widgets.isNotEmpty) widgets.add(const SizedBox(height: 7));
      final isLast = entry.$1 == renderable.length - 1;
      widgets.add(
        isLast ? _renderBlockWithTrailing(entry.$2.$1, metadata) : entry.$2.$2,
      );
    }
    return widgets;
  }

  Widget _renderBlockWithTrailing(MatrixHtmlNode node, Widget metadata) {
    final inline = _inlineBlockForNode(node);
    if (inline != null) {
      return _InlineRichTextMetadata(text: inline.span, metadata: metadata);
    }

    final element = node as MatrixElementNode;
    switch (element.tag) {
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10, top: 3),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accentColor, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: renderBlocksWithTrailing(element.children, metadata),
          ),
        );
      case 'ul':
      case 'ol':
        return _renderList(
          element,
          ordered: element.tag == 'ol',
          trailingMetadata: metadata,
        );
      default:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            _renderBlock(node)!,
            const SizedBox(height: 3),
            Align(alignment: Alignment.centerRight, child: metadata),
          ],
        );
    }
  }

  Widget? _renderBlock(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      if (node.text.trim().isEmpty) return null;
      return _richText([node], baseStyle);
    }
    final element = node as MatrixElementNode;
    switch (element.tag) {
      case 'p':
        return _richText(element.children, baseStyle);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(element.tag.substring(1));
        return _richText(
          element.children,
          baseStyle.copyWith(
            fontSize: (22 - level * 1.5).clamp(15, 21).toDouble(),
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        );
      case 'blockquote':
        return Container(
          padding: const EdgeInsets.only(left: 10, top: 3, bottom: 3),
          decoration: BoxDecoration(
            border: Border(left: BorderSide(color: accentColor, width: 3)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: renderBlocks(element.children),
          ),
        );
      case 'ul':
      case 'ol':
        return _renderList(element, ordered: element.tag == 'ol');
      case 'pre':
        return Container(
          constraints: const BoxConstraints(maxWidth: 520),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Text(
              element.textContent,
              style: baseStyle.copyWith(
                fontFamily: 'monospace',
                fontSize: baseStyle.fontSize == null
                    ? 13
                    : baseStyle.fontSize! - 1,
              ),
            ),
          ),
        );
      case 'hr':
        return Divider(color: baseStyle.color?.withValues(alpha: 0.3));
      default:
        return _richText([element], baseStyle);
    }
  }

  Widget _renderList(
    MatrixElementNode list, {
    required bool ordered,
    Widget? trailingMetadata,
  }) {
    final items = list.children
        .whereType<MatrixElementNode>()
        .where((node) => node.tag == 'li')
        .toList();
    if (items.isEmpty && trailingMetadata != null) {
      return Align(alignment: Alignment.centerRight, child: trailingMetadata);
    }
    final start = int.tryParse(list.attributes['start'] ?? '') ?? 1;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final entry in items.indexed)
          Padding(
            padding: EdgeInsets.only(
              top: 2,
              bottom: trailingMetadata != null && entry.$1 == items.length - 1
                  ? 0
                  : 2,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  child: Text(
                    ordered ? '${start + entry.$1}.' : '•',
                    textAlign: TextAlign.right,
                    style: baseStyle.copyWith(fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(width: 7),
                Expanded(
                  child: Column(
                    crossAxisAlignment: trailingMetadata != null
                        ? CrossAxisAlignment.stretch
                        : CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children:
                        trailingMetadata != null && entry.$1 == items.length - 1
                        ? renderBlocksWithTrailing(
                            entry.$2.children,
                            trailingMetadata,
                          )
                        : renderBlocks(entry.$2.children),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _richText(List<MatrixHtmlNode> nodes, TextStyle style) {
    return Text.rich(_inlineBlock(nodes, style).span, softWrap: true);
  }

  _InlineBlock? _inlineBlockForNode(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      if (node.text.trim().isEmpty) return null;
      return _inlineBlock([node], baseStyle);
    }

    final element = node as MatrixElementNode;
    switch (element.tag) {
      case 'p':
        return _inlineBlock(element.children, baseStyle);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(element.tag.substring(1));
        return _inlineBlock(
          element.children,
          baseStyle.copyWith(
            fontSize: (22 - level * 1.5).clamp(15, 21).toDouble(),
            fontWeight: FontWeight.w800,
            height: 1.25,
          ),
        );
      case 'blockquote':
      case 'ul':
      case 'ol':
      case 'pre':
      case 'hr':
        return null;
      default:
        return _inlineBlock([element], baseStyle);
    }
  }

  _InlineBlock _inlineBlock(List<MatrixHtmlNode> nodes, TextStyle style) {
    return _InlineBlock(
      TextSpan(style: style, children: _inlineSpans(nodes, style)),
    );
  }

  List<InlineSpan> _inlineSpans(
    List<MatrixHtmlNode> nodes,
    TextStyle inherited,
  ) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is MatrixTextNode) {
        spans.add(TextSpan(text: node.text, style: inherited));
        continue;
      }
      final element = node as MatrixElementNode;
      var style = inherited;
      if (element.tag == 'strong' || element.tag == 'b') {
        style = style.copyWith(fontWeight: FontWeight.w800);
      } else if (element.tag == 'em' || element.tag == 'i') {
        style = style.copyWith(fontStyle: FontStyle.italic);
      } else if (element.tag == 'del' || element.tag == 's') {
        style = style.copyWith(decoration: TextDecoration.lineThrough);
      } else if (element.tag == 'code') {
        style = style.copyWith(
          fontFamily: 'monospace',
          backgroundColor: Colors.black.withValues(alpha: 0.14),
        );
      } else if (element.tag == 'br') {
        spans.add(const TextSpan(text: '\n'));
        continue;
      } else if (element.tag == 'a') {
        final href = element.attributes['href'];
        if (href != null) {
          final uri = Uri.tryParse(href);
          final mentionUserId = uri == null ? null : matrixUserIdFromUri(uri);
          final isMention = mentionUserId != null;
          TapGestureRecognizer? recognizer;
          if (isMention && onMentionTap != null) {
            recognizer = TapGestureRecognizer()
              ..onTap = () => onMentionTap!(mentionUserId);
          } else if (!isMention && uri != null) {
            recognizer = TapGestureRecognizer()..onTap = () => onLinkTap(uri);
          }
          if (recognizer != null) gestureRecognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: isMention
                  ? matrixMentionLabel(
                      mentionUserId,
                      mentionDisplayNames[mentionUserId],
                    )
                  : element.textContent,
              style: style.copyWith(
                color: accentColor,
                fontWeight: isMention ? FontWeight.w800 : FontWeight.w600,
                decoration: isMention
                    ? TextDecoration.none
                    : TextDecoration.underline,
                backgroundColor: isMention
                    ? accentColor.withValues(alpha: 0.12)
                    : null,
              ),
              recognizer: recognizer,
            ),
          );
          continue;
        }
      }
      spans.addAll(_inlineSpans(element.children, style));
    }
    return spans;
  }
}

class _InlineBlock {
  final InlineSpan span;

  const _InlineBlock(this.span);
}

class _InlineRichTextMetadata extends StatelessWidget {
  final InlineSpan text;
  final Widget metadata;
  final double minWidth;

  const _InlineRichTextMetadata({
    required this.text,
    required this.metadata,
    this.minWidth = 0,
  });

  @override
  Widget build(BuildContext context) {
    return _InlineRichTextMetadataRenderWidget(
      text: RichText(
        text: text,
        softWrap: true,
        textDirection: Directionality.of(context),
        textScaler: MediaQuery.textScalerOf(context),
      ),
      metadata: metadata,
      minWidth: minWidth,
    );
  }
}

class _InlineRichTextMetadataRenderWidget extends MultiChildRenderObjectWidget {
  final double minWidth;

  _InlineRichTextMetadataRenderWidget({
    required Widget text,
    required Widget metadata,
    required this.minWidth,
  }) : super(children: [text, metadata]);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderInlineRichTextMetadata(minWidth: minWidth);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderInlineRichTextMetadata renderObject,
  ) {
    renderObject.minWidth = minWidth;
  }
}

class _InlineRichTextMetadataParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderInlineRichTextMetadata extends RenderBox
    with
        ContainerRenderObjectMixin<
          RenderBox,
          _InlineRichTextMetadataParentData
        >,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _InlineRichTextMetadataParentData
        > {
  static const _horizontalGap = 8.0;
  static const _verticalGap = 3.0;

  _RenderInlineRichTextMetadata({required this._minWidth});

  double _minWidth;

  double get minWidth => _minWidth;

  set minWidth(double value) {
    if (_minWidth == value) return;
    _minWidth = value;
    markNeedsLayout();
  }

  RenderParagraph get _text => firstChild! as RenderParagraph;

  RenderBox get _metadata => childAfter(_text)!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _InlineRichTextMetadataParentData) {
      child.parentData = _InlineRichTextMetadataParentData();
    }
  }

  @override
  void performLayout() {
    final childConstraints = constraints.loosen();
    _metadata.layout(childConstraints, parentUsesSize: true);
    _text.layout(childConstraints, parentUsesSize: true);

    // The paragraph is a direct child laid out with parentUsesSize. Do not
    // inspect deeper render descendants here; scrollable blocks make that illegal.
    final textLength = _text.text.toPlainText().length;
    final trailingOffset = _text.getOffsetForCaret(
      TextPosition(offset: textLength),
      Rect.zero,
    );
    final trailingWidth =
        trailingOffset.dx + _horizontalGap + _metadata.size.width;
    final width = constraints.constrainWidth(
      math.max(minWidth, math.max(_text.size.width, trailingWidth)),
    );
    final inline = trailingWidth <= width + 0.001;
    final height = inline
        ? math.max(_text.size.height, _metadata.size.height)
        : _text.size.height + _verticalGap + _metadata.size.height;
    size = constraints.constrain(Size(width, height));

    final textParentData =
        _text.parentData! as _InlineRichTextMetadataParentData;
    textParentData.offset = Offset.zero;
    final metadataParentData =
        _metadata.parentData! as _InlineRichTextMetadataParentData;
    metadataParentData.offset = Offset(
      math.max(0, size.width - _metadata.size.width),
      inline
          ? math.max(0, size.height - _metadata.size.height)
          : _text.size.height + _verticalGap,
    );
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    defaultPaint(context, offset);
  }

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) {
    return defaultHitTestChildren(result, position: position);
  }
}
