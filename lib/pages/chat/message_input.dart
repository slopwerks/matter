import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/chat_provider.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import 'composer_picker_panel.dart';
import 'sticker_catalog.dart';

/// Provider to hold the message being replied to (per room).
final replyingToProvider =
    NotifierProvider.family<
      MutableState<rust.ChatMessage?>,
      rust.ChatMessage?,
      String
    >((_) => MutableState(null));

/// Provider to hold the message being edited (per room).
final editingMessageProvider =
    NotifierProvider.family<
      MutableState<rust.ChatMessage?>,
      rust.ChatMessage?,
      String
    >((_) => MutableState(null));

class MessageInput extends ConsumerStatefulWidget {
  final String roomId;

  const MessageInput({super.key, required this.roomId});

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _isSending = false;
  Timer? _typingTimer;
  bool _isTyping = false;
  final _imagePicker = ImagePicker();
  bool _showPicker = false;
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;

  /// Tracks the event id currently being edited, so we only prefill the input
  /// when the edited message changes (not on every rebuild).
  String? _lastEditingId;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && _showPicker && mounted) {
        setState(() => _showPicker = false);
      }
    });
  }

  @override
  void dispose() {
    _typingTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
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
    rust.sendTypingNotice(roomId: widget.roomId, typing: typing).catchError((
      e,
    ) {
      debugPrint('sendTypingNotice failed: $e');
    });
  }

  void _togglePicker([ComposerPickerTab? tab]) {
    setState(() {
      final nextTab = tab ?? _pickerTab;
      final sameTab = nextTab == _pickerTab;
      if (_showPicker && sameTab) {
        _showPicker = false;
      } else {
        _pickerTab = nextTab;
        _showPicker = true;
        _focusNode.unfocus();
      }
    });
  }

  void _insertComposerText(String value) {
    final selection = _controller.selection;
    final current = _controller.text;
    final start = selection.start >= 0 ? selection.start : current.length;
    final end = selection.end >= 0 ? selection.end : current.length;
    final inserted = current.replaceRange(start, end, value);
    _controller.value = TextEditingValue(
      text: inserted,
      selection: TextSelection.collapsed(offset: start + value.length),
    );
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isSending) return;

    final editing = ref.read(editingMessageProvider(widget.roomId));
    final replyTo = ref.read(replyingToProvider(widget.roomId));

    setState(() => _isSending = true);

    try {
      if (editing != null) {
        await rust.editMessage(
          roomId: widget.roomId,
          eventId: editing.id,
          newText: text,
        );
      } else if (replyTo != null) {
        await rust.sendReply(
          roomId: widget.roomId,
          message: text,
          replyToEventId: replyTo.id,
        );
      } else {
        await rust.sendMessage(roomId: widget.roomId, message: text);
      }
      _stopTyping();
      _controller.clear();
      if (editing != null) {
        ref.read(editingMessageProvider(widget.roomId).notifier).value = null;
      } else if (replyTo != null) {
        ref.read(replyingToProvider(widget.roomId).notifier).value = null;
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

  void _insertEmoji(String emoji) {
    _insertComposerText(emoji);
  }

  Future<Uint8List> _renderStickerPng(StickerItem sticker) async {
    const size = 512.0;
    const padding = 36.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final rect = const Rect.fromLTWH(0, 0, size, size);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(96));

    final background = Paint()
      ..shader = ui.Gradient.linear(
        Offset.zero,
        const Offset(size, size),
        sticker.colors,
      );
    canvas.drawRRect(rrect, background);

    final glow = Paint()
      ..shader = ui.Gradient.radial(
        const Offset(size * 0.3, size * 0.28),
        size * 0.9,
        [
          Colors.white.withValues(alpha: 0.28),
          Colors.white.withValues(alpha: 0.0),
        ],
      );
    canvas.drawRRect(rrect, glow);

    final frame = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawRRect(rrect.deflate(8), frame);

    final glyphPainter = TextPainter(
      text: TextSpan(
        text: sticker.glyph ?? sticker.body,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 92,
          fontWeight: FontWeight.w700,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 3,
    )..layout(maxWidth: size - padding * 2);
    glyphPainter.paint(
      canvas,
      Offset(
        (size - glyphPainter.width) / 2,
        (size - glyphPainter.height) / 2 - 28,
      ),
    );

    final labelPainter = TextPainter(
      text: TextSpan(
        text: sticker.label,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.92),
          fontSize: 28,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
      textDirection: TextDirection.ltr,
      textAlign: TextAlign.center,
      maxLines: 1,
    )..layout(maxWidth: size - padding * 2);
    labelPainter.paint(
      canvas,
      Offset((size - labelPainter.width) / 2, size - padding - 38),
    );

    final image = await recorder.endRecording().toImage(
      size.toInt(),
      size.toInt(),
    );
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    if (bytes == null) {
      throw StateError('生成贴纸图片失败');
    }
    return bytes.buffer.asUint8List();
  }

  Future<void> _sendSticker(StickerItem sticker) async {
    if (_isSending) return;

    setState(() => _isSending = true);
    try {
      if (sticker.isRemote && sticker.imageUrl != null) {
        await rust.sendSticker(
          roomId: widget.roomId,
          imageUrl: sticker.imageUrl!,
          body: sticker.body,
          mimeType: sticker.mimeType,
          width: sticker.width,
          height: sticker.height,
        );
      } else {
        final bytes = await _renderStickerPng(sticker);
        await rust.sendImageMessage(
          roomId: widget.roomId,
          imageData: bytes,
          filename: 'sticker__${sticker.label}.png',
        );
      }
      _stopTyping();
      ref.invalidate(messagesProvider(widget.roomId));
      if (mounted) {
        setState(() => _showPicker = false);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送贴纸失败: $e'),
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
    final editing = ref.watch(editingMessageProvider(widget.roomId));

    // When entering edit mode (or switching the edited message), prefill the
    // input with the original text. Tracked via id so re-renders don't reset.
    if (editing != null && editing.id != _lastEditingId) {
      _lastEditingId = editing.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _controller.text = editing.content;
        _controller.selection = TextSelection.fromPosition(
          TextPosition(offset: _controller.text.length),
        );
        setState(() {
          _hasText = _controller.text.trim().isNotEmpty;
        });
      });
    } else if (editing == null) {
      _lastEditingId = null;
    }

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
            // Edit bar takes precedence; otherwise show reply bar.
            if (editing != null)
              _buildEditingBar(editing)
            else if (replyTo != null)
              _buildReplyBar(replyTo),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  SizedBox.square(
                    dimension: 44,
                    child: IconButton(
                      icon: Icon(
                        _showPicker
                            ? Icons.keyboard_rounded
                            : (_pickerTab == ComposerPickerTab.sticker
                                  ? Icons.sticky_note_2_rounded
                                  : Icons.sentiment_satisfied_alt_rounded),
                        color: _showPicker
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                        size: 25,
                      ),
                      onPressed: _isSending
                          ? null
                          : () => _togglePicker(ComposerPickerTab.emoji),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      constraints: const BoxConstraints(
                        minHeight: 44,
                        maxHeight: 120,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant,
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                      ),
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        readOnly: _isSending,
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
                            vertical: 11,
                          ),
                          border: InputBorder.none,
                          isDense: true,
                        ),
                        maxLines: null,
                        textInputAction: TextInputAction.newline,
                        keyboardType: TextInputType.multiline,
                        onTap: () {
                          if (_showPicker) {
                            setState(() => _showPicker = false);
                          }
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 180),
                    transitionBuilder: (child, animation) => FadeTransition(
                      opacity: animation,
                      child: ScaleTransition(scale: animation, child: child),
                    ),
                    child: _hasText
                        ? SizedBox.square(
                            key: const ValueKey('send_only'),
                            dimension: 44,
                            child: IconButton(
                              onPressed: _isSending ? null : _sendMessage,
                              padding: EdgeInsets.zero,
                              icon: _isSending
                                  ? const SizedBox.square(
                                      dimension: 20,
                                      child: CircularProgressIndicator(
                                        color: AppColors.primary,
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(
                                      Icons.send_rounded,
                                      color: AppColors.primary,
                                      size: 25,
                                    ),
                            ),
                          )
                        : Row(
                            key: const ValueKey('tools'),
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox.square(
                                dimension: 44,
                                child: IconButton(
                                  tooltip: '文件发送暂仅支持图片',
                                  onPressed: _isSending ? null : _pickImage,
                                  padding: EdgeInsets.zero,
                                  icon: const Icon(
                                    Icons.attach_file_rounded,
                                    color: AppColors.onSurfaceVariant,
                                    size: 24,
                                  ),
                                ),
                              ),
                              SizedBox.square(
                                dimension: 44,
                                child: IconButton(
                                  tooltip: '语音消息暂未提供',
                                  icon: const Icon(
                                    Icons.mic_none_rounded,
                                    color: AppColors.onSurfaceVariant,
                                    size: 25,
                                  ),
                                  onPressed: null,
                                  padding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: ComposerPickerPanel(
                roomId: widget.roomId,
                tab: _pickerTab,
                onTabChanged: (tab) => setState(() => _pickerTab = tab),
                onEmojiSelected: _insertEmoji,
                onStickerSelected: (sticker) {
                  _sendSticker(sticker);
                },
              ),
              crossFadeState: _showPicker
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 180),
              sizeCurve: Curves.easeOutCubic,
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
              ref.read(replyingToProvider(widget.roomId).notifier).value = null;
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

  Widget _buildEditingBar(rust.ChatMessage editing) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      decoration: BoxDecoration(
        color: AppColors.surfaceVariant.withValues(alpha: 0.3),
        border: Border(left: BorderSide(color: AppColors.primary, width: 3)),
      ),
      child: Row(
        children: [
          const Icon(Icons.edit_rounded, color: AppColors.primary, size: 16),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '编辑中',
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
                  editing.content,
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
              ref.read(editingMessageProvider(widget.roomId).notifier).value =
                  null;
              _controller.clear();
              setState(() => _hasText = false);
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
