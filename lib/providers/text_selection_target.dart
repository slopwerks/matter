import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The message whose body is selectable right now.
///
/// Selecting a part of a message is a deliberate mode on touch input: a plain
/// long press belongs to the message menu, so the text only accepts a drag
/// after the menu's "选择文字" entry put the message here.
class TextSelectionTarget extends Notifier<String?> {
  @override
  String? build() => null;

  void enter(String messageId) => state = messageId;

  void clear() => state = null;
}

final textSelectionTargetProvider =
    NotifierProvider<TextSelectionTarget, String?>(TextSelectionTarget.new);

/// Drops an active selection mode and reports whether it consumed the back
/// gesture, so back leaves the selection before it leaves the room.
bool clearTextSelectionOnBack(WidgetRef ref) {
  if (ref.read(textSelectionTargetProvider) == null) return false;
  ref.read(textSelectionTargetProvider.notifier).clear();
  return true;
}
