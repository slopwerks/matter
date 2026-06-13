import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' hide redactMessage;
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'image_message_bubble.dart';
import 'message_input.dart';

class MessageGroup {
  final String senderId;
  final String senderName;
  final bool isMe;
  final List<ChatMessage> messages;

  MessageGroup({
    required this.senderId,
    required this.senderName,
    required this.isMe,
    required this.messages,
  });
}

class MessageGroupWidget extends ConsumerWidget {
  final MessageGroup group;
  final bool showAvatar;
  final String roomId;
  final String? senderAvatarUrl;
  final bool compact;
  final VoidCallback? onImageLoaded;

  const MessageGroupWidget({
    super.key,
    required this.group,
    required this.roomId,
    this.showAvatar = true,
    this.senderAvatarUrl,
    this.compact = false,
    this.onImageLoaded,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isMe = group.isMe;
    final isEventGroup = group.messages.every(
      (m) => m.msgType == MessageType.event,
    );

    if (isEventGroup) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => _buildMessage(
                  context,
                  ref,
                  e.value,
                  false,
                  isFirst: e.key == 0,
                  isLast: e.key == group.messages.length - 1,
                ),
              )
              .toList(),
        ),
      );
    }

    if (isMe) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: group.messages
              .asMap()
              .entries
              .map(
                (e) => _buildMessage(
                  context,
                  ref,
                  e.value,
                  true,
                  isFirst: e.key == 0,
                  isLast: e.key == group.messages.length - 1,
                ),
              )
              .toList(),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: compact ? 12 : (showAvatar ? 12 : 68),
        right: 12,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showAvatar) _buildAvatar(group.senderName, senderAvatarUrl),
          if (showAvatar) const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: group.messages
                  .asMap()
                  .entries
                  .map(
                    (e) => _buildMessage(
                      context,
                      ref,
                      e.value,
                      false,
                      isFirst: e.key == 0,
                      isLast: e.key == group.messages.length - 1,
                    ),
                  )
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    bool isFirst = false,
    bool isLast = false,
  }) {
    return GestureDetector(
      onLongPress: () => _showContextMenu(context, ref, message),
      child: Padding(
        padding: EdgeInsets.only(top: isFirst ? 2 : 1, bottom: isLast ? 10 : 1),
        child: message.msgType == MessageType.event
            ? _buildEventMessage(context, message)
            : message.msgType == MessageType.image && message.imageUrl != null
            ? ImageMessageBubble(
                imageUrl: message.imageUrl!,
                timestamp: message.timestamp,
                isMe: isMe,
                onLoaded: onImageLoaded,
              )
            : _buildTextBubble(context, ref, message, isMe, isFirst: isFirst),
      ),
    );
  }

  Widget _buildTextBubble(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe, {
    bool isFirst = false,
  }) {
    return Container(
      constraints: BoxConstraints(
        maxWidth: MediaQuery.of(context).size.width * 0.70,
      ),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: isMe ? AppColors.primary : AppColors.surfaceElevated,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(AppRadii.content),
          topRight: const Radius.circular(AppRadii.content),
          bottomLeft: Radius.circular(isMe ? AppRadii.content : AppRadii.tag),
          bottomRight: Radius.circular(isMe ? AppRadii.tag : AppRadii.content),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (!isMe && isFirst)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                message.senderName,
                style: TextStyle(
                  color: AppColors.primary.withValues(alpha: 0.85),
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          // Reply preview
          if (message.inReplyTo != null)
            _buildReplyPreview(context, ref, message, isMe),
          Text(
            message.content,
            style: TextStyle(
              color: isMe ? Colors.white : AppColors.onBackground,
              fontSize: 15,
              height: 1.35,
            ),
          ),
          const SizedBox(height: 3),
          Align(
            alignment: Alignment.bottomRight,
            widthFactor: 1.0,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(
                  message.timestamp,
                  style: TextStyle(
                    color: isMe
                        ? Colors.white.withValues(alpha: 0.65)
                        : AppColors.onSurfaceVariant,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                if (message.isEdited) ...[
                  const SizedBox(width: 6),
                  GestureDetector(
                    onTap: () => _showEditHistory(context, message),
                    child: Text(
                      '已编辑',
                      style: TextStyle(
                        color: isMe
                            ? Colors.white.withValues(alpha: 0.45)
                            : AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                        fontSize: 10,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _showEditHistory(BuildContext context, ChatMessage message) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        minChildSize: 0.3,
        maxChildSize: 0.8,
        expand: false,
        builder: (context, scrollController) {
          return Container(
            decoration: const BoxDecoration(
              color: AppColors.surface,
              borderRadius: BorderRadius.vertical(
                top: Radius.circular(AppRadii.surface),
              ),
            ),
            child: Column(
              children: [
                // Handle bar
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 8, bottom: 12),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  child: Text(
                    '编辑记录',
                    style: TextStyle(
                      color: AppColors.onBackground,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Divider(color: AppColors.surfaceVariant, height: 0.5),
                Expanded(
                  child: ListView.builder(
                    controller: scrollController,
                    padding: const EdgeInsets.symmetric(
                      vertical: 8,
                      horizontal: 16,
                    ),
                    itemCount: message.editHistory.length,
                    itemBuilder: (context, index) {
                      final isOriginal = index == 0;
                      final isLatest = index == message.editHistory.length - 1;
                      String label;
                      if (isOriginal) {
                        label = '原始';
                      } else if (isLatest) {
                        label = '最新';
                      } else {
                        label = '第 $index 次编辑';
                      }
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: isLatest
                                        ? AppColors.primary.withValues(
                                            alpha: 0.15,
                                          )
                                        : AppColors.surfaceVariant.withValues(
                                            alpha: 0.5,
                                          ),
                                    borderRadius: BorderRadius.circular(
                                      AppRadii.tag,
                                    ),
                                  ),
                                  child: Text(
                                    label,
                                    style: TextStyle(
                                      color: isLatest
                                          ? AppColors.primary
                                          : AppColors.onSurfaceVariant,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              message.editHistory[index],
                              style: const TextStyle(
                                color: AppColors.onBackground,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),
                const SizedBox(height: 8),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildReplyPreview(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
    bool isMe,
  ) {
    return FutureBuilder<String?>(
      future: _getReplyContent(ref, message.inReplyTo!),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox.shrink();
        final replyContent = snapshot.data!;
        return Container(
          margin: const EdgeInsets.only(bottom: 6),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: (isMe ? Colors.white : AppColors.primary).withValues(
              alpha: 0.1,
            ),
            borderRadius: BorderRadius.circular(AppRadii.tag),
            border: Border(
              left: BorderSide(
                color: isMe ? Colors.white : AppColors.primary,
                width: 2,
              ),
            ),
          ),
          child: Text(
            replyContent,
            style: TextStyle(
              color: isMe
                  ? Colors.white.withValues(alpha: 0.7)
                  : AppColors.onSurfaceVariant,
              fontSize: 12,
              height: 1.3,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
        );
      },
    );
  }

  Future<String> _getReplyContent(WidgetRef ref, String replyToId) async {
    // Look for the replied-to message in current messages
    final messages = await ref.read(messagesProvider(roomId).future);
    final found = messages.where((m) => m.id == replyToId).firstOrNull;
    if (found != null) {
      return '${found.senderName}: ${found.content}';
    }
    return '...';
  }

  IconData _eventIcon(ChatMessage message) {
    final content = message.content;
    if (content.contains('加入') || content.contains('邀请')) {
      return Icons.person_add_rounded;
    }
    if (content.contains('退出') ||
        content.contains('离开') ||
        content.contains('踢出') ||
        content.contains('移出')) {
      return Icons.person_remove_rounded;
    }
    if (content.contains('创建')) {
      return Icons.add_circle_outline_rounded;
    }
    if (content.contains('修改') ||
        content.contains('更改') ||
        content.contains('设置')) {
      return Icons.edit_rounded;
    }
    return Icons.info_outline_rounded;
  }

  Widget _buildEventMessage(BuildContext context, ChatMessage message) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.82,
            minHeight: 24,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.surfaceVariant.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(AppRadii.tag),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                _eventIcon(message),
                size: 13,
                color: AppColors.onSurfaceVariant,
              ),
              const SizedBox(width: 5),
              Flexible(
                child: Text(
                  message.content,
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                    height: 1.2,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar(String name, String? avatarUrl) {
    return AppAvatar(
      fallback: name,
      size: 48,
      radius: AppRadii.content,
      url: avatarUrl,
    );
  }

  void _showContextMenu(
    BuildContext context,
    WidgetRef ref,
    ChatMessage message,
  ) {
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
              if (message.msgType == MessageType.text)
                _MenuItem(
                  icon: Icons.copy_rounded,
                  label: '复制',
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: message.content));
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('已复制'),
                        duration: Duration(seconds: 1),
                      ),
                    );
                  },
                ),
              _MenuItem(
                icon: Icons.reply_rounded,
                label: '回复',
                onTap: () {
                  Navigator.of(context).pop();
                  // Set the reply target
                  ref.read(replyingToProvider(roomId).notifier).value = message;
                },
              ),
              _MenuItem(
                icon: Icons.forward_rounded,
                label: '转发',
                onTap: () => Navigator.of(context).pop(),
              ),
              if (message.isMe) ...[
                const Divider(color: AppColors.surfaceVariant, height: 0.5),
                _MenuItem(
                  icon: Icons.delete_outline_rounded,
                  label: '撤回',
                  iconColor: AppColors.error,
                  textColor: AppColors.error,
                  onTap: () async {
                    Navigator.of(context).pop();
                    try {
                      await redactMessage(ref, roomId, message.id);
                    } catch (e) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('撤回失败: $e'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color? iconColor;
  final Color? textColor;

  const _MenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor,
    this.textColor,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AppRadii.surface),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: iconColor ?? AppColors.onSurface, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: textColor ?? AppColors.onBackground,
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
