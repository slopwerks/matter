import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import 'action_failure_message.dart';
import 'message_pin_actions.dart';
import 'pinned_message_indicator.dart';

/// Row height of one pinned message in the stack. The chat page reserves the
/// same height for the single visible row, so the two must stay in sync.
const double kPinnedMessageRowHeight = 46.0;

class PinnedMessagesStack extends ConsumerStatefulWidget {
  final String roomId;
  final ValueChanged<String> onMessageTap;
  final VoidCallback? onShowAll;
  final ValueNotifier<String?>? jumpTarget;
  final ValueChanged<int>? onVisibleCountChanged;

  const PinnedMessagesStack({
    super.key,
    required this.roomId,
    required this.onMessageTap,
    this.onShowAll,
    this.jumpTarget,
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
  String? _selectedMessageId;
  String? _lastJumpedMessageId;

  RoomAccountKey _providerKey(String userId) =>
      (roomId: widget.roomId, userId: userId);

  @override
  void initState() {
    super.initState();
    widget.jumpTarget?.addListener(_syncJumpTarget);
    ref.listenManual(activeUserIdProvider, (_, _) {
      if (!mounted) return;
      for (final timer in _hiddenExpiryTimers.values) {
        timer.cancel();
      }
      setState(() {
        _selectedMessageId = null;
        _lastJumpedMessageId = null;
        _hiddenExpiryTimers.clear();
        _hiddenMessageIds.clear();
        _unpinningMessageIds.clear();
        _reportedVisibleCount = -1;
      });
    });
  }

  void _syncJumpTarget() {
    final messageId = widget.jumpTarget?.value;
    final userId = ref.read(activeUserIdProvider);
    if (!mounted || messageId == null || userId == null) return;
    final messages = ref
        .read(pinnedMessagesProvider(_providerKey(userId)))
        .value;
    if (messages?.any((m) => m.id == messageId) != true) return;
    setState(() {
      _selectedMessageId = messageId;
      _lastJumpedMessageId = messageId;
    });
  }

  @override
  void didUpdateWidget(PinnedMessagesStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.jumpTarget != widget.jumpTarget) {
      oldWidget.jumpTarget?.removeListener(_syncJumpTarget);
      widget.jumpTarget?.addListener(_syncJumpTarget);
    }
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
    widget.jumpTarget?.removeListener(_syncJumpTarget);
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
    final confirmed = await confirmMessagePinChange(context, pinned: false);
    if (!confirmed ||
        !mounted ||
        ref.read(activeUserIdProvider) != accountUserId) {
      return;
    }
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
      showMessagePinFeedback(
        context: context,
        container: ProviderScope.containerOf(context, listen: false),
        accountUserId: accountUserId,
        roomId: widget.roomId,
        eventId: message.id,
        pinned: false,
        onChanged: (pinned) {
          if (!mounted) return;
          _hiddenExpiryTimers.remove(message.id)?.cancel();
          setState(() {
            if (pinned) {
              _hiddenMessageIds.remove(message.id);
            } else {
              _hiddenMessageIds.add(message.id);
            }
          });
          if (!pinned) {
            _hiddenExpiryTimers[message.id] = Timer(
              const Duration(seconds: 30),
              () {
                if (!mounted) return;
                setState(() => _hiddenMessageIds.remove(message.id));
                _hiddenExpiryTimers.remove(message.id);
                ref.invalidate(pinnedMessagesProvider(providerKey));
              },
            );
          }
        },
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
    const visibleRows = 1;
    final selectedIndex = messages.indexWhere(
      (m) => m.id == _selectedMessageId,
    );
    final index = selectedIndex < 0 ? 0 : selectedIndex;
    _reportVisibleCount(visibleRows);
    final colors = context.neu;
    return GlassPanel(
      radius: context.isMaterial ? 0 : NeuRadius.surface,
      child: SizedBox(
        key: const ValueKey('pinned-messages-stack'),
        height: rowHeight * visibleRows,
        child: Builder(
          builder: (context) {
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
              onLongPress: widget.onShowAll,
              onTap: () {
                final nextIndex =
                    _lastJumpedMessageId == message.id || ignoredSender
                    ? (index + 1) % messages.length
                    : index;
                final target = messages[nextIndex];
                final targetIgnored =
                    ignoredUserIds == null ||
                    (!target.isMe && ignoredUserIds.contains(target.senderId));
                setState(() {
                  _selectedMessageId = target.id;
                  _lastJumpedMessageId = target.id;
                });
                if (!targetIgnored) widget.onMessageTap(target.id);
              },
              child: Row(
                children: [
                  const SizedBox(width: 12),
                  PinnedMessageIndicator(count: messages.length, index: index),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '置顶消息 #${index + 1} · 共 ${messages.length} 条',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.accent,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        Text(
                          ignoredSender
                              ? content
                              : '${message.senderName}：$content',
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
                  if (widget.onShowAll != null)
                    IconButton(
                      tooltip: '查看全部置顶消息',
                      onPressed: widget.onShowAll,
                      icon: const Icon(Icons.list_alt, size: 20),
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
