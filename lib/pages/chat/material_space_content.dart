import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/matrix.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/material_press.dart';
import 'chat_list_item.dart';
import 'space_detail_page.dart';

/// Material space directory, with standalone cards above the remaining rooms.
class MaterialSpaceContent extends StatelessWidget {
  const MaterialSpaceContent({
    super.key,
    required this.spaces,
    required this.rooms,
    required this.onCreate,
    required this.onJoin,
  });

  final AsyncValue<List<Space>> spaces;
  final AsyncValue<List<ChatRoom>> rooms;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final titleStyle = theme.textTheme.titleMedium!;
    final titleLineHeight =
        MediaQuery.textScalerOf(context).scale(titleStyle.fontSize!) *
        (titleStyle.height ?? 1.5);
    // Reserve two title lines, including when accessibility text is enlarged.
    final cardHeight = math.max(48.0, titleLineHeight * 2) + 32;

    return LayoutBuilder(
      builder: (context, constraints) {
        final gutter = math.max(16.0, (constraints.maxWidth - 960) / 2);
        final columns = constraints.maxWidth - gutter * 2 >= 600 ? 2 : 1;
        return CustomScrollView(
          slivers: [
            SliverPadding(
              padding: EdgeInsets.fromLTRB(
                gutter,
                // Scaffold exposes the full floating header inset in padding.
                MediaQuery.paddingOf(context).top + 16,
                gutter,
                96 + MediaQuery.paddingOf(context).bottom,
              ),
              sliver: SliverMainAxisGroup(
                slivers: [
                  spaces.when(
                    data: (items) => items.isEmpty
                        ? SliverToBoxAdapter(
                            child: _EmptySpaces(
                              onCreate: onCreate,
                              onJoin: onJoin,
                            ),
                          )
                        : SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: columns,
                                  mainAxisExtent: cardHeight,
                                  crossAxisSpacing: 12,
                                  mainAxisSpacing: 12,
                                ),
                            itemCount: items.length,
                            itemBuilder: (context, index) => _SpaceCard(
                              key: ValueKey(items[index].id),
                              space: items[index],
                            ),
                          ),
                    loading: () => const SliverToBoxAdapter(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                    error: (error, _) => SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 24),
                        child: Text(
                          '加载空间失败: $error',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ),
                  ),
                  rooms.when(
                    data: (items) => items.isEmpty
                        ? const SliverToBoxAdapter(child: SizedBox.shrink())
                        : SliverMainAxisGroup(
                            slivers: [
                              const SliverToBoxAdapter(
                                child: _OtherRoomsHeader(),
                              ),
                              SliverList.separated(
                                itemCount: items.length,
                                separatorBuilder: (_, _) =>
                                    const ChatListDivider(),
                                itemBuilder: (context, index) => ChatListItem(
                                  key: ValueKey(items[index].id),
                                  room: items[index],
                                  showRoomTypeIcon: true,
                                ),
                              ),
                            ],
                          ),
                    loading: () =>
                        const SliverToBoxAdapter(child: SizedBox.shrink()),
                    error: (_, _) =>
                        const SliverToBoxAdapter(child: SizedBox.shrink()),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _SpaceCard extends StatelessWidget {
  const _SpaceCard({super.key, required this.space});

  final Space space;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return MaterialPress(
      builder: (states) => Card(
        child: InkWell(
          statesController: states,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SpaceDetailPage(space: space),
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                AppAvatar(fallback: space.name, size: 48, url: space.avatarUrl),
                const SizedBox(width: 16),
                Expanded(
                  child: Text(
                    space.name,
                    style: theme.textTheme.titleMedium,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  Icons.chevron_right_rounded,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptySpaces extends StatelessWidget {
  const _EmptySpaces({required this.onCreate, required this.onJoin});

  final VoidCallback onCreate;
  final VoidCallback onJoin;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Column(
        children: [
          Icon(
            Icons.workspaces_outline,
            size: 48,
            color: theme.colorScheme.primary,
          ),
          const SizedBox(height: 16),
          Text(
            '还没有加入空间',
            style: theme.textTheme.titleLarge,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 8),
          Text(
            '用空间整理相关房间',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 12,
            runSpacing: 12,
            children: [
              FilledButton.icon(
                onPressed: onCreate,
                icon: const Icon(Icons.create_new_folder_outlined),
                label: const Text('创建空间'),
              ),
              OutlinedButton.icon(
                onPressed: onJoin,
                icon: const Icon(Icons.travel_explore_rounded),
                label: const Text('加入空间'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _OtherRoomsHeader extends StatelessWidget {
  const _OtherRoomsHeader();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 24, 0, 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              '其他房间',
              style: theme.textTheme.titleSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          IconButton(
            tooltip: '关于其他房间',
            icon: const Icon(Icons.info_outline_rounded, size: 20),
            onPressed: () => showDialog<void>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('其他房间'),
                content: const Text('这些房间当前不属于任何已加入空间。'),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('知道了'),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
