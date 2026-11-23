import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../src/rust/api/matrix.dart' hide redactMessage;
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';

import '../../../widgets/sheets.dart';
import '../chat_timestamp.dart';
import 'timeline_read_receipts.dart';
import 'timeline_bubble_frame.dart';

class TimelineMessageMetadata extends StatelessWidget {
  const TimelineMessageMetadata({
    super.key,
    required this.message,
    required this.roomId,
    this.overlay = false,
  });
  final ChatMessage message;
  final String roomId;
  final bool overlay;
  void _showEditHistory(BuildContext context, ChatMessage message) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final material = context.isMaterial;
    final history = message.editHistory;
    String editLabel(int index) => index == 0
        ? '原始'
        : index == history.length - 1
        ? '最新'
        : '第 $index 次编辑';

    showNeuSheet(
      context: context,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 10),
              child: Text('编辑记录', style: textTheme.titleMedium),
            ),
            for (var index = 0; index < history.length; index++)
              if (material) ...[
                if (index > 0)
                  const Divider(height: 1, indent: 16, endIndent: 16),
                ListTile(
                  title: Text(editLabel(index)),
                  subtitle: Text(history[index]),
                ),
              ] else
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: index == history.length - 1
                              ? colors.accentSoft
                              : colors.card.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(NeuRadius.tag),
                        ),
                        child: Text(
                          editLabel(index),
                          style: textTheme.labelSmall?.copyWith(
                            color: index == history.length - 1
                                ? colors.accent
                                : colors.textTertiary,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        history[index],
                        style: textTheme.bodyMedium?.copyWith(
                          color: colors.text,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final labelStyle = theme.textTheme.labelSmall;
    final onSolidBubble =
        context.isMaterial &&
        overlay &&
        switch (message.msgType) {
          MessageType.file || MessageType.location || MessageType.poll => true,
          _ => false,
        };
    final foreground = onSolidBubble
        ? (message.isMe
              ? outgoingBubbleForeground(context)
              : theme.colorScheme.onSurfaceVariant)
        : overlay
        ? Colors.white.withValues(alpha: 0.9)
        : message.isMe
        ? outgoingBubbleForeground(context).withValues(alpha: 0.65)
        : colors.textTertiary;
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (message.isEdited) ...[
          GestureDetector(
            onTap: () => _showEditHistory(context, message),
            child: Text(
              '已编辑',
              style: labelStyle?.copyWith(
                color: foreground.withValues(alpha: 0.75),
              ),
            ),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          formatMessageTime(message.timestamp),
          style: labelStyle?.copyWith(
            color: foreground,
            fontWeight: FontWeight.w500,
          ),
        ),
        if (message.isMe) ...[
          const SizedBox(width: 4),
          TimelineReadIndicator(
            message: message,
            roomId: roomId,
            color: foreground,
          ),
        ],
      ],
    );

    if (!overlay) {
      return KeyedSubtree(
        key: ValueKey('message-metadata:${message.id}'),
        child: content,
      );
    }
    return Positioned(
      right: 7,
      bottom: 6,
      child: Container(
        key: ValueKey('message-metadata:${message.id}'),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: onSolidBubble
            ? null
            : BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                borderRadius: BorderRadius.circular(8),
              ),
        child: content,
      ),
    );
  }
}

IconData _eventIcon(ChatMessage message) {
  final content = message.content;
  if (content.contains('房间头像')) {
    return Icons.photo_size_select_actual_outlined;
  }
  if (content.contains('头像')) {
    return Icons.account_circle_outlined;
  }
  if (content.contains('加密')) {
    return Icons.lock_outline_rounded;
  }
  if (content.contains('权限')) {
    return Icons.admin_panel_settings_outlined;
  }
  if (content.contains('置顶')) {
    return Icons.push_pin_outlined;
  }
  if (content.contains('封禁')) {
    return Icons.block_rounded;
  }
  if (content.contains('通话')) {
    return Icons.call_outlined;
  }
  if (content.contains('加入') || content.contains('邀请')) {
    return Icons.person_add_rounded;
  }
  if (content.contains('退出') ||
      content.contains('离开') ||
      content.contains('踢出') ||
      content.contains('移出')) {
    return Icons.person_remove_rounded;
  }
  if (content.contains('创建')) {
    return Icons.add_circle_outline_rounded;
  }
  if (content.contains('修改') ||
      content.contains('更改') ||
      content.contains('设置')) {
    return Icons.edit_rounded;
  }
  return Icons.info_outline_rounded;
}

Widget buildEventMessage(BuildContext context, ChatMessage message) {
  final colors = context.neu;
  final theme = Theme.of(context);
  final style = context.isMaterial ? materialTimelineEventStyle(theme) : null;
  return Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Center(
      child: Container(
        constraints: BoxConstraints(
          maxWidth: math.min(MediaQuery.of(context).size.width * 0.82, 640.0),
          minHeight: 24,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration:
            style?.decoration ??
            BoxDecoration(
              color: colors.card.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(NeuRadius.tag),
            ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              _eventIcon(message),
              size: 13,
              color: style?.foreground ?? colors.textTertiary,
            ),
            const SizedBox(width: 5),
            Flexible(
              child: Text(
                message.content,
                style:
                    style?.label ??
                    theme.textTheme.bodySmall?.copyWith(height: 1.2),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}
