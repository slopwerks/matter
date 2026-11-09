import 'package:flutter/material.dart';

import '../../src/rust/api/matrix.dart';
import '../../theme/app_component_theme.dart';
import '../../theme/neu_colors.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/avatar.dart' show NeuBadge;
import 'chat_timestamp.dart';

class NeuChatListContent extends StatelessWidget {
  const NeuChatListContent({
    super.key,
    required this.room,
    required this.preview,
    required this.hasDraft,
    required this.hasUnread,
    required this.dense,
    required this.showRoomTypeIcon,
    required this.unreadAccent,
    this.membershipActions,
  });
  final ChatRoom room;
  final String preview;
  final bool hasDraft;
  final bool hasUnread;
  final bool dense;
  final bool showRoomTypeIcon;
  final Color unreadAccent;
  final Widget? membershipActions;
  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final components = AppComponentTheme.of(context);
    return Row(
      children: [
        AppAvatar(
          key: ValueKey('room-avatar:${room.id}:${room.avatarUrl}'),
          fallback: room.name,
          size: dense ? components.denseAvatarSize : components.avatarSize,
          url: room.avatarUrl,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (showRoomTypeIcon) ...[
                    _roomTypeIcon(context, room.roomType),
                    const SizedBox(width: 4),
                  ],
                  Expanded(
                    child: Text(
                      room.name,
                      style: context.tokens.typography.listTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (room.isMuted) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.notifications_off_outlined,
                      key: ValueKey('room-muted-icon:${room.id}'),
                      size: 15,
                      color: colors.textTertiary,
                    ),
                  ],
                  const SizedBox(width: 8),
                  Text(
                    formatChatListTime(room.lastMessageTime),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: hasUnread ? unreadAccent : colors.textTertiary,
                      fontWeight: hasUnread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  Expanded(
                    child: hasDraft
                        ? Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '草稿：',
                                  style: TextStyle(
                                    color: colors.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(text: preview),
                              ],
                            ),
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            preview,
                            style: Theme.of(context).textTheme.bodyMedium,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                  ),
                  if (hasUnread) ...[
                    const SizedBox(width: 8),
                    if (room.unreadCount > 0)
                      NeuBadge(
                        key: ValueKey('room-unread-badge:${room.id}'),
                        count: room.unreadCount,
                        muted: room.isMuted,
                      )
                    else
                      Container(
                        key: ValueKey('room-unread-dot:${room.id}'),
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: unreadAccent, width: 2.4),
                        ),
                      ),
                  ],
                ],
              ),
              if (membershipActions != null) ...[
                const SizedBox(height: 10),
                membershipActions!,
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _roomTypeIcon(BuildContext context, String roomType) {
    final colors = context.neu;
    return switch (roomType) {
      'dm' => Icon(Icons.person_rounded, size: 14, color: colors.accent),
      'space' => Icon(
        Icons.account_tree_rounded,
        size: 14,
        color: colors.textSecondary,
      ),
      _ => Icon(Icons.group_rounded, size: 14, color: colors.textTertiary),
    };
  }
}
