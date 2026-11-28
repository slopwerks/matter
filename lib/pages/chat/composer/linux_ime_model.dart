import 'package:flutter/services.dart';

/// GTK offsets count Unicode scalars; Flutter editing offsets count UTF-16.
int imeUtf16Offset(String text, int scalars) => text.runes
    .take(scalars.clamp(0, text.runes.length))
    .fold(0, (offset, rune) => offset + (rune > 0xffff ? 2 : 1));

class LinuxImeModel {
  LinuxImeModel(this.value);

  TextEditingValue value;
  TextEditingValue? _before;
  bool get composing => _before != null;

  TextRange get _replacement => value.composing.isValid
      ? value.composing
      : value.selection.isValid
      ? TextRange(start: value.selection.start, end: value.selection.end)
      : TextRange.collapsed(value.text.length);

  void start() => _before ??= value;

  void preedit(String text, int cursor) {
    start();
    // GTK can report an empty preedit when the selection/context changes or
    // just before commit. It is not a request to delete selected text.
    if (text.isEmpty) {
      value = _before!;
      return;
    }
    final range = _replacement;
    value = TextEditingValue(
      text: value.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(
        offset: range.start + imeUtf16Offset(text, cursor),
      ),
      composing: TextRange(start: range.start, end: range.start + text.length),
    );
  }

  void commit(String text) {
    final range = _replacement;
    value = TextEditingValue(
      text: value.text.replaceRange(range.start, range.end, text),
      selection: TextSelection.collapsed(offset: range.start + text.length),
    );
    _before = null;
  }

  void cancel() {
    if (_before != null) value = _before!;
    _before = null;
  }

  // Controller edits (paste, undo, draft replacement, selection) take priority
  // over an outstanding GTK preedit. Keep the visible text, not an old draft.
  void synchronize(TextEditingValue next) {
    value = next.copyWith(composing: TextRange.empty);
    _before = null;
  }

  bool deleteSurrounding(int offset, int count) {
    if (count < 0 || !value.selection.isValid) return false;
    final cursor = value.text
        .substring(0, value.selection.extentOffset)
        .runes
        .length;
    final start = cursor + offset;
    final end = start + count;
    if (start < 0 || end > value.text.runes.length) return false;
    final from = imeUtf16Offset(value.text, start);
    final to = imeUtf16Offset(value.text, end);
    int adjust(int position) => position < from
        ? position
        : position > to
        ? position - (to - from)
        : from;
    value = TextEditingValue(
      text: value.text.replaceRange(from, to, ''),
      selection: value.selection.copyWith(
        baseOffset: adjust(value.selection.baseOffset),
        extentOffset: adjust(value.selection.extentOffset),
      ),
      composing: value.composing.isValid
          ? TextRange(
              start: adjust(value.composing.start),
              end: adjust(value.composing.end),
            )
          : TextRange.empty,
    );
    // Cancellation must not resurrect surrounding text the IME deleted.
    if (_before != null) {
      final current = value;
      final before = _before!;
      final preedit = current.composing;
      if (!preedit.isValid) {
        _before = current;
      } else {
        _before = TextEditingValue(
          text: current.text.replaceRange(
            preedit.start,
            preedit.end,
            before.selection.textInside(before.text),
          ),
          selection: TextSelection(
            baseOffset:
                preedit.start +
                (before.selection.isValid
                    ? before.selection.baseOffset - before.selection.start
                    : 0),
            extentOffset:
                preedit.start +
                (before.selection.isValid
                    ? before.selection.extentOffset - before.selection.start
                    : 0),
          ),
        );
      }
    }
    return true;
  }
}
