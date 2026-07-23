import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../providers/connection_provider.dart';
import '../../theme/app_theme.dart';
import '../../widgets/cascade_title.dart';
import 'create_chat_page.dart';
import 'chat_list_item.dart';
import 'search_bar.dart';

class ChatPage extends ConsumerStatefulWidget {
  final ValueChanged<ChatRoom>? onRoomSelected;
  final String? selectedRoomId;
  final bool embedded;
  final String? title;
  final String? emptyLabel;
  final String? spaceId;
  final bool directMessagesOnly;
  final bool ungroupedRoomsOnly;

  const ChatPage({
    super.key,
    this.onRoomSelected,
    this.selectedRoomId,
    this.embedded = false,
    this.title,
    this.emptyLabel,
    this.spaceId,
    this.directMessagesOnly = false,
    this.ungroupedRoomsOnly = false,
  }) : assert(!directMessagesOnly || !ungroupedRoomsOnly);

  @override
  ConsumerState<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends ConsumerState<ChatPage> {
  @override
  Widget build(BuildContext context) {
    final AsyncValue<List<ChatRoom>> roomsAsync;
    if (widget.spaceId case final spaceId?) {
      roomsAsync = ref.watch(spaceChildrenProvider(spaceId));
    } else if (widget.directMessagesOnly) {
      roomsAsync = ref
          .watch(inboxRoomsProvider)
          .whenData(
            (rooms) => rooms.where((room) => room.roomType == 'dm').toList(),
          );
    } else if (widget.ungroupedRoomsOnly) {
      roomsAsync = ref
          .watch(ungroupedRoomsProvider)
          .whenData(
            (rooms) => rooms.where((room) => room.roomType != 'dm').toList(),
          );
    } else {
      roomsAsync = ref.watch(inboxRoomsProvider);
    }
    final connectionLabel = ref.watch(connectionLabelProvider);

    final titleText =
        widget.title ??
        (connectionLabel.isNotEmpty ? connectionLabel : 'Matter');

    final content = Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverAppBar(
              floating: !widget.embedded,
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
              backgroundColor: widget.embedded
                  ? AppColors.background
                  : AppColors.background.withValues(alpha: 0.85),
            ),
            const SliverToBoxAdapter(child: ChatSearchBar()),
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
            roomsAsync.when(
              data: (rooms) {
                if (widget.onRoomSelected != null &&
                    widget.selectedRoomId == null) {
                  final firstJoinedRoom = rooms.where(
                    (room) => room.roomState == 'joined',
                  );
                  if (firstJoinedRoom.isNotEmpty) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) {
                        widget.onRoomSelected!(firstJoinedRoom.first);
                      }
                    });
                  }
                }
                if (rooms.isEmpty) {
                  return SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.all(40),
                      child: Center(
                        child: Text(
                          widget.emptyLabel ?? '暂无聊天',
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  );
                }
                return SliverList.separated(
                  itemCount: rooms.length,
                  separatorBuilder: (context, index) => widget.embedded
                      ? const SizedBox(height: 2)
                      : const Divider(
                          color: Color(0xFF1E242C),
                          thickness: 0.5,
                          height: 0.5,
                        ),
                  itemBuilder: (context, index) {
                    final room = rooms[index];
                    return ChatListItem(
                      room: room,
                      isSelected: room.id == widget.selectedRoomId,
                      onRoomSelected: widget.onRoomSelected,
                    );
                  },
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
                  padding: const EdgeInsets.all(32),
                  child: Center(
                    child: SelectableText(
                      '加载失败: $err',
                      style: const TextStyle(color: AppColors.onSurfaceVariant),
                    ),
                  ),
                ),
              ),
            ),
            SliverPadding(
              padding: EdgeInsets.only(bottom: widget.embedded ? 80 : 96),
            ),
          ],
        ),
        Positioned(
          right: 16,
          bottom: widget.embedded ? 16 : 96,
          child: FloatingActionButton(
            mini: widget.embedded,
            onPressed: () {
              Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const CreateChatPage()));
            },
            backgroundColor: AppColors.primary,
            elevation: 2,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(
              Icons.add_rounded,
              color: Colors.white,
              size: widget.embedded ? 20 : 24,
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return ColoredBox(color: AppColors.background, child: content);
    }
    return Scaffold(body: content);
  }
}
