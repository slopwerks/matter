import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../providers/hidden_rooms_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import 'chat_detail_page.dart';

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
      appBar: AppBar(
        backgroundColor: context.neu.base,
        elevation: 0,
        title: Text('隐藏的聊天', style: Theme.of(context).textTheme.titleLarge),
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
            return const Center(child: Text('暂无隐藏的聊天'));
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 96),
            itemCount: hiddenRooms.length,
            separatorBuilder: (_, _) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final room = hiddenRooms[index];
              final selected = _selectedRoomIds.contains(room.id);
              return NeuAction(
                label: room.name,
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
                child: Padding(
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
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ),
                      if (selected)
                        Icon(
                          Icons.check_circle_rounded,
                          color: context.neu.accent,
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
          );
        },
      ),
      floatingActionButton: _selectionMode
          ? FloatingActionButton.extended(
              onPressed: _unhideSelected,
              icon: const Icon(Icons.visibility_outlined),
              label: Text('显示 ${_selectedRoomIds.length} 个聊天'),
            )
          : null,
    );
  }
}
