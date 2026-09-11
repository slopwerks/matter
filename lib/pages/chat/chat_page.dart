import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../providers/connection_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/cascade_title.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import 'create_chat_page.dart';
import 'chat_list_item.dart';
import 'search_page.dart';

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
  void _openSearch() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const ChatSearchPage()));
  }

  void _openCreateChat() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const CreateChatPage()));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
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

    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: CascadeTitle(
                  text: titleText,
                  style: Theme.of(context).textTheme.titleLarge!,
                ),
              ),
              NeuIconButton(
                icon: Icons.edit_square,
                tooltip: '新聊天',
                onPressed: _openCreateChat,
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            NeuSpacing.lg,
            NeuSpacing.xs,
            NeuSpacing.lg,
            0,
          ),
          // 只读入口:点击进入独立搜索页。
          child: NeuAction(
            key: const ValueKey('open-chat-search'),
            label: '搜索消息或聊天',
            onTap: _openSearch,
            child: const ExcludeFocus(
              child: ExcludeSemantics(
                child: IgnorePointer(
                  child: NeuTextField(
                    hint: '搜索消息或聊天',
                    leading: Icon(Icons.search),
                  ),
                ),
              ),
            ),
          ),
        ),
        Expanded(
          child: roomsAsync.when(
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
                return Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.forum_outlined,
                          size: 44,
                          color: colors.textSecondary,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          widget.emptyLabel ?? '暂无聊天',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      ],
                    ),
                  ),
                );
              }
              return ListView.separated(
                // 与联系人页同节奏:列表上 8、卡片间距 12。
                padding: EdgeInsets.fromLTRB(
                  NeuSpacing.lg,
                  NeuSpacing.sm,
                  NeuSpacing.lg,
                  widget.embedded ? NeuSpacing.xl : NeuSpacing.navClearance,
                ),
                itemCount: rooms.length,
                separatorBuilder: (_, _) =>
                    const SizedBox(height: NeuSpacing.md),
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
            loading: () => Center(
              child: CircularProgressIndicator(
                color: colors.accent,
                strokeWidth: 2,
              ),
            ),
            error: (err, _) => Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: SelectableText(
                  '加载失败: $err',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
            ),
          ),
        ),
      ],
    );

    if (widget.embedded) {
      return ColoredBox(color: colors.base, child: content);
    }
    return Scaffold(body: content);
  }
}
