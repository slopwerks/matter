import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/chat_provider.dart';
import '../../../providers/composer_keyboard_settings_provider.dart';
import '../../../src/rust/api/matrix.dart' as rust;
import '../composer_autocomplete.dart';
import 'composer_autocomplete_popup.dart';

/// Keyboard shortcuts and autocomplete selection for the inline editor.
/// The host owns the editor/focus; this controller owns only suggestion state.
class ComposerKeyboardController {
  ComposerKeyboardController({
    required this.ref,
    required this.roomId,
    required this.text,
    required this.focus,
    required this.context,
    required this.isMounted,
    required this.keyboardMouse,
    required this.onChanged,
    required this.onPaste,
    required this.onSend,
  });

  final WidgetRef ref;
  final String roomId;
  final TextEditingController text;
  final FocusNode focus;
  final BuildContext Function() context;
  final bool Function() isMounted;
  final bool Function() keyboardMouse;
  final VoidCallback onChanged;
  final Future<void> Function(SelectionChangedCause) onPaste;
  final Future<void> Function() onSend;
  final scroll = ScrollController();
  ComposerAutocompleteMatch? match;
  int index = 0;
  bool _wasComposing = false;

  bool get isComposing =>
      text.value.composing.isValid && !text.value.composing.isCollapsed;

  void initialize() {
    _wasComposing = isComposing;
    match = composerAutocompleteMatch(text.value);
  }

  bool textChanged() {
    final next = composerAutocompleteMatch(text.value);
    final changed = isComposing != _wasComposing || next != match;
    _wasComposing = isComposing;
    if (next != match) {
      match = next;
      index = 0;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (isMounted() && scroll.hasClients) scroll.jumpTo(0);
      });
    }
    return changed;
  }

  void insertText(String value) {
    final selection = text.selection;
    final current = text.text;
    final start = selection.start >= 0 ? selection.start : current.length;
    final end = selection.end >= 0 ? selection.end : current.length;
    text.value = TextEditingValue(
      text: current.replaceRange(start, end, value),
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  KeyEventResult handleKey(FocusNode node, KeyEvent event) {
    if (isComposing) return KeyEventResult.ignored;
    final keyboard = HardwareKeyboard.instance;
    final pasteModifier = Theme.of(context()).platform == TargetPlatform.macOS
        ? keyboard.isMetaPressed
        : keyboard.isControlPressed;
    if (keyboardMouse() &&
        event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.keyV &&
        pasteModifier &&
        !keyboard.isShiftPressed &&
        !keyboard.isAltPressed) {
      unawaited(onPaste(SelectionChangedCause.keyboard));
      return KeyEventResult.handled;
    }
    if (_isEnter(event)) {
      final shortcut = keyboard.isShiftPressed
          ? ComposerEnterShortcut.shiftEnter
          : keyboard.isAltPressed
          ? ComposerEnterShortcut.altEnter
          : ComposerEnterShortcut.enter;
      if (ref.read(composerKeyboardSettingsProvider).actionFor(shortcut) ==
          ComposerEnterAction.newline) {
        if (event is KeyDownEvent) insertText('\n');
        return KeyEventResult.handled;
      }
    }
    if (_handleAutocomplete(event)) return KeyEventResult.handled;
    if (!_isEnter(event)) return KeyEventResult.ignored;
    if (event is KeyDownEvent) unawaited(onSend());
    return KeyEventResult.handled;
  }

  bool _isEnter(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;

  bool _handleAutocomplete(KeyEvent event) {
    final current = focus.hasFocus ? match : null;
    if (current == null) return false;
    final candidates = options(current);
    if (candidates.isEmpty) return false;
    final key = event.logicalKey;
    final selects = key == LogicalKeyboardKey.tab || _isEnter(event);
    final moves =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp;
    if (!selects && !moves) return false;
    if (event is! KeyDownEvent) return true;
    if (selects) {
      select(current, candidates[index.clamp(0, candidates.length - 1)]);
      return true;
    }
    final direction = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
    index = (index + direction + candidates.length) % candidates.length;
    onChanged();
    _scrollToIndex(index);
    return true;
  }

  void _scrollToIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isMounted() || !scroll.hasClients) return;
      final position = scroll.position;
      final top = index * 52.0;
      final bottom = top + 52;
      final target = top < position.pixels
          ? top
          : bottom > position.pixels + position.viewportDimension
          ? bottom - position.viewportDimension
          : null;
      if (target != null) {
        scroll.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
    });
  }

  List<ComposerAutocompleteOption> options(
    ComposerAutocompleteMatch current, {
    List<rust.Contact>? members,
    List<rust.ChatRoom>? rooms,
  }) => composerAutocompleteOptions(
    current,
    members:
        members ??
        (current.kind == ComposerAutocompleteKind.mention
            ? ref.read(roomMembersProvider(roomId)).asData?.value
            : null) ??
        const [],
    rooms:
        rooms ??
        (current.kind == ComposerAutocompleteKind.room
            ? ref.read(chatRoomsProvider).asData?.value
            : null) ??
        const [],
  );

  void select(
    ComposerAutocompleteMatch current,
    ComposerAutocompleteOption option,
  ) {
    if (current != match) return;
    text.value = applyComposerAutocomplete(
      text.value,
      current,
      option.insertion,
    );
    focus.requestFocus();
  }

  void hover(int next) {
    index = next;
    onChanged();
  }

  void dispose() => scroll.dispose();
}
