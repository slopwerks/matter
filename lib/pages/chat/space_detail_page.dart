import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/max_content_width.dart';
import 'chat_detail_page.dart';

class SpaceDetailPage extends ConsumerWidget {
  final Space space;

  const SpaceDetailPage({super.key, required this.space});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailsAsync = ref.watch(spaceDetailsProvider(space.id));
    final membersAsync = ref.watch(roomMembersProvider(space.id));
    final childrenAsync = ref.watch(spaceChildrenProvider(space.id));
    final fallbackDetails = SpaceDetails(
      id: space.id,
      name: space.name,
      avatarUrl: space.avatarUrl,
      topic: null,
    );
    final details = detailsAsync.maybeWhen(
      data: (value) => value,
      orElse: () => fallbackDetails,
    );

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: AppColors.onBackground,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text(
          '空间',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(
              Icons.playlist_add_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () => _showAddRoomDialog(context, ref),
          ),
          PopupMenuButton<_SpaceMenuAction>(
            color: AppColors.surface,
            icon: const Icon(
              Icons.more_horiz_rounded,
              color: AppColors.onBackground,
            ),
            onSelected: (action) {
              switch (action) {
                case _SpaceMenuAction.edit:
                  _showEditSpaceDialog(context, ref, details);
                case _SpaceMenuAction.leave:
                  _confirmLeaveSpace(context, ref, details);
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(value: _SpaceMenuAction.edit, child: Text('编辑空间')),
              PopupMenuItem(value: _SpaceMenuAction.leave, child: Text('退出空间')),
            ],
          ),
        ],
      ),
      body: MaxContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppColors.surfaceElevated,
                borderRadius: BorderRadius.circular(AppRadii.surface),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      AppAvatar(
                        fallback: details.name,
                        size: 56,
                        radius: AppRadii.content,
                        url: details.avatarUrl,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              details.name,
                              style: const TextStyle(
                                color: AppColors.onBackground,
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              details.id,
                              style: const TextStyle(
                                color: AppColors.onSurfaceVariant,
                                fontSize: 12.5,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  if ((details.topic ?? '').isNotEmpty) ...[
                    const SizedBox(height: 14),
                    Text(
                      details.topic!,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13.5,
                        height: 1.35,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '房间列表',
              child: childrenAsync.when(
                data: (rooms) {
                  if (rooms.isEmpty) {
                    return const Text(
                      '这个空间下暂时没有可见房间',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final room in rooms)
                        _SpaceChildTile(
                          room: room,
                          onRemove: room.roomType == 'space'
                              ? null
                              : () => _confirmRemoveRoom(context, ref, room),
                        ),
                    ],
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载房间失败: $err',
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '成员',
              child: membersAsync.when(
                data: (members) {
                  if (members.isEmpty) {
                    return const Text(
                      '暂无成员信息',
                      style: TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    );
                  }
                  return Column(
                    children: [
                      for (final member in members.take(8))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 10),
                          child: Row(
                            children: [
                              AppAvatar(
                                fallback: member.name,
                                size: 36,
                                radius: AppRadii.content,
                                url: member.avatarUrl,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Text(
                                  member.name,
                                  style: const TextStyle(
                                    color: AppColors.onBackground,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      if (members.length > 8)
                        Text(
                          '还有 ${members.length - 8} 位成员',
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                    ],
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppColors.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (err, _) => Text(
                  '加载成员失败: $err',
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _Section(
              title: '设置',
              child: Column(
                children: [
                  _ActionSettingRow(
                    icon: Icons.edit_rounded,
                    label: '编辑空间',
                    value: '修改名称与说明',
                    onTap: () => _showEditSpaceDialog(context, ref, details),
                  ),
                  const SizedBox(height: 10),
                  _ActionSettingRow(
                    icon: Icons.exit_to_app_rounded,
                    label: '退出空间',
                    value: '离开当前空间',
                    danger: true,
                    onTap: () => _confirmLeaveSpace(context, ref, details),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showEditSpaceDialog(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    final nameController = TextEditingController(text: details.name);
    final topicController = TextEditingController(text: details.topic ?? '');
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        title: const Text(
          '编辑空间',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              style: const TextStyle(color: AppColors.onBackground),
              decoration: const InputDecoration(
                hintText: '空间名称',
                hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: topicController,
              minLines: 2,
              maxLines: 4,
              style: const TextStyle(color: AppColors.onBackground),
              decoration: const InputDecoration(
                hintText: '空间说明',
                hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () async {
              final name = nameController.text.trim();
              final topic = topicController.text.trim();
              if (name.isEmpty) return;
              try {
                await updateSpaceDetails(
                  spaceId: details.id,
                  name: name,
                  topic: topic.isEmpty ? null : topic,
                );
                ref.invalidate(spaceDetailsProvider(details.id));
                ref.invalidate(spacesProvider);
                ref.invalidate(chatRoomsProvider);
                if (!dialogContext.mounted || !context.mounted) return;
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('空间已更新')));
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('更新失败: $e')));
              }
            },
            child: const Text(
              '保存',
              style: TextStyle(color: AppColors.secondary),
            ),
          ),
        ],
      ),
    );
  }

  void _showAddRoomDialog(BuildContext context, WidgetRef ref) {
    final availableRooms = ref
        .read(ungroupedRoomsProvider)
        .maybeWhen(data: (rooms) => rooms.toList(), orElse: () => <ChatRoom>[]);

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: availableRooms.isEmpty
              ? const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    '当前没有可加入这个空间的未归属群组。',
                    style: TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 13,
                    ),
                  ),
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final room in availableRooms)
                      ListTile(
                        title: Text(
                          room.name,
                          style: const TextStyle(color: AppColors.onBackground),
                        ),
                        subtitle: Text(
                          room.lastMessage.isEmpty ? room.id : room.lastMessage,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 12.5,
                          ),
                        ),
                        trailing: const Icon(
                          Icons.add_link_rounded,
                          color: AppColors.secondary,
                        ),
                        onTap: () async {
                          try {
                            await addRoomToSpace(
                              spaceId: space.id,
                              roomId: room.id,
                            );
                            ref.invalidate(spaceChildrenProvider(space.id));
                            ref.invalidate(ungroupedRoomsProvider);
                            if (!sheetContext.mounted || !context.mounted) {
                              return;
                            }
                            Navigator.of(sheetContext).pop();
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('已加入空间')),
                            );
                          } catch (e) {
                            if (!context.mounted) return;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(content: Text('加入空间失败: $e')),
                            );
                          }
                        },
                      ),
                  ],
                ),
        ),
      ),
    );
  }

  void _confirmRemoveRoom(BuildContext context, WidgetRef ref, ChatRoom room) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        title: const Text(
          '移出空间',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: Text(
          '要把“${room.name}”从这个空间移除吗？',
          style: const TextStyle(color: AppColors.onBackground),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                await removeRoomFromSpace(spaceId: space.id, roomId: room.id);
                ref.invalidate(spaceChildrenProvider(space.id));
                ref.invalidate(ungroupedRoomsProvider);
                if (!dialogContext.mounted || !context.mounted) return;
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已从空间移除')));
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('移除失败: $e')));
              }
            },
            child: const Text('移除', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }

  void _confirmLeaveSpace(
    BuildContext context,
    WidgetRef ref,
    SpaceDetails details,
  ) {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        title: const Text(
          '退出空间',
          style: TextStyle(color: AppColors.onBackground),
        ),
        content: Text(
          '确认退出“${details.name}”吗？',
          style: const TextStyle(color: AppColors.onBackground),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text(
              '取消',
              style: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          TextButton(
            onPressed: () async {
              try {
                await leaveSpace(spaceId: details.id);
                ref.invalidate(spacesProvider);
                ref.invalidate(chatRoomsProvider);
                ref.invalidate(ungroupedRoomsProvider);
                if (!dialogContext.mounted || !context.mounted) return;
                Navigator.of(dialogContext).pop();
                Navigator.of(context).pop();
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(const SnackBar(content: Text('已退出空间')));
              } catch (e) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('退出失败: $e')));
              }
            },
            child: const Text('退出', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );
  }
}

enum _SpaceMenuAction { edit, leave }

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.surface),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppColors.onBackground,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 12),
          child,
        ],
      ),
    );
  }
}

class _SpaceChildTile extends StatelessWidget {
  final ChatRoom room;
  final VoidCallback? onRemove;

  const _SpaceChildTile({required this.room, this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.surface),
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
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              AppAvatar(fallback: room.name, size: 42, url: room.avatarUrl),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      room.name,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 14.5,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      room.lastMessage.isEmpty ? room.id : room.lastMessage,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12.5,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              if (onRemove != null)
                IconButton(
                  onPressed: onRemove,
                  icon: const Icon(
                    Icons.remove_circle_outline_rounded,
                    color: AppColors.error,
                  ),
                  tooltip: '从空间移除',
                )
              else
                const Icon(
                  Icons.chevron_right_rounded,
                  color: AppColors.onSurfaceVariant,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionSettingRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final bool danger;
  final VoidCallback onTap;

  const _ActionSettingRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.danger = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = danger ? AppColors.error : AppColors.onBackground;
    return InkWell(
      borderRadius: BorderRadius.circular(AppRadii.content),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            Icon(
              icon,
              color: danger ? AppColors.error : AppColors.onSurfaceVariant,
              size: 18,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Text(
              value,
              style: const TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
              ),
            ),
            const SizedBox(width: 6),
            const Icon(
              Icons.chevron_right_rounded,
              color: AppColors.onSurfaceVariant,
              size: 18,
            ),
          ],
        ),
      ),
    );
  }
}
