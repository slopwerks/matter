import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../providers/connection_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cascade_title.dart';
import 'chat_list_item.dart';
import 'space_detail_page.dart';

class SpacePage extends ConsumerWidget {
  const SpacePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(spacesProvider);
    final ungroupedAsync = ref.watch(ungroupedRoomsProvider);
    final connectionLabel = ref.watch(connectionLabelProvider);
    final titleText = connectionLabel.isNotEmpty ? connectionLabel : '空间';

    return Scaffold(
      body: Stack(
        children: [
          CustomScrollView(
            slivers: [
              SliverAppBar(
                floating: true,
                pinned: true,
                expandedHeight: 56,
                collapsedHeight: 56,
                toolbarHeight: 56,
                flexibleSpace: FlexibleSpaceBar(
                  titlePadding: const EdgeInsets.only(left: 16, bottom: 12),
                  title: CascadeTitle(
                    text: titleText,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: AppColors.onBackground,
                      letterSpacing: -0.5,
                    ),
                  ),
                ),
                backgroundColor: AppColors.background.withValues(alpha: 0.85),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              spacesAsync.when(
                data: (spaces) {
                  if (spaces.isEmpty) {
                    return const SliverToBoxAdapter(
                      child: _SectionCard(
                        title: '空间',
                        subtitle: '暂无已加入空间',
                        child: _HintText('当前账号还没有可浏览的空间。'),
                      ),
                    );
                  }

                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '空间',
                      subtitle: '用于组织房间和成员，不直接作为聊天入口',
                      child: Column(
                        children: [
                          for (final space in spaces)
                            _SpaceRoomTile(
                              space: space,
                              key: ValueKey(space.id),
                            ),
                        ],
                      ),
                    ),
                  );
                },
                loading: () => const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
                error: (err, _) => SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      '加载空间失败: $err',
                      style: const TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
              const SliverToBoxAdapter(child: SizedBox(height: 12)),
              ungroupedAsync.when(
                data: (rooms) {
                  return SliverToBoxAdapter(
                    child: _SectionCard(
                      title: '未归属群组',
                      subtitle: '这些房间当前不属于任何已加入空间',
                      child: rooms.isEmpty
                          ? const _HintText('暂无普通房间')
                          : Column(
                              children: [
                                for (final room in rooms)
                                  ChatListItem(
                                    room: room,
                                    dense: true,
                                    showRoomTypeIcon: true,
                                  ),
                              ],
                            ),
                    ),
                  );
                },
                loading: () =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
                error: (_, _) =>
                    const SliverToBoxAdapter(child: SizedBox.shrink()),
              ),
              const SliverPadding(padding: EdgeInsets.only(bottom: 96)),
            ],
          ),
          Positioned(
            right: 16,
            bottom: 96,
            child: FloatingActionButton(
              onPressed: () => _showSpaceActions(context),
              backgroundColor: AppColors.secondary,
              elevation: 2,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
              child: const Icon(
                Icons.add_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _showSpaceActions(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _ActionTile(
                icon: Icons.create_new_folder_rounded,
                title: '创建空间',
                subtitle: '创建一个新的组织空间',
                onTap: () {
                  Navigator.of(context).pop();
                  _showCreateSpaceDialog(context);
                },
              ),
              _ActionTile(
                icon: Icons.travel_explore_rounded,
                title: '加入空间',
                subtitle: '通过空间 ID 或链接加入',
                onTap: () {
                  Navigator.of(context).pop();
                  _showJoinSpaceDialog(context);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showCreateSpaceDialog(BuildContext context) {
    final nameController = TextEditingController();
    final topicController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (context, ref, _) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '创建空间',
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
              const SizedBox(height: 10),
              TextField(
                controller: topicController,
                style: const TextStyle(color: AppColors.onBackground),
                decoration: const InputDecoration(
                  hintText: '空间说明（可选）',
                  hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
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
                  await createSpace(
                    name: name,
                    topic: topic.isEmpty ? null : topic,
                  );
                  ref.invalidate(spacesProvider);
                  ref.invalidate(chatRoomsProvider);
                  if (!ctx.mounted || !context.mounted) return;
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('空间已创建')));
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('创建失败: $e')));
                }
              },
              child: const Text(
                '创建',
                style: TextStyle(color: AppColors.secondary),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showJoinSpaceDialog(BuildContext context) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => Consumer(
        builder: (context, ref, _) => AlertDialog(
          backgroundColor: AppColors.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          title: const Text(
            '加入空间',
            style: TextStyle(color: AppColors.onBackground),
          ),
          content: TextField(
            controller: controller,
            style: const TextStyle(color: AppColors.onBackground),
            decoration: const InputDecoration(
              hintText: '!space_id:server 或 #alias:server',
              hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text(
                '取消',
                style: TextStyle(color: AppColors.onSurfaceVariant),
              ),
            ),
            TextButton(
              onPressed: () async {
                final value = controller.text.trim();
                if (value.isEmpty) return;
                try {
                  await joinRoom(identifier: value);
                  ref.invalidate(spacesProvider);
                  ref.invalidate(chatRoomsProvider);
                  ref.invalidate(ungroupedRoomsProvider);
                  if (!ctx.mounted || !context.mounted) return;
                  Navigator.of(ctx).pop();
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已加入空间')));
                } catch (e) {
                  if (!context.mounted) return;
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(SnackBar(content: Text('加入失败: $e')));
                }
              },
              child: const Text(
                '加入',
                style: TextStyle(color: AppColors.secondary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SpaceRoomTile extends StatelessWidget {
  final Space space;

  const _SpaceRoomTile({super.key, required this.space});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.surface),
        onTap: () {
          Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => SpaceDetailPage(space: space)),
          );
        },
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadii.surface),
          ),
          child: Row(
            children: [
              _SpaceAvatar(name: space.name),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      space.name,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '查看房间、成员和空间设置',
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
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

class _SectionCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final Widget child;

  const _SectionCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
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
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              subtitle,
              style: const TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 13,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 14),
            child,
          ],
        ),
      ),
    );
  }
}

class _HintText extends StatelessWidget {
  final String text;

  const _HintText(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppColors.onSurfaceVariant,
        fontSize: 13,
        height: 1.4,
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _ActionTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.secondary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: const TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 13,
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
}

class _SpaceAvatar extends StatelessWidget {
  final String name;

  const _SpaceAvatar({required this.name});

  @override
  Widget build(BuildContext context) {
    final initial = name.trim().isEmpty ? '空' : name.trim().characters.first;
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: AppColors.secondary.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(AppRadii.content),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: const TextStyle(
          color: AppColors.secondary,
          fontSize: 18,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
