import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'chat_detail_page.dart';
import 'space_detail_page.dart';

class ChatListItem extends ConsumerWidget {
  final ChatRoom room;
  final bool dense;
  final bool showRoomTypeIcon;

  const ChatListItem({
    super.key,
    required this.room,
    this.dense = false,
    this.showRoomTypeIcon = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final room = this.room;

    return InkWell(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => room.roomType == 'space'
                ? SpaceDetailPage(
                    space: Space(
                      id: room.id,
                      name: room.name,
                      avatarUrl: room.avatarUrl,
                    ),
                  )
                : ChatDetailPage(
                    roomId: room.id,
                    roomName: room.name,
                    avatarUrl: room.avatarUrl,
                    isDm: room.roomType == 'dm',
                    subtitle: room.unreadCount > 0
                        ? '${room.unreadCount} 条未读消息'
                        : '在线',
                  ),
          ),
        );
      },
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 6 : 8),
        child: Row(
          children: [
            AppAvatar(
              key: ValueKey('room-avatar:${room.id}:${room.avatarUrl}'),
              fallback: room.name,
              size: dense ? 44 : 52,
              url: room.avatarUrl,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      if (showRoomTypeIcon) ...[
                        _roomTypeIcon(room.roomType),
                        const SizedBox(width: 4),
                      ],
                      Expanded(
                        child: Text(
                          room.name,
                          style: const TextStyle(
                            color: AppColors.onBackground,
                            fontSize: 15.5,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        formatChatListTime(room.lastMessageTime),
                        style: TextStyle(
                          color: room.unreadCount > 0
                              ? AppColors.primary
                              : AppColors.onSurfaceVariant,
                          fontSize: 12,
                          fontWeight: room.unreadCount > 0
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          room.lastMessage,
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 13.5,
                            height: 1.3,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (room.unreadCount > 0) ...[
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.primary,
                            borderRadius: BorderRadius.circular(AppRadii.tag),
                          ),
                          child: Text(
                            room.unreadCount > 99
                                ? '99+'
                                : '${room.unreadCount}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _roomTypeIcon(String roomType) {
    return switch (roomType) {
      'dm' => const Icon(
        Icons.person_rounded,
        size: 14,
        color: AppColors.primary,
      ),
      'space' => const Icon(
        Icons.account_tree_rounded,
        size: 14,
        color: AppColors.secondary,
      ),
      _ => const Icon(
        Icons.group_rounded,
        size: 14,
        color: AppColors.onSurfaceVariant,
      ),
    };
  }
}
