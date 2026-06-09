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
            messages: [message],
          ),
        );
      } else if (groups.isEmpty || groups.last.senderId != message.senderId) {
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
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
                final reversed = groups.reversed.toList();

                // 重建 keys
                _keys.clear();
                for (int i = 0; i < reversed.length; i++) {
                  if (reversed[i].senderId != 'me') {
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
                    const SliverPadding(padding: EdgeInsets.only(top: 8)),
                    const SliverToBoxAdapter(child: DateSeparator(dateLabel: '今天')),
                    for (int i = 0; i < reversed.length; i++)
                      if (reversed[i].senderId == 'me')
                        SliverToBoxAdapter(
                          child: MessageGroupWidget(group: reversed[i]),
                        )
                      else
SliverLayoutBuilder(
                            builder: (context, constraints) {
                            final height = _heights[i] ?? 80.0;
                            final so = constraints.scrollOffset;

                            // 头像默认在 group 底部 (bottom: 4.5, height: 32)
                            // 4.5 = 3(外边距) + 1.5(最后一条消息底边距)，与消息气泡底对齐
                            // sticky: dy = -so 使头像保持屏幕位置不变
                            // 到达消息内容顶部时夹住: dy ≥ 39.5 - height
                            // 39.5 = 32(头像高) + 3(底边距) + 1.5(消息底边距) + 3(外顶边距) + 1.5(消息顶边距)
                            // = 3 + 1.5 + 32 + 3 + 1.5，头停在第一条消息气泡顶部而非外边距顶部
                            final dy = (-so).clamp(39.5 - height, 0.0);

                            return SliverToBoxAdapter(
                              child: Stack(
                                key: _keys[i],
                                clipBehavior: Clip.hardEdge,
                                children: [
                                  MessageGroupWidget(
                                    group: reversed[i],
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
                                          reversed[i].senderName,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                    const SliverPadding(padding: EdgeInsets.only(bottom: 8)),
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
