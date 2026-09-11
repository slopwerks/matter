import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import 'action_failure_message.dart';

/// Row height of one pinned message in the stack. The chat page reserves the
/// same height per visible row, so the two must stay in sync.
const double kPinnedMessageRowHeight = 46.0;

class PinnedMessagesStack extends ConsumerStatefulWidget {
  final String roomId;
  final ValueChanged<String> onMessageTap;
  final ValueChanged<int>? onVisibleCountChanged;

  const PinnedMessagesStack({
    super.key,
    required this.roomId,
    required this.onMessageTap,
    this.onVisibleCountChanged,
  });

  @override
  ConsumerState<PinnedMessagesStack> createState() =>
      _PinnedMessagesStackState();
}

class _PinnedMessagesStackState extends ConsumerState<PinnedMessagesStack> {
  final Set<String> _hiddenMessageIds = {};
  final Set<String> _unpinningMessageIds = {};
  final Map<String, Timer> _hiddenExpiryTimers = {};
  int _reportedVisibleCount = -1;

  RoomAccountKey _providerKey(String userId) =>
      (roomId: widget.roomId, userId: userId);

  @override
  void initState() {
    super.initState();
    ref.listenManual(activeUserIdProvider, (_, _) {
      if (!mounted) return;
      for (final timer in _hiddenExpiryTimers.values) {
        timer.cancel();
      }
      setState(() {
        _hiddenExpiryTimers.clear();
        _hiddenMessageIds.clear();
        _unpinningMessageIds.clear();
        _reportedVisibleCount = -1;
      });
    });
  }

  void _reportVisibleCount(int count) {
    if (_reportedVisibleCount == count) return;
    _reportedVisibleCount = count;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.onVisibleCountChanged?.call(count);
    });
  }

  @override
  void dispose() {
    for (final timer in _hiddenExpiryTimers.values) {
      timer.cancel();
    }
    super.dispose();
  }

  Future<void> _unpin(rust.ChatMessage message) async {
    if (_unpinningMessageIds.contains(message.id)) return;
    final accountUserId = ref.read(activeUserIdProvider);
    if (accountUserId == null) return;
    final providerKey = _providerKey(accountUserId);
    setState(() {
      _hiddenMessageIds.add(message.id);
      _unpinningMessageIds.add(message.id);
    });
    try {
      await rust.setPinnedMessage(
        accountUserId: accountUserId,
        roomId: widget.roomId,
        eventId: message.id,
        pinned: false,
      );
      if (!mounted || ref.read(activeUserIdProvider) != accountUserId) return;
      setState(() => _unpinningMessageIds.remove(message.id));
      _hiddenExpiryTimers[message.id]?.cancel();
      _hiddenExpiryTimers[message.id] = Timer(const Duration(seconds: 30), () {
        if (!mounted) return;
        setState(() => _hiddenMessageIds.remove(message.id));
        _hiddenExpiryTimers.remove(message.id);
        ref.invalidate(pinnedMessagesProvider(providerKey));
      });
      ref.invalidate(pinnedMessagesProvider(providerKey));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已取消置顶'), duration: Duration(seconds: 1)),
      );
    } catch (error) {
      if (!mounted || ref.read(activeUserIdProvider) != accountUserId) return;
      setState(() {
        _hiddenMessageIds.remove(message.id);
        _unpinningMessageIds.remove(message.id);
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('取消置顶失败: ${actionFailureMessage(error)}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final activeUserId = ref.watch(activeUserIdProvider);
    if (activeUserId == null) {
      _reportVisibleCount(0);
      return const SizedBox.shrink();
    }
    final pinnedAsync = ref.watch(
      pinnedMessagesProvider(_providerKey(activeUserId)),
    );
    final ignoredUserIds = ref.watch(ignoredUserIdsProvider).value;
    final messages = pinnedAsync.value
        ?.where((message) => !_hiddenMessageIds.contains(message.id))
        .toList();
    if (messages == null || messages.isEmpty) {
      _reportVisibleCount(0);
      return const SizedBox.shrink();
    }

    const rowHeight = kPinnedMessageRowHeight;
    final visibleRows = messages.length.clamp(1, 3);
    _reportVisibleCount(visibleRows);
    final colors = context.neu;
    return GlassPanel(
      radius: NeuRadius.surface,
      child: SizedBox(
        key: const ValueKey('pinned-messages-stack'),
        height: rowHeight * visibleRows,
        child: ListView.builder(
          padding: EdgeInsets.zero,
          itemCount: messages.length,
          itemExtent: rowHeight,
          itemBuilder: (context, index) {
            final message = messages[index];
            final ignoredSender =
                ignoredUserIds == null ||
                (!message.isMe && ignoredUserIds.contains(message.senderId));
            final content = ignoredSender
                ? '来自已忽略用户的消息'
                : message.content.trim().isEmpty
                ? (message.filename ?? '媒体消息')
                : message.content;
            return InkWell(
              key: ValueKey('pinned-message:${message.id}'),
              onTap: ignoredSender
                  ? null
                  : () => widget.onMessageTap(message.id),
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  Container(
                    width: 3,
                    height: 28,
                    decoration: BoxDecoration(
                      color: colors.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          message.senderName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          content,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textTertiary,
                            fontSize: 12.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    key: ValueKey('unpin-message:${message.id}'),
                    tooltip: '取消置顶',
                    onPressed: _unpinningMessageIds.contains(message.id)
                        ? null
                        : () => unawaited(_unpin(message)),
                    icon: Icon(
                      Icons.push_pin_outlined,
                      color: colors.textTertiary,
                      size: 19,
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}
