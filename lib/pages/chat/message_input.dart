import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

/// Provider to hold the message being replied to (per room).
final replyingToProvider = StateProvider.family<rust.ChatMessage?, String>(
  (ref, _) => null,
);

class MessageInput extends ConsumerStatefulWidget {
  final String roomId;

  const MessageInput({super.key, required this.roomId});

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  final _controller = TextEditingController();
  bool _hasText = false;
  bool _isSending = false;
  Timer? _typingTimer;
  bool _isTyping = false;
  final _imagePicker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    // Stop typing notice when leaving
    _stopTyping();
    super.dispose();
  }

  void _onTextChanged() {
    setState(() {
      _hasText = _controller.text.trim().isNotEmpty;
    });
    _handleTyping();
  }

  void _handleTyping() {
    if (!_isTyping) {
      _isTyping = true;
      _sendTypingNotice(true);
    }
    // Reset the timer
    _typingTimer?.cancel();
    _typingTimer = Timer(const Duration(seconds: 3), () {
      _stopTyping();
    });
  }

  void _stopTyping() {
    if (_isTyping) {
      _isTyping = false;
      _sendTypingNotice(false);
    }
  }

  void _sendTypingNotice(bool typing) {
    rust
        .sendTypingNotice(roomId: widget.roomId, typing: typing)
        .catchError((_) {});
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _controller.clear();
    _stopTyping();

    final replyTo = ref.read(replyingToProvider(widget.roomId));
    ref.read(replyingToProvider(widget.roomId).notifier).state = null;

    try {
      if (replyTo != null) {
        await rust.sendReply(
          roomId: widget.roomId,
          message: text,
          replyToEventId: replyTo.id,
        );
      } else {
        await rust.sendMessage(roomId: widget.roomId, message: text);
      }
      // Refresh message list after sending
      ref.invalidate(messagesProvider(widget.roomId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  Future<void> _pickImage() async {
    if (_isSending) return;

    try {
      final pickedFile = await _imagePicker.pickImage(
        source: ImageSource.gallery,
        imageQuality: 85,
      );
      if (pickedFile == null) return;

      setState(() => _isSending = true);

      final bytes = await pickedFile.readAsBytes();
      final filename = pickedFile.name;

      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: filename,
      );

      ref.invalidate(messagesProvider(widget.roomId));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送图片失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final replyTo = ref.watch(replyingToProvider(widget.roomId));

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border(
            top: BorderSide(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Reply preview bar
            if (replyTo != null) _buildReplyBar(replyTo),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  IconButton(
                    icon: const Icon(
                      Icons.image_outlined,
                      color: AppColors.onSurfaceVariant,
                      size: 26,
                    ),
                    onPressed: _isSending ? null : _pickImage,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(maxHeight: 120),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                      ),
                      child: TextField(
                        controller: _controller,
                        style: const TextStyle(
                          color: AppColors.onBackground,
                          fontSize: 15,
                        ),
                        decoration: const InputDecoration(
                          hintText: '消息',
                          hintStyle: TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 15,
                          ),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    curve: Curves.easeInOut,
                    width: _hasText ? 40 : 0,
                    height: 40,
                    child: _hasText
                        ? GestureDetector(
                            onTap: _isSending ? null : _sendMessage,
                            child: Container(
                              decoration: BoxDecoration(
                                color: _isSending
                                    ? AppColors.onSurfaceVariant
                                    : AppColors.primary,
                                shape: BoxShape.circle,
                              ),
                              child: _isSending
                                  ? const Padding(
                                      padding: EdgeInsets.all(10),
                                      child: CircularProgressIndicator(
                                        color: Colors.white,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.send_rounded,
                                      color: Colors.white,
                                      size: 20,
                                    ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                  if (!_hasText)
                    IconButton(
                      icon: const Icon(
                        Icons.mic_none_rounded,
                        color: AppColors.onSurfaceVariant,
                        size: 26,
                      ),
                      onPressed: () {},
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 40,
                        minHeight: 40,
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildReplyBar(rust.ChatMessage replyTo) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.3),
        border: Border(left: BorderSide(color: AppColors.primary, width: 3)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  replyTo.senderName,
                  style: TextStyle(
                    color: AppColors.primary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  replyTo.content,
                  style: TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          GestureDetector(
            onTap: () {
              ref.read(replyingToProvider(widget.roomId).notifier).state = null;
            },
            child: const Icon(
              Icons.close_rounded,
              color: AppColors.onSurfaceVariant,
              size: 18,
            ),
          ),
        ],
      ),
    );
  }
}
