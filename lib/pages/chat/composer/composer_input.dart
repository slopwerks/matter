import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../../features/markdown/markdown_text_editing_controller.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/chat_provider.dart';
import '../../../providers/disabled_sticker_packs_provider.dart';
import '../../../providers/composer_keyboard_settings_provider.dart';
import '../../../providers/composer_attachment_provider.dart';
import '../../../providers/interaction_mode_provider.dart';
import '../../../src/rust/api/matrix.dart' as rust;
import '../../../theme/neu_colors.dart';
import '../../../widgets/glass.dart';
import '../attachment_picker.dart';
import '../desktop_clipboard.dart';
import '../desktop_composer_picker.dart';
import 'composer_actions_bar.dart';
import 'composer_autocomplete_popup.dart';
import 'composer_keyboard_controller.dart';
import 'composer_draft_controller.dart';
import 'composer_quote_banner.dart';
import 'composer_send_controller.dart';
import 'composer_send.dart';
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
  final ValueChanged<bool>? onAttachmentInputFocusChanged;
  final ValueChanged<double> onPickerHeightChanged;
  final ValueChanged<double>? onChromeHeightChanged;
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
    this.onAttachmentInputFocusChanged,
    required this.onPickerHeightChanged,
    this.onChromeHeightChanged,
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
  bool _sendingPendingImages = false;
  late final ComposerToolsController _tools;

  late final ComposerTypingController _typingController;
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;
  int _pickerInstance = 0;
  final _desktopPicker = MenuController();
  bool _desktopPickerOpen = false;
  InputPanelMode _lastPickerPanelMode = InputPanelMode.emoji;
  double _renderedPickerHeight = 0;
  bool _attachmentInputFocused = false;

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
      isDesktop: () => _isDesktop,
      keyboardMouse: () => _keyboardMouse,
      sourceLoading: () => _draftController.isSourceLoading,
      hidePanel: () {
        _unfocusOwnedInputs();
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
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
      onStickerSelected: (sticker) => _sender.sendSticker(sticker, null),
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
    if (widget.panelMode != InputPanelMode.attachment &&
        _attachmentInputFocused) {
      _attachmentInputFocused = false;
      final onFocusChanged = widget.onAttachmentInputFocusChanged;
      if (onFocusChanged != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_attachmentInputFocused) onFocusChanged(false);
        });
      }
    }
    if (oldWidget.panelMode != widget.panelMode &&
        widget.panelMode == InputPanelMode.none) {
      _unfocusOwnedInputs();
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

  bool _ownsPrimaryFocus() {
    final primary = FocusManager.instance.primaryFocus;
    if (primary == null) return false;
    if (primary == _focusNode) return true;
    final primaryContext = primary.context;
    if (primaryContext == null || !mounted) return false;
    var owned = false;
    primaryContext.visitAncestorElements((element) {
      if (identical(element, context)) {
        owned = true;
        return false;
      }
      return true;
    });
    return owned;
  }

  void _unfocusOwnedInputs() {
    if (_ownsPrimaryFocus()) {
      FocusManager.instance.primaryFocus?.unfocus();
    } else {
      _focusNode.unfocus();
    }
  }

  void _handleAttachmentFocusChanged(bool focused) {
    if (!mounted || _attachmentInputFocused == focused) return;
    setState(() => _attachmentInputFocused = focused);
    widget.onAttachmentInputFocusChanged?.call(focused);
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

  bool get _expandedComposer =>
      !context.isMaterial && MediaQuery.sizeOf(context).width >= 600;

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
        unawaited(previewExternalFiles([image]));
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
    if (_isDesktop) {
      setState(() => _pickerTab = nextTab);
      if (_desktopPicker.isOpen) {
        _desktopPicker.close();
      } else {
        _desktopPicker.open();
      }
      return;
    }
    final sameTab = nextTab == _pickerTab;
    if (widget.panelMode == InputPanelMode.emoji && sameTab) {
      widget.onPanelModeChanged(InputPanelMode.none);
      return;
    }

    if (widget.panelMode != InputPanelMode.emoji) {
      _pickerInstance++;
    }
    setState(() => _pickerTab = nextTab);
    _unfocusOwnedInputs();
    SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onPanelModeChanged(InputPanelMode.emoji);
    });
  }

  void _showKeyboard() {
    if (_desktopPicker.isOpen) _desktopPicker.close();
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
    if (_sendingPendingImages) return;
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
    if (_sendingPendingImages || pending.isSending || _sender.isSending) {
      return false;
    }
    final sender = _pendingImagesKey.currentState;
    if (sender == null) return false;
    final text = _controller.text;
    final replyState = ref.read(replyingToProvider(_draftKey).notifier);
    final replyTo = replyState.value;
    final draftState = ref.read(messageDraftProvider(_draftKey).notifier);
    _sendingPendingImages = true;
    try {
      final imagesSent = await sender.sendSelectedMedia(description: '');
      if (!imagesSent) return false;
      if (!mounted || ref.read(activeUserIdProvider) != _draftKey.userId) {
        return true;
      }
      var sent = true;
      if (text.trim().isNotEmpty) {
        Object? textError;
        sent = await sendDraftText(
          ref,
          roomId: widget.roomId,
          draftKey: _draftKey,
          rawText: text,
          replyToOverride: replyTo,
          overrideReply: true,
          totalMembers: widget.totalMembers,
          refreshContainer: ProviderScope.containerOf(context, listen: false),
          onError: (error) => textError = error,
        );
        if (!sent && replyState.mounted && replyState.value == null) {
          replyState.value = replyTo;
        }
        if (!sent && mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(SnackBar(content: Text('文字发送失败: $textError')));
        }
        if (sent && mounted) unawaited(refreshMessages(ref, widget.roomId));
      }
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
    } finally {
      _sendingPendingImages = false;
    }
  }

  void _toggleAttachmentPicker() {
    if (_isDesktop || _keyboardMouse) {
      unawaited(_tools.pickImages());
      return;
    }
    _toggleAttachmentPanel();
  }

  void _toggleAttachmentPanel() {
    if (widget.panelMode == InputPanelMode.attachment) {
      _unfocusOwnedInputs();
      SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
      widget.onPanelModeChanged(InputPanelMode.none);
      return;
    }

    _unfocusOwnedInputs();
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
    AsyncValue<List<rust.StickerPack>>? stickerPacksAsync;
    if (autocompleteMatch?.kind == ComposerAutocompleteKind.mention) {
      membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    } else if (autocompleteMatch?.kind == ComposerAutocompleteKind.room) {
      roomsAsync = ref.watch(chatRoomsProvider);
    } else if (autocompleteMatch?.kind == ComposerAutocompleteKind.emoji) {
      stickerPacksAsync = ref.watch(stickerPacksProvider(widget.roomId));
      final account = ref.watch(activeUserIdProvider);
      if (account != null) {
        ref.watch(
          disabledStickerPacksProvider((
            account: account,
            roomId: widget.roomId,
          )),
        );
      }
    }
    final autocompleteOptions = autocompleteMatch == null
        ? const <ComposerAutocompleteOption>[]
        : _keyboard.options(
            autocompleteMatch,
            members: membersAsync?.asData?.value,
            rooms: roomsAsync?.asData?.value,
            stickerPacks: stickerPacksAsync?.asData?.value,
          );
    final autocompleteLoading =
        membersAsync?.isLoading == true ||
        roomsAsync?.isLoading == true ||
        stickerPacksAsync?.isLoading == true;
    final visiblePickerMode =
        widget.panelMode == InputPanelMode.emoji ||
            widget.panelMode == InputPanelMode.attachment
        ? widget.panelMode
        : _lastPickerPanelMode;

    final attachmentKeyboard =
        widget.panelMode == InputPanelMode.attachment &&
        _attachmentInputFocused &&
        MediaQuery.viewInsetsOf(context).bottom > 0;
    final panelContentHeight = attachmentKeyboard
        ? widget.pickerHeight
        : widget.pickerFullHeight;
    final attachments = inlineImages && (hasImages || pendingImages.isSending)
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
        : null;

    final quote = editing != null
        ? ComposerQuoteBanner.editing(
            content: editing.content,
            sendInFlight: editingSendInFlight,
            onCancel: () {
              ref.read(editingMessageProvider(_draftKey).notifier).value = null;
              ref.read(editingDraftProvider(_draftKey).notifier).value = null;
              if (desktop) _focusNode.requestFocus();
            },
          )
        : replyTo != null
        ? ComposerQuoteBanner.reply(
            senderName: replyTo.senderName,
            content: replyTo.content,
            onCancel: () =>
                ref.read(replyingToProvider(_draftKey).notifier).value = null,
          )
        : null;

    final input = SafeArea(
      top: false,
      child: ColoredBox(
        color: Colors.transparent,
        child: _ComposerChromeMeasure(
          onChromeHeightChanged: widget.onChromeHeightChanged,
          pickerHeight: () => _renderedPickerHeight,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (context.isMaterial &&
                  !MediaQuery.disableAnimationsOf(context))
                ComposerQuoteTransition(key: ValueKey(_draftKey), banner: quote)
              else
                ?quote,
              ComposerAutocompleteOverlay(
                popup:
                    autocompleteMatch != null &&
                        (autocompleteOptions.isNotEmpty || autocompleteLoading)
                    ? ComposerAutocompletePopup(
                        options: autocompleteOptions,
                        loading: autocompleteLoading,
                        viewportItemCount:
                            MediaQuery.sizeOf(context).width < 600 ? 4 : 8,
                        selectedIndex: _keyboard.index,
                        scrollController: _keyboard.scroll,
                        onHover: _keyboard.hover,
                        onSelected: (option) {
                          final match = _keyboard.match;
                          if (match != null) _keyboard.select(match, option);
                        },
                      )
                    : null,
                child: ComposerSurface(
                  expanded: expanded,
                  compact: desktop,
                  attachments: context.isMaterial ? attachments : null,
                  child: ComposerActionsBar(
                    expanded: expanded,
                    compact: desktop,
                    showMore: _isDesktop || desktop,
                    inlineImages: inlineImages,
                    emojiButtonWrapper: _isDesktop
                        ? (child) => DesktopComposerPicker(
                            controller: _desktopPicker,
                            roomId: widget.roomId,
                            tab: _pickerTab,
                            onTabChanged: (tab) =>
                                setState(() => _pickerTab = tab),
                            onEmojiSelected: _insertEmoji,
                            onStickerSelected: (sticker, rect) {
                              _desktopPicker.close();
                              _sender.sendSticker(sticker, rect);
                            },
                            onOpenChanged: (open) {
                              if (mounted) {
                                setState(() => _desktopPickerOpen = open);
                              }
                            },
                            child: child,
                          )
                        : null,
                    emojiIcon:
                        !_isDesktop && widget.panelMode == InputPanelMode.emoji
                        ? Icons.keyboard_rounded
                        : (_pickerTab == ComposerPickerTab.sticker
                              ? Icons.interests_rounded
                              : Icons.sentiment_satisfied_alt_rounded),
                    emojiSelected: _isDesktop
                        ? _desktopPickerOpen
                        : widget.panelMode == InputPanelMode.emoji,
                    attachmentSelected:
                        widget.panelMode == InputPanelMode.attachment,
                    sendBusy: sendBusy,
                    hasText: _hasText,
                    hasImages: hasImages,
                    onToggleEmoji:
                        !_isDesktop && widget.panelMode == InputPanelMode.emoji
                        ? _showKeyboard
                        : _togglePicker,
                    onToggleAttachment: _toggleAttachmentPicker,
                    onShowTools: _tools.showToolsMenu,
                    onSend: _sendMessage,
                    attachments: context.isMaterial ? null : attachments,
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
              ),
              _ComposerPickerMeasure(
                onHeightLayout: (height) => _renderedPickerHeight = height,
                child: AnimatedContainer(
                  duration: widget.animatePickerHeight
                      ? const Duration(milliseconds: 180)
                      : Duration.zero,
                  curve: Curves.easeOutCubic,
                  width: double.infinity,
                  height:
                      _isDesktop && visiblePickerMode == InputPanelMode.emoji
                      ? 0
                      : widget.pickerHeight,
                  child: ClipRect(
                    child: OverflowBox(
                      alignment: Alignment.topCenter,
                      minHeight: panelContentHeight,
                      maxHeight: panelContentHeight,
                      child: SizedBox(
                        width: double.infinity,
                        height: panelContentHeight,
                        child:
                            (_isDesktop &&
                                    visiblePickerMode ==
                                        InputPanelMode.emoji) ||
                                widget.pickerHeight <= 0 &&
                                    widget.panelMode !=
                                        InputPanelMode.attachment
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
                                InputPanelMode.attachment => Focus(
                                  canRequestFocus: false,
                                  skipTraversal: true,
                                  onFocusChange: _handleAttachmentFocusChanged,
                                  child: AttachmentPicker(
                                    key: ValueKey(
                                      'attachment_picker_${_draftKey.userId}_${widget.roomId}',
                                    ),
                                    composerController: _controller,
                                    composerDraft: pendingImages,
                                    onImagesSelected: (items) {
                                      if (ref.read(activeUserIdProvider) !=
                                              _draftKey.userId ||
                                          pendingImages.isSending) {
                                        return;
                                      }
                                      pendingImages.addItems(items);
                                    },
                                    onImagesDeselected: (items) {
                                      if (ref.read(activeUserIdProvider) !=
                                              _draftKey.userId ||
                                          pendingImages.isSending) {
                                        return;
                                      }
                                      pendingImages.selected.removeWhere(
                                        (item) => items.contains(item),
                                      );
                                      pendingImages.selectionChanged();
                                      pendingImages.discardUnselected();
                                    },
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
                                    onClose: () {
                                      if (pendingImages.selected.isNotEmpty) {
                                        _showKeyboard();
                                      } else {
                                        widget.onPanelModeChanged(
                                          InputPanelMode.none,
                                        );
                                      }
                                    },
                                  ),
                                ),
                                _ => const SizedBox.shrink(),
                              },
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

    if (expanded) return input;
    if (context.isMaterial) {
      return input;
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

class _ComposerPickerMeasure extends SingleChildRenderObjectWidget {
  const _ComposerPickerMeasure({
    required this.onHeightLayout,
    required super.child,
  });

  final ValueChanged<double> onHeightLayout;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderComposerPickerMeasure(onHeightLayout);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderComposerPickerMeasure renderObject,
  ) {
    renderObject.onHeightLayout = onHeightLayout;
  }
}

class _RenderComposerPickerMeasure extends RenderProxyBox {
  _RenderComposerPickerMeasure(this.onHeightLayout);

  ValueChanged<double> onHeightLayout;

  @override
  void performLayout() {
    super.performLayout();
    onHeightLayout(child?.size.height ?? 0.0);
  }
}

class _ComposerChromeMeasure extends SingleChildRenderObjectWidget {
  const _ComposerChromeMeasure({
    required this.onChromeHeightChanged,
    required this.pickerHeight,
    required super.child,
  });

  final ValueChanged<double>? onChromeHeightChanged;
  final double Function() pickerHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderComposerChromeMeasure(onChromeHeightChanged, pickerHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderComposerChromeMeasure renderObject,
  ) {
    renderObject
      ..onChromeHeightChanged = onChromeHeightChanged
      ..pickerHeight = pickerHeight;
  }
}

class _RenderComposerChromeMeasure extends RenderProxyBox {
  _RenderComposerChromeMeasure(this.onChromeHeightChanged, this.pickerHeight);

  ValueChanged<double>? onChromeHeightChanged;
  double Function() pickerHeight;
  double? _lastChromeHeight;

  @override
  void performLayout() {
    super.performLayout();
    final callback = onChromeHeightChanged;
    if (callback == null) return;
    final totalHeight = child?.size.height ?? 0.0;
    final chromeHeight = (totalHeight - pickerHeight()).clamp(
      0.0,
      double.infinity,
    );
    if (_lastChromeHeight != null &&
        (chromeHeight - _lastChromeHeight!).abs() < 0.5) {
      return;
    }
    _lastChromeHeight = chromeHeight;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onChromeHeightChanged?.call(chromeHeight);
    });
  }
}
