import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'chat_detail_page.dart';
import 'message_input.dart';
import 'space_detail_page.dart';

String chatListPreview(ChatRoom room) {
  if (room.roomState == 'invited') {
    return '邀请你加入';
  }
  if (room.roomState == 'knocked') {
    return '等待对方批准';
  }
  final sender = room.lastMessageSender?.trim();
  if (room.roomType != 'group' ||
      sender == null ||
      sender.isEmpty ||
      room.lastMessage.isEmpty) {
    return room.lastMessage;
  }
  return '$sender：${room.lastMessage}';
}

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
    final isPendingMembership =
        room.roomState == 'invited' || room.roomState == 'knocked';
    final userId =
        ref.watch(activeUserIdProvider) ??
        ref.watch(currentUserProvider.select((user) => user?.id)) ??
        'anonymous';
    final draft = ref.watch(
      messageDraftProvider((roomId: room.id, userId: userId)),
    );
    final hasDraft =
        room.roomState == 'joined' &&
        room.roomType != 'space' &&
        draft.trim().isNotEmpty;
    final preview = hasDraft
        ? draft.trim().replaceAll(RegExp(r'\s+'), ' ')
        : chatListPreview(room);

    return InkWell(
      onTap: () {
        if (isPendingMembership) return;
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
                        child: Text.rich(
                          TextSpan(
                            children: [
                              if (hasDraft)
                                const TextSpan(
                                  text: '草稿：',
                                  style: TextStyle(
                                    color: AppColors.error,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              TextSpan(text: preview),
                            ],
                          ),
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
                  if (isPendingMembership) ...[
                    const SizedBox(height: 8),
                    _PendingRoomActions(room: room),
                  ],
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

class _PendingRoomActions extends ConsumerWidget {
  final ChatRoom room;

  const _PendingRoomActions({required this.room});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (room.roomState == 'invited') {
      return Row(
        children: [
          _ActionButton(
            icon: Icons.check_rounded,
            label: '接受',
            onPressed: () => _runAction(
              context,
              ref,
              () => acceptRoomInvite(roomId: room.id),
              successMessage: '已接受邀请',
            ),
          ),
          const SizedBox(width: 8),
          _ActionButton(
            icon: Icons.close_rounded,
            label: '拒绝',
            destructive: true,
            onPressed: () => _runAction(
              context,
              ref,
              () => rejectRoomInvite(roomId: room.id),
              successMessage: '已拒绝邀请',
            ),
          ),
        ],
      );
    }
    return Row(
      children: [
        _ActionButton(
          icon: Icons.undo_rounded,
          label: '撤回',
          destructive: true,
          onPressed: () => _runAction(
            context,
            ref,
            () => withdrawRoomKnock(roomId: room.id),
            successMessage: '已撤回请求',
          ),
        ),
      ],
    );
  }

  Future<void> _runAction(
    BuildContext context,
    WidgetRef ref,
    Future<void> Function() action, {
    required String successMessage,
  }) async {
    try {
      await action();
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(successMessage)));
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('操作失败: $error')));
    }
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool destructive;
  final VoidCallback onPressed;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onPressed,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = destructive ? AppColors.error : AppColors.primary;
    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.55)),
        visualDensity: VisualDensity.compact,
        minimumSize: const Size(0, 34),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        textStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
      ),
    );
  }
}
