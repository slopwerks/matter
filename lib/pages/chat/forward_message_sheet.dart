import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_field.dart';

typedef ForwardMessageSender =
    Future<void> Function({
      required String sourceRoomId,
      required String targetRoomId,
      required rust.ChatMessage message,
    });

List<rust.ChatRoom> forwardableRooms(List<rust.ChatRoom> rooms, String query) {
  final normalizedQuery = query.trim().toLowerCase();
  return rooms.where((room) {
    if (room.roomType == 'space' || room.roomState != 'joined') return false;
    return normalizedQuery.isEmpty ||
        room.name.toLowerCase().contains(normalizedQuery);
  }).toList();
}

Future<void> _sendForward({
  required String sourceRoomId,
  required String targetRoomId,
  required rust.ChatMessage message,
}) async {
  // Forwarding changes context: mentions from the source room are no longer
  // valid in the target room (a mentioned user may not be a member there, or
  // may receive an unexpected push). Pass empty mentions so build_text_content
  // still emits an m.mentions object (avoiding legacy implicit-mention push
  // rules) without carrying stale user IDs across rooms.
  await rust.forwardMessage(
    sourceRoomId: sourceRoomId,
    targetRoomId: targetRoomId,
    eventId: message.id,
    text: rust.FormattedMessageInput(
      body: message.content,
      formattedBody: message.formattedBody,
      mentionedUserIds: const [],
      mentionsRoom: false,
    ),
  );
}

Future<rust.ChatRoom?> showForwardMessageSheet({
  required BuildContext context,
  required String sourceRoomId,
  required rust.ChatMessage message,
  ForwardMessageSender sender = _sendForward,
}) async {
  return showModalBottomSheet<rust.ChatRoom>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => ForwardMessageSheet(
      sourceRoomId: sourceRoomId,
      message: message,
      sender: sender,
    ),
  );
}

class ForwardSuccessNotice extends StatelessWidget {
  final String roomName;
  final VoidCallback onRoomTap;

  const ForwardSuccessNotice({
    super.key,
    required this.roomName,
    required this.onRoomTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Material(
          key: const ValueKey('forward-success-notice-surface'),
          color: colors.surfaceStrong,
          elevation: 8,
          shadowColor: Colors.black54,
          borderRadius: BorderRadius.circular(NeuRadius.button),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
            child: Wrap(
              alignment: WrapAlignment.center,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  '成功转发到',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: colors.text),
                ),
                Semantics(
                  link: true,
                  label: '前往$roomName',
                  child: InkWell(
                    key: const ValueKey('forward-success-room-link'),
                    onTap: onRoomTap,
                    child: Text(
                      roomName,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: colors.accent,
                        decoration: TextDecoration.underline,
                        decorationColor: colors.accent,
                      ),
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
}

class ForwardSuccessNoticeOverlay extends StatelessWidget {
  final double bottomInset;
  final String roomName;
  final VoidCallback onRoomTap;

  const ForwardSuccessNoticeOverlay({
    super.key,
    required this.bottomInset,
    required this.roomName,
    required this.onRoomTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedPositioned(
      left: 16,
      right: 16,
      bottom: bottomInset + 12,
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      child: ForwardSuccessNotice(roomName: roomName, onRoomTap: onRoomTap),
    );
  }
}

class ForwardMessageSheet extends ConsumerStatefulWidget {
  final String sourceRoomId;
  final rust.ChatMessage message;
  final ForwardMessageSender sender;

  const ForwardMessageSheet({
    super.key,
    required this.sourceRoomId,
    required this.message,
    this.sender = _sendForward,
  });

  @override
  ConsumerState<ForwardMessageSheet> createState() =>
      _ForwardMessageSheetState();
}

class _ForwardMessageSheetState extends ConsumerState<ForwardMessageSheet> {
  final _searchController = TextEditingController();
  String _query = '';
  String? _sendingRoomId;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _forwardTo(rust.ChatRoom room) async {
    if (_sendingRoomId != null) return;
    setState(() => _sendingRoomId = room.id);
    try {
      await widget.sender(
        sourceRoomId: widget.sourceRoomId,
        targetRoomId: room.id,
        message: widget.message,
      );
      // `mounted` first: `ref.invalidate` throws once the sheet was
      // dismissed while the send was in flight (Riverpod asserts on
      // disposed widgets).
      if (!mounted) return;
      ref.invalidate(chatRoomsProvider);
      // `isCurrent` guard: the sheet may be in its exit animation (the
      // user dismissed it while the send was in flight) — popping then
      // would pop the chat page below it.
      if (mounted && ModalRoute.of(context)?.isCurrent == true) {
        Navigator.of(context).pop(room);
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _sendingRoomId = null);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('转发失败: $error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final rooms = ref.watch(chatRoomsProvider);
    return FractionallySizedBox(
      heightFactor: 0.72,
      child: Material(
        color: colors.surfaceStrong,
        borderRadius: const BorderRadius.vertical(
          top: Radius.circular(NeuRadius.surface),
        ),
        clipBehavior: Clip.antiAlias,
        child: SafeArea(
          top: false,
          child: Column(
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: colors.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
                child: Row(
                  children: [
                    Expanded(child: Text('转发到', style: textTheme.titleMedium)),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _sendingRoomId == null
                          ? () => Navigator.of(context).pop()
                          : null,
                      icon: const Icon(Icons.close_rounded),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: IgnorePointer(
                  ignoring: _sendingRoomId != null,
                  child: NeuTextField(
                    key: const ValueKey('forward-room-search'),
                    controller: _searchController,
                    hint: '搜索会话',
                    radius: NeuRadius.button,
                    onChanged: (value) => setState(() => _query = value),
                    leading: const Icon(Icons.search_rounded),
                    trailing: _query.isEmpty
                        ? null
                        : GestureDetector(
                            onTap: () {
                              _searchController.clear();
                              setState(() => _query = '');
                            },
                            child: const Icon(Icons.close_rounded),
                          ),
                  ),
                ),
              ),
              Divider(height: 0.5, color: colors.hairline),
              Expanded(
                child: rooms.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (error, _) => _ForwardRoomsMessage(
                    icon: Icons.error_outline_rounded,
                    text: '加载会话失败: $error',
                  ),
                  data: (allRooms) {
                    final visibleRooms = forwardableRooms(allRooms, _query);
                    if (visibleRooms.isEmpty) {
                      return _ForwardRoomsMessage(
                        icon: Icons.forum_outlined,
                        text: _query.trim().isEmpty ? '暂无可转发的会话' : '未找到会话',
                      );
                    }
                    return ListView.builder(
                      itemCount: visibleRooms.length,
                      itemBuilder: (context, index) {
                        final room = visibleRooms[index];
                        final isSending = _sendingRoomId == room.id;
                        return ListTile(
                          key: ValueKey('forward-room-${room.id}'),
                          enabled: _sendingRoomId == null,
                          leading: AppAvatar(
                            fallback: room.name,
                            size: 42,
                            url: room.avatarUrl,
                          ),
                          title: Text(
                            room.name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: room.id == widget.sourceRoomId
                              ? const Text('当前会话')
                              : null,
                          trailing: isSending
                              ? const SizedBox.square(
                                  dimension: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                )
                              : Icon(
                                  Icons.chevron_right_rounded,
                                  color: colors.textTertiary,
                                ),
                          onTap: () => _forwardTo(room),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ForwardRoomsMessage extends StatelessWidget {
  final IconData icon;
  final String text;

  const _ForwardRoomsMessage({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: colors.textTertiary, size: 30),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(color: colors.textTertiary),
            ),
          ],
        ),
      ),
    );
  }
}
