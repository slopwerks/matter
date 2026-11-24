import 'package:material_ui/material_ui.dart';

import '../../widgets/material_list_detail.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_detail_card.dart';
import 'material_room_member_rows.dart';

enum RoomPanelAction { manage, search, pins }

/// Conversation information shared by the supporting pane and its modal view.
class MaterialRoomDetailsPanel extends ConsumerWidget {
  const MaterialRoomDetailsPanel({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    required this.onManage,
    this.onTimelineAction,
  });

  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final VoidCallback onManage;
  final ValueChanged<RoomPanelAction>? onTimelineAction;

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
                        AppAvatar(fallback: roomName, size: 64, url: avatarUrl),
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
                if (onTimelineAction != null) ...[
                  Wrap(
                    alignment: WrapAlignment.center,
                    spacing: NeuSpacing.sm,
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            onTimelineAction!(RoomPanelAction.search),
                        icon: const Icon(Icons.search),
                        label: const Text('搜索'),
                      ),
                      FilledButton.tonalIcon(
                        onPressed: () =>
                            onTimelineAction!(RoomPanelAction.pins),
                        icon: const Icon(Icons.push_pin_outlined),
                        label: const Text('置顶消息'),
                      ),
                    ],
                  ),
                  const SizedBox(height: NeuSpacing.lg),
                ],
                MaterialDetailCard(
                  title: '会话信息',
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.tune_rounded),
                        title: const Text('房间管理'),
                        subtitle: const Text('资料、成员与消息设置'),
                        trailing: const Icon(Icons.chevron_right_rounded),
                        onTap: onManage,
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
            data: (loaded) => SliverToBoxAdapter(
              child: GroupedRows(
                children: [
                  ListTile(
                    leading: const Icon(Icons.group_outlined),
                    title: Text('成员 ${loaded.length}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => MaterialListDetail.push(
                      context,
                      MaterialPageRoute<void>(
                        builder: (_) => Scaffold(
                          appBar: buildFloatingAppBar(title: const Text('成员')),
                          body: Consumer(
                            builder: (context, ref, _) => ref
                                .watch(membersProvider)
                                .when(
                                  data: (people) => people.isEmpty
                                      ? const Center(child: Text('暂无成员'))
                                      : ListView.builder(
                                          itemCount: people.length,
                                          itemBuilder: (context, index) {
                                            final member = people[index];
                                            return Padding(
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: NeuSpacing.lg,
                                                    vertical: NeuSpacing.sm,
                                                  ),
                                              child: MaterialMemberIdentity(
                                                name: member.name,
                                                userId: member.id,
                                                avatarUrl: member.avatarUrl,
                                              ),
                                            );
                                          },
                                        ),
                                  loading: () => const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                  error: (_, _) => Center(
                                    child: TextButton(
                                      onPressed: () =>
                                          ref.invalidate(membersProvider),
                                      child: const Text('重试'),
                                    ),
                                  ),
                                ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
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
