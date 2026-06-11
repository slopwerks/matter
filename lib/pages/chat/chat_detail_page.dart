import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
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
  int _prevGroupCount = 0;

  /// senderId → avatar HTTP URL, populated from room members.
  Map<String, String?> _avatarMap = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(replyingToProvider(widget.roomId).notifier).state = null;
      ref.read(currentRoomIdProvider.notifier).state = widget.roomId;
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
    super.dispose();
  }

  List<MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <MessageGroup>[];
    for (final message in messages) {
      if (groups.isEmpty || groups.last.senderId != message.senderId) {
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
    // Clear current room when leaving
    ref.read(currentRoomIdProvider.notifier).state = null;
    super.deactivate();
  }

  void _measureHeights() {
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _heights[entry.key] = box.size.height;
      }
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
      size: 48,
      radius: AppRadii.content,
      url: avatarUrl,
    );
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
            icon: const Icon(
              Icons.search_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () {},
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
                final groups = _groupMessages(messages);

                // Resolve member avatars
                final membersAsync = ref.read(
                  roomMembersProvider(widget.roomId),
                );
                membersAsync.whenData(
                  (members) => _buildAvatarMap(messages, members),
                );

                // Lazily create keys only for new indices; remove stale ones.
                for (int i = 0; i < groups.length; i++) {
                  if (!groups[i].isMe) {
                    _keys.putIfAbsent(i, () => GlobalKey());
                  }
                }
                // Remove keys for indices that no longer exist
                _keys.removeWhere((i, _) => i >= groups.length);
                // Schedule a height measurement if group count changed
                if (groups.length != _prevGroupCount) {
                  _prevGroupCount = groups.length;
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => _measureHeights(),
                  );
                }

                return CustomScrollView(
                  reverse: true,
                  controller: _scrollController,
                  slivers: [
                    const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
                    for (int i = groups.length - 1; i >= 0; i--)
                      if (groups[i].isMe)
                        SliverToBoxAdapter(
                          child: MessageGroupWidget(
                            group: groups[i],
                            roomId: widget.roomId,
                          ),
                        )
                      else
                        SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final height = _heights[i] ?? _defaultHeight;
                            final so = constraints.scrollOffset;
                            final dy = (-so).clamp(39.5 - height, 0.0);

                            return SliverToBoxAdapter(
                              child: Stack(
                                key: _keys[i],
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  MessageGroupWidget(
                                    group: groups[i],
                                    roomId: widget.roomId,
                                    showAvatar: false,
                                    compact: widget.isDm,
                                  ),
                                  if (!widget.isDm)
                                    Positioned(
                                      left: 12,
                                      bottom: 4.5,
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
                    const SliverToBoxAdapter(
                      child: DateSeparator(dateLabel: '今天'),
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
          MessageInput(
            key: ValueKey('msg_input_${widget.roomId}'),
            roomId: widget.roomId,
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
