import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_math_fork/flutter_math.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../widgets/app_avatar.dart';
import 'matrix_code_block.dart';
import 'matrix_html_node.dart';
import 'matrix_html_parser.dart';
import 'matrix_link_router.dart';

typedef MatrixHtmlImageResolver = Future<String?> Function(
  WidgetRef ref,
  String src,
);

class MatrixHtmlMessage extends StatefulWidget {
  final String html;
  final TextStyle style;
  final Color accentColor;
  final MatrixLinkHandler? onLinkTap;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;
  final Widget? trailingMetadata;
  final double minWidth;
  final MatrixHtmlImageResolver? imageResolver;

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
    this.imageResolver,
  });

  @override
  State<MatrixHtmlMessage> createState() => _MatrixHtmlMessageState();
}

class _MatrixHtmlMessageState extends State<MatrixHtmlMessage> {
  static const _parser = MatrixHtmlParser();
  late List<MatrixHtmlNode> _nodes;
  final Set<MatrixElementNode> _revealedSpoilers = {};
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
      _revealedSpoilers.clear();
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
      imageResolver: widget.imageResolver,
      revealedSpoilers: _revealedSpoilers,
      revealSpoiler: (spoiler) {
        if (_revealedSpoilers.add(spoiler)) setState(() {});
      },
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
  static const _maxRichTableRows = 200;
  static const _maxRichTableColumns = 32;
  static const _maxRichTableGridCells = 1024;

  final BuildContext context;
  final TextStyle baseStyle;
  final Color accentColor;
  final MatrixLinkHandler onLinkTap;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;
  final List<TapGestureRecognizer> gestureRecognizers;
  final MatrixHtmlImageResolver? imageResolver;
  final Set<MatrixElementNode> revealedSpoilers;
  final ValueChanged<MatrixElementNode> revealSpoiler;

  /// Alignment inherited from a container (e.g. a table cell's `align`),
  /// applied to rich text that doesn't carry its own `align`.
  final TextAlign? textAlign;

  const _MatrixNodeRenderer({
    required this.context,
    required this.baseStyle,
    required this.accentColor,
    required this.onLinkTap,
    required this.mentionDisplayNames,
    required this.onMentionTap,
    required this.gestureRecognizers,
    required this.imageResolver,
    required this.revealedSpoilers,
    required this.revealSpoiler,
    this.textAlign,
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
      'img',
      'figure',
      'div',
      'table',
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
        final loneImage = _loneImageChild(element);
        if (loneImage != null) return _renderBlock(loneImage);
        final paragraphAlign = _textAlignOf(element);
        if (paragraphAlign != null) {
          return _alignedText(element.children, baseStyle, paragraphAlign);
        }
        return _richText(element.children, baseStyle);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        final level = int.parse(element.tag.substring(1));
        final headerStyle = baseStyle.copyWith(
          fontSize: (22 - level * 1.5).clamp(15, 21).toDouble(),
          fontWeight: FontWeight.w800,
          height: 1.25,
        );
        final headerAlign = _textAlignOf(element);
        if (headerAlign != null) {
          return _alignedText(element.children, headerStyle, headerAlign);
        }
        return _richText(element.children, headerStyle);
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
        return LayoutBuilder(
          builder: (context, constraints) {
            final width = constraints.maxWidth.isFinite
                ? constraints.maxWidth
                : 520.0;
            return MatrixCodeBlock(
              code: element.textContent,
              language: extractCodeLanguage(element),
              width: width,
              baseStyle: baseStyle,
              accentColor: accentColor,
            );
          },
        );
      case 'hr':
        // The app-wide DividerTheme carries indent: 72 for settings-style
        // list separators; a markdown rule must not inherit it.
        return Divider(
          color: baseStyle.color?.withValues(alpha: 0.3),
          thickness: 1,
          indent: 0,
          endIndent: 0,
        );
      case 'img':
        return _imageBlock(
          element.attributes['src'],
          alt: element.attributes['alt'],
          caption: element.attributes['title'] == null
              ? null
              : Text(element.attributes['title']!, style: _captionStyle()),
        );
      case 'figure':
        return _figureBlock(element);
      case 'div':
        final maths = element.attributes['data-mx-maths'];
        if (maths != null) {
          return _mathBlock(maths.isNotEmpty ? maths : element.textContent);
        }
        final divAlign = _textAlignOf(element);
        if (divAlign != null) {
          return _alignedText(element.children, baseStyle, divAlign);
        }
        return _richText(element.children, baseStyle);
      case 'table':
        return _renderTable(element);
      default:
        return _richText([element], baseStyle);
    }
  }

  Widget? _renderTable(MatrixElementNode table) {
    final rows = <(bool, List<MatrixElementNode>)>[];
    final captions = <MatrixElementNode>[];
    void collectRows(MatrixHtmlNode node, bool inHeader) {
      if (node is! MatrixElementNode) return;
      if (node.tag == 'caption') {
        captions.add(node);
        return;
      }
      if (node.tag == 'tr') {
        final cells = node.children
            .whereType<MatrixElementNode>()
            .where((cell) => cell.tag == 'th' || cell.tag == 'td')
            .toList();
        if (cells.isNotEmpty) {
          rows.add((inHeader, cells));
        }
        return;
      }
      final header = inHeader || node.tag == 'thead';
      for (final child in node.children) {
        collectRows(child, header);
      }
    }

    for (final child in table.children) {
      collectRows(child, false);
    }
    if (rows.isEmpty && captions.isEmpty) return null;

    // Remote HTML is not guaranteed to be regular (ragged rows, colspan):
    // pad rows to a uniform column count so Table never sees irregular
    // row lengths.
    final columnCount = rows.fold<int>(
      1,
      (max, row) => math.max(max, row.$2.length),
    );

    final borderColor = (baseStyle.color ?? Colors.white).withValues(
      alpha: 0.25,
    );
    final exceedsRichTableBudget =
        rows.length > _maxRichTableRows ||
        columnCount > _maxRichTableColumns ||
        rows.length * columnCount > _maxRichTableGridCells;
    final grid = rows.isEmpty
        ? null
        : exceedsRichTableBudget
        ? Container(
            constraints: const BoxConstraints(maxWidth: 520),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                rows
                    .map(
                      (row) => row.$2
                          .map((cell) => cell.textContent.trim())
                          .join(' | '),
                    )
                    .join(' / '),
                style: baseStyle,
                maxLines: 1,
              ),
            ),
          )
        : Container(
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(
              border: Border.all(color: borderColor),
              borderRadius: BorderRadius.circular(8),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(7),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Table(
                  defaultColumnWidth: const IntrinsicColumnWidth(),
                  border: TableBorder.symmetric(
                    inside: BorderSide(color: borderColor),
                  ),
                  children: [
                    for (final (isHeader, cells) in rows)
                      TableRow(
                        decoration: isHeader
                            ? BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.14),
                              )
                            : null,
                        children: [
                          for (final cell in cells)
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              child: _renderTableCell(
                                cell,
                                isHeader || cell.tag == 'th',
                              ),
                            ),
                          for (var i = cells.length; i < columnCount; i++)
                            const SizedBox.shrink(),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          );
    if (grid == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final caption in captions)
            _richText(
              caption.children,
              baseStyle.copyWith(fontWeight: FontWeight.w700),
            ),
        ],
      );
    }
    // The bordered container must hug the table's intrinsic width; inside a
    // stretched bubble column it would otherwise span the full maxWidth and
    // detach the frame from the content.
    final fittedGrid = Align(
      alignment: Alignment.centerLeft,
      widthFactor: 1,
      child: grid,
    );
    if (captions.isEmpty) return fittedGrid;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final caption in captions)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: _richText(
              caption.children,
              baseStyle.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
        fittedGrid,
      ],
    );
  }

  Widget _renderTableCell(MatrixElementNode cell, bool isHeader) {
    final renderer = _MatrixNodeRenderer(
      context: context,
      baseStyle: isHeader
          ? baseStyle.copyWith(fontWeight: FontWeight.w800)
          : baseStyle,
      accentColor: accentColor,
      onLinkTap: onLinkTap,
      mentionDisplayNames: mentionDisplayNames,
      onMentionTap: onMentionTap,
      gestureRecognizers: gestureRecognizers,
      imageResolver: imageResolver,
      revealedSpoilers: revealedSpoilers,
      revealSpoiler: revealSpoiler,
      textAlign: _textAlignOf(cell),
    );
    final blocks = renderer.renderBlocks(cell.children);
    if (blocks.isEmpty) return const SizedBox.shrink();
    if (blocks.length == 1) return blocks.single;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: blocks,
    );
  }

  /// The single meaningful child of [element] when it is just an image
  /// (markdown `![alt](src)` produces `<p><img></p>`). Such paragraphs
  /// render as block images instead of inline text.
  MatrixElementNode? _loneImageChild(MatrixElementNode element) {
    final meaningful = element.children
        .where((node) => node is! MatrixTextNode || node.text.trim().isNotEmpty)
        .toList();
    if (meaningful.length != 1) return null;
    final only = meaningful.single;
    if (only is MatrixElementNode && only.tag == 'img') return only;
    return null;
  }

  TextStyle _captionStyle() => baseStyle.copyWith(
    fontSize: (baseStyle.fontSize ?? 15) - 1.5,
    color: baseStyle.color?.withValues(alpha: 0.75),
  );

  Widget _imageBlock(String? src, {String? alt, Widget? caption}) {
    if (src == null) {
      if (alt == null || alt.isEmpty) return const SizedBox.shrink();
      return Text(alt, style: baseStyle);
    }
    final image = LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 320.0;
        return ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: _MatrixHtmlImage(
            src: src,
            alt: alt,
            width: width,
            cacheWidth: (width * MediaQuery.devicePixelRatioOf(context))
                .round(),
            fallbackStyle: baseStyle,
            resolver: imageResolver,
          ),
        );
      },
    );
    if (caption == null) return image;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [image, const SizedBox(height: 4), caption],
    );
  }

  Widget _figureBlock(MatrixElementNode figure) {
    MatrixElementNode? img;
    MatrixElementNode? captionNode;
    for (final child in figure.children) {
      if (child is! MatrixElementNode) continue;
      if (child.tag == 'img') img ??= child;
      if (child.tag == 'figcaption') captionNode ??= child;
    }
    final title = img?.attributes['title'];
    final caption = captionNode != null
        ? _richText(captionNode.children, _captionStyle())
        : (title != null && title.isNotEmpty
              ? Text(title, style: _captionStyle())
              : null);
    return _imageBlock(
      img?.attributes['src'],
      alt: img?.attributes['alt'],
      caption: caption,
    );
  }

  Widget _mathBlock(String tex) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : 520.0;
        return SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: ConstrainedBox(
            constraints: BoxConstraints(minWidth: width),
            child: Center(
              child: Math.tex(
                tex,
                mathStyle: MathStyle.display,
                textStyle: _mathTextStyle(),
                onErrorFallback: (_) => Text('\$\$$tex\$\$', style: baseStyle),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _inlineMath(String tex, TextStyle style) {
    return Math.tex(
      tex,
      mathStyle: MathStyle.text,
      textStyle: _mathTextStyle(),
      onErrorFallback: (_) => Text('\$$tex\$', style: style),
    );
  }

  // flutter_math_fork dereferences fontSize/color unconditionally, so make
  // sure both are concrete before handing the style over.
  TextStyle _mathTextStyle() {
    var style = baseStyle;
    if (style.inherit) {
      style = DefaultTextStyle.of(context).style.merge(style);
    }
    return style.copyWith(
      fontSize: style.fontSize ?? 15,
      color: style.color ?? Colors.black87,
    );
  }

  /// Detects a task-list checkbox leading the item (direct child, or inside
  /// the first paragraph) and returns the checked state plus the item's
  /// content with the checkbox removed. Null for plain list items.
  (bool, List<MatrixHtmlNode>)? _taskCheckboxItem(MatrixElementNode item) {
    (bool, List<MatrixHtmlNode>)? textMarker(List<MatrixHtmlNode> source) {
      if (source.isEmpty || source.first is! MatrixTextNode) return null;
      final first = source.first as MatrixTextNode;
      final match = RegExp(r'^\[([ xX])\](?=\s|$)').firstMatch(first.text);
      if (match == null) return null;
      final remaining = first.text.substring(match.end);
      return (
        match.group(1)!.toLowerCase() == 'x',
        <MatrixHtmlNode>[
          if (remaining.isNotEmpty) MatrixTextNode(remaining),
          ...source.skip(1),
        ],
      );
    }

    bool? checked;
    final children = List<MatrixHtmlNode>.of(item.children);
    if (children.isEmpty) return null;
    final first = children.first;
    if (first is MatrixElementNode && first.tag == 'input') {
      checked = first.attributes.containsKey('checked');
      children.removeAt(0);
    } else if (first is MatrixElementNode &&
        first.tag == 'p' &&
        first.children.isNotEmpty) {
      final nested = first.children.first;
      if (nested is MatrixElementNode && nested.tag == 'input') {
        checked = nested.attributes.containsKey('checked');
        children[0] = MatrixElementNode(
          tag: 'p',
          children: first.children.sublist(1),
          attributes: first.attributes,
        );
      } else {
        final task = textMarker(first.children);
        if (task != null) {
          children[0] = MatrixElementNode(
            tag: 'p',
            children: task.$2,
            attributes: first.attributes,
          );
          return (task.$1, children);
        }
      }
    } else if (first is MatrixTextNode) {
      return textMarker(children);
    }
    if (checked == null) return null;
    return (checked, children);
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
          Builder(
            builder: (context) {
              final task = _taskCheckboxItem(entry.$2);
              final content = task?.$2 ?? entry.$2.children;
              return Padding(
                padding: EdgeInsets.only(
                  top: 2,
                  bottom:
                      trailingMetadata != null && entry.$1 == items.length - 1
                      ? 0
                      : 2,
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 24,
                      child: task == null
                          ? Text(
                              ordered ? '${start + entry.$1}.' : '•',
                              textAlign: TextAlign.right,
                              style: baseStyle.copyWith(
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : Align(
                              alignment: Alignment.topRight,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 1),
                                child: Icon(
                                  task.$1
                                      ? Icons.check_box_rounded
                                      : Icons.check_box_outline_blank_rounded,
                                  size: 16,
                                  color: task.$1
                                      ? accentColor
                                      : baseStyle.color?.withValues(alpha: 0.6),
                                ),
                              ),
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
                            trailingMetadata != null &&
                                entry.$1 == items.length - 1
                            ? renderBlocksWithTrailing(
                                content,
                                trailingMetadata,
                              )
                            : renderBlocks(content),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _richText(List<MatrixHtmlNode> nodes, TextStyle style) {
    return Text.rich(
      _inlineBlock(nodes, style).span,
      softWrap: true,
      textAlign: textAlign,
    );
  }

  /// The element's whitelisted `align` attribute as a [TextAlign].
  TextAlign? _textAlignOf(MatrixElementNode element) {
    return switch (element.attributes['align']) {
      'left' => TextAlign.left,
      'center' => TextAlign.center,
      'right' => TextAlign.right,
      'justify' => TextAlign.justify,
      _ => null,
    };
  }

  /// Aligned text needs the paragraph to span the full width, otherwise a
  /// shrink-wrapped one-liner has no visible alignment. Inside unbounded
  /// contexts (intrinsic table cells) the width expansion is skipped.
  Widget _alignedText(
    List<MatrixHtmlNode> nodes,
    TextStyle style,
    TextAlign align,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final text = Text.rich(
          _inlineBlock(nodes, style).span,
          softWrap: true,
          textAlign: align,
        );
        if (!constraints.maxWidth.isFinite) return text;
        return SizedBox(width: constraints.maxWidth, child: text);
      },
    );
  }

  _InlineBlock? _inlineBlockForNode(MatrixHtmlNode node) {
    if (node is MatrixTextNode) {
      if (node.text.trim().isEmpty) return null;
      return _inlineBlock([node], baseStyle);
    }

    final element = node as MatrixElementNode;
    switch (element.tag) {
      case 'p':
        if (_loneImageChild(element) != null) return null;
        // Aligned paragraphs need the block path: alignment only shows when
        // the paragraph spans the full width.
        if (_textAlignOf(element) != null) return null;
        return _inlineBlock(element.children, baseStyle);
      case 'h1':
      case 'h2':
      case 'h3':
      case 'h4':
      case 'h5':
      case 'h6':
        if (_textAlignOf(element) != null) return null;
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
      case 'figure':
      case 'div':
      case 'table':
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

  // Some senders emit HTML source with blank-line runs between stripped
  // structures; rendering them literally produces huge vertical gaps.
  static final _blankLineRun = RegExp(r'[ \t]*\n[ \t\n]*');

  List<InlineSpan> _inlineSpans(
    List<MatrixHtmlNode> nodes,
    TextStyle inherited,
  ) {
    final spans = <InlineSpan>[];
    for (final node in nodes) {
      if (node is MatrixTextNode) {
        spans.add(
          TextSpan(
            text: node.text.replaceAll(_blankLineRun, '\n'),
            style: inherited,
          ),
        );
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
      } else if (element.tag == 'span' &&
          element.attributes.containsKey('data-mx-spoiler')) {
        final reason = element.attributes['data-mx-spoiler']!.trim();
        if (reason.isNotEmpty) {
          final reasonColor = style.color;
          spans.add(
            TextSpan(
              text: '$reason ',
              style: style.copyWith(
                color: reasonColor?.withValues(alpha: 0.72),
                fontStyle: FontStyle.italic,
              ),
            ),
          );
        }
        if (revealedSpoilers.contains(element)) {
          spans.addAll(_inlineSpans(element.children, style));
        } else {
          final concealedColor =
              style.color ?? Theme.of(context).colorScheme.onSurface;
          final recognizer = TapGestureRecognizer()
            ..onTap = () => revealSpoiler(element);
          gestureRecognizers.add(recognizer);
          spans.add(
            TextSpan(
              text: element.textContent,
              semanticsLabel: reason.isEmpty ? 'Spoiler' : 'Spoiler: $reason',
              style: style.copyWith(
                color: concealedColor.withValues(alpha: 0),
                backgroundColor: concealedColor.withValues(alpha: 0.28),
                decoration: TextDecoration.none,
                shadows: const [],
              ),
              recognizer: recognizer,
            ),
          );
        }
        continue;
      } else if (element.tag == 'span' &&
          element.attributes.containsKey('data-mx-maths')) {
        final tex = element.attributes['data-mx-maths']!;
        spans.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: _inlineMath(
              tex.isNotEmpty ? tex : element.textContent,
              style,
            ),
          ),
        );
        continue;
      } else if (element.tag == 'img') {
        final src = element.attributes['src'];
        if (src != null) {
          spans.add(
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: _MatrixHtmlImage(
                src: src,
                alt: element.attributes['alt'],
                fallbackStyle: style,
                resolver: imageResolver,
              ),
            ),
          );
        }
        continue;
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

/// An image referenced by message HTML. `mxc://` sources are resolved to
/// authenticated media URLs first; plain http(s) sources load directly.
///
/// With [width] set the image renders as a block at that width (height from
/// the image's aspect ratio). Without it the image is an inline span child
/// capped to a small box.
class _MatrixHtmlImage extends ConsumerStatefulWidget {
  final String src;
  final String? alt;
  final double? width;
  final int? cacheWidth;
  final TextStyle fallbackStyle;
  final MatrixHtmlImageResolver? resolver;

  const _MatrixHtmlImage({
    required this.src,
    this.alt,
    this.width,
    this.cacheWidth,
    required this.fallbackStyle,
    this.resolver,
  });

  @override
  ConsumerState<_MatrixHtmlImage> createState() => _MatrixHtmlImageState();
}

class _MatrixHtmlImageState extends ConsumerState<_MatrixHtmlImage> {
  String? _resolvedUrl;
  bool _failed = false;
  int _resolveGeneration = 0;

  bool get _isMxc => widget.src.startsWith('mxc://');

  @override
  void initState() {
    super.initState();
    if (!_isMxc) _resolvedUrl = widget.src;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_isMxc && _resolvedUrl == null && !_failed) {
      final cached = cachedResolvedMxcUrl(ref, widget.src);
      if (cached != null) {
        _resolvedUrl = cached;
      } else {
        _resolve();
      }
    }
  }

  @override
  void didUpdateWidget(covariant _MatrixHtmlImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.src != widget.src || oldWidget.resolver != widget.resolver) {
      _resolveGeneration++;
      setState(() {
        _failed = false;
        _resolvedUrl = _isMxc ? null : widget.src;
      });
      if (_isMxc) _resolve();
    }
  }

  Future<void> _resolve() async {
    final generation = ++_resolveGeneration;
    final src = widget.src;
    final url = await (widget.resolver ?? resolveMxcUrl)(ref, src);
    if (!mounted || generation != _resolveGeneration) return;
    setState(() {
      if (url == null) {
        _failed = true;
      } else {
        _resolvedUrl = url;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final url = _resolvedUrl;
    if (url == null || _failed) {
      final alt = widget.alt;
      if (_failed && alt != null && alt.isNotEmpty) {
        return Text(alt, style: widget.fallbackStyle);
      }
      return _MatrixHtmlImagePlaceholder(width: widget.width, failed: _failed);
    }
    final image = AuthenticatedImageMessage(
      imageUrl: url,
      fit: widget.width == null ? BoxFit.contain : BoxFit.fitWidth,
      cacheWidth: widget.cacheWidth,
      onError: () {
        if (mounted && _resolvedUrl == url) {
          setState(() => _failed = true);
        }
      },
    );
    final width = widget.width;
    if (width != null) {
      return SizedBox(width: width, child: image);
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 240, maxHeight: 160),
      child: image,
    );
  }
}

class _MatrixHtmlImagePlaceholder extends StatelessWidget {
  final double? width;
  final bool failed;

  const _MatrixHtmlImagePlaceholder({this.width, required this.failed});

  @override
  Widget build(BuildContext context) {
    final icon = Icon(
      failed ? Icons.broken_image_outlined : Icons.image_outlined,
      size: 22,
      color: Colors.white.withValues(alpha: 0.5),
    );
    final width = this.width;
    if (width == null) {
      return Padding(padding: const EdgeInsets.all(4), child: icon);
    }
    return Container(
      width: width,
      height: 120,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: icon,
    );
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
