import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../theme/tokens.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/material_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/material_press.dart';
import '../../widgets/material_search_header.dart';
import '../../widgets/app_search_field.dart';
import 'room_directory_page.dart';
import '../../widgets/material_list_detail.dart';
import 'chat_list_item.dart';
import 'space_detail_page.dart';

/// Material space directory, with a compact list above the remaining rooms.
class MaterialSpaceContent extends StatefulWidget {
  const MaterialSpaceContent({
    super.key,
    required this.title,
    this.onAdd,
    required this.spaces,
    required this.rooms,
    required this.onCreate,
    required this.onJoin,
  });

  final AsyncValue<List<Space>> spaces;
  final AsyncValue<List<ChatRoom>> rooms;
  final VoidCallback onCreate;
  final VoidCallback onJoin;

  final String title;
  final VoidCallback? onAdd;
  @override
  State<MaterialSpaceContent> createState() => _MaterialSpaceContentState();
}

class _MaterialSpaceContentState extends State<MaterialSpaceContent> {
  final _search = TextEditingController();
  String _query = '';
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      resizeToAvoidBottomInset: false,
      floatingActionButton: widget.onAdd == null
          ? null
          : FloatingActionButton(
              tooltip: '添加空间',
              onPressed: widget.onAdd,
              child: const Icon(Icons.add),
            ),
      body: MaterialSearchDirectory(
        title: widget.title,
        hint: '搜索已加入的空间',
        query: _search.text,
        actions: [
          IconButton(
            tooltip: '探索公开房间',
            icon: const Icon(Icons.explore_outlined),
            onPressed: () => RoomDirectoryPage.open(context),
          ),
        ],
        searchBuilder: (focus) => AppSearchField(
          focusNode: focus,
          controller: _search,
          hint: '搜索已加入的空间',
          onChanged: (value) =>
              setState(() => _query = value.trim().toLowerCase()),
          trailing: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  icon: const Icon(Icons.close),
                  onPressed: () {
                    _search.clear();
                    setState(() => _query = '');
                  },
                ),
        ),
        body: LayoutBuilder(
          builder: (context, constraints) {
            final gutter = math.max(16.0, (constraints.maxWidth - 960) / 2);
            return CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    gutter,
                    context.tokens.spacing.lg,
                    gutter,
                    math.max(
                      96 + MediaQuery.paddingOf(context).bottom,
                      MediaQuery.viewInsetsOf(context).bottom +
                          context.tokens.spacing.lg,
                    ),
                  ),
                  sliver: SliverMainAxisGroup(
                    slivers: [
                      widget.spaces.when(
                        data: (spaces) {
                          final items = spaces
                              .where(
                                (space) =>
                                    space.name.toLowerCase().contains(_query) ||
                                    space.id.toLowerCase().contains(_query),
                              )
                              .toList();
                          if (items.isEmpty && _query.isNotEmpty) {
                            return const SliverToBoxAdapter(
                              child: Text('没有匹配的空间'),
                            );
                          }
                          return items.isEmpty
                              ? SliverToBoxAdapter(
                                  child: _EmptySpaces(
                                    onCreate: widget.onCreate,
                                    onJoin: widget.onJoin,
                                  ),
                                )
                              : SliverList.builder(
                                  itemCount: items.length,
                                  itemBuilder: (context, index) => _SpaceRow(
                                    key: ValueKey(items[index].id),
                                    space: items[index],
                                  ),
                                );
                        },
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
                      if (_query.isEmpty)
                        widget.rooms.when(
                          data: (items) => items.isEmpty
                              ? const SliverToBoxAdapter(
                                  child: SizedBox.shrink(),
                                )
                              : SliverMainAxisGroup(
                                  slivers: [
                                    const SliverToBoxAdapter(
                                      child: _OtherRoomsHeader(),
                                    ),
                                    SliverList.separated(
                                      itemCount: items.length,
                                      separatorBuilder: (_, _) =>
                                          const ChatListDivider(),
                                      itemBuilder: (context, index) =>
                                          ChatListItem(
                                            key: ValueKey(items[index].id),
                                            room: items[index],
                                            showRoomTypeIcon: true,
                                          ),
                                    ),
                                  ],
                                ),
                          loading: () => const SliverToBoxAdapter(
                            child: SizedBox.shrink(),
                          ),
                          error: (_, _) => const SliverToBoxAdapter(
                            child: SizedBox.shrink(),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _SpaceRow extends ConsumerWidget {
  const _SpaceRow({super.key, required this.space});

  final Space space;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final tokens = context.tokens;
    final rooms = ref
        .watch(spaceChildrenProvider(space.id))
        .value
        ?.where((room) => room.roomType != 'space');
    final details = ref.watch(spaceDetailsProvider(space.id)).value;
    final topic = details?.topic?.trim();
    final summary = [
      if (rooms != null) '${rooms.length} 个房间',
      if (details != null) topic == null || topic.isEmpty ? '暂无话题' : topic,
    ].join(' · ');
    var unread = 0;
    if (rooms != null) {
      for (final room in rooms) {
        if (roomHasUnread(
          room,
          ref.watch(roomUnreadOverrideProvider(room.id)),
        )) {
          unread += math.max(1, room.unreadCount);
        }
      }
    }
    return MaterialPress(
      builder: (states) => InkWell(
        customBorder: materialListItemShape,
        statesController: states,
        onTap: () => MaterialListDetail.push(
          context,
          MaterialPageRoute<void>(
            builder: (_) => SpaceDetailPage(space: space),
          ),
        ),
        child: Padding(
          padding: EdgeInsets.all(tokens.spacing.sm),
          child: Row(
            spacing: materialListContentGap,
            children: [
              AppAvatar(
                fallback: space.name,
                size: materialListAvatarSize,
                url: space.avatarUrl,
                materialRadius: tokens.radii.thumbnail,
                fallbackColors: materialSpaceAvatarStyle(
                  theme,
                  space.id.hashCode,
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      spacing: tokens.spacing.sm,
                      children: [
                        Expanded(
                          child: Text(
                            space.name,
                            style: tokens.typography.listTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (unread > 0)
                          Semantics(
                            label: '$unread 条未读',
                            excludeSemantics: true,
                            child: Badge.count(count: unread),
                          ),
                      ],
                    ),
                    Text(
                      summary,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ],
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
