import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_component_theme.dart';
import '../../theme/material_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/app_search_field.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';
import 'chat_list_item.dart' show ChatListDivider;

/// M3 presentation; filtering and sending remain in the sheet's stateful host.
class MaterialForwardMessagePicker extends StatelessWidget {
  const MaterialForwardMessagePicker({
    super.key,
    required this.message,
    required this.sourceRoomId,
    required this.rooms,
    required this.controller,
    required this.query,
    required this.sendingRoomId,
    required this.onQueryChanged,
    required this.onForward,
    required this.onClose,
  });

  final rust.ChatMessage message;
  final String sourceRoomId;
  final AsyncValue<List<rust.ChatRoom>> rooms;
  final TextEditingController controller;
  final String query;
  final String? sendingRoomId;
  final ValueChanged<String> onQueryChanged;
  final ValueChanged<rust.ChatRoom> onForward;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: FractionallySizedBox(
        heightFactor: .72,
        child: Material(
          color: theme.bottomSheetTheme.backgroundColor,
          shape: theme.bottomSheetTheme.shape,
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 12, 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          '转发到',
                          style: theme.textTheme.headlineSmall,
                        ),
                      ),
                      MaterialToolbar(
                        child: NeuIconButton(
                          icon: Icons.close_rounded,
                          tooltip: '关闭',
                          size: 40,
                          onPressed: onClose,
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: IgnorePointer(
                    ignoring: sendingRoomId != null,
                    child: AppSearchField(
                      key: const ValueKey('forward-room-search'),
                      controller: controller,
                      hint: '搜索会话',
                      onChanged: onQueryChanged,
                      trailing: query.isEmpty
                          ? null
                          : IconButton(
                              tooltip: '清除搜索',
                              icon: const Icon(Icons.close_rounded),
                              onPressed: () {
                                controller.clear();
                                onQueryChanged('');
                              },
                            ),
                    ),
                  ),
                ),
                const Divider(height: 1),
                Expanded(
                  child: rooms.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, _) => _empty(context, '加载会话失败: $error'),
                    data: (rooms) => ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
                      itemCount: rooms.length + 2,
                      separatorBuilder: (_, index) => index < 2
                          ? const SizedBox(height: 12)
                          : const ChatListDivider(),
                      itemBuilder: (context, index) {
                        if (index == 0) {
                          return MaterialDetailCard(
                            title: '待转发的消息',
                            description: message.senderName,
                            child: Text(
                              message.msgType == rust.MessageType.image
                                  ? message.caption ??
                                        message.sharedCaption ??
                                        message.content
                                  : message.content,
                              maxLines: 3,
                              overflow: TextOverflow.ellipsis,
                            ),
                          );
                        }
                        if (index == 1) {
                          if (rooms.isEmpty) {
                            return _empty(
                              context,
                              query.trim().isEmpty ? '暂无可转发的会话' : '未找到会话',
                            );
                          }
                          return Text(
                            '选择会话 · ${rooms.length}\n点击会话立即转发。',
                            style: theme.textTheme.bodySmall,
                          );
                        }
                        final room = rooms[index - 2];
                        final sending = room.id == sendingRoomId;
                        return NeuAction(
                          key: ValueKey('forward-room-${room.id}'),
                          label: room.name,
                          selected: sending,
                          radius: materialSurfaceRadius,
                          onTap: sendingRoomId == null
                              ? () => onForward(room)
                              : null,
                          child: Ink(
                            color: sending
                                ? AppComponentTheme.of(context).selectedRowFill
                                : null,
                            child: ListTile(
                              enabled: sendingRoomId == null,
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 8,
                              ),
                              horizontalTitleGap: materialListContentGap,
                              leading: AppAvatar(
                                fallback: room.name,
                                url: room.avatarUrl,
                                size: materialListAvatarSize,
                              ),
                              title: Text(
                                room.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              titleTextStyle: materialListTitleStyle(theme),
                              subtitle: Text(
                                room.id == sourceRoomId
                                    ? '当前会话'
                                    : room.lastMessage.isNotEmpty
                                    ? room.lastMessage
                                    : room.roomType == 'dm'
                                    ? '私聊'
                                    : '群聊',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: sending
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.forward_rounded),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _empty(BuildContext context, String text) => Padding(
    padding: const EdgeInsets.all(24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.forum_outlined, size: 36),
        const SizedBox(height: 12),
        Text(
          text,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        if (query.trim().isNotEmpty) ...[
          const SizedBox(height: 8),
          Text('试试其他会话名称。', style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    ),
  );
}
