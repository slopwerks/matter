import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../providers/auth_provider.dart';
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

enum InputPanelMode { none, keyboard, emoji }

class MessageInput extends ConsumerStatefulWidget {
  final String roomId;
  final InputPanelMode panelMode;
  final double pickerHeight;
  final double pickerFullHeight;
  final double pickerBaseHeight;
  final double pickerMaxHeight;
  final bool animatePickerHeight;
  final ValueChanged<InputPanelMode> onPanelModeChanged;
  final ValueChanged<double> onPickerHeightChanged;

  const MessageInput({
    super.key,
    required this.roomId,
    required this.panelMode,
    required this.pickerHeight,
    required this.pickerFullHeight,
    required this.pickerBaseHeight,
    required this.pickerMaxHeight,
    required this.animatePickerHeight,
    required this.onPanelModeChanged,
    required this.onPickerHeightChanged,
  });

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  static const _toolbarAnimationDuration = Duration(milliseconds: 180);
  static const _toolbarAnimationCurve = Curves.easeOutCubic;

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;
  bool _isSending = false;
  Timer? _typingTimer;
  bool _isTyping = false;
  final _imagePicker = ImagePicker();
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;
  int _pickerInstance = 0;

  /// Tracks the event id currently being edited, so we only prefill the input
  /// when the edited message changes (not on every rebuild).
  String? _lastEditingId;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onTextChanged);
    _focusNode.addListener(() {
      if (_focusNode.hasFocus && mounted) {
        widget.onPanelModeChanged(InputPanelMode.keyboard);
      }
    });
  }

  @override
  void didUpdateWidget(covariant MessageInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.panelMode != widget.panelMode &&
        widget.panelMode == InputPanelMode.none) {
      _focusNode.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    }
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
    final hasText = _controller.text.trim().isNotEmpty;
    if (_hasText != hasText) {
      setState(() {
        _hasText = hasText;
      });
    }
    if (hasText) {
      _handleTyping();
    } else {
      _stopTyping();
    }
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
    final nextTab = tab ?? _pickerTab;
    final sameTab = nextTab == _pickerTab;
    if (widget.panelMode == InputPanelMode.emoji && sameTab) {
      widget.onPanelModeChanged(InputPanelMode.none);
      return;
    }

    if (widget.panelMode != InputPanelMode.emoji) {
      _pickerInstance++;
    }
    setState(() => _pickerTab = nextTab);
    _focusNode.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPanelModeChanged(InputPanelMode.emoji);
    });
  }

  void _showKeyboard() {
    widget.onPanelModeChanged(InputPanelMode.keyboard);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focusNode.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
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
    final shouldRestoreKeyboard =
        widget.panelMode == InputPanelMode.keyboard || _focusNode.hasFocus;

    final isNewMessage = editing == null;
    final localId = isNewMessage
        ? '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}'
        : null;
    if (localId != null) {
      upsertLocalOutgoingMessage(
        ref,
        widget.roomId,
        LocalOutgoingMessage(
          message: _localTextMessage(
            id: localId,
            text: text,
            inReplyTo: replyTo?.id,
          ),
        ),
      );
      _controller.clear();
      if (replyTo != null) {
        ref.read(replyingToProvider(widget.roomId).notifier).value = null;
      }
    }

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
      if (!mounted) return;
      _stopTyping();
      if (!isNewMessage) _controller.clear();
      if (editing != null) {
        ref.read(editingMessageProvider(widget.roomId).notifier).value = null;
      }
      if (localId != null && mounted) {
        final sentId = markLocalOutgoingMessageSent(
          ref,
          widget.roomId,
          localId,
        );
        unawaited(_reconcileSentLocalMessage(sentId));
      } else {
        unawaited(refreshMessages(ref, widget.roomId));
      }
    } catch (e) {
      if (localId != null && mounted) {
        removeLocalOutgoingMessage(ref, widget.roomId, localId);
        upsertLocalOutgoingMessage(
          ref,
          widget.roomId,
          LocalOutgoingMessage(
            message: _localTextMessage(
              id: failedLocalOutgoingId(localId),
              text: text,
              inReplyTo: replyTo?.id,
            ),
          ),
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送失败: $e'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isSending = false);
        if (shouldRestoreKeyboard) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.onPanelModeChanged(InputPanelMode.keyboard);
            _focusNode.requestFocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          });
        }
      }
    }
  }

  Future<void> _reconcileSentLocalMessage(String localId) async {
    const retryDelays = [
      Duration.zero,
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
    ];
    for (final delay in retryDelays) {
      if (delay != Duration.zero) await Future<void>.delayed(delay);
      if (!mounted) return;
      final stillLocal = ref
          .read(localOutgoingMessagesProvider(widget.roomId))
          .any((message) => message.message.id == localId);
      if (!stillLocal) return;
      await refreshMessages(ref, widget.roomId);
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
  }

  rust.ChatMessage _localTextMessage({
    required String id,
    required String text,
    String? inReplyTo,
  }) {
    final currentUser = ref.read(currentUserProvider);
    return rust.ChatMessage(
      id: id,
      senderId: currentUser?.id ?? '',
      senderName: '我',
      content: text,
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
      isMe: true,
      msgType: rust.MessageType.text,
      inReplyTo: inReplyTo,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: 0,
    );
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
      final imageSize = await _decodeImageSize(bytes);

      await rust.sendImageMessage(
        roomId: widget.roomId,
        imageData: bytes,
        filename: filename,
        width: imageSize?.width.round(),
        height: imageSize?.height.round(),
      );

      unawaited(refreshMessages(ref, widget.roomId));
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

  Future<Size?> _decodeImageSize(Uint8List bytes) async {
    try {
      final completer = Completer<ui.Image>();
      ui.decodeImageFromList(bytes, completer.complete);
      final image = await completer.future;
      final size = Size(image.width.toDouble(), image.height.toDouble());
      image.dispose();
      return size;
    } catch (_) {
      return null;
    }
  }

  void _insertEmoji(String emoji) {
    _insertComposerText(emoji);
  }

  rust.ChatMessage _localStickerMessage({
    required String id,
    required StickerItem sticker,
    required String displayImageUrl,
  }) {
    final currentUser = ref.read(currentUserProvider);
    final now = DateTime.now().millisecondsSinceEpoch.toString();
    return rust.ChatMessage(
      id: id,
      senderId: currentUser?.id ?? '',
      senderName: '我',
      content: sticker.body,
      timestamp: now,
      isMe: true,
      msgType: rust.MessageType.image,
      imageUrl: displayImageUrl,
      imageWidth: sticker.width,
      imageHeight: sticker.height,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: 0,
    );
  }

  Future<void> _sendSticker(StickerItem sticker) async {
    final imageUrl = sticker.imageUrl;
    if (imageUrl == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('贴纸缺少图片地址'),
          duration: Duration(seconds: 2),
        ),
      );
      return;
    }

    final localId =
        '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}';
    final displayImageUrl =
        cachedResolvedMxcUrl(ref, sticker.thumbnailUrl ?? imageUrl) ??
        cachedResolvedMxcUrl(ref, imageUrl) ??
        imageUrl;
    upsertLocalOutgoingMessage(
      ref,
      widget.roomId,
      LocalOutgoingMessage(
        message: _localStickerMessage(
          id: localId,
          sticker: sticker,
          displayImageUrl: displayImageUrl,
        ),
        sourceImageUrl: imageUrl,
      ),
    );

    try {
      await rust.sendSticker(
        roomId: widget.roomId,
        imageUrl: imageUrl,
        body: sticker.body,
        mimeType: sticker.mimeType,
        width: sticker.width,
        height: sticker.height,
      );
      _stopTyping();
      if (!mounted) return;
      final sentId = markLocalOutgoingMessageSent(ref, widget.roomId, localId);
      unawaited(_reconcileSentLocalMessage(sentId));
    } catch (e) {
      if (mounted) {
        removeLocalOutgoingMessage(ref, widget.roomId, localId);
        upsertLocalOutgoingMessage(
          ref,
          widget.roomId,
          LocalOutgoingMessage(
            message: _localStickerMessage(
              id: failedLocalOutgoingId(localId),
              sticker: sticker,
              displayImageUrl: displayImageUrl,
            ),
            sourceImageUrl: imageUrl,
          ),
        );
      }
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
                        widget.panelMode == InputPanelMode.emoji
                            ? Icons.keyboard_rounded
                            : (_pickerTab == ComposerPickerTab.sticker
                                  ? Icons.sticky_note_2_rounded
                                  : Icons.sentiment_satisfied_alt_rounded),
                        color: widget.panelMode == InputPanelMode.emoji
                            ? AppColors.primary
                            : AppColors.onSurfaceVariant,
                        size: 25,
                      ),
                      onPressed: _isSending
                          ? null
                          : widget.panelMode == InputPanelMode.emoji
                          ? _showKeyboard
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
                          widget.onPanelModeChanged(InputPanelMode.keyboard);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  AnimatedContainer(
                    duration: _toolbarAnimationDuration,
                    curve: _toolbarAnimationCurve,
                    width: _hasText ? 44 : 94,
                    height: 44,
                    alignment: Alignment.centerRight,
                    child: ClipRect(
                      child: AnimatedSwitcher(
                        duration: _toolbarAnimationDuration,
                        switchInCurve: _toolbarAnimationCurve,
                        switchOutCurve: Curves.easeInCubic,
                        layoutBuilder: (currentChild, previousChildren) {
                          return Stack(
                            alignment: Alignment.centerRight,
                            children: [...previousChildren, ?currentChild],
                          );
                        },
                        transitionBuilder: (child, animation) {
                          final scale = Tween<double>(
                            begin: 0.92,
                            end: 1,
                          ).animate(animation);
                          return FadeTransition(
                            opacity: animation,
                            child: ScaleTransition(
                              scale: scale,
                              alignment: Alignment.centerRight,
                              child: child,
                            ),
                          );
                        },
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
                            : SizedBox(
                                key: const ValueKey('tools'),
                                width: 94,
                                height: 44,
                                child: Row(
                                  mainAxisAlignment: MainAxisAlignment.end,
                                  children: [
                                    SizedBox.square(
                                      dimension: 44,
                                      child: IconButton(
                                        tooltip: '文件发送暂仅支持图片',
                                        onPressed: _isSending
                                            ? null
                                            : _pickImage,
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
                      ),
                    ),
                  ),
                ],
              ),
            ),
            AnimatedContainer(
              duration: widget.animatePickerHeight
                  ? const Duration(milliseconds: 180)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              height: widget.pickerHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: widget.pickerFullHeight,
                  maxHeight: widget.pickerFullHeight,
                  child: SizedBox(
                    height: widget.pickerFullHeight,
                    child: widget.pickerHeight > 0
                        ? ComposerPickerPanel(
                            key: ValueKey(
                              'composer_picker_${widget.roomId}_$_pickerInstance',
                            ),
                            height: widget.pickerBaseHeight,
                            maxHeight: widget.pickerMaxHeight,
                            roomId: widget.roomId,
                            tab: _pickerTab,
                            onTabChanged: (tab) =>
                                setState(() => _pickerTab = tab),
                            onEmojiSelected: _insertEmoji,
                            onStickerSelected: (sticker) {
                              _sendSticker(sticker);
                            },
                            onHeightChanged: widget.onPickerHeightChanged,
                          )
                        : const SizedBox.shrink(),
                  ),
                ),
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
