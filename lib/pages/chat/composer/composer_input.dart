import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../features/markdown/markdown_text_editing_controller.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/composer_keyboard_settings_provider.dart';
import '../../../providers/composer_attachment_provider.dart';
import '../../../providers/interaction_mode_provider.dart';
import '../../../src/rust/api/matrix.dart' as rust;
import '../../../theme/neu_colors.dart';
import '../../../widgets/glass.dart';
import '../attachment_picker.dart';
import '../desktop_clipboard.dart';
import 'composer_actions_bar.dart';
import 'composer_autocomplete_popup.dart';
import 'composer_keyboard_controller.dart';
import 'composer_draft_controller.dart';
import 'composer_quote_banner.dart';
import 'composer_send_controller.dart';
import 'composer_text_field.dart';
import 'composer_typing_controller.dart';
import 'composer_tools_controller.dart';
import '../composer_layout.dart';
import '../composer_autocomplete.dart';
import '../composer_picker_panel.dart';
import '../latest_message_control.dart';

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
  ConsumerState<MessageInput> createState() => MessageInputState();
}

class MessageInputState extends ConsumerState<MessageInput> {
  late final ComposerSendController _sender;
  late final ComposerDraftController _draftController;

  final _controller = MarkdownTextEditingController();
  final _focusNode = FocusNode();
  late final ComposerKeyboardController _keyboard;
  final _textFieldKey = GlobalKey();
  final _pendingImagesKey = GlobalKey<AttachmentPickerState>();
  late final RoomAccountKey _draftKey;
  bool _hasText = false;
  bool _readingClipboard = false;
  late final ComposerToolsController _tools;

  late final ComposerTypingController _typingController;
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;
  int _pickerInstance = 0;
  InputPanelMode _lastPickerPanelMode = InputPanelMode.emoji;

  @override
  void initState() {
    super.initState();
    // This state belongs to the account that opened it. During an account
    // switch it may remain alive for a frame; pin all draft and typing work
    // to the originating account instead of following the global provider.
    _draftKey = activeRoomAccountKey(ref, widget.roomId);
    if (widget.panelMode == InputPanelMode.attachment) {
      _lastPickerPanelMode = InputPanelMode.attachment;
    }
    _typingController = ComposerTypingController(
      userId: _draftKey.userId,
      roomId: widget.roomId,
    );
    _draftController = ComposerDraftController(
      ref: ref,
      draftKey: _draftKey,
      textController: _controller,
      onTextRestored: () {
        setState(() => _hasText = _controller.text.trim().isNotEmpty);
      },
      onEditingCancelled: _stopTyping,
      onTextChanged: _onTextChanged,
    );
    _sender = ComposerSendController(
      ref: ref,
      draftKey: _draftKey,
      context: () => context,
      isMounted: () => mounted,
      textController: _controller,
      textFieldKey: _textFieldKey,
      totalMembers: () => widget.totalMembers,
      sourceLoading: () => _draftController.isSourceLoading,
      composerOpen: () => _tools.composerOpen,
      shouldRestoreKeyboard: () =>
          widget.panelMode == InputPanelMode.keyboard || _focusNode.hasFocus,
      showKeyboard: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          widget.onPanelModeChanged(InputPanelMode.keyboard);
          _focusNode.requestFocus();
          SystemChannels.textInput.invokeMethod<void>('TextInput.show');
        });
      },
      stopTyping: _stopTyping,
      onChanged: () => setState(() {}),
      resolveSendPresentation: () => widget.resolveSendPresentation(),
      onMessageQueued: (id, presentation) =>
          widget.onMessageQueued(id, presentation),
      onMessageSent: (presentation, inserted) =>
          widget.onMessageSent(presentation, inserted),
    );
    _tools = ComposerToolsController(
      ref: ref,
      draftKey: _draftKey,
      context: () => context,
      isMounted: () => mounted,
      textController: _controller,
      totalMembers: () => widget.totalMembers,
      inlineImages: () => _inlineImages,
      isDesktop: () => _isDesktop,
      keyboardMouse: () => _keyboardMouse,
      sourceLoading: () => _draftController.isSourceLoading,
      hidePanel: () {
        _focusNode.unfocus();
        widget.onPanelModeChanged(InputPanelMode.none);
      },
      showKeyboard: _showKeyboard,
      onChanged: () => setState(() {}),
      onTyping: (typing) => typing ? _handleTyping() : _stopTyping(),
      sendText: _sender.sendText,
      resolveSendPresentation: () => widget.resolveSendPresentation(),
      onMessageQueued: (id, presentation) =>
          widget.onMessageQueued(id, presentation),
      onMessageSent: (presentation, inserted) =>
          widget.onMessageSent(presentation, inserted),
    );
    _draftController.restoreInitialText();
    _hasText = _controller.text.trim().isNotEmpty;
    _keyboard = ComposerKeyboardController(
      ref: ref,
      roomId: widget.roomId,
      text: _controller,
      focus: _focusNode,
      context: () => context,
      isMounted: () => mounted,
      keyboardMouse: () => _isDesktop || _keyboardMouse,
      onChanged: () => setState(() {}),
      onPaste: _pasteClipboard,
      onSend: _sendMessage,
    );
    _keyboard.initialize();
    _controller.addListener(_onTextChanged);
    ref.read(composerKeyboardSettingsProvider);
    _focusNode.onKeyEvent = _keyboard.handleKey;
    _focusNode.addListener(() {
      if (!mounted) return;
      if (_focusNode.hasFocus) {
        widget.onPanelModeChanged(InputPanelMode.keyboard);
      }
      setState(() {});
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
    _draftController.dispose();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _keyboard.dispose();
    _typingController.dispose();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    final autocompleteChanged = _keyboard.textChanged();
    _draftController.saveText();
    if (_hasText != hasText || autocompleteChanged) {
      setState(() => _hasText = hasText);
    }
    if (hasText) {
      _handleTyping();
    } else {
      _stopTyping();
    }
  }

  void _handleTyping() => _typingController.activity();

  void _stopTyping() => _typingController.stop();

  bool get _isDesktop => switch (Theme.of(context).platform) {
    TargetPlatform.linux ||
    TargetPlatform.macOS ||
    TargetPlatform.windows => true,
    _ => false,
  };

  bool get _keyboardMouse => ref
      .read(interactionModeProvider)
      .usesKeyboardMouse(Theme.of(context).platform);

  bool get _inlineImages =>
      _isDesktop ||
      _keyboardMouse ||
      ref.read(composerAttachmentDraftProvider(_draftKey)).selected.isNotEmpty;

  bool get _expandedComposer => MediaQuery.sizeOf(context).width >= 600;

  Future<void> _pasteClipboard(SelectionChangedCause cause) async {
    if (_readingClipboard ||
        _tools.attachmentsOpen ||
        _draftController.isSourceLoading) {
      return;
    }
    _readingClipboard = true;
    try {
      final image = await readClipboardImage();
      if (!mounted ||
          (ref.read(activeUserIdProvider) ?? '') != _draftKey.userId) {
        return;
      }
      if (image != null) {
        if (_inlineImages) {
          unawaited(previewExternalFiles([image]));
        } else {
          await previewExternalFiles([image]);
        }
      } else {
        final editable = _focusNode.context
            ?.findAncestorStateOfType<EditableTextState>();
        await editable?.pasteText(cause);
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('粘贴失败: $error')));
      }
    } finally {
      _readingClipboard = false;
    }
  }

  Future<void> previewExternalFiles(List<XFile> files) =>
      _tools.previewExternalFiles(files);

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

  void insertMention(String userId) {
    final selection = _controller.selection;
    final current = _controller.text;
    final start = selection.start >= 0 ? selection.start : current.length;
    final end = selection.end >= 0 ? selection.end : current.length;
    final needsLeadingSpace =
        start > 0 && current.substring(start - 1, start).trim().isNotEmpty;
    final needsTrailingSpace =
        end == current.length ||
        current.substring(end, end + 1).trim().isNotEmpty;
    _keyboard.insertText(
      '${needsLeadingSpace ? ' ' : ''}$userId${needsTrailingSpace ? ' ' : ''}',
    );
    _showKeyboard();
  }

  Future<void> _sendMessage() async {
    if (_inlineImages &&
        ref.read(editingMessageProvider(_draftKey)) == null &&
        ref
            .read(composerAttachmentDraftProvider(_draftKey))
            .selected
            .isNotEmpty) {
      await _sendPendingImages();
      return;
    }
    await _sender.sendText(_controller.text);
  }

  Future<bool> _sendPendingImages() async {
    final pending = ref.read(composerAttachmentDraftProvider(_draftKey));
    if (pending.isSending || _sender.isSending) return false;
    final sender = _pendingImagesKey.currentState;
    if (sender == null) return false;
    final text = _controller.text;
    final draftState = ref.read(messageDraftProvider(_draftKey).notifier);
    try {
      final sent = await sender.sendSelectedMedia(description: text);
      if (sent && draftState.mounted && draftState.value == text) {
        draftState.value = '';
      }
      if (sent && mounted && _controller.text == text) _controller.clear();
      if (mounted) _showKeyboard();
      return sent;
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('发送失败: $error')));
      }
      return false;
    }
  }

  void _toggleAttachmentPicker() {
    if (_inlineImages) {
      unawaited(_tools.pickImages());
      return;
    }
    _toggleAttachmentPanel();
  }

  void _toggleAttachmentPanel() {
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
    _keyboard.insertText(emoji);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final desktop = ref
        .watch(interactionModeProvider)
        .usesKeyboardMouse(Theme.of(context).platform);
    final pendingImages = ref.watch(composerAttachmentDraftProvider(_draftKey));
    final inlineImages =
        _isDesktop ||
        desktop ||
        pendingImages.selected.isNotEmpty ||
        pendingImages.isSending;
    final expanded = _expandedComposer;
    final replyTo = ref.watch(replyingToProvider(_draftKey));
    final editing = ref.watch(editingMessageProvider(_draftKey));
    // Do not expose a stale draft while the selected edit source is loading.
    _draftController.synchronize(editing);
    final editingSendId = ref.watch(editingSendInFlightProvider(_draftKey));
    final editingSendInFlight = editing != null && editingSendId == editing.id;
    final editingSourceLoading = _draftController.isSourceLoading;
    final hasImages = pendingImages.selected.isNotEmpty;
    final sendBusy =
        _sender.isSending ||
        editingSendInFlight ||
        editingSourceLoading ||
        pendingImages.isSending;
    final autocompleteMatch = _focusNode.hasFocus && !_keyboard.isComposing
        ? _keyboard.match
        : null;
    AsyncValue<List<rust.Contact>>? membersAsync;
    AsyncValue<List<rust.ChatRoom>>? roomsAsync;
    if (autocompleteMatch?.kind == ComposerAutocompleteKind.mention) {
      membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    } else if (autocompleteMatch?.kind == ComposerAutocompleteKind.room) {
      roomsAsync = ref.watch(chatRoomsProvider);
    }
    final autocompleteOptions = autocompleteMatch == null
        ? const <ComposerAutocompleteOption>[]
        : _keyboard.options(
            autocompleteMatch,
            members: membersAsync?.asData?.value,
            rooms: roomsAsync?.asData?.value,
          );
    final autocompleteLoading =
        membersAsync?.isLoading == true || roomsAsync?.isLoading == true;
    final visiblePickerMode =
        widget.panelMode == InputPanelMode.emoji ||
            widget.panelMode == InputPanelMode.attachment
        ? widget.panelMode
        : _lastPickerPanelMode;

    final attachmentKeyboard =
        visiblePickerMode == InputPanelMode.attachment &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final panelContentHeight = attachmentKeyboard
        ? widget.pickerHeight
        : widget.pickerFullHeight;

    final input = SafeArea(
      top: false,
      child: ColoredBox(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Edit bar takes precedence; otherwise show reply bar.
            if (editing != null)
              ComposerQuoteBanner.editing(
                content: editing.content,
                sendInFlight: editingSendInFlight,
                onCancel: () {
                  ref.read(editingMessageProvider(_draftKey).notifier).value =
                      null;
                  ref.read(editingDraftProvider(_draftKey).notifier).value =
                      null;
                },
              )
            else if (replyTo != null)
              ComposerQuoteBanner.reply(
                senderName: replyTo.senderName,
                content: replyTo.content,
                onCancel: () {
                  ref.read(replyingToProvider(_draftKey).notifier).value = null;
                },
              ),
            if (autocompleteMatch != null &&
                (autocompleteOptions.isNotEmpty || autocompleteLoading))
              Flexible(
                fit: FlexFit.loose,
                child: ComposerAutocompletePopup(
                  options: autocompleteOptions,
                  loading: autocompleteLoading,
                  viewportItemCount: MediaQuery.sizeOf(context).width < 600
                      ? 4
                      : 8,
                  selectedIndex: _keyboard.index,
                  scrollController: _keyboard.scroll,
                  onHover: _keyboard.hover,
                  onSelected: (option) {
                    final match = _keyboard.match;
                    if (match != null) _keyboard.select(match, option);
                  },
                ),
              ),
            ComposerSurface(
              expanded: expanded,
              compact: desktop,
              child: ComposerActionsBar(
                expanded: expanded,
                compact: desktop,
                showMore: _isDesktop || desktop,
                inlineImages: inlineImages,
                emojiIcon: widget.panelMode == InputPanelMode.emoji
                    ? Icons.keyboard_rounded
                    : (_pickerTab == ComposerPickerTab.sticker
                          ? Icons.interests_rounded
                          : Icons.sentiment_satisfied_alt_rounded),
                emojiSelected: widget.panelMode == InputPanelMode.emoji,
                attachmentSelected:
                    widget.panelMode == InputPanelMode.attachment,
                sendBusy: sendBusy,
                hasText: _hasText,
                hasImages: hasImages,
                onToggleEmoji: widget.panelMode == InputPanelMode.emoji
                    ? _showKeyboard
                    : _togglePicker,
                onToggleAttachment: _toggleAttachmentPicker,
                onShowTools: _tools.showToolsMenu,
                onSend: _sendMessage,
                attachments:
                    inlineImages && (hasImages || pendingImages.isSending)
                    ? AttachmentPicker(
                        key: _pendingImagesKey,
                        inline: true,
                        draft: pendingImages,
                        composerController: _controller,
                        onInlineSend: _sendPendingImages,
                        roomId: widget.roomId,
                        accountUserId: _draftKey.userId,
                        height: 0,
                        maxHeight: 0,
                        totalMembers: widget.totalMembers,
                        onRefresh: (_) => refreshMessagesContainer(
                          ProviderScope.containerOf(context, listen: false),
                          widget.roomId,
                        ),
                        resolveSendPresentation: widget.resolveSendPresentation,
                        onMessageQueued: widget.onMessageQueued,
                        onMessageSent: widget.onMessageSent,
                        onHeightChanged: (_) {},
                        onClose: _showKeyboard,
                      )
                    : null,
                editor: ComposerTextField(
                  key: _textFieldKey,
                  controller: _controller,
                  focusNode: _focusNode,
                  expanded: expanded,
                  compact: desktop,
                  readOnly: editingSourceLoading,
                  onPaste: (_isDesktop || desktop)
                      ? () {
                          ContextMenuController.removeAny();
                          unawaited(
                            _pasteClipboard(SelectionChangedCause.toolbar),
                          );
                        }
                      : null,
                  onTap: () =>
                      widget.onPanelModeChanged(InputPanelMode.keyboard),
                ),
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
                  minHeight: panelContentHeight,
                  maxHeight: panelContentHeight,
                  child: SizedBox(
                    width: double.infinity,
                    height: panelContentHeight,
                    child:
                        widget.pickerHeight <= 0 &&
                            widget.panelMode != InputPanelMode.attachment
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
                                _sender.sendSticker(sticker, sourceRect);
                              },
                              onHeightChanged: widget.onPickerHeightChanged,
                            ),
                            InputPanelMode.attachment => AttachmentPicker(
                              key: ValueKey(
                                'attachment_picker_${_draftKey.userId}_${widget.roomId}',
                              ),
                              roomId: widget.roomId,
                              accountUserId: _draftKey.userId,
                              onRefresh: (roomId) =>
                                  refreshMessages(ref, roomId),
                              resolveSendPresentation:
                                  widget.resolveSendPresentation,
                              onMessageSent: widget.onMessageSent,
                              onMessageQueued: widget.onMessageQueued,
                              totalMembers: widget.totalMembers,
                              height: attachmentKeyboard
                                  ? widget.pickerHeight
                                  : widget.pickerBaseHeight,
                              maxHeight: attachmentKeyboard
                                  ? widget.pickerHeight
                                  : widget.pickerMaxHeight,
                              onHeightChanged: (height) {
                                if (!attachmentKeyboard) {
                                  widget.onPickerHeightChanged(height);
                                }
                              },
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

    if (expanded) return input;
    if (context.isMaterial) {
      return ColoredBox(color: colors.glassFill, child: input);
    }
    return ClipRect(
      child: Stack(
        alignment: Alignment.bottomCenter,
        children: [
          const Positioned.fill(child: BottomFadeBlur(useShader: true)),
          input,
        ],
      ),
    );
  }
}
