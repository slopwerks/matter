import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/neu_action.dart';
import 'material_room_member_rows.dart';

/// Conversation information shared by the supporting pane and its modal view.
class MaterialRoomDetailsPanel extends ConsumerWidget {
  const MaterialRoomDetailsPanel({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    required this.onManage,
  });

  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final VoidCallback onManage;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final membersProvider = roomMembersProvider(roomId);
    final members = ref.watch(membersProvider);
    final isEncrypted = ref.watch(
      allChatRoomsProvider.select(
        (rooms) => rooms.value
            ?.where((room) => room.id == roomId)
            .firstOrNull
            ?.isEncrypted,
      ),
    );
    final theme = Theme.of(context);
    final hero = materialProfileCardStyle(theme, detail: true);
    return CustomScrollView(
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          sliver: SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  color: hero.fill,
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        AppAvatar(
                          fallback: roomName,
                          size: 80,
                          radius: NeuRadius.content,
                          url: avatarUrl,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          roomName,
                          textAlign: TextAlign.center,
                          style: hero.title,
                        ),
                        if (members.value case final loaded?) ...[
                          const SizedBox(height: 8),
                          Text('${loaded.length} 位成员', style: hero.subtitle),
                        ],
                        if (isEncrypted == true) ...[
                          const SizedBox(height: 12),
                          const Chip(
                            avatar: Icon(Icons.lock_outline_rounded, size: 16),
                            label: Text('端到端加密'),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                MaterialDetailCard(
                  title: '会话信息',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      NeuAction(
                        onTap: onManage,
                        label: '房间管理',
                        child: ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.tune_rounded),
                          title: const Text('房间管理'),
                          subtitle: const Text('资料、成员与消息设置'),
                          trailing: const Icon(Icons.chevron_right_rounded),
                        ),
                      ),
                      const Divider(),
                      Text('房间 ID', style: theme.textTheme.labelMedium),
                      const SizedBox(height: 4),
                      SelectableText(roomId, style: theme.textTheme.bodySmall),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            0,
            16,
            24 + MediaQuery.paddingOf(context).bottom,
          ),
          sliver: members.when(
            data: (loaded) => SliverList.separated(
              itemCount: loaded.length + 1,
              separatorBuilder: (_, index) => Divider(
                height: 1,
                indent: index == 0
                    ? 0
                    : materialListAvatarSize + materialListContentGap,
              ),
              itemBuilder: (context, index) {
                if (index == 0) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '成员 ${loaded.length}',
                          style: theme.textTheme.titleSmall,
                        ),
                        if (loaded.isEmpty) ...[
                          const SizedBox(height: 12),
                          const Text('暂无成员'),
                        ],
                      ],
                    ),
                  );
                }
                final member = loaded[index - 1];
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: MaterialMemberIdentity(
                    name: member.name,
                    userId: member.id,
                    avatarUrl: member.avatarUrl,
                  ),
                );
              },
            ),
            loading: () => const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
            error: (_, _) => SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('成员', style: theme.textTheme.titleSmall),
                    const SizedBox(height: 12),
                    const Text('无法加载成员'),
                    TextButton.icon(
                      onPressed: () => ref.invalidate(membersProvider),
                      icon: const Icon(Icons.refresh_rounded),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
