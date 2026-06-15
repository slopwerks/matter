import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'date_separator.dart';
import 'message_group.dart';
import 'message_input.dart';

class ChatDetailPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final String subtitle;
  final bool isDm;

  const ChatDetailPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.subtitle = '在线',
    this.isDm = false,
  });

  @override
  ConsumerState<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends ConsumerState<ChatDetailPage> {
  final _scrollController = ScrollController();
  final Map<int, double> _heights = {};
  final Map<int, GlobalKey> _keys = {};
  final List<ChatMessage> _olderMessages = [];
  List<ChatMessage> _displayedMessages = [];
  bool _isLoadingOlder = false;
  bool _hasMoreMessages = true;

  /// senderId → avatar HTTP URL, populated from room members.
  Map<String, String?> _avatarMap = {};

  // ── Sticky avatar constants ─────────────────────────────────────────
  //
  // The sticky offset limit is: avatar size + bottom padding + top gap.
  static const double _avatarSize = 48.0;
  static const double _avatarBottom = 4.5;
  static const double _stickyLimit =
      _avatarSize + _avatarBottom; // avatar slides all the way to the group top

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_maybeLoadOlderMessages);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(replyingToProvider(widget.roomId).notifier).value = null;
      ref.read(currentRoomIdProvider.notifier).value = widget.roomId;
      // Keep the global typing listener alive and subscribe to this room.
      ref.read(typingStreamProvider);
      subscribeTypingForRoom(roomId: widget.roomId).catchError((e) {
        debugPrint('subscribeTypingForRoom failed: $e');
      });
    });
  }

  void _buildAvatarMap(List<ChatMessage> messages, List<Contact> members) {
    final map = <String, String?>{};
    for (final m in members) {
      map[m.id] = m.avatarUrl;
    }
    // Also cover senders not in members (edge case)
    for (final msg in messages) {
      if (!msg.isMe && !map.containsKey(msg.senderId)) {
        map[msg.senderId] = null;
      }
    }
    _avatarMap = map;
  }

  @override
  void dispose() {
    _scrollController.removeListener(_maybeLoadOlderMessages);
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadOlderMessages() {
    if (!_scrollController.hasClients ||
        _isLoadingOlder ||
        !_hasMoreMessages ||
        _displayedMessages.isEmpty) {
      return;
    }
    final position = _scrollController.position;
    if (position.pixels >= position.maxScrollExtent - 240) {
      _loadOlderMessages();
    }
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreMessages || _displayedMessages.isEmpty) {
      return;
    }

    setState(() => _isLoadingOlder = true);
    try {
      final older = await getMessagesBefore(
        roomId: widget.roomId,
        fromEventId: _displayedMessages.first.id,
        limit: 100,
      );
      if (!mounted) return;

      final knownIds = _displayedMessages.map((message) => message.id).toSet();
      final newMessages = older
          .where((message) => !knownIds.contains(message.id))
          .toList();
      setState(() {
        _olderMessages.insertAll(0, newMessages);
        _hasMoreMessages = older.isNotEmpty;
        _isLoadingOlder = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingOlder = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载更早消息失败: $error')));
    }
  }

  List<ChatMessage> _mergeMessages(List<ChatMessage> latestMessages) {
    final byId = <String, ChatMessage>{
      for (final message in _olderMessages) message.id: message,
      for (final message in latestMessages) message.id: message,
    };
    final messages = byId.values.toList()
      ..sort((a, b) {
        final aTime = int.tryParse(a.timestamp) ?? 0;
        final bTime = int.tryParse(b.timestamp) ?? 0;
        return aTime.compareTo(bTime);
      });
    return messages;
  }

  List<MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <MessageGroup>[];
    for (final message in messages) {
      final startsNewGroup =
          groups.isEmpty ||
          groups.last.senderId != message.senderId ||
          chatDateKey(groups.last.messages.last.timestamp) !=
              chatDateKey(message.timestamp);
      if (startsNewGroup) {
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: message.isMe,
            messages: [message],
          ),
        );
      } else {
        groups.last.messages.add(message);
      }
    }
    return groups;
  }

  @override
  void deactivate() {
    // Clear current room and stop typing tracking — defer to avoid modifying
    // provider during build.
    Future.microtask(() {
      try {
        ref.read(currentRoomIdProvider.notifier).value = null;
      } catch (e) {
        debugPrint('deactivate: clear currentRoomId failed: $e');
      }
      unsubscribeTyping().catchError((e) {
        debugPrint('unsubscribeTyping failed: $e');
      });
    });
    super.deactivate();
  }

  void _measureHeights() {
    bool changed = false;
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        final newHeight = box.size.height;
        if (_heights[entry.key] != newHeight) {
          _heights[entry.key] = newHeight;
          changed = true;
        }
      }
    }
    if (changed && mounted) {
      // Defer to after the current frame to avoid calling setState during build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Default height for unmeasured groups: use the median of already-measured heights.
  double get _defaultHeight {
    if (_heights.isEmpty) return 80.0;
    final vals = _heights.values.toList()..sort();
    return vals[vals.length ~/ 2];
  }

  Widget _buildAvatar(String name, String? avatarUrl) {
    return AppAvatar(
      fallback: name,
      size: _avatarSize,
      radius: AppRadii.content,
      url: avatarUrl,
    );
  }

  /// Check if a message group consists entirely of event-type messages.
  bool _isEventGroup(MessageGroup group) {
    return group.messages.every((m) => m.msgType == MessageType.event);
  }

  bool _needsStickyAvatar(MessageGroup group) {
    return !group.isMe && !_isEventGroup(group);
  }

  @override
  Widget build(BuildContext context) {
    final messagesAsync = ref.watch(messagesProvider(widget.roomId));

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background.withValues(alpha: 0.92),
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: AppColors.onBackground,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        titleSpacing: 0,
        title: Row(
          children: [
            AppAvatar(
              fallback: widget.roomName,
              size: 36,
              radius: AppRadii.content,
              url: widget.avatarUrl,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.roomName,
                    style: const TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 15.5,
                      fontWeight: FontWeight.w700,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    widget.subtitle,
                    style: const TextStyle(
                      color: AppColors.onSurfaceVariant,
                      fontSize: 12,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: '搜索暂未提供',
            icon: const Icon(
              Icons.search_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: null,
          ),
          IconButton(
            icon: const Icon(
              Icons.more_vert_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () {
              _showRoomDetails(context);
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                final displayedMessages = _mergeMessages(messages);
                _displayedMessages = displayedMessages;
                final messageIndex = <String, ChatMessage>{
                  for (final message in displayedMessages) message.id: message,
                };
                final groups = _groupMessages(displayedMessages);

                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _maybeLoadOlderMessages(),
                );

                // Resolve member avatars
                final membersAsync = ref.read(
                  roomMembersProvider(widget.roomId),
                );
                membersAsync.whenData(
                  (members) => _buildAvatarMap(displayedMessages, members),
                );

                // Lazily create keys only for new indices; remove stale ones.
                for (int i = 0; i < groups.length; i++) {
                  if (_needsStickyAvatar(groups[i])) {
                    _keys.putIfAbsent(i, () => GlobalKey());
                  }
                }
                // Remove keys for indices that no longer exist
                _keys.removeWhere(
                  (i, _) =>
                      i >= groups.length || !_needsStickyAvatar(groups[i]),
                );
                _heights.removeWhere(
                  (i, _) =>
                      i >= groups.length || !_needsStickyAvatar(groups[i]),
                );
                // Schedule height measurement after every build so that async
                // image loads are picked up even when the group count doesn't change.
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _measureHeights(),
                );

                return CustomScrollView(
                  reverse: true,
                  controller: _scrollController,
                  slivers: [
                    const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
                    for (int i = groups.length - 1; i >= 0; i--) ...[
                      if (!_needsStickyAvatar(groups[i]))
                        SliverToBoxAdapter(
                          child: MessageGroupWidget(
                            group: groups[i],
                            roomId: widget.roomId,
                            messageIndex: messageIndex,
                          ),
                        )
                      else
                        SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final height = _heights[i] ?? _defaultHeight;
                            final so = constraints.scrollOffset;

                            // Slide the avatar from its resting position at the
                            // message group's bottom up to the top gap, then
                            // hold it there. Because each group's avatar is
                            // clipped to its own Stack, it cannot follow the
                            // viewport bottom across groups; a full Telegram-
                            // style sticky header would need a global sliver
                            // header instead.
                            final dy = (-so).clamp(
                              (_stickyLimit - height).clamp(
                                double.negativeInfinity,
                                0.0,
                              ),
                              0.0,
                            );

                            return SliverToBoxAdapter(
                              child: Stack(
                                key: _keys[i],
                                clipBehavior: Clip.none,
                                children: [
                                  MessageGroupWidget(
                                    group: groups[i],
                                    roomId: widget.roomId,
                                    messageIndex: messageIndex,
                                    showAvatar: false,
                                    compact: widget.isDm,
                                    onImageLoaded: _measureHeights,
                                  ),
                                  if (!widget.isDm)
                                    Positioned(
                                      left: 12,
                                      bottom: _avatarBottom,
                                      child: Transform.translate(
                                        offset: Offset(0, dy),
                                        child: _buildAvatar(
                                          groups[i].senderName,
                                          _avatarMap[groups[i].senderId],
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            );
                          },
                        ),
                      if (i == 0 ||
                          chatDateKey(groups[i - 1].messages.first.timestamp) !=
                              chatDateKey(groups[i].messages.first.timestamp))
                        SliverToBoxAdapter(
                          child: DateSeparator(
                            dateLabel: formatChatDate(
                              groups[i].messages.first.timestamp,
                            ),
                          ),
                        ),
                    ],
                    if (_isLoadingOlder)
                      const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(
                                color: AppColors.primary,
                                strokeWidth: 2,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const SliverPadding(padding: EdgeInsets.only(top: 8)),
                  ],
                );
              },
              loading: () => const Center(
                child: CircularProgressIndicator(
                  color: AppColors.primary,
                  strokeWidth: 2,
                ),
              ),
              error: (err, _) => Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText(
                    '加载失败: $err',
                    style: const TextStyle(color: AppColors.onSurfaceVariant),
                  ),
                ),
              ),
            ),
          ),
          _buildTypingIndicator(),
          MessageInput(
            key: ValueKey('msg_input_${widget.roomId}'),
            roomId: widget.roomId,
          ),
        ],
      ),
    );
  }

  /// "… is typing" indicator shown above the message input.
  Widget _buildTypingIndicator() {
    final typing = ref.watch(typingUsersProvider(widget.roomId));
    if (typing.isEmpty) return const SizedBox.shrink();

    // Derive display names from user ids (localpart fallback).
    final names = typing.map((id) {
      final part = id.split(':').first;
      return part.startsWith('@') ? part.substring(1) : part;
    }).toList();

    final String text;
    if (names.length == 1) {
      text = '${names.first} 正在输入…';
    } else if (names.length == 2) {
      text = '${names[0]} 和 ${names[1]} 正在输入…';
    } else {
      text = '${names.length} 人正在输入…';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showRoomDetails(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) => Container(
        margin: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppColors.surface,
          borderRadius: BorderRadius.circular(AppRadii.surface),
        ),
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    AppAvatar(
                      fallback: widget.roomName,
                      size: 56,
                      url: widget.avatarUrl,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.roomName,
                            style: const TextStyle(
                              color: AppColors.onBackground,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.roomId,
                            style: const TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.surfaceVariant, height: 0.5),
              // Room members preview
              Consumer(
                builder: (context, ref, _) {
                  final membersAsync = ref.watch(
                    roomMembersProvider(widget.roomId),
                  );
                  return membersAsync.when(
                    data: (members) {
                      return Column(
                        children: [
                          _DetailMenuItem(
                            icon: Icons.people_rounded,
                            label: '成员 (${members.length})',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: SizedBox(
                              height: 44,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: members.length > 10
                                    ? 10
                                    : members.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final member = members[index];
                                  return AppAvatar(
                                    fallback: member.name,
                                    size: 40,
                                    radius: 20,
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                    error: (_, _) => const SizedBox.shrink(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DetailMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DetailMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.onSurface, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.onBackground,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
