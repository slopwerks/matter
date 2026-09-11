import 'dart:async';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../features/markdown/markdown_composer.dart';
import '../../features/markdown/markdown_format_toolbar.dart';
import '../../features/markdown/markdown_text_editing_controller.dart';
import '../../features/markdown/markdown_source_store.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_surface.dart';
import 'attachment_picker.dart';
import 'composer_autocomplete.dart';
import 'composer_picker_panel.dart';
import 'latest_message_control.dart';
import 'markdown_composer_page.dart';
import 'send_flight.dart';
import 'sticker_catalog.dart';

/// In-memory draft text, isolated by both account and room.
final messageDraftProvider =
    NotifierProvider.family<MutableState<String>, String, RoomAccountKey>(
      (key) => AccountScopedMutableState('', key.userId),
    );

/// In-progress edit text for [editingMessageProvider]'s message, isolated
/// by account and room. The full-screen composer syncs here while editing
/// so an edit survives the input widget being disposed (e.g. responsive
/// layout switches); matched by message id so a stale edit never leaks
/// into a different message's prefill.
final editingDraftProvider =
    NotifierProvider.family<
      MutableState<({String editingId, String text})?>,
      ({String editingId, String text})?,
      RoomAccountKey
    >((key) => AccountScopedMutableState(null, key.userId));

/// The message edit currently being sent for this account and room. Unlike
/// [_MessageInputState._isSending], this survives responsive layout switches,
/// so a remounted input cannot submit or replace the same edit mid-flight.
final editingSendInFlightProvider =
    NotifierProvider.family<MutableState<String?>, String?, RoomAccountKey>(
      (key) => AccountScopedMutableState(null, key.userId),
    );

/// Typing notices owned by a full-screen composer after its opening input has
/// been disposed. The route drives the active/idle lifecycle; this controller
/// supplies the same keep-alive and in-flight coalescing as the live input.
class _DetachedTypingNoticeSender {
  _DetachedTypingNoticeSender({
    required this.container,
    required this.roomId,
    required this.userId,
  });

  final ProviderContainer container;
  final String roomId;
  final String userId;

  Timer? _keepAliveTimer;
  bool _typing = false;
  bool _noticeInFlight = false;
  int _noticeSequence = 0;

  void setTyping(bool typing) {
    if (typing) {
      if (_typing || container.read(activeUserIdProvider) != userId) return;
      _typing = true;
      _send(true, force: true);
      _keepAliveTimer?.cancel();
      _keepAliveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_typing) _send(true);
      });
      return;
    }

    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
    if (!_typing) return;
    _typing = false;
    _send(false);
  }

  void _send(bool typing, {bool force = false}) {
    if (container.read(activeUserIdProvider) != userId) return;
    if (!force && typing && _noticeInFlight) return;
    _noticeInFlight = true;
    final sequence = ++_noticeSequence;
    rust
        .sendTypingNotice(accountUserId: userId, roomId: roomId, typing: typing)
        .whenComplete(() {
          if (sequence == _noticeSequence) {
            _noticeInFlight = false;
          } else if (typing && !_typing) {
            _send(false);
          }
        })
        .catchError((error) {
          debugPrint('sendTypingNotice failed: $error');
        });
  }
}

enum InputPanelMode { none, keyboard, emoji, attachment }

class _ComposerAutocompleteOption {
  final String title;
  final String? subtitle;
  final String insertion;
  final String? avatarUrl;
  final String? emoji;

  const _ComposerAutocompleteOption({
    required this.title,
    this.subtitle,
    required this.insertion,
    this.avatarUrl,
    this.emoji,
  });
}

const _maxComposerAutocompleteOptions = 50;

String _escapeMarkdownLinkLabel(String value) =>
    value.replaceAll(r'\', r'\\').replaceAll('[', r'\[').replaceAll(']', r'\]');

/// Sends [rawText] through the normal pipeline (optimistic local bubble,
/// reply/edit handling, failure retry). Returns true once the server has
/// accepted the message; on failure [onError] receives the underlying
/// error and false is returned.
///
/// Defined outside [MessageInputState] so a caller that may outlive the
/// state — the full-screen composer on the root navigator survives a
/// layout switch disposing this widget — can invoke the pipeline without
/// touching a dead ref. For the same reason the post-send refresh goes
/// through [refreshContainer] when provided: a `ProviderContainer` never
/// unmounts, unlike a widget [ref] that may be gone by the time the
/// refresh finishes. Conflicts with the live state's synchronous part
/// (double-sending the same text) are prevented by the composer's sending
/// guard plus [editingSendInFlightProvider]; the failure path is safe on a
/// live input because `_composerOpen` routes it to the composer variant.
Future<bool> sendDraftText(
  WidgetRef ref, {
  required String roomId,
  required RoomAccountKey draftKey,
  required String rawText,
  required int totalMembers,
  ValueNotifier<bool>? sendInFlight,
  bool composerHoldsDraft = false,
  ProviderContainer? refreshContainer,
  void Function(Object error)? onError,
  void Function(MessageSendPresentation presentation, bool success)?
  onMessageSent,
  void Function(String localId, MessageSendPresentation presentation)?
  onMessageQueued,
  MessageSendPresentation Function()? resolveSendPresentation,
}) async {
  final text = rawText.trim();
  if (text.isEmpty) return false;
  final compiled = const MarkdownComposer().compile(text);
  if (compiled.body.trim().isEmpty) return false;

  final editing = ref.read(editingMessageProvider(draftKey));
  final replyTo = ref.read(replyingToProvider(draftKey));
  final replyState = ref.read(replyingToProvider(draftKey).notifier);
  final draftState = ref.read(messageDraftProvider(draftKey).notifier);
  final editingState = ref.read(editingMessageProvider(draftKey).notifier);
  final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
  final editingSendState = ref.read(
    editingSendInFlightProvider(draftKey).notifier,
  );
  String? ownedEditingSendId;
  if (editing != null) {
    if (editingSendState.value != null) {
      final error = StateError('An edit is already being sent');
      onError?.call(error);
      return false;
    }
    ownedEditingSendId = editing.id;
    editingSendState.value = editing.id;
  }
  bool accountStillActive() =>
      refreshContainer == null ||
      refreshContainer.read(activeUserIdProvider) == draftKey.userId;
  MutableState<List<LocalOutgoingMessage>>? fallbackOutgoing;
  LocalOutgoingMessage? fallbackFailedMessage;
  if (composerHoldsDraft && editing == null) {
    final outgoingState = ref.read(
      localOutgoingMessagesProvider(draftKey).notifier,
    );
    fallbackOutgoing = outgoingState;
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    for (final message in ref.read(messageCacheProvider(roomId))) {
      final candidate = int.tryParse(message.timestamp) ?? 0;
      if (candidate >= timestamp) timestamp = candidate + 1;
    }
    for (final outgoing in outgoingState.value) {
      final candidate = int.tryParse(outgoing.message.timestamp) ?? 0;
      if (candidate >= timestamp) timestamp = candidate + 1;
    }
    final failedId =
        '$localOutgoingFailedPrefix${DateTime.now().microsecondsSinceEpoch}';
    fallbackFailedMessage = LocalOutgoingMessage(
      message: rust.ChatMessage(
        id: failedId,
        senderId: draftKey.userId,
        senderName: '我',
        content: compiled.body,
        formattedBody: compiled.formattedBody,
        mentionedUserIds: compiled.mentionedUserIds,
        mentionsRoom: compiled.mentionsRoom,
        timestamp: timestamp.toString(),
        isMe: true,
        msgType: rust.MessageType.text,
        inReplyTo: replyTo?.id,
        isEdited: false,
        editHistory: const [],
        reactions: const [],
        readers: const [],
        totalMembers: totalMembers,
      ),
      replyToUserId: (replyTo == null || replyTo.isMe)
          ? null
          : replyTo.senderId,
      markdownSource: compiled.source,
    );
  }

  sendInFlight?.value = true;
  if (editing == null) {
    if (composerHoldsDraft) {
      draftState.value = '';
    }
    // Consume the relation before the network wait. A newly selected reply
    // then belongs to the next draft and must not be cleared by this send's
    // eventual success.
    if (replyTo != null) replyState.value = null;
  }
  try {
    String remoteEventId;
    if (editing != null) {
      remoteEventId = await rust.editMessage(
        accountUserId: draftKey.userId,
        roomId: roomId,
        eventId: editing.id,
        message: compiled.toRust(),
        previousMentionedUserIds: editing.mentionedUserIds,
        previousMentionsRoom: editing.mentionsRoom,
      );
    } else if (replyTo != null) {
      remoteEventId = await rust.sendReply(
        accountUserId: draftKey.userId,
        roomId: roomId,
        message: compiled.toRust(),
        replyToEventId: replyTo.id,
        replyToUserId: replyTo.isMe ? null : replyTo.senderId,
      );
    } else {
      remoteEventId = await rust.sendMessage(
        accountUserId: draftKey.userId,
        roomId: roomId,
        message: compiled.toRust(),
      );
    }
    var persistMarkdownSource = false;
    if (accountStillActive()) {
      final canPersist = await _canPersistMarkdownSource(roomId);
      persistMarkdownSource = accountStillActive() && canPersist;
    }
    try {
      await const MarkdownSourceStore().save(
        userId: draftKey.userId,
        roomId: roomId,
        eventId: editing?.id ?? remoteEventId,
        source: compiled.source,
        body: compiled.body,
        formattedBody: compiled.formattedBody,
        persist: persistMarkdownSource,
      );
    } catch (e) {
      // The message was already accepted by the server; failing to persist
      // the markdown source must not flip the bubble into "failed" (which
      // would then offer a retry that duplicates the send).
      debugPrint('Failed to save markdown source: $e');
    }
    if (editing != null) {
      final currentEditDraft = editDraftState.value;
      final stillSendingSameText =
          editingState.value?.id == editing.id &&
          (currentEditDraft == null ||
              (currentEditDraft.editingId == editing.id &&
                  currentEditDraft.text == rawText));
      if (stillSendingSameText) {
        editingState.value = null;
        editDraftState.value = null;
      } else if (editingState.value?.id == editing.id) {
        // A newer draft was typed while this edit was in flight. Keep edit
        // mode open, but advance its accepted mention baseline so the next
        // edit only notifies mentions newly introduced after this version.
        editingState.value = _acceptedEditedMessage(editing, compiled);
      }
    }
    if ((editing != null || composerHoldsDraft) && accountStillActive()) {
      // No local bubble was queued (edit, or composer send outliving its
      // input): reconcile through a refresh. A container never unmounts, so
      // the refresh still lands after the caller's widget tore down
      // mid-flight; the plain WidgetRef path is fine when the input itself
      // initiated the send.
      unawaited(
        refreshContainer != null
            ? refreshMessagesContainer(refreshContainer, roomId)
            : refreshMessages(ref, roomId),
      );
    }
    return true;
  } catch (e) {
    // A detached new-message send consumed its provider state up front;
    // restore it unless newer work now owns those providers. Edits stay in
    // provider state for the entire request and need no failure restoration.
    if (composerHoldsDraft && editing == null) {
      final stateStillConsumed =
          draftState.value == '' &&
          replyState.value == null &&
          editingState.value == null &&
          editDraftState.value == null;
      // A remounted input may already contain a newer draft/reply/edit. In
      // that case the failure is still reported, but the old snapshot must
      // not overwrite the user's newer work. Preserve a failed new message
      // as a retryable timeline entry instead of silently dropping it.
      if (!stateStillConsumed) {
        if (fallbackOutgoing != null && fallbackFailedMessage != null) {
          final failedId = fallbackFailedMessage.message.id;
          if (!fallbackOutgoing.value.any(
            (entry) => entry.message.id == failedId,
          )) {
            fallbackOutgoing.value = [
              ...fallbackOutgoing.value,
              fallbackFailedMessage,
            ];
          }
        }
        onError?.call(e);
        return false;
      }
      draftState.value = rawText;
      if (replyTo != null) replyState.value = replyTo;
    }
    onError?.call(e);
    return false;
  } finally {
    if (ownedEditingSendId != null &&
        editingSendState.value == ownedEditingSendId) {
      editingSendState.value = null;
    }
    sendInFlight?.value = false;
  }
}

rust.ChatMessage _acceptedEditedMessage(
  rust.ChatMessage original,
  CompiledMarkdownMessage accepted,
) => rust.ChatMessage(
  id: original.id,
  senderId: original.senderId,
  senderName: original.senderName,
  content: accepted.body,
  formattedBody: accepted.formattedBody,
  caption: original.caption,
  captionFormattedBody: original.captionFormattedBody,
  mentionedUserIds: accepted.mentionedUserIds,
  mentionsRoom: accepted.mentionsRoom,
  timestamp: original.timestamp,
  isMe: original.isMe,
  msgType: original.msgType,
  imageUrl: original.imageUrl,
  mediaSourceJson: original.mediaSourceJson,
  imageWidth: original.imageWidth,
  imageHeight: original.imageHeight,
  filename: original.filename,
  fileSize: original.fileSize,
  geoUri: original.geoUri,
  poll: original.poll,
  inReplyTo: original.inReplyTo,
  isEdited: true,
  editHistory: original.editHistory,
  reactions: original.reactions,
  readers: original.readers,
  totalMembers: original.totalMembers,
);

Future<bool> _canPersistMarkdownSource(String roomId) async {
  try {
    return !await rust.isRoomEncrypted(roomId: roomId);
  } catch (_) {
    return false;
  }
}

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
  static const _toolbarAnimationDuration = Duration(milliseconds: 180);
  static const _toolbarAnimationCurve = Curves.easeOutCubic;
  static const _markdownComposer = MarkdownComposer();
  static const _markdownSourceStore = MarkdownSourceStore();

  final _controller = MarkdownTextEditingController();
  final _focusNode = FocusNode();
  final _autocompleteScrollController = ScrollController();
  final _textFieldKey = GlobalKey();
  late final RoomAccountKey _draftKey;
  bool _hasText = false;
  bool _isSending = false;
  bool _wasComposingText = false;
  ComposerAutocompleteMatch? _autocompleteMatch;
  int _autocompleteIndex = 0;

  /// Tracks the full-screen markdown composer: while it is open, a failed
  /// send must drop the optimistic entry (the composer still holds the
  /// draft, so a retry resends instead of leaving a duplicate failed
  /// bubble) rather than marking it failed for bubble-level retry.
  bool _composerOpen = false;
  Timer? _typingTimer;
  Timer? _typingKeepAliveTimer;
  bool _isTyping = false;
  ComposerPickerTab _pickerTab = ComposerPickerTab.emoji;
  int _pickerInstance = 0;
  InputPanelMode _lastPickerPanelMode = InputPanelMode.emoji;

  /// Tracks the event id currently being edited, so we only prefill the input
  /// when the edited message changes (not on every rebuild).
  String? _lastEditingId;
  String? _editingSourceLoadingId;

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
    final draft = ref.read(messageDraftProvider(_draftKey));
    _controller.value = TextEditingValue(
      text: draft,
      selection: TextSelection.collapsed(offset: draft.length),
    );
    _hasText = draft.trim().isNotEmpty;
    _wasComposingText = _isComposingText;
    _autocompleteMatch = composerAutocompleteMatch(_controller.value);
    _controller.addListener(_onTextChanged);
    _focusNode.onKeyEvent = _handleKeyEvent;
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
    _typingTimer?.cancel();
    _typingKeepAliveTimer?.cancel();
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _focusNode.dispose();
    _autocompleteScrollController.dispose();
    // Stop typing notice when leaving
    _stopTyping();
    super.dispose();
  }

  void _onTextChanged() {
    final hasText = _controller.text.trim().isNotEmpty;
    final isComposingText = _isComposingText;
    final composingChanged = isComposingText != _wasComposingText;
    final autocompleteMatch = composerAutocompleteMatch(_controller.value);
    final autocompleteChanged = autocompleteMatch != _autocompleteMatch;
    final editing = ref.read(editingMessageProvider(_draftKey));
    if (editing == null) {
      ref.read(messageDraftProvider(_draftKey).notifier).value =
          _controller.text;
    } else {
      // Keep the surviving edit draft in step with the inline text, so a
      // layout switch never recovers an older full-screen edit over a
      // newer inline one (or vice versa).
      ref.read(editingDraftProvider(_draftKey).notifier).value = (
        editingId: editing.id,
        text: _controller.text,
      );
    }
    if (_hasText != hasText || autocompleteChanged || composingChanged) {
      setState(() {
        _hasText = hasText;
        _wasComposingText = isComposingText;
        if (autocompleteChanged) {
          _autocompleteMatch = autocompleteMatch;
          _autocompleteIndex = 0;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _autocompleteScrollController.hasClients) {
              _autocompleteScrollController.jumpTo(0);
            }
          });
        }
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
      // Session start: force the notice even when a stale stop notice is
      // still in flight — dropping it would hide the typing indicator for
      // the whole remaining flight (~90s on a dead network) while the
      // user is actively typing. A late `false` flips the remote briefly;
      // the next keep-alive (≤3s) corrects it.
      _sendTypingNotice(true, force: true);
      // The server expires a typing notice after ~4s. While the user keeps
      // typing (which resets the 3s idle timer below), re-send the notice
      // periodically so the remote end does not lose the indicator mid-
      // sentence.
      _typingKeepAliveTimer?.cancel();
      _typingKeepAliveTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        if (_isTyping) _sendTypingNotice(true);
      });
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
    _typingKeepAliveTimer?.cancel();
    _typingKeepAliveTimer = null;
  }

  // One typing write in flight at a time: the SDK call can take ~90s to
  // fail on a dead network (30s timeout × 3 retries) while holding the
  // client lease — a keep-alive firing every 3s without this guard would
  // stack dozens of concurrent calls and stall account switching behind
  // the lock for the whole period. Only the periodic keep-alive (true) is
  // skipped while in flight; the stop notice (false) always goes out.
  // The sequence number ties the in-flight flag to the LATEST call: an
  // older call completing (e.g. a slow `true` resolving after the `false`
  // that superseded it) must not reopen the gate while the newer call is
  // still on the wire. It also drives the stop-direction correction in
  // whenComplete: the stale `true` may have reached the remote AFTER the
  // `false` that superseded it (out-of-order on a flaky network), reviving
  // "正在输入" with no keep-alive left to fix it — a corrective stop goes
  // out once the stale call finishes.
  int _typingNoticeSeq = 0;
  bool _typingNoticeInFlight = false;

  void _sendTypingNotice(bool typing, {bool force = false}) {
    // [force] is used by the session-start notice: it must go out even
    // while a stale stop notice is in flight (see _handleTyping).
    if (!force && _typingNoticeInFlight && typing) return;
    _typingNoticeInFlight = true;
    final seq = ++_typingNoticeSeq;
    rust
        .sendTypingNotice(
          accountUserId: _draftKey.userId,
          roomId: widget.roomId,
          typing: typing,
        )
        .whenComplete(() {
          if (seq == _typingNoticeSeq) {
            _typingNoticeInFlight = false;
          } else if (typing && !_isTyping) {
            // Stop-direction correction: this stale `true` is no longer the
            // latest notice (a stop `false` superseded it), but the remote
            // may still receive it AFTER that `false` on a flaky network —
            // reviving "正在输入" with no keep-alive left (the timer was
            // cancelled on stop). Re-send the stop so the remote ends
            // stopped. Skipped while the user is typing again: the newer
            // start/keep-alive `true` already superseded this one and will
            // land; an extra stop would only hide the indicator.
            _sendTypingNotice(false);
          }
        })
        .catchError((e) {
          debugPrint('sendTypingNotice failed: $e');
        });
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (!_isComposingText && _handleAutocompleteKey(event)) {
      return KeyEventResult.handled;
    }
    // Keep Linux's existing multiline Enter behavior. The handler is still
    // installed there so Tab and arrow-key autocomplete remain available.
    if (defaultTargetPlatform == TargetPlatform.linux) {
      return KeyEventResult.ignored;
    }
    if (!_isEnterKey(event) ||
        HardwareKeyboard.instance.isShiftPressed ||
        _isComposingText) {
      return KeyEventResult.ignored;
    }

    if (event is KeyDownEvent) {
      unawaited(_sendMessage());
    }
    return KeyEventResult.handled;
  }

  bool get _isComposingText {
    final composing = _controller.value.composing;
    return composing.isValid && !composing.isCollapsed;
  }

  bool _isEnterKey(KeyEvent event) =>
      event.logicalKey == LogicalKeyboardKey.enter ||
      event.logicalKey == LogicalKeyboardKey.numpadEnter;

  bool _handleAutocompleteKey(KeyEvent event) {
    final match = _focusNode.hasFocus ? _autocompleteMatch : null;
    if (match == null) return false;
    final options = _autocompleteOptions(match);
    if (options.isEmpty) return false;
    final key = event.logicalKey;
    final selects = key == LogicalKeyboardKey.tab || _isEnterKey(event);
    final moves =
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowUp;
    if (!selects && !moves) return false;
    if (event is! KeyDownEvent) return true;

    if (selects) {
      _selectAutocomplete(
        match,
        options[_autocompleteIndex.clamp(0, options.length - 1)],
      );
      return true;
    }
    final direction = key == LogicalKeyboardKey.arrowDown ? 1 : -1;
    late final int nextIndex;
    setState(() {
      nextIndex =
          (_autocompleteIndex + direction + options.length) % options.length;
      _autocompleteIndex = nextIndex;
    });
    _scrollAutocompleteToIndex(nextIndex);
    return true;
  }

  int _autocompleteViewportCount(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 600 ? 4 : 8;

  void _scrollAutocompleteToIndex(int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_autocompleteScrollController.hasClients) return;
      final position = _autocompleteScrollController.position;
      final itemTop = index * 52.0;
      final itemBottom = itemTop + 52;
      final visibleTop = position.pixels;
      final visibleBottom = visibleTop + position.viewportDimension;
      final target = itemTop < visibleTop
          ? itemTop
          : itemBottom > visibleBottom
          ? itemBottom - position.viewportDimension
          : null;
      if (target != null) {
        _autocompleteScrollController.jumpTo(
          target.clamp(position.minScrollExtent, position.maxScrollExtent),
        );
      }
    });
  }

  List<_ComposerAutocompleteOption> _autocompleteOptions(
    ComposerAutocompleteMatch match, {
    List<rust.Contact>? members,
    List<rust.ChatRoom>? rooms,
  }) {
    final query = match.query.toLowerCase();
    switch (match.kind) {
      case ComposerAutocompleteKind.mention:
        final source =
            members ??
            ref.read(roomMembersProvider(widget.roomId)).asData?.value ??
            const <rust.Contact>[];
        final matches = _boundedAutocompleteMatches(
          source,
          matches: (member) {
            return member.name.toLowerCase().contains(query) ||
                member.id.toLowerCase().contains(query);
          },
          starts: (member) {
            return member.name.toLowerCase().startsWith(query) ||
                member.id.toLowerCase().startsWith('@$query');
          },
          compare: (left, right) {
            final byName = left.name.toLowerCase().compareTo(
              right.name.toLowerCase(),
            );
            return byName != 0 ? byName : left.id.compareTo(right.id);
          },
        );
        return matches
            .map(
              (member) => _ComposerAutocompleteOption(
                title: member.name,
                subtitle: member.id,
                insertion: '${member.id} ',
                avatarUrl: member.avatarUrl,
              ),
            )
            .toList();
      case ComposerAutocompleteKind.room:
        final source =
            rooms ??
            ref.read(chatRoomsProvider).asData?.value ??
            const <rust.ChatRoom>[];
        final matches = _boundedAutocompleteMatches(
          source,
          matches: (room) {
            if (room.roomType == 'space' || room.roomState != 'joined') {
              return false;
            }
            return room.name.toLowerCase().contains(query) ||
                room.id.toLowerCase().contains(query);
          },
          starts: (room) => room.name.toLowerCase().startsWith(query),
          compare: (left, right) {
            final byName = left.name.toLowerCase().compareTo(
              right.name.toLowerCase(),
            );
            return byName != 0 ? byName : left.id.compareTo(right.id);
          },
        );
        return matches.map((room) {
          final label = _escapeMarkdownLinkLabel('#${room.name}');
          final roomId = Uri.encodeComponent(room.id);
          return _ComposerAutocompleteOption(
            title: '#${room.name}',
            subtitle: room.id,
            insertion: '[$label](https://matrix.to/#/$roomId) ',
            avatarUrl: room.avatarUrl,
          );
        }).toList();
      case ComposerAutocompleteKind.emoji:
        return emojiAutocompleteOptions(match.query)
            .map(
              (option) => _ComposerAutocompleteOption(
                title: ':${option.name}:',
                insertion: option.emoji,
                emoji: option.emoji,
              ),
            )
            .toList();
    }
  }

  List<T> _boundedAutocompleteMatches<T>(
    Iterable<T> source, {
    required bool Function(T value) matches,
    required bool Function(T value) starts,
    required int Function(T left, T right) compare,
  }) {
    final leading = <T>[];
    final remaining = <T>[];
    for (final value in source) {
      if (!matches(value)) continue;
      final bucket = starts(value) ? leading : remaining;
      if (bucket.length < _maxComposerAutocompleteOptions) {
        bucket.add(value);
      }
      if (leading.length == _maxComposerAutocompleteOptions) break;
    }
    leading.sort(compare);
    remaining.sort(compare);
    return [
      ...leading,
      ...remaining.take(_maxComposerAutocompleteOptions - leading.length),
    ];
  }

  void _selectAutocomplete(
    ComposerAutocompleteMatch match,
    _ComposerAutocompleteOption option,
  ) {
    if (match != _autocompleteMatch) return;
    _controller.value = applyComposerAutocomplete(
      _controller.value,
      match,
      option.insertion,
    );
    _focusNode.requestFocus();
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
    _insertComposerText(
      '${needsLeadingSpace ? ' ' : ''}$userId${needsTrailingSpace ? ' ' : ''}',
    );
    _showKeyboard();
  }

  Future<void> _sendMessage() => _sendMessageText(_controller.text);

  /// Long-press on the attachment button: a small menu of extra composer
  /// tools that don't deserve a permanent spot in the input row.
  Future<void> _showComposerToolsMenu(BuildContext buttonContext) async {
    final buttonBox = buttonContext.findRenderObject();
    final overlay = Overlay.of(context).context.findRenderObject();
    if (buttonBox is! RenderBox ||
        !buttonBox.attached ||
        !buttonBox.hasSize ||
        overlay is! RenderBox) {
      return;
    }
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        buttonBox.localToGlobal(Offset.zero) & buttonBox.size,
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'markdown',
          child: Row(
            children: [
              Icon(
                Icons.edit_note_rounded,
                color: context.neu.textSecondary,
                size: 22,
              ),
              const SizedBox(width: 12),
              const Text('Markdown 编辑器'),
            ],
          ),
        ),
      ],
    );
    if (action == 'markdown' && mounted) {
      _openMarkdownComposer();
    }
  }

  /// Opens the full-screen markdown composer with the current draft. On
  /// close the (possibly edited) text is written back so no draft is lost;
  /// a completed send has already cleared the input via the send pipeline.
  ///
  /// The composer route lives on the root navigator and can outlive this
  /// state (e.g. a responsive layout switch disposes the page while the
  /// composer stays open), so the text is also synced live into provider
  /// state that survives — [messageDraftProvider] for new messages,
  /// [editingDraftProvider] for edits — and a send after this state is gone
  /// goes through [sendDraftText] with provider state only.
  Future<void> _openMarkdownComposer() async {
    if (_editingSourceLoadingId != null) return;
    _focusNode.unfocus();
    widget.onPanelModeChanged(InputPanelMode.none);
    _composerOpen = true;
    // Captured now, while mounted: these provider notifiers (and the
    // container for the post-send refresh) stay valid after this state is
    // disposed, unlike ref.
    final draftKey = _draftKey;
    final roomId = widget.roomId;
    final totalMembers = widget.totalMembers;
    final container = ProviderScope.containerOf(context, listen: false);
    final navigator = Navigator.of(context, rootNavigator: true);
    final editing = ref.read(editingMessageProvider(draftKey));
    final draftState = ref.read(messageDraftProvider(draftKey).notifier);
    final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
    final detachedTyping = _DetachedTypingNoticeSender(
      container: container,
      roomId: roomId,
      userId: draftKey.userId,
    );
    void persistText(String text) {
      if (editing == null) {
        draftState.value = text;
      } else {
        editDraftState.value = (editingId: editing.id, text: text);
      }
    }

    void showSendError(Object error) {
      if (container.read(activeUserIdProvider) != draftKey.userId) return;
      final feedbackContext = navigator.context;
      if (!feedbackContext.mounted) return;
      ScaffoldMessenger.maybeOf(feedbackContext)?.showSnackBar(
        SnackBar(
          content: Text('发送失败: $error'),
          duration: const Duration(seconds: 2),
        ),
      );
    }

    final result = await navigator.push<MarkdownComposerResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) {
          // While this state is alive the input's own pipeline sends
          // (flight animation, reply-bar clearance); once it is gone the
          // route's element still provides a live ref whose container is
          // the shared one, so the composer keeps a working send.
          return MarkdownComposerPage(
            initialText: _controller.text,
            onSend: (text, composerRef) => mounted
                ? _sendMessageText(text, onDetachedError: showSendError)
                : sendDraftText(
                    composerRef,
                    roomId: roomId,
                    draftKey: draftKey,
                    rawText: text,
                    totalMembers: totalMembers,
                    composerHoldsDraft: true,
                    // A ProviderContainer never unmounts, so the
                    // post-send refresh still lands after the composer
                    // route popped itself away.
                    refreshContainer: container,
                    onError: showSendError,
                  ),
            onTyping: (typing) {
              if (mounted) {
                if (typing) {
                  _handleTyping();
                } else {
                  _stopTyping();
                }
              } else {
                detachedTyping.setTyping(typing);
              }
            },
            onDraftChanged: persistText,
          );
        },
      ),
    );
    detachedTyping.setTyping(false);
    _composerOpen = false;
    if (!mounted) {
      // The host is gone (layout switch): the live sync above already
      // keeps provider state current, and this covers the final text on
      // close, so a future mount recovers it. The controller path below
      // belongs to the dead state.
      if (result != null && !result.sent) persistText(result.text);
      return;
    }
    if (result == null || result.sent) return;
    if (result.text != _controller.text) {
      _controller.value = TextEditingValue(
        text: result.text,
        selection: TextSelection.collapsed(offset: result.text.length),
      );
    }
  }

  /// Sends [rawText] through the shared [sendDraftText] core first; only
  /// after the server accepts it do the local UI affordances run (optimistic
  /// bubble, reply-bar clearance, editing-state reset, reconcile). The
  /// full-screen markdown composer sends through this while the input is
  /// alive (see `_openMarkdownComposer`), and falls back to [sendDraftText]
  /// directly once a layout switch disposed this state.
  Future<bool> _sendMessageText(
    String rawText, {
    void Function(Object error)? onDetachedError,
  }) async {
    final text = rawText.trim();
    final draftKey = _draftKey;
    if (text.isEmpty ||
        _isSending ||
        _editingSourceLoadingId != null ||
        ref.read(editingSendInFlightProvider(draftKey)) != null) {
      return false;
    }
    final container = ProviderScope.containerOf(context, listen: false);
    final compiled = _markdownComposer.compile(text);
    if (compiled.body.trim().isEmpty) return false;

    final editing = ref.read(editingMessageProvider(draftKey));
    final replyTo = ref.read(replyingToProvider(draftKey));
    // Captured while mounted: the failure path may run after this state
    // was disposed (a composer send outliving a layout switch), where ref
    // is dead but these notifiers are not.
    final replyState = ref.read(replyingToProvider(draftKey).notifier);
    final draftState = ref.read(messageDraftProvider(draftKey).notifier);
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

    MutableState<List<LocalOutgoingMessage>>? localOutgoing;
    LocalOutgoingMessage? failedLocalMessage;
    if (localId != null) {
      if (sendPresentation == MessageSendPresentation.flight) {
        _registerTextSendFlight(localId, compiled.body);
      }
      widget.onMessageQueued(sendFlightId(localId), sendPresentation!);
      // Capture the reply target into the optimistic entry. The provider
      // [sendDraftText] captures and then clears the reply relation before
      // awaiting the network, so a relation chosen while this send is in
      // flight belongs to the next draft and survives settlement.
      final replyToUserId = (replyTo == null || replyTo.isMe)
          ? null
          : replyTo.senderId;
      localOutgoing = ref.read(
        localOutgoingMessagesProvider(draftKey).notifier,
      );
      failedLocalMessage = LocalOutgoingMessage(
        message: _localTextMessage(
          id: failedLocalOutgoingId(localId),
          compiled: compiled,
          inReplyTo: replyTo?.id,
          timestamp: localTimestamp,
        ),
        replyToUserId: replyToUserId,
        markdownSource: compiled.source,
      );
      upsertLocalOutgoingMessage(
        ref,
        draftKey,
        LocalOutgoingMessage(
          message: _localTextMessage(
            id: localId,
            compiled: compiled,
            inReplyTo: replyTo?.id,
            timestamp: localTimestamp,
          ),
          replyToUserId: replyToUserId,
          markdownSource: compiled.source,
        ),
      );
      _controller.clear();
    }

    setState(() => _isSending = true);
    Object? sendError;
    final sent = await sendDraftText(
      ref,
      roomId: widget.roomId,
      draftKey: draftKey,
      rawText: rawText,
      totalMembers: widget.totalMembers,
      onError: (e) => sendError = e,
      // The network wait may span a layout switch that disposes this state;
      // the container-driven refresh still lands afterwards.
      refreshContainer: container,
    );

    void handleFailure(Object error) {
      if (localId != null && localOutgoing != null) {
        if (_composerOpen) {
          // The full-screen composer still holds the draft and will offer
          // the retry: remove the optimistic entry outright — marking it
          // failed would leave a bubble that a retry from the editor
          // duplicates — and restore the reply relation cleared at queue
          // time so the retry stays a reply. All through captured
          // notifiers: this state may already be disposed (layout switch
          // while the send was in flight), where ref is dead.
          localOutgoing.value = localOutgoing.value
              .where((entry) => entry.message.id != localId)
              .toList();
          if (replyTo != null && replyState.value == null) {
            replyState.value = replyTo;
          }
          // The queue-time controller clear also emptied the shared draft;
          // the composer still holds the text, so put it back into the
          // surviving draft state instead of losing it with this widget.
          if (editing == null && draftState.value.isEmpty) {
            draftState.value = rawText;
          }
        } else if (failedLocalMessage != null) {
          markLocalOutgoingMessageFailedInState(
            localOutgoing,
            localId,
            failedLocalMessage,
          );
          // The original relation was consumed before the request. Any
          // relation present now was selected for the next draft and must
          // survive this older request's failure.
        }
      }
      final accountStillActive =
          container.read(activeUserIdProvider) == draftKey.userId;
      if (mounted) {
        setState(() => _isSending = false);
      }
      if (!accountStillActive) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('发送失败: $error'),
            duration: const Duration(seconds: 2),
          ),
        );
        if (shouldRestoreKeyboard) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            widget.onPanelModeChanged(InputPanelMode.keyboard);
            _focusNode.requestFocus();
            SystemChannels.textInput.invokeMethod<void>('TextInput.show');
          });
        }
      } else {
        onDetachedError?.call(error);
      }
    }

    if (!sent) {
      handleFailure(sendError ?? StateError('send failed'));
      return false;
    }

    final accountStillActive =
        container.read(activeUserIdProvider) == draftKey.userId;
    if (!mounted || !accountStillActive) {
      // The server accepted the message; with no live page there is no
      // bubble to reconcile. A leftover optimistic entry would resurface as a
      // stuck "sent" bubble on the next visit (its echo renders as a normal
      // message via sync), so drop it through the captured notifier.
      if (localId != null && localOutgoing != null) {
        localOutgoing.value = localOutgoing.value
            .where((entry) => entry.message.id != localId)
            .toList();
      }
      if (!mounted && accountStillActive && localId != null) {
        unawaited(refreshMessagesContainer(container, widget.roomId));
      }
      if (mounted) setState(() => _isSending = false);
      return true;
    }
    final sentId = localId == null
        ? null
        : markLocalOutgoingMessageSentInState(localOutgoing!, localId);
    _stopTyping();
    if (localId != null) {
      widget.onMessageSent(sendPresentation!, true);
      unawaited(_reconcileSentLocalMessage(draftKey, sentId!));
    }
    // Edits were already refreshed by the shared core.
    setState(() => _isSending = false);
    return true;
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
                style:
                    Theme.of(context).textTheme.bodyLarge?.copyWith(
                      decoration: TextDecoration.none,
                    ) ??
                    const TextStyle(decoration: TextDecoration.none),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _reconcileSentLocalMessage(
    RoomAccountKey draftKey,
    String localId,
  ) async {
    // Shared with failed-message retry so both paths reconcile the local
    // sent bubble with the server echo identically.
    await reconcileSentLocalMessage(ref, draftKey, localId);
  }

  int _nextLocalTimestamp() {
    var timestamp = DateTime.now().millisecondsSinceEpoch;
    final cached = ref.read(messageCacheProvider(widget.roomId));
    for (final message in cached) {
      final ts = int.tryParse(message.timestamp) ?? 0;
      if (ts >= timestamp) timestamp = ts + 1;
    }
    final local = ref.read(localOutgoingMessagesProvider(_draftKey));
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
    final draftKey = _draftKey;
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
    final localOutgoing = ref.read(
      localOutgoingMessagesProvider(draftKey).notifier,
    );
    final failedLocalMessage = LocalOutgoingMessage(
      message: _localStickerMessage(
        id: failedLocalOutgoingId(localId),
        sticker: sticker,
        displayImageUrl: displayImageUrl,
        timestamp: localTimestamp,
      ),
      sourceImageUrl: imageUrl,
    );
    upsertLocalOutgoingMessage(
      ref,
      draftKey,
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
      final sentId = markLocalOutgoingMessageSentInState(
        localOutgoing,
        localId,
      );
      if (!mounted) return;
      _stopTyping();
      widget.onMessageSent(sendPresentation, true);
      unawaited(_reconcileSentLocalMessage(draftKey, sentId));
    } catch (e) {
      markLocalOutgoingMessageFailedInState(
        localOutgoing,
        localId,
        failedLocalMessage,
      );
    }
  }

  Widget _buildAutocompletePanel({
    required List<_ComposerAutocompleteOption> options,
    required bool loading,
    required int viewportItemCount,
  }) {
    final selectedIndex = options.isEmpty
        ? 0
        : _autocompleteIndex.clamp(0, options.length - 1);
    final visibleItems = options.length.clamp(1, viewportItemCount);
    final height = loading && options.isEmpty ? 52.0 : visibleItems * 52.0;
    final colors = context.neu;
    return TextFieldTapRegion(
      child: Container(
        key: const ValueKey('composer-autocomplete-panel'),
        height: height,
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceStrong,
          borderRadius: BorderRadius.circular(NeuRadius.button),
          border: Border.all(color: colors.hairline),
        ),
        child: loading && options.isEmpty
            ? Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
              )
            : Scrollbar(
                controller: _autocompleteScrollController,
                thumbVisibility: options.length > viewportItemCount,
                child: ListView.builder(
                  controller: _autocompleteScrollController,
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  itemExtent: 52,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    final selected = index == selectedIndex;
                    return Material(
                      key: ValueKey('composer-autocomplete-option-$index'),
                      color: selected ? colors.accentSoft : Colors.transparent,
                      child: InkWell(
                        onHover: (hovering) {
                          if (hovering && _autocompleteIndex != index) {
                            setState(() => _autocompleteIndex = index);
                          }
                        },
                        onTap: () {
                          final match = _autocompleteMatch;
                          if (match != null) {
                            _selectAutocomplete(match, option);
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (option.emoji case final emoji?)
                                SizedBox(
                                  width: 34,
                                  child: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                )
                              else
                                AppAvatar(
                                  fallback: option.title,
                                  size: 32,
                                  radius: 16,
                                  url: option.avatarUrl,
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleSmall,
                                    ),
                                    if (option.subtitle case final subtitle?)
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(
                                          context,
                                        ).textTheme.labelSmall,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final replyTo = ref.watch(replyingToProvider(_draftKey));
    final editing = ref.watch(editingMessageProvider(_draftKey));
    // Do not expose a stale new-message draft as editable content while the
    // original source for a newly selected edit is still being restored.
    if (editing != null && editing.id != _lastEditingId) {
      _lastEditingId = editing.id;
      _editingSourceLoadingId = editing.id;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _lastEditingId != editing.id) return;
        _prefillEditingSource(editing);
      });
    } else if (editing == null) {
      _lastEditingId = null;
      _editingSourceLoadingId = null;
    }
    final editingSendId = ref.watch(editingSendInFlightProvider(_draftKey));
    final editingSendInFlight = editing != null && editingSendId == editing.id;
    final editingSourceLoading =
        editing != null && _editingSourceLoadingId == editing.id;
    final sendBusy = _isSending || editingSendInFlight || editingSourceLoading;
    final autocompleteMatch = _focusNode.hasFocus && !_isComposingText
        ? _autocompleteMatch
        : null;
    AsyncValue<List<rust.Contact>>? membersAsync;
    AsyncValue<List<rust.ChatRoom>>? roomsAsync;
    if (autocompleteMatch?.kind == ComposerAutocompleteKind.mention) {
      membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    } else if (autocompleteMatch?.kind == ComposerAutocompleteKind.room) {
      roomsAsync = ref.watch(chatRoomsProvider);
    }
    final autocompleteOptions = autocompleteMatch == null
        ? const <_ComposerAutocompleteOption>[]
        : _autocompleteOptions(
            autocompleteMatch,
            members: membersAsync?.asData?.value,
            rooms: roomsAsync?.asData?.value,
          );
    final autocompleteLoading =
        membersAsync?.isLoading == true || roomsAsync?.isLoading == true;
    // Follow external text writes: the full-screen composer syncs its text
    // into these providers live, and a layout switch may mount a fresh
    // input while the composer is still open. Our own writes echo back
    // with identical text and no-op, so this cannot loop.
    ref.listen(editingMessageProvider(_draftKey), (previous, next) {
      if (previous != null && next == null) _restoreDraft();
    });
    ref.listen(messageDraftProvider(_draftKey), (_, next) {
      if (ref.read(editingMessageProvider(_draftKey)) != null) return;
      if (_controller.text != next) {
        _controller.value = TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        );
      }
    });
    ref.listen(editingDraftProvider(_draftKey), (_, next) {
      final editing = ref.read(editingMessageProvider(_draftKey));
      if (editing == null || next == null || next.editingId != editing.id) {
        return;
      }
      if (_controller.text != next.text) {
        _controller.value = TextEditingValue(
          text: next.text,
          selection: TextSelection.collapsed(offset: next.text.length),
        );
      }
    });
    final visiblePickerMode =
        widget.panelMode == InputPanelMode.emoji ||
            widget.panelMode == InputPanelMode.attachment
        ? widget.panelMode
        : _lastPickerPanelMode;

    final input = SafeArea(
      top: false,
      child: ColoredBox(
        color: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Edit bar takes precedence; otherwise show reply bar.
            if (editing != null)
              _buildEditingBar(editing, sendInFlight: editingSendInFlight)
            else if (replyTo != null)
              _buildReplyBar(replyTo),
            if (autocompleteMatch != null &&
                (autocompleteOptions.isNotEmpty || autocompleteLoading))
              Flexible(
                fit: FlexFit.loose,
                child: _buildAutocompletePanel(
                  options: autocompleteOptions,
                  loading: autocompleteLoading,
                  viewportItemCount: _autocompleteViewportCount(context),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 4, 10, 12),
              child: GlassPanel(
                key: const ValueKey('message-input-surface'),
                radius: NeuRadius.nav,
                blur: 18,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    NeuIconButton(
                      icon: widget.panelMode == InputPanelMode.emoji
                          ? Icons.keyboard_rounded
                          : (_pickerTab == ComposerPickerTab.sticker
                                ? Icons.interests_rounded
                                : Icons.sentiment_satisfied_alt_rounded),
                      size: 44,
                      selected: widget.panelMode == InputPanelMode.emoji,
                      onPressed: sendBusy
                          ? null
                          : widget.panelMode == InputPanelMode.emoji
                          ? _showKeyboard
                          : _togglePicker,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Container(
                        key: _textFieldKey,
                        constraints: const BoxConstraints(
                          minHeight: 44,
                          maxHeight: 120,
                        ),
                        decoration: NeuDecoration(
                          colors: colors,
                          depth: NeuDepth.pressed,
                          radius: NeuRadius.content,
                          intensity: .85,
                          borderColor: _focusNode.hasFocus
                              ? colors.accent
                              : null,
                        ),
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          readOnly: editingSourceLoading,
                          contextMenuBuilder:
                              markdownSelectionContextMenuBuilder,
                          style: Theme.of(context).textTheme.bodyLarge,
                          cursorColor: colors.accent,
                          decoration: InputDecoration(
                            hintText: '消息',
                            hintStyle: Theme.of(context).textTheme.bodyLarge
                                ?.copyWith(color: colors.textTertiary),
                            contentPadding: const EdgeInsets.symmetric(
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
                    SizedBox(
                      width: 94,
                      height: 44,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          Builder(
                            builder: (buttonContext) => Tooltip(
                              message: '附件',
                              // Desktop hover still shows the tooltip; its
                              // long-press trigger belongs to the outer
                              // GestureDetector so it can open the tools menu
                              // instead.
                              triggerMode: TooltipTriggerMode.manual,
                              child: GestureDetector(
                                onLongPress: sendBusy
                                    ? null
                                    : () =>
                                          _showComposerToolsMenu(buttonContext),
                                child: NeuIconButton(
                                  icon: Icons.add_rounded,
                                  size: 44,
                                  selected:
                                      widget.panelMode ==
                                      InputPanelMode.attachment,
                                  onPressed: sendBusy
                                      ? null
                                      : _toggleAttachmentPicker,
                                ),
                              ),
                            ),
                          ),
                          AnimatedSwitcher(
                            duration: _toolbarAnimationDuration,
                            switchInCurve: _toolbarAnimationCurve,
                            switchOutCurve: Curves.easeInCubic,
                            child: _hasText
                                ? SizedBox.square(
                                    key: const ValueKey('send_only'),
                                    dimension: 44,
                                    child: sendBusy
                                        ? Center(
                                            child: SizedBox.square(
                                              dimension: 20,
                                              child: CircularProgressIndicator(
                                                color: colors.accent,
                                                strokeWidth: 2,
                                              ),
                                            ),
                                          )
                                        : NeuIconButton(
                                            icon: Icons.send_rounded,
                                            size: 44,
                                            accent: true,
                                            onPressed: _sendMessage,
                                          ),
                                  )
                                : const SizedBox.square(
                                    key: ValueKey('voice_only'),
                                    dimension: 44,
                                    child: NeuIconButton(
                                      tooltip: '语音消息暂未提供',
                                      icon: Icons.mic_none_rounded,
                                      size: 44,
                                      onPressed: null,
                                    ),
                                  ),
                          ),
                        ],
                      ),
                    ),
                  ],
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
                            colors.base.withValues(alpha: 0.52),
                            colors.base.withValues(alpha: 0.88),
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
    final draftKey = _draftKey;
    final roomId = widget.roomId;
    // An in-progress edit from a (possibly disposed) full-screen composer
    // session takes precedence over the stored original. Captured before
    // the awaits: after an unmount this state's ref is dead, the notifier
    // is not.
    final editDraftState = ref.read(editingDraftProvider(draftKey).notifier);
    var pending = editDraftState.value;
    String? source;
    try {
      if (pending != null && pending.editingId == editing.id) {
        source = pending.text;
      } else {
        final allowPersistence = await _canPersistMarkdownSource(roomId);
        source = await _markdownSourceStore.load(
          userId: draftKey.userId,
          roomId: roomId,
          eventId: editing.id,
          body: editing.content,
          formattedBody: editing.formattedBody,
          allowPersistence: allowPersistence,
        );
        // The full-screen composer may have synced a newer edit while the
        // store read was in flight; re-check so it wins over the stored text.
        pending = editDraftState.value;
        if (pending != null && pending.editingId == editing.id) {
          source = pending.text;
        }
      }
    } catch (e) {
      debugPrint('Failed to restore markdown source: $e');
    }
    if (!mounted || _lastEditingId != editing.id) return;
    _controller.text = source ?? editing.content;
    _controller.selection = TextSelection.fromPosition(
      TextPosition(offset: _controller.text.length),
    );
    setState(() {
      if (_editingSourceLoadingId == editing.id) {
        _editingSourceLoadingId = null;
      }
      _hasText = _controller.text.trim().isNotEmpty;
    });
  }

  void _restoreDraft() {
    _lastEditingId = null;
    _editingSourceLoadingId = null;
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
      setState(() {
        _hasText = hasText;
      });
    }
  }

  Widget _buildReplyBar(rust.ChatMessage replyTo) {
    final colors = context.neu;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: NeuDecoration(
        colors: colors,
        depth: NeuDepth.pressed,
        radius: NeuRadius.button,
        intensity: .7,
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: colors.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  replyTo.senderName,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.accent,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  replyTo.content,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          NeuIconButton(
            icon: Icons.close_rounded,
            size: 30,
            onPressed: () {
              ref.read(replyingToProvider(_draftKey).notifier).value = null;
            },
          ),
        ],
      ),
    );
  }

  Widget _buildEditingBar(
    rust.ChatMessage editing, {
    required bool sendInFlight,
  }) {
    final colors = context.neu;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: NeuDecoration(
        colors: colors,
        depth: NeuDepth.pressed,
        radius: NeuRadius.button,
        intensity: .7,
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 32,
            decoration: BoxDecoration(
              color: colors.warning,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '编辑中',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w700,
                    color: colors.warning,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  editing.content,
                  style: Theme.of(context).textTheme.bodySmall,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (sendInFlight)
            SizedBox.square(
              dimension: 30,
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    color: colors.accent,
                    strokeWidth: 2,
                  ),
                ),
              ),
            )
          else
            NeuIconButton(
              icon: Icons.close_rounded,
              size: 30,
              onPressed: () {
                ref.read(editingMessageProvider(_draftKey).notifier).value =
                    null;
                ref.read(editingDraftProvider(_draftKey).notifier).value = null;
              },
            ),
        ],
      ),
    );
  }
}
