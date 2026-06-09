import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/message_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

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

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      setState(() {
        _hasText = _controller.text.trim().isNotEmpty;
      });
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    setState(() => _isSending = true);
    _controller.clear();

    try {
      await rust.sendMessage(roomId: widget.roomId, message: text);
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

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: AppColors.background,
          border: Border(
            top: BorderSide(
              color: AppColors.surfaceVariant.withValues(alpha: 0.5),
              width: 0.5,
            ),
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            IconButton(
              icon: const Icon(
                Icons.add_circle_outline_rounded,
                color: AppColors.onSurfaceVariant,
                size: 26,
              ),
              onPressed: () {},
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
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
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
              ),
          ],
        ),
      ),
    );
  }
}
