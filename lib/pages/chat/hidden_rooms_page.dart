import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../providers/hidden_rooms_provider.dart';
import '../../theme/app_component_theme.dart';
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_action.dart';
import 'chat_detail_page.dart';
import 'chat_list_item.dart' show ChatListDivider;

class HiddenRoomsPage extends ConsumerStatefulWidget {
  const HiddenRoomsPage({super.key});

  @override
  ConsumerState<HiddenRoomsPage> createState() => _HiddenRoomsPageState();
}

class _HiddenRoomsPageState extends ConsumerState<HiddenRoomsPage> {
  final _selectedRoomIds = <String>{};

  bool get _selectionMode => _selectedRoomIds.isNotEmpty;

  void _toggleSelection(String roomId) {
    setState(() {
      if (!_selectedRoomIds.add(roomId)) _selectedRoomIds.remove(roomId);
    });
  }

  Future<void> _unhideSelected() async {
    final ids = _selectedRoomIds.toList();
    if (ids.isEmpty) return;
    await ref.read(hiddenRoomsProvider.notifier).unhideRooms(ids);
    if (mounted) setState(_selectedRoomIds.clear);
  }

  @override
  Widget build(BuildContext context) {
    final roomsAsync = ref.watch(allChatRoomsProvider);
    ref.watch(hiddenRoomsProvider);
    final hidden = ref.read(hiddenRoomsProvider.notifier);
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(
        title: Text('隐藏的聊天', style: Theme.of(context).textTheme.headlineSmall),
        actions: [
          if (_selectionMode)
            IconButton(
              tooltip: '取消选择',
              icon: const Icon(Icons.close_rounded),
              onPressed: () => setState(_selectedRoomIds.clear),
            ),
        ],
      ),
      body: roomsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('加载隐藏聊天失败: $error')),
        data: (rooms) {
          final hiddenRooms = rooms
              .where(hidden.isHidden)
              .where((room) => room.roomType != 'space')
              .toList();
          if (hiddenRooms.isEmpty) {
            if (context.isMaterial) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility_off_outlined,
                        size: 48,
                        color: context.neu.textSecondary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        '暂无隐藏的聊天',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        '隐藏的聊天会出现在这里，可随时恢复到聊天列表。',
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              );
            }
            return const Center(child: Text('暂无隐藏的聊天'));
          }
          final material = context.isMaterial;
          return MaxContentWidth(
            maxWidth: material ? 720 : double.infinity,
            child: ListView.separated(
              padding: EdgeInsets.fromLTRB(
                16,
                MediaQuery.viewPaddingOf(context).top + kToolbarHeight + 8,
                16,
                96,
              ),
              itemCount: hiddenRooms.length + (material ? 1 : 0),
              separatorBuilder: (_, index) => material && index == 0
                  ? const SizedBox(height: 16)
                  : material
                  ? const ChatListDivider()
                  : const Divider(height: 1),
              itemBuilder: (context, index) {
                if (material && index == 0) {
                  return MaterialDetailCard(
                    title: _selectionMode
                        ? '已选择 ${_selectedRoomIds.length} 个聊天'
                        : '${hiddenRooms.length} 个隐藏的聊天',
                    description: '恢复后重新显示在聊天列表中。',
                    child: Text(
                      _selectionMode
                          ? '点击聊天继续选择，或使用右下角按钮批量恢复。'
                          : '长按聊天可多选，也可以单独恢复。',
                    ),
                  );
                }
                final room = hiddenRooms[index - (material ? 1 : 0)];
                final selected = _selectedRoomIds.contains(room.id);
                return NeuAction(
                  label: room.name,
                  selected: material ? selected : null,
                  radius: material ? 0 : NeuRadius.button,
                  onTap: _selectionMode
                      ? () => _toggleSelection(room.id)
                      : () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => ChatDetailPage(
                              roomId: room.id,
                              roomName: room.name,
                              avatarUrl: room.avatarUrl,
                              nameEventId: room.nameEventId,
                              avatarEventId: room.avatarEventId,
                              isDm: room.roomType == 'dm',
                            ),
                          ),
                        ),
                  onLongPress: () => _toggleSelection(room.id),
                  child: material
                      ? Ink(
                          color: selected
                              ? AppComponentTheme.of(context).selectedRowFill
                              : Colors.transparent,
                          child: ListTile(
                            contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 4,
                            ),
                            horizontalTitleGap: 12,
                            selected: selected,
                            leading: AppAvatar(
                              fallback: room.name,
                              size: materialListAvatarSize,
                              url: room.avatarUrl,
                            ),
                            title: Text(
                              room.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            titleTextStyle: materialListTitleStyle(
                              Theme.of(context),
                            ),
                            subtitle: const Text('已隐藏'),
                            trailing: _selectionMode
                                ? Checkbox(
                                    value: selected,
                                    onChanged: (_) => _toggleSelection(room.id),
                                  )
                                : OutlinedButton(
                                    onPressed: () => ref
                                        .read(hiddenRoomsProvider.notifier)
                                        .unhideRooms([room.id]),
                                    child: const Text('恢复'),
                                  ),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 10,
                          ),
                          child: Row(
                            children: [
                              AppAvatar(
                                fallback: room.name,
                                size: 46,
                                url: room.avatarUrl,
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  room.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleMedium,
                                ),
                              ),
                              if (_selectionMode)
                                Checkbox(
                                  value: selected,
                                  onChanged: (_) => _toggleSelection(room.id),
                                )
                              else
                                IconButton(
                                  tooltip: '显示聊天',
                                  icon: const Icon(Icons.visibility_outlined),
                                  onPressed: () => ref
                                      .read(hiddenRoomsProvider.notifier)
                                      .unhideRooms([room.id]),
                                ),
                            ],
                          ),
                        ),
                );
              },
            ),
          );
        },
      ),
      floatingActionButton: _selectionMode
          ? context.isMaterial
                ? FloatingActionButton(
                    tooltip: '显示 ${_selectedRoomIds.length} 个聊天',
                    onPressed: _unhideSelected,
                    child: const Icon(Icons.visibility_outlined),
                  )
                : FloatingActionButton.extended(
                    onPressed: _unhideSelected,
                    icon: const Icon(Icons.visibility_outlined),
                    label: Text('显示 ${_selectedRoomIds.length} 个聊天'),
                  )
          : null,
    );
  }
}
