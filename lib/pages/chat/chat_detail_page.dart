import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/message_provider.dart';
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

  const ChatDetailPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.subtitle = '在线',
  });

  @override
  ConsumerState<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends ConsumerState<ChatDetailPage> {
  final _scrollController = ScrollController();
  final Map<int, double> _heights = {};
  final Map<int, GlobalKey> _keys = {};

  List<MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <MessageGroup>[];
    for (final message in messages) {
      if (message.isMe) {
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: true,
            messages: [message],
          ),
        );
      } else if (groups.isEmpty || groups.last.senderId != message.senderId) {
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: false,
            messages: [message],
          ),
        );
      } else {
        groups.last.messages.add(message);
      }
    }
    return groups;
  }

  void _measureHeights() {
    for (final entry in _keys.entries) {
      final box = entry.value.currentContext?.findRenderObject() as RenderBox?;
      if (box != null && box.hasSize) {
        _heights[entry.key] = box.size.height;
      }
    }
  }

  Widget _buildAvatar(String name) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: AppColors.surfaceElevated,
        borderRadius: BorderRadius.circular(AppRadii.tag),
      ),
      child: Center(
        child: Text(
          name.isNotEmpty ? name[0] : '?',
          style: const TextStyle(
            color: AppColors.primary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
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
            onPressed: () {},
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: messagesAsync.when(
              data: (messages) {
                final groups = _groupMessages(messages);

                // 按时间正序排列，reverse:true 会把列表末尾（最新消息）显示在屏幕底部
                _keys.clear();
                for (int i = 0; i < groups.length; i++) {
                  if (!groups[i].isMe) {
                    _keys[i] = GlobalKey();
                  }
                }
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _measureHeights(),
                );

                return CustomScrollView(
                  reverse: true,
                  controller: _scrollController,
                  slivers: [
                    const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
                    // sliver 顺序：最新在前 → reverse:true 把它显示在底部
                    for (int i = groups.length - 1; i >= 0; i--)
                      if (groups[i].isMe)
                        SliverToBoxAdapter(
                          child: MessageGroupWidget(group: groups[i]),
                        )
                      else
                        SliverLayoutBuilder(
                          builder: (context, constraints) {
                            final height = _heights[i] ?? 80.0;
                            final so = constraints.scrollOffset;
                            final dy = (-so).clamp(39.5 - height, 0.0);

                            return SliverToBoxAdapter(
                              child: Stack(
                                key: _keys[i],
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  MessageGroupWidget(
                                    group: groups[i],
                                    showAvatar: false,
                                  ),
                                  Positioned(
                                    left: 12,
                                    bottom: 4.5,
                                    child: Transform.translate(
                                      offset: Offset(0, dy),
                                      child: SizedBox(
                                        width: 32,
                                        height: 32,
                                        child: _buildAvatar(
                                          groups[i].senderName,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    // DateSeparator 在 sliver 列表末尾 → reverse 后显示在最顶部（最旧消息上方）
                    const SliverToBoxAdapter(child: DateSeparator(dateLabel: '今天')),
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
                child: Text(
                  '加载失败: $err',
                  style: const TextStyle(color: AppColors.onSurfaceVariant),
                ),
              ),
            ),
          ),
          MessageInput(roomId: widget.roomId),
        ],
      ),
    );
  }
}
