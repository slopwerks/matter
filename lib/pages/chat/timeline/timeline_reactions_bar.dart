import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/chat_visual_settings_provider.dart';
import '../../../src/rust/api/matrix.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/neu_decoration.dart';

/// Shared by the inline chips, quick menu and full picker. Never apply a
/// response after unmount or to another active account's message cache.
Future<void> toggleTimelineReaction(
  BuildContext context,
  WidgetRef ref, {
  required String roomId,
  required String eventId,
  required String emoji,
}) async {
  try {
    final userId = ref.read(activeUserIdProvider) ?? '';
    final updated = await toggleReaction(
      accountUserId: userId,
      roomId: roomId,
      eventId: eventId,
      key: emoji,
    );
    if (!context.mounted || !ref.context.mounted) return;
    if (ref.read(activeUserIdProvider) != userId) return;
    updateMessageCache(
      ref,
      roomId,
      mergeMessageSnapshotAdditions(ref.read(messageCacheProvider(roomId)), [
        updated,
      ]),
    );
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('回应失败: $error'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }
}

/// The aggregated emoji row keeps server order and sender counts; message and
/// emoji keys remain stable while the same reaction's senders change.
class TimelineReactionsBar extends ConsumerWidget {
  const TimelineReactionsBar({
    super.key,
    required this.message,
    required this.isMe,
    required this.onToggle,
  });

  final ChatMessage message;
  final bool isMe;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final userId = ref.watch(activeUserIdProvider);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        alignment: isMe ? WrapAlignment.end : WrapAlignment.start,
        children: message.reactions
            .map(
              (reaction) => _ReactionChip(
                key: ValueKey('${message.id}:${reaction.key}'),
                reaction: reaction,
                reacted: reaction.senders.contains(userId),
                onTap: () => onToggle(reaction.key),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ReactionChip extends StatelessWidget {
  const _ReactionChip({
    super.key,
    required this.reaction,
    required this.reacted,
    required this.onTap,
  });

  final Reaction reaction;
  final bool reacted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: NeuDecoration(
          colors: colors,
          superellipseEnabled: ChatVisualSettingsScope.of(context)
              .superellipseBorderEnabled,
          depth: NeuDepth.pressed,
          radius: NeuRadius.nav,
          intensity: .6,
          borderColor: reacted ? colors.accent : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(reaction.key, style: const TextStyle(fontSize: 13)),
            const SizedBox(width: 3),
            Text(
              '${reaction.senders.length}',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: reacted ? colors.accent : colors.textTertiary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
