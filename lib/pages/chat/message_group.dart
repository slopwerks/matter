import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import 'image_message_bubble.dart';

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

class MessageGroupWidget extends StatelessWidget {
  final MessageGroup group;
  final bool showAvatar;

  const MessageGroupWidget({
    super.key,
    required this.group,
    this.showAvatar = true,
  });

  @override
  Widget build(BuildContext context) {
    final isMe = group.isMe;

    if (isMe) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: group.messages
              .map((m) => _buildMessage(context, m, true))
              .toList(),
        ),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: showAvatar ? 12 : 52,
        right: 12,
        top: 3,
        bottom: 3,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (showAvatar) _buildAvatar(group.senderName),
          if (showAvatar) const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: group.messages
                  .map((m) => _buildMessage(context, m, false))
                  .toList(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(BuildContext context, ChatMessage message, bool isMe) {
    return GestureDetector(
      onLongPress: () => _showContextMenu(context, message),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 1.5),
        child: message.msgType == MessageType.image && message.imageUrl != null
            ? ImageMessageBubble(
                imageUrl: message.imageUrl!,
                timestamp: message.timestamp,
                isMe: isMe,
              )
            : _buildTextBubble(message, isMe),
      ),
    );
  }

  Widget _buildTextBubble(ChatMessage message, bool isMe) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 280),
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
          if (!isMe)
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
            child: Text(
              message.timestamp,
              style: TextStyle(
                color: isMe
                    ? Colors.white.withValues(alpha: 0.65)
                    : AppColors.onSurfaceVariant,
                fontSize: 10.5,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
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

  void _showContextMenu(BuildContext context, ChatMessage message) {
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
                onTap: () => Navigator.of(context).pop(),
              ),
              _MenuItem(
                icon: Icons.forward_rounded,
                label: '转发',
                onTap: () => Navigator.of(context).pop(),
              ),
              const Divider(color: AppColors.surfaceVariant, height: 0.5),
              _MenuItem(
                icon: Icons.delete_outline_rounded,
                label: '删除',
                iconColor: AppColors.error,
                textColor: AppColors.error,
                onTap: () => Navigator.of(context).pop(),
              ),
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
