import 'package:material_ui/material_ui.dart';

import '../../../providers/chat_provider.dart';
import '../../../src/rust/api/matrix.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/neu_decoration.dart';

/// Repeat key for the inline "+1" affordance: only plain text messages can be
/// repeated, and optimistic local rows have no server event to repeat yet.
String? _repeatKey(ChatMessage message) {
  if (message.msgType != MessageType.text) return null;
  if (isLocalOutgoingMessage(message.id)) return null;
  final text = message.content.trim();
  if (text.isEmpty) return null;
  return text;
}

/// Ids of messages that offer the inline "+1" button.
///
/// Only the newest message qualifies, whoever sent it, and only while it
/// directly repeats the message before it: the button bumps a text that was
/// just said, not any older copy further up the timeline.
Set<String> plusOneEligibleIds(List<ChatMessage> messages) {
  if (messages.length < 2) return const {};
  final newest = messages.last;
  final key = _repeatKey(newest);
  if (key == null) return const {};
  for (var index = messages.length - 2; index >= 0; index--) {
    final previous = messages[index];
    // The same event listed twice is one message, not a repeat.
    if (previous.id == newest.id) continue;
    return _repeatKey(previous) == key ? {newest.id} : const {};
  }
  return const {};
}

/// Small "+1" chip shown beside a repeated message: tapping it re-sends the
/// same content as a new event.
class PlusOneButton extends StatelessWidget {
  const PlusOneButton({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Semantics(
      button: true,
      label: '再发一条相同消息',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: NeuDecoration(
            colors: colors,
            depth: NeuDepth.pressed,
            radius: NeuRadius.tag,
            intensity: .6,
          ),
          child: Text(
            '+1',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              fontWeight: FontWeight.w700,
              color: colors.textTertiary,
            ),
          ),
        ),
      ),
    );
  }
}
