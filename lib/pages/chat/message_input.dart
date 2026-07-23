import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../features/markdown/markdown_composer.dart';
import '../../features/markdown/markdown_source_store.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';
import '../../widgets/liquid_glass.dart';
import 'attachment_picker.dart';
import 'composer_picker_panel.dart';
import 'latest_message_control.dart';
import 'send_flight.dart';
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

typedef MessageDraftKey = ({String roomId, String userId});

/// In-memory draft text, isolated by both account and room.
final messageDraftProvider =
    NotifierProvider.family<MutableState<String>, String, MessageDraftKey>(
      (_) => MutableState(''),
    );

enum InputPanelMode { none, keyboard, emoji, attachment }

class MessageInput extends ConsumerStatefulWidget {
  final String roomId;
  final int totalMembers;
  final InputPanelMode panelMode;
  final double pickerHeight;
  final double pickerFullHeight;
  final double pickerBaseHeight;
  final double pickerMaxHeight;
  final bool animatePickerHeight;
  final ValueChanged<InputPanelMode> onPanelModeChanged;
  final ValueChanged<double> onPickerHeightChanged;
  final MessageSendPresentation Function() resolveSendPresentation;
  final void Function(
    String stableMessageId,
    MessageSendPresentation presentation,
  )
  onMessageQueued;
  final void Function(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  )
  onMessageSent;

  const MessageInput({
    super.key,
    required this.roomId,
    required this.totalMembers,
    required this.panelMode,
    required this.pickerHeight,
    required this.pickerFullHeight,
    required this.pickerBaseHeight,
    required this.pickerMaxHeight,
    required this.animatePickerHeight,
    required this.onPanelModeChanged,
    required this.onPickerHeightChanged,
    required this.resolveSendPresentation,
    required this.onMessageQueued,
    required this.onMessageSent,
  });

  @override
  ConsumerState<MessageInput> createState() => _MessageInputState();
}

class _MessageInputState extends ConsumerState<MessageInput> {
  static const _toolbarAnimationDuration = Duration(milliseconds: 180);
  static const _toolbarAnimationCurve = Curves.easeOutCubic;
  static const _markdownComposer = MarkdownComposer();
  static const _markdownSourceStore = MarkdownSourceStore();

  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _textFieldKey = GlobalKey();
  late final MessageDraftKey _draftKey;
  bool _hasText = false;
  bool _isSending = false;
  Timer? _typingTimer;
  bool _isTyping = false;
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;
  int _pickerInstance = 0;
  InputPanelMode _lastPickerPanelMode = InputPanelMode.emoji;

  /// Tracks the event id currently being edited, so we only prefill the input
  /// when the edited message changes (not on every rebuild).
  String? _lastEditingId;

  @override
  void initState() {
    super.initState();
    if (widget.panelMode == InputPanelMode.attachment) {
      _lastPickerPanelMode = InputPanelMode.attachment;
    }
    _draftKey = (
      roomId: widget.roomId,
      userId:
          ref.read(activeUserIdProvider) ??
          ref.read(currentUserProvider)?.id ??
          'anonymous',
    );
    final draft = ref.read(messageDraftProvider(_draftKey));
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _hasText = draft.trim().isNotEmpty;
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
    if (widget.panelMode == InputPanelMode.emoji ||
        widget.panelMode == InputPanelMode.attachment) {
      _lastPickerPanelMode = widget.panelMode;
    }
    if (oldWidget.panelMode != widget.panelMode &&
        widget.panelMode == InputPanelMode.none) {
      _focusNode.unfocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    } else if (oldWidget.panelMode != widget.panelMode &&
        widget.panelMode == InputPanelMode.keyboard &&
        !_focusNode.hasFocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _focusNode.requestFocus();
        SystemChannels.textInput.invokeMethod<void>('TextInput.show');
      });
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
    if (ref.read(editingMessageProvider(widget.roomId)) == null) {
      ref.read(messageDraftProvider(_draftKey).notifier).value =
          _controller.text;
    }
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
    final compiled = _markdownComposer.compile(text);
    if (compiled.body.trim().isEmpty) return;

    final editing = ref.read(editingMessageProvider(widget.roomId));
    final replyTo = ref.read(replyingToProvider(widget.roomId));
    final shouldRestoreKeyboard =
        widget.panelMode == InputPanelMode.keyboard || _focusNode.hasFocus;

    final isNewMessage = editing == null;
    final localId = isNewMessage
        ? '$localOutgoingPendingPrefix${DateTime.now().microsecondsSinceEpoch}'
        : null;
    final localTimestamp = isNewMessage ? _nextLocalTimestamp() : null;
    final sendPresentation = localId != null
        ? widget.resolveSendPresentation()
        : null;
    if (localId != null) {
      if (sendPresentation == MessageSendPresentation.flight) {
        _registerTextSendFlight(localId, compiled.body);
      }
      widget.onMessageQueued(sendFlightId(localId), sendPresentation!);
      upsertLocalOutgoingMessage(
        ref,
        widget.roomId,
        LocalOutgoingMessage(
          message: _localTextMessage(
            id: localId,
            compiled: compiled,
            inReplyTo: replyTo?.id,
            timestamp: localTimestamp,
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
      String remoteEventId;
      if (editing != null) {
        remoteEventId = await rust.editMessage(
          roomId: widget.roomId,
          eventId: editing.id,
          message: compiled.toRust(),
          previousMentionedUserIds: editing.mentionedUserIds,
          previousMentionsRoom: editing.mentionsRoom,
        );
      } else if (replyTo != null) {
        remoteEventId = await rust.sendReply(
          roomId: widget.roomId,
          message: compiled.toRust(),
          replyToEventId: replyTo.id,
          replyToUserId: replyTo.isMe ? null : replyTo.senderId,
        );
      } else {
        remoteEventId = await rust.sendMessage(
          roomId: widget.roomId,
          message: compiled.toRust(),
        );
      }
      final persistMarkdownSource = await _canPersistMarkdownSource();
      await _markdownSourceStore.save(
        userId: _draftKey.userId,
        roomId: widget.roomId,
        eventId: editing?.id ?? remoteEventId,
        source: compiled.source,
        body: compiled.body,
        formattedBody: compiled.formattedBody,
        persist: persistMarkdownSource,
      );
      if (!mounted) return;
      _stopTyping();
      if (!isNewMessage) _controller.clear();
      if (editing != null) {
        ref.read(editingMessageProvider(widget.roomId).notifier).value = null;
        _restoreDraft();
      }
      if (localId != null && mounted) {
        final sentId = markLocalOutgoingMessageSent(
          ref,
          widget.roomId,
          localId,
        );
        widget.onMessageSent(sendPresentation!, true);
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
              compiled: compiled,
              inReplyTo: replyTo?.id,
              timestamp: localTimestamp,
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

  Rect? _globalRectFor(GlobalKey key) {
    final box = key.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void _registerTextSendFlight(String localId, String text) {
    final sourceRect = _globalRectFor(_textFieldKey);
    if (sourceRect == null) return;
    unawaited(
      registerSendFlight(
        localId,
        SendFlightSpec(
          sourceRect: sourceRect,
          kind: SendFlightKind.text,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                text,
                maxLines: 5,
                overflow: TextOverflow.clip,
                style: const TextStyle(
                  color: AppColors.onBackground,
                  fontSize: 15,
                  fontWeight: FontWeight.w400,
                  decoration: TextDecoration.none,
                ),
              ),
            ),
          ),
        ),
      ),
    );
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

  int _nextLocalTimestamp() {
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    final cached = ref.read(messageCacheProvider(widget.roomId));
    for (final message in cached) {
      final ts = int.tryParse(message.timestamp) ?? 0;
      if (ts >= timestamp) timestamp = ts + 1;
    }
    final local = ref.read(localOutgoingMessagesProvider(widget.roomId));
    for (final outgoing in local) {
      final ts = int.tryParse(outgoing.message.timestamp) ?? 0;
      if (ts >= timestamp) timestamp = ts + 1;
    }
    return timestamp;
  }

  rust.ChatMessage _localTextMessage({
    required String id,
    required CompiledMarkdownMessage compiled,
    String? inReplyTo,
    int? timestamp,
  }) {
    final currentUser = ref.read(currentUserProvider);
    return rust.ChatMessage(
      id: id,
      senderId: currentUser?.id ?? '',
      senderName: '我',
      content: compiled.body,
      formattedBody: compiled.formattedBody,
      mentionedUserIds: compiled.mentionedUserIds,
      mentionsRoom: compiled.mentionsRoom,
      timestamp: (timestamp ?? DateTime.now().millisecondsSinceEpoch)
          .toString(),
      isMe: true,
      msgType: rust.MessageType.text,
      inReplyTo: inReplyTo,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: widget.totalMembers,
    );
  }

  void _toggleAttachmentPicker() {
    if (widget.panelMode == InputPanelMode.attachment) {
      widget.onPanelModeChanged(InputPanelMode.none);
      return;
    }

    _focusNode.unfocus();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPanelModeChanged(InputPanelMode.attachment);
    });
  }

  void _insertEmoji(String emoji) {
    _insertComposerText(emoji);
  }

  rust.ChatMessage _localStickerMessage({
    required String id,
    required StickerItem sticker,
    required String displayImageUrl,
    int? timestamp,
  }) {
    final currentUser = ref.read(currentUserProvider);
    return rust.ChatMessage(
      id: id,
      senderId: currentUser?.id ?? '',
      senderName: '我',
      content: sticker.body,
      mentionedUserIds: const [],
      mentionsRoom: false,
      timestamp: (timestamp ?? DateTime.now().millisecondsSinceEpoch)
          .toString(),
      isMe: true,
      msgType: rust.MessageType.sticker,
      imageUrl: displayImageUrl,
      imageWidth: sticker.width,
      imageHeight: sticker.height,
      isEdited: false,
      editHistory: const [],
      reactions: const [],
      readers: const [],
      totalMembers: widget.totalMembers,
    );
  }

  Future<void> _sendSticker(StickerItem sticker, Rect? sourceRect) async {
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
    final localTimestamp = _nextLocalTimestamp();
    final sendPresentation = widget.resolveSendPresentation();
    final displayImageUrl =
        cachedResolvedMxcUrl(ref, sticker.thumbnailUrl ?? imageUrl) ??
        cachedResolvedMxcUrl(ref, imageUrl) ??
        imageUrl;
    if (sendPresentation == MessageSendPresentation.flight &&
        sourceRect != null) {
      unawaited(
        registerSendFlight(
          localId,
          SendFlightSpec(
            sourceRect: sourceRect,
            kind: SendFlightKind.sticker,
            child: StickerFlightPreview(sticker: sticker),
          ),
        ),
      );
    }
    widget.onMessageQueued(sendFlightId(localId), sendPresentation);
    upsertLocalOutgoingMessage(
      ref,
      widget.roomId,
      LocalOutgoingMessage(
        message: _localStickerMessage(
          id: localId,
          sticker: sticker,
          displayImageUrl: displayImageUrl,
          timestamp: localTimestamp,
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
      widget.onMessageSent(sendPresentation, true);
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
              timestamp: localTimestamp,
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
    final visiblePickerMode =
        widget.panelMode == InputPanelMode.emoji ||
            widget.panelMode == InputPanelMode.attachment
        ? widget.panelMode
        : _lastPickerPanelMode;

    // When entering edit mode (or switching the edited message), prefill the
    // input with the original text. Tracked via id so re-renders don't reset.
    if (editing != null && editing.id != _lastEditingId) {
      _lastEditingId = editing.id;
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => _prefillEditingSource(editing),
      );
    } else if (editing == null) {
      _lastEditingId = null;
    }

    final input = SafeArea(
      top: false,
      child: ColoredBox(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Edit bar takes precedence; otherwise show reply bar.
            if (editing != null)
              _buildEditingBar(editing)
            else if (replyTo != null)
              _buildReplyBar(replyTo),
            LiquidGlassContainer(
              key: const ValueKey('message-input-surface'),
              margin: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              borderRadius: AppRadii.nav,
              blurSigma: 18,
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
                                  ? Icons.interests_rounded
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
                          : _togglePicker,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Container(
                      key: _textFieldKey,
                      constraints: const BoxConstraints(
                        minHeight: 44,
                        maxHeight: 120,
                      ),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceVariant.withValues(alpha: 0.58),
                        borderRadius: BorderRadius.circular(AppRadii.surface),
                        border: Border.all(color: AppColors.glassBorder),
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
                                        tooltip: '附件',
                                        onPressed: _isSending
                                            ? null
                                            : _toggleAttachmentPicker,
                                        padding: EdgeInsets.zero,
                                        icon: Icon(
                                          Icons.add_rounded,
                                          color:
                                              widget.panelMode ==
                                                  InputPanelMode.attachment
                                              ? AppColors.primary
                                              : AppColors.onSurfaceVariant,
                                          size: 26,
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
              width: double.infinity,
              height: widget.pickerHeight,
              child: ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topCenter,
                  minHeight: widget.pickerFullHeight,
                  maxHeight: widget.pickerFullHeight,
                  child: SizedBox(
                    width: double.infinity,
                    height: widget.pickerFullHeight,
                    child: widget.pickerHeight <= 0
                        ? const SizedBox.shrink()
                        : switch (visiblePickerMode) {
                            InputPanelMode.emoji => ComposerPickerPanel(
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
                              onStickerSelected: (sticker, sourceRect) {
                                _sendSticker(sticker, sourceRect);
                              },
                              onHeightChanged: widget.onPickerHeightChanged,
                            ),
                            InputPanelMode.attachment => AttachmentPicker(
                              key: ValueKey(
                                'attachment_picker_${widget.roomId}',
                              ),
                              roomId: widget.roomId,
                              onRefresh: (roomId) =>
                                  refreshMessages(ref, roomId),
                              resolveSendPresentation:
                                  widget.resolveSendPresentation,
                              onMessageSent: widget.onMessageSent,
                              height: widget.pickerBaseHeight,
                              maxHeight: widget.pickerMaxHeight,
                              onHeightChanged: widget.onPickerHeightChanged,
                              onClose: () => widget.onPanelModeChanged(
                                InputPanelMode.none,
                              ),
                            ),
                            _ => const SizedBox.shrink(),
                          },
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );

    return ClipRect(
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          Positioned.fill(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final fadeStop = constraints.maxHeight <= 32
                    ? 1.0
                    : 32 / constraints.maxHeight;
                return ShaderMask(
                  blendMode: BlendMode.dstIn,
                  shaderCallback: (bounds) => LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: const [Colors.transparent, Colors.black],
                    stops: [0, fadeStop],
                  ).createShader(bounds),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Colors.transparent,
                            AppColors.background.withValues(alpha: 0.52),
                            AppColors.background.withValues(alpha: 0.88),
                          ],
                          stops: [0, fadeStop, 1],
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          input,
        ],
      ),
    );
  }

  Future<void> _prefillEditingSource(rust.ChatMessage editing) async {
    final allowPersistence = await _canPersistMarkdownSource();
    final source = await _markdownSourceStore.load(
      userId: _draftKey.userId,
      roomId: widget.roomId,
      eventId: editing.id,
      body: editing.content,
      formattedBody: editing.formattedBody,
      allowPersistence: allowPersistence,
    );
    if (!mounted || _lastEditingId != editing.id) return;
    _controller.text = source ?? editing.content;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    setState(() => _hasText = _controller.text.trim().isNotEmpty);
  }

  Future<bool> _canPersistMarkdownSource() async {
    try {
      return !await rust.isRoomEncrypted(roomId: widget.roomId);
    } catch (_) {
      return false;
    }
  }

  void _restoreDraft() {
    _lastEditingId = null;
    _stopTyping();
    final draft = ref.read(messageDraftProvider(_draftKey));
    _controller.removeListener(_onTextChanged);
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _controller.addListener(_onTextChanged);
    final hasText = draft.trim().isNotEmpty;
    if (_hasText != hasText) {
      setState(() => _hasText = hasText);
    }
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
              _restoreDraft();
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
