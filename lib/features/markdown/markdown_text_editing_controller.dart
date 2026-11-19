import 'package:flutter/material.dart';

import 'markdown_protected_ranges.dart';

/// A [TextEditingController] that renders the simple inline markdown
/// formats offered by the selection toolbar directly inside the field: the
/// marked content is styled (bold, italic, strikethrough, spoiler
/// background) and the markers themselves are dimmed. The underlying text
/// is unchanged, so selection offsets, IME composition and the markdown
/// source sent on submit are all unaffected.
class MarkdownTextEditingController extends TextEditingController {
  MarkdownTextEditingController({super.text});

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final text = value.text;
    final dimColor = style?.color?.withValues(alpha: 0.35);
    final spans = <TextSpan>[];
    final parser = _InlineSpanParser(
      text,
      markerColor: dimColor,
      spoilerColor: style?.color?.withValues(alpha: 0.18),
    );
    parser.parseInto(spans, 0, text.length, const TextStyle());
    if (!parser.foundFormat) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }

    return TextSpan(
      style: style,
      children: _applyComposingUnderline(spans, withComposing),
    );
  }

  /// Splits [spans] at the IME composing region and underlines it, mirroring
  /// the default [TextEditingController.buildTextSpan] behavior.
  List<TextSpan> _applyComposingUnderline(
    List<TextSpan> spans,
    bool withComposing,
  ) {
    final composing = value.composing;
    if (!withComposing ||
        !composing.isValid ||
        composing.start < 0 ||
        composing.end > value.text.length) {
      return spans;
    }

    final result = <TextSpan>[];
    var offset = 0;
    for (final span in spans) {
      final text = span.text!;
      final end = offset + text.length;
      if (end <= composing.start || offset >= composing.end) {
        result.add(span);
      } else {
        final localStart = (composing.start - offset).clamp(0, text.length);
        final localEnd = (composing.end - offset).clamp(0, text.length);
        if (localStart > 0) {
          result.add(
            TextSpan(text: text.substring(0, localStart), style: span.style),
          );
        }
        result.add(
          TextSpan(
            text: text.substring(localStart, localEnd),
            style: _withUnderline(span.style),
          ),
        );
        if (localEnd < text.length) {
          result.add(
            TextSpan(text: text.substring(localEnd), style: span.style),
          );
        }
      }
      offset = end;
    }
    return result;
  }

  static TextStyle _withUnderline(TextStyle? base) {
    final decoration = base?.decoration;
    if (decoration == null) {
      return base == null
          ? const TextStyle(decoration: TextDecoration.underline)
          : base.merge(const TextStyle(decoration: TextDecoration.underline));
    }
    return base!.copyWith(
      decoration: TextDecoration.combine([
        decoration,
        TextDecoration.underline,
      ]),
    );
  }
}

class _InlineSpanParser {
  final String text;
  final Color? markerColor;
  final Color? spoilerColor;
  late final Map<int, int> _protectedEnds = {
    for (final range in markdownProtectedRanges(text)) range.start: range.end,
  };
  late final Map<String, List<_DelimiterClose>> _closingDelimiters =
      _indexClosingDelimiters();
  bool foundFormat = false;

  _InlineSpanParser(
    this.text, {
    required this.markerColor,
    required this.spoilerColor,
  });

  void parseInto(
    List<TextSpan> spans,
    int start,
    int end,
    TextStyle currentStyle,
  ) {
    var plainStart = start;
    var index = start;
    while (index < end) {
      final protectedEnd = _protectedEnds[index];
      if (protectedEnd != null) {
        index = protectedEnd.clamp(index, end);
        continue;
      }
      if (text.codeUnitAt(index) == 0x5c && index + 1 < end) {
        index += 2;
        continue;
      }

      final format = _formatAt(index, end);
      if (format == null || !_canOpen(index, format, end)) {
        index++;
        continue;
      }
      final close = _findClose(index + format.marker.length, end, format);
      if (close == null ||
          (format.marker == '||' &&
              text
                  .substring(index + format.marker.length, close)
                  .trim()
                  .isEmpty)) {
        index++;
        continue;
      }

      _addText(spans, plainStart, index, currentStyle);
      _addMarker(spans, format.marker, currentStyle);
      parseInto(
        spans,
        index + format.marker.length,
        close,
        currentStyle.merge(format.style(spoilerColor)),
      );
      _addMarker(spans, format.marker, currentStyle);
      foundFormat = true;
      index = close + format.marker.length;
      plainStart = index;
    }
    _addText(spans, plainStart, end, currentStyle);
  }

  _InlineFormat? _formatAt(int index, int end) {
    for (final format in _formats) {
      if (index + format.marker.length <= end &&
          text.startsWith(format.marker, index)) {
        if (format.marker == '***' &&
            _findClose(index + format.marker.length, end, format) == null) {
          return _formats.last;
        }
        return format;
      }
    }
    return null;
  }

  bool _canOpen(int index, _InlineFormat format, int end) {
    final after = index + format.marker.length;
    if (after >= end) return false;
    return !format.requiresTightDelimiters ||
        markdownDelimiterCanOpen(text, index, after);
  }

  int? _findClose(int start, int end, _InlineFormat format) {
    final candidates = _closingDelimiters[format.marker]!;
    var low = 0;
    var high = candidates.length;
    while (low < high) {
      final middle = (low + high) >> 1;
      if (candidates[middle].offset <= start) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    if (low == candidates.length ||
        candidates[low].offset + format.marker.length > end) {
      return null;
    }

    var index = start;
    while (index + format.marker.length <= end) {
      if (!format.canCrossLine && text[index] == '\n') return null;
      final protectedEnd = _protectedEnds[index];
      if (protectedEnd != null) {
        index = protectedEnd.clamp(index, end);
        continue;
      }
      if (text.codeUnitAt(index) == 0x5c && index + 1 < end) {
        index += 2;
        continue;
      }
      if (format.marker.startsWith('*') && text[index] == '*') {
        var runLength = 1;
        while (index + runLength < end && text[index + runLength] == '*') {
          runLength++;
        }
        final close = switch (format.marker) {
          '***' when runLength == 3 => index,
          '**' when runLength == 2 => index,
          '**' when runLength == 3 => index + 1,
          '*' when runLength == 1 => index,
          '*' when runLength == 3 => index + 2,
          _ => null,
        };
        if (close != null &&
            close > start &&
            markdownDelimiterCanClose(text, index, index + runLength)) {
          return close;
        }
        index += runLength;
        continue;
      }
      if (text.startsWith(format.marker, index) &&
          index > start &&
          (!format.requiresTightDelimiters ||
              markdownDelimiterCanClose(
                text,
                index,
                index + format.marker.length,
              ))) {
        return index;
      }
      index++;
    }
    return null;
  }

  Map<String, List<_DelimiterClose>> _indexClosingDelimiters() {
    final result = {
      for (final format in _formats) format.marker: <_DelimiterClose>[],
    };
    var index = 0;
    while (index < text.length) {
      final protectedEnd = _protectedEnds[index];
      if (protectedEnd != null) {
        index = protectedEnd;
        continue;
      }
      if (text.codeUnitAt(index) == 0x5c && index + 1 < text.length) {
        index += 2;
        continue;
      }

      if (text[index] == '*') {
        var runLength = 1;
        while (index + runLength < text.length &&
            text[index + runLength] == '*') {
          runLength++;
        }
        if (markdownDelimiterCanClose(text, index, index + runLength)) {
          if (runLength == 1) {
            result['*']!.add(_DelimiterClose(index));
          } else if (runLength == 2) {
            result['**']!.add(_DelimiterClose(index));
          } else if (runLength == 3) {
            result['***']!.add(_DelimiterClose(index));
            result['**']!.add(_DelimiterClose(index));
            result['**']!.add(_DelimiterClose(index + 1));
            result['*']!.add(_DelimiterClose(index));
            result['*']!.add(_DelimiterClose(index + 2));
          }
        }
        index += runLength;
        continue;
      }

      if (text.startsWith('~~', index)) {
        var runLength = 2;
        while (index + runLength < text.length &&
            text[index + runLength] == '~') {
          runLength++;
        }
        if (markdownDelimiterCanClose(text, index, index + runLength)) {
          result['~~']!.add(_DelimiterClose(index));
        }
        index += runLength;
        continue;
      }

      if (text.startsWith('||', index)) {
        result['||']!.add(_DelimiterClose(index));
        index += 2;
        continue;
      }
      index++;
    }
    return result;
  }

  void _addText(List<TextSpan> spans, int start, int end, TextStyle style) {
    if (start >= end) return;
    spans.add(TextSpan(text: text.substring(start, end), style: style));
  }

  void _addMarker(List<TextSpan> spans, String marker, TextStyle currentStyle) {
    final style = markerColor == null
        ? currentStyle
        : currentStyle.merge(TextStyle(color: markerColor));
    spans.add(TextSpan(text: marker, style: style));
  }

  static final _formats = <_InlineFormat>[
    _InlineFormat(
      '***',
      (_) => const TextStyle(
        fontWeight: FontWeight.bold,
        fontStyle: FontStyle.italic,
      ),
    ),
    _InlineFormat('**', (_) => const TextStyle(fontWeight: FontWeight.bold)),
    _InlineFormat(
      '~~',
      (_) => const TextStyle(decoration: TextDecoration.lineThrough),
    ),
    _InlineFormat(
      '||',
      (color) => TextStyle(backgroundColor: color),
      requiresTightDelimiters: false,
      canCrossLine: false,
    ),
    _InlineFormat('*', (_) => const TextStyle(fontStyle: FontStyle.italic)),
  ];
}

class _InlineFormat {
  final String marker;
  final TextStyle Function(Color? spoilerColor) style;
  final bool requiresTightDelimiters;
  final bool canCrossLine;

  const _InlineFormat(
    this.marker,
    this.style, {
    this.requiresTightDelimiters = true,
    this.canCrossLine = true,
  });
}

class _DelimiterClose {
  final int offset;

  const _DelimiterClose(this.offset);
}
