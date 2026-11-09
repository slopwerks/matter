import 'package:flutter/material.dart';

import '../../src/rust/api/matrix.dart';
import '../../theme/app_component_theme.dart';
import '../../theme/material_theme.dart';
import '../../theme/tokens.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/avatar.dart' show NeuBadge;
import 'chat_timestamp.dart';

class MaterialChatListContent extends StatelessWidget {
  const MaterialChatListContent({
    super.key,
    required this.room,
    required this.preview,
    required this.hasDraft,
    required this.hasUnread,
    required this.dense,
    required this.showRoomTypeIcon,
    this.membershipActions,
  });

  final ChatRoom room;
  final String preview;
  final bool hasDraft;
  final bool hasUnread;
  final bool dense;
  final bool showRoomTypeIcon;
  final Widget? membershipActions;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final components = AppComponentTheme.of(context);
    final text = materialConversationTextTheme(
      theme,
      unread: hasUnread,
      muted: room.isMuted,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            AppAvatar(
              key: ValueKey('room-avatar:${room.id}:${room.avatarUrl}'),
              fallback: room.name,
              size: dense ? components.denseAvatarSize : components.avatarSize,
              url: room.avatarUrl,
            ),
            SizedBox(width: context.tokens.spacing.md),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (showRoomTypeIcon && room.roomType != 'dm') ...[
                        Icon(
                          room.roomType == 'space'
                              ? Icons.account_tree_outlined
                              : Icons.group_outlined,
                          size: 16,
                          color: scheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          room.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: text.titleMedium,
                        ),
                      ),
                      if (room.isMuted) ...[
                        const SizedBox(width: 6),
                        Icon(
                          Icons.notifications_off_outlined,
                          key: ValueKey('room-muted-icon:${room.id}'),
                          size: 15,
                          color: scheme.onSurfaceVariant,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 4),
                  if (hasDraft)
                    Text.rich(
                      TextSpan(
                        children: [
                          TextSpan(
                            text: '草稿：',
                            style: TextStyle(color: scheme.error),
                          ),
                          TextSpan(text: preview),
                        ],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    )
                  else
                    Text(
                      preview,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: text.bodyMedium,
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 80),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    formatChatListTime(room.lastMessageTime),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: text.labelSmall,
                  ),
                  if (hasUnread) ...[
                    const SizedBox(height: 10),
                    if (room.unreadCount > 0)
                      NeuBadge(
                        key: ValueKey('room-unread-badge:${room.id}'),
                        count: room.unreadCount,
                        muted: room.isMuted,
                      )
                    else
                      Icon(
                        Icons.circle,
                        key: ValueKey('room-unread-dot:${room.id}'),
                        size: 10,
                        color: room.isMuted
                            ? scheme.onSurfaceVariant
                            : scheme.primary,
                      ),
                  ],
                ],
              ),
            ),
          ],
        ),
        if (membershipActions != null) ...[
          const SizedBox(height: 12),
          membershipActions!,
        ],
      ],
    );
  }
}
