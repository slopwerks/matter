import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/interaction_mode_provider.dart';
import '../message_text.dart';

class TimelineAdaptiveTextMetadata extends ConsumerWidget {
  final String text;
  final TextStyle textStyle;
  final Widget metadata;
  final double maxWidth;
  final double minWidth;
  final Color linkColor;
  final MessageUrlTapHandler? onUrlTap;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;

  const TimelineAdaptiveTextMetadata({
    super.key,
    required this.text,
    required this.textStyle,
    required this.metadata,
    required this.maxWidth,
    this.minWidth = 0,
    required this.linkColor,
    this.onUrlTap,
    this.mentionDisplayNames = const {},
    this.mentionedUserIds = const [],
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final content = _AdaptiveTextMetadataRenderWidget(
      minWidth: minWidth,
      text: MessageText(
        text,
        style: textStyle,
        mentionColor: linkColor,
        linkColor: linkColor,
        onUrlTap: onUrlTap,
        mentionDisplayNames: mentionDisplayNames,
        mentionedUserIds: mentionedUserIds,
        onMentionTap: onMentionTap,
      ),
      metadata: metadata,
    );
    final desktop = ref
        .watch(interactionModeProvider)
        .usesKeyboardMouse(Theme.of(context).platform);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: desktop ? SelectionArea(child: content) : content,
    );
  }
}

class _AdaptiveTextMetadataRenderWidget extends MultiChildRenderObjectWidget {
  final double minWidth;

  _AdaptiveTextMetadataRenderWidget({
    required Widget text,
    required Widget metadata,
    required this.minWidth,
  }) : super(children: [text, metadata]);

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderAdaptiveTextMetadata(minWidth: minWidth);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderAdaptiveTextMetadata renderObject,
  ) {
    renderObject.minWidth = minWidth;
  }
}

class _AdaptiveTextMetadataParentData
    extends ContainerBoxParentData<RenderBox> {}

class _RenderAdaptiveTextMetadata extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _AdaptiveTextMetadataParentData>,
        RenderBoxContainerDefaultsMixin<
          RenderBox,
          _AdaptiveTextMetadataParentData
        > {
  static const _horizontalGap = 8.0;
  static const _verticalGap = 3.0;

  _RenderAdaptiveTextMetadata({required this._minWidth});

  double _minWidth;

  set minWidth(double value) {
    if (_minWidth == value) return;
    _minWidth = value;
    markNeedsLayout();
  }

  RenderBox get _text => firstChild!;

  // Selectable Text.rich adds a MouseRegion around its paragraph. Layout
  // the outer box, but measure the caret on the paragraph inside it.
  RenderParagraph get _paragraph {
    RenderBox child = _text;
    while (child is RenderProxyBox) {
      child = child.child!;
    }
    return child as RenderParagraph;
  }

  RenderBox get _metadata => childAfter(_text)!;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _AdaptiveTextMetadataParentData) {
      child.parentData = _AdaptiveTextMetadataParentData();
    }
  }

  @override
  void performLayout() {
    final childConstraints = constraints.loosen();
    _metadata.layout(childConstraints, parentUsesSize: true);
    _text.layout(childConstraints, parentUsesSize: true);

    final textLength = _paragraph.text.toPlainText().length;
    final trailingOffset = _paragraph.getOffsetForCaret(
      TextPosition(offset: textLength),
      Rect.zero,
    );
    final trailingWidth =
        trailingOffset.dx + _horizontalGap + _metadata.size.width;
    final width = constraints.constrainWidth(
      math.max(_minWidth, math.max(_text.size.width, trailingWidth)),
    );
    final inline = trailingWidth <= width + 0.001;
    final height = inline
        ? math.max(_text.size.height, _metadata.size.height)
        : _text.size.height + _verticalGap + _metadata.size.height;
    size = constraints.constrain(Size(width, height));

    final textParentData = _text.parentData! as _AdaptiveTextMetadataParentData;
    textParentData.offset = Offset.zero;
    final metadataParentData =
        _metadata.parentData! as _AdaptiveTextMetadataParentData;
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
