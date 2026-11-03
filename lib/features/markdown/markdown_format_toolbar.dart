import 'package:flutter/material.dart';

import 'markdown_protected_ranges.dart';

/// A markdown inline format offered on the text-selection toolbar.
class MarkdownFormat {
  final String label;

  /// Shown instead of [label] when the selection already carries this
  /// format, i.e. pressing the button removes the markers.
  final String activeLabel;
  final String marker;

  const MarkdownFormat(this.label, this.activeLabel, this.marker);
}

/// The formats shown on the selection toolbar, in display order. All
/// markers are supported by [MarkdownComposer]'s inline syntaxes.
const markdownToolbarFormats = [
  MarkdownFormat('加粗', '取消加粗', '**'),
  MarkdownFormat('斜体', '取消斜体', '*'),
  MarkdownFormat('删除线', '取消删除线', '~~'),
  MarkdownFormat('剧透', '取消剧透', '||'),
];

/// Whether the markers sit immediately outside [`start`, `end`) in [text].
/// A match that is part of a longer run of the same character (e.g. `*`
/// inside `**`) does not count as the marker.
bool _hasOuterMarkers(String text, int start, int end, String marker) =>
    start >= marker.length &&
    end + marker.length <= text.length &&
    text.substring(start - marker.length, start) == marker &&
    text.substring(end, end + marker.length) == marker &&
    !_isEscaped(text, start - marker.length) &&
    !_isEscaped(text, end) &&
    (start - marker.length == 0 ||
        text[start - marker.length - 1] != marker[0]) &&
    (end + marker.length == text.length ||
        text[end + marker.length] != marker[0]);

/// Whether [inner] itself starts and ends with [marker]. As in
/// [_hasOuterMarkers], a marker that is part of a longer run of the same
/// character does not count.
bool _innerHasMarkers(String inner, String marker) =>
    inner.length >= marker.length * 2 &&
    inner.startsWith(marker) &&
    inner.endsWith(marker) &&
    (inner.length == marker.length * 2 ||
        (inner[marker.length] != marker[0] &&
            inner[inner.length - marker.length - 1] != marker[0]));

({int open, int close})? _enclosingMarkers(
  String text,
  int start,
  int end,
  String marker,
) {
  ({int open, int close})? result;
  var open = text.indexOf(marker);
  while (open >= 0 && open + marker.length <= start) {
    final contentStart = open + marker.length;
    if (_isStandaloneMarker(text, open, marker) &&
        contentStart < text.length &&
        text[contentStart].trim().isNotEmpty) {
      var close = text.indexOf(marker, contentStart);
      while (close >= 0) {
        if (_isStandaloneMarker(text, close, marker) &&
            close > contentStart &&
            text[close - 1].trim().isNotEmpty) {
          if (close >= end) {
            if (result == null ||
                open > result.open ||
                (open == result.open && close < result.close)) {
              result = (open: open, close: close);
            }
          }
          break;
        }
        close = text.indexOf(marker, close + marker.length);
      }
    }
    open = text.indexOf(marker, open + 1);
  }
  return result;
}

bool _isStandaloneMarker(String text, int offset, String marker) =>
    (offset == 0 || text[offset - 1] != marker[0]) &&
    (offset + marker.length == text.length ||
        text[offset + marker.length] != marker[0]) &&
    !_isEscaped(text, offset);

bool _isEscaped(String text, int offset) {
  var backslashes = 0;
  for (var index = offset - 1; index >= 0 && text[index] == r'\'; index--) {
    backslashes++;
  }
  return backslashes.isOdd;
}

String _wrapNonWhitespace(String text, String marker) {
  var start = 0;
  var end = text.length;
  while (start < end && text[start].trim().isEmpty) {
    start++;
  }
  while (end > start && text[end - 1].trim().isEmpty) {
    end--;
  }
  if (start == end) return text;
  return '${text.substring(0, start)}$marker${text.substring(start, end)}'
      '$marker${text.substring(end)}';
}

bool _wrappedSegmentIsValid(
  String fullText,
  int segmentStart,
  String segment,
  String marker,
) {
  final localOpen = segment.indexOf(marker);
  if (localOpen < 0) return true;
  final localClose = segment.lastIndexOf(marker);
  if (marker == '||') return localClose > localOpen;
  final open = segmentStart + localOpen;
  final close = segmentStart + localClose;
  return localClose > localOpen &&
      markdownDelimiterCanOpen(fullText, open, open + marker.length) &&
      markdownDelimiterCanClose(fullText, close, close + marker.length);
}

/// Whether pressing the toolbar button for [marker] would remove the format
/// from [value]'s selection rather than apply it. Mirrors the two toggle-off
/// paths of [toggleMarkdownWrap].
bool markdownWrapActive(TextEditingValue value, String marker) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid || selection.isCollapsed) return false;

  if (_hasOuterMarkers(text, selection.start, selection.end, marker)) {
    return true;
  }

  var innerStart = selection.start;
  var innerEnd = selection.end;
  while (innerStart < innerEnd && text[innerStart].trim().isEmpty) {
    innerStart++;
  }
  while (innerEnd > innerStart && text[innerEnd - 1].trim().isEmpty) {
    innerEnd--;
  }
  if (innerStart == innerEnd) return false;
  if ((marker == '*' || marker == '**') &&
      ((_innerHasMarkers(text.substring(innerStart, innerEnd), '***') &&
              !_isEscaped(text, innerStart) &&
              !_isEscaped(text, innerEnd - 3)) ||
          _enclosingMarkers(text, innerStart, innerEnd, '***') != null)) {
    return true;
  }
  return (_innerHasMarkers(text.substring(innerStart, innerEnd), marker) &&
          !_isEscaped(text, innerStart) &&
          !_isEscaped(text, innerEnd - marker.length)) ||
      _enclosingMarkers(text, innerStart, innerEnd, marker) != null;
}

/// Toggles [marker] around the selected text of [value].
///
/// - Collapsed selection: inserts `marker + marker` and places the cursor
///   between them.
/// - Surrounded selection (markers immediately outside the selection) or
///   a selection that itself starts and ends with the marker: removes the
///   markers instead of wrapping again.
/// - Leading/trailing whitespace inside the selection stays outside the
///   markers.
TextEditingValue toggleMarkdownWrap(TextEditingValue value, String marker) {
  final text = value.text;
  final selection = value.selection;
  if (!selection.isValid) return value;

  final start = selection.start;
  final end = selection.end;

  if (selection.isCollapsed) {
    final inserted =
        text.substring(0, start) + marker + marker + text.substring(end);
    final offset = start + marker.length;
    return value.copyWith(
      text: inserted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  // Toggle off: the markers sit immediately outside the selection, so
  // italic on bold text wraps instead of stripping the bold down to italic.
  if (_hasOuterMarkers(text, start, end, marker)) {
    final unwrapped =
        text.substring(0, start - marker.length) +
        text.substring(start, end) +
        text.substring(end + marker.length);
    return value.copyWith(
      text: unwrapped,
      selection: TextSelection(
        baseOffset: start - marker.length,
        extentOffset: end - marker.length,
      ),
    );
  }

  var innerStart = start;
  var innerEnd = end;
  while (innerStart < innerEnd && text[innerStart].trim().isEmpty) {
    innerStart++;
  }
  while (innerEnd > innerStart && text[innerEnd - 1].trim().isEmpty) {
    innerEnd--;
  }
  if (innerStart == innerEnd) return value;
  if (marker == '||' && text.substring(innerStart, innerEnd).contains('\n')) {
    return value;
  }

  // Toggle off: the selection itself includes the markers, so italic on a
  // fully selected bold span adds italic instead of degrading the bold.
  final inner = text.substring(innerStart, innerEnd);
  if (marker == '*' || marker == '**') {
    final retainedMarker = marker == '*' ? '**' : '*';
    if (_innerHasMarkers(inner, '***') &&
        !_isEscaped(text, innerStart) &&
        !_isEscaped(text, innerEnd - 3)) {
      final stripped = inner.substring(3, inner.length - 3);
      final replaced =
          text.substring(0, innerStart) +
          retainedMarker +
          stripped +
          retainedMarker +
          text.substring(innerEnd);
      return value.copyWith(
        text: replaced,
        selection: TextSelection(
          baseOffset: innerStart + retainedMarker.length,
          extentOffset: innerStart + retainedMarker.length + stripped.length,
        ),
      );
    }

    final combined = _enclosingMarkers(text, innerStart, innerEnd, '***');
    if (combined != null) {
      final before = text.substring(combined.open + 3, innerStart);
      final selected = text.substring(innerStart, innerEnd);
      final after = text.substring(innerEnd, combined.close);
      final wrappedBefore = _wrapNonWhitespace(before, '***');
      final wrappedSelected = '$retainedMarker$selected$retainedMarker';
      final replacement =
          wrappedBefore + wrappedSelected + _wrapNonWhitespace(after, '***');
      final replaced =
          text.substring(0, combined.open) +
          replacement +
          text.substring(combined.close + 3);
      final selectedStart = combined.open + wrappedBefore.length;
      final afterStart = selectedStart + wrappedSelected.length;
      if (!_wrappedSegmentIsValid(
            replaced,
            combined.open,
            wrappedBefore,
            '***',
          ) ||
          !_wrappedSegmentIsValid(
            replaced,
            selectedStart,
            wrappedSelected,
            retainedMarker,
          ) ||
          !_wrappedSegmentIsValid(
            replaced,
            afterStart,
            replacement.substring(afterStart - combined.open),
            '***',
          )) {
        return value;
      }
      final selectionStart =
          combined.open + wrappedBefore.length + retainedMarker.length;
      return value.copyWith(
        text: replaced,
        selection: TextSelection(
          baseOffset: selectionStart,
          extentOffset: selectionStart + selected.length,
        ),
      );
    }
  }

  if (_innerHasMarkers(inner, marker) &&
      !_isEscaped(text, innerStart) &&
      !_isEscaped(text, innerEnd - marker.length)) {
    final stripped = inner.substring(
      marker.length,
      inner.length - marker.length,
    );
    final replaced =
        text.substring(0, innerStart) + stripped + text.substring(innerEnd);
    return value.copyWith(
      text: replaced,
      selection: TextSelection(
        baseOffset: innerStart,
        extentOffset: innerStart + stripped.length,
      ),
    );
  }

  // A selection may cover only part of an existing formatted span. Remove
  // the outer pair and re-wrap the unselected pieces separately; simply
  // wrapping the selection would create crossing delimiter runs.
  final enclosing = _enclosingMarkers(text, innerStart, innerEnd, marker);
  if (enclosing != null) {
    final before = text.substring(enclosing.open + marker.length, innerStart);
    final selected = text.substring(innerStart, innerEnd);
    final after = text.substring(innerEnd, enclosing.close);
    final wrappedBefore = _wrapNonWhitespace(before, marker);
    final wrappedAfter = _wrapNonWhitespace(after, marker);
    final replacement = wrappedBefore + selected + wrappedAfter;
    final replaced =
        text.substring(0, enclosing.open) +
        replacement +
        text.substring(enclosing.close + marker.length);
    final afterStart = enclosing.open + wrappedBefore.length + selected.length;
    if (!_wrappedSegmentIsValid(
          replaced,
          enclosing.open,
          wrappedBefore,
          marker,
        ) ||
        !_wrappedSegmentIsValid(replaced, afterStart, wrappedAfter, marker)) {
      return value;
    }
    final selectionStart = enclosing.open + wrappedBefore.length;
    return value.copyWith(
      text: replaced,
      selection: TextSelection(
        baseOffset: selectionStart,
        extentOffset: selectionStart + selected.length,
      ),
    );
  }

  final wrapped =
      text.substring(0, innerStart) +
      marker +
      inner +
      marker +
      text.substring(innerEnd);
  if (marker != '||') {
    final openingEnd = innerStart + marker.length;
    final closingStart = innerEnd + marker.length;
    if (!markdownDelimiterCanOpen(wrapped, innerStart, openingEnd) ||
        !markdownDelimiterCanClose(
          wrapped,
          closingStart,
          closingStart + marker.length,
        )) {
      return value;
    }
  }
  return value.copyWith(
    text: wrapped,
    selection: TextSelection(
      baseOffset: innerStart + marker.length,
      extentOffset: innerEnd + marker.length,
    ),
  );
}

/// A [TextField.contextMenuBuilder] that appends markdown format buttons
/// ([markdownToolbarFormats]) to the platform's default selection menu
/// whenever text is selected. Read-only fields keep the default menu so the
/// text cannot be mutated while sending or loading.
Widget markdownSelectionContextMenuBuilder(
  BuildContext context,
  EditableTextState editableTextState, {
  VoidCallback? onPaste,
}) {
  final buttonItems = List<ContextMenuButtonItem>.of(
    editableTextState.contextMenuButtonItems,
  );
  if (onPaste != null && !editableTextState.widget.readOnly) {
    final index = buttonItems.indexWhere(
      (item) => item.type == ContextMenuButtonType.paste,
    );
    final paste = ContextMenuButtonItem(
      type: ContextMenuButtonType.paste,
      onPressed: onPaste,
    );
    if (index < 0) {
      buttonItems.add(paste);
    } else {
      buttonItems[index] = paste;
    }
  }
  final selection = editableTextState.textEditingValue.selection;
  if (!editableTextState.widget.readOnly &&
      selection.isValid &&
      !selection.isCollapsed &&
      !markdownProtectedRanges(editableTextState.textEditingValue.text).any(
        (range) => selection.start < range.end && selection.end > range.start,
      )) {
    final value = editableTextState.textEditingValue;
    for (final format in markdownToolbarFormats) {
      if (format.marker == '||' &&
          value.selection.textInside(value.text).contains('\n')) {
        continue;
      }
      final active = markdownWrapActive(value, format.marker);
      if (toggleMarkdownWrap(value, format.marker) == value) {
        continue;
      }
      buttonItems.add(
        ContextMenuButtonItem(
          label: active ? format.activeLabel : format.label,
          onPressed: () {
            ContextMenuController.removeAny();
            editableTextState.userUpdateTextEditingValue(
              toggleMarkdownWrap(
                editableTextState.textEditingValue,
                format.marker,
              ),
              SelectionChangedCause.toolbar,
            );
          },
        ),
      );
    }
  }
  return AdaptiveTextSelectionToolbar.buttonItems(
    anchors: editableTextState.contextMenuAnchors,
    buttonItems: buttonItems,
  );
}
