import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/message_cache_persistence.dart';
import '../../providers/message_ordering.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart';
import '../../theme/app_theme.dart';
import '../../widgets/app_avatar.dart';
import 'chat_timestamp.dart';
import 'composer_picker_panel.dart';
import 'date_separator.dart';
import 'floating_date_header.dart';
import 'forward_message_sheet.dart';
import 'latest_message_control.dart';
import 'local_outgoing_matcher.dart';
import 'message_group.dart';
import 'message_input.dart';

final chatRouteObserver = RouteObserver<ModalRoute<dynamic>>();

class ChatDetailPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final String subtitle;
  final bool isDm;

  const ChatDetailPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.subtitle = '在线',
    this.isDm = false,
  });

  @override
  ConsumerState<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends ConsumerState<ChatDetailPage>
    with RouteAware {
  final _scrollController = ScrollController();
  final _scrollViewportKey = GlobalKey();
  late final MutableState<String?> _currentRoomIdNotifier;
  ModalRoute<dynamic>? _route;
  final List<ChatMessage> _olderMessages = [];
  final List<MessageGroup> _groupedMessages = [];
  final Map<String, ChatMessage> _messageIndex = {};
  final List<_TimelineEntry> _timelineEntries = [];
  final Map<Key, int> _timelineEntryIndexByKey = {};
  final Map<String, GlobalKey> _dateSeparatorKeys = {};
  List<ChatMessage> _displayedMessages = [];
  List<DateBoundary> _floatingDateBoundariesCache = const [];
  List<GlobalKey> _floatingDateSeparatorKeysCache = const [];
  bool _hasTimelineGroups = false;
  List<ChatMessage>? _lastMessageMergeInput;
  List<LocalOutgoingMessage>? _lastLocalMergeInput;
  List<ChatMessage> _lastTimelineMessages = const [];
  List<ChatMessage>? _lastDerivedMessagesInput;
  int _olderMessagesRevision = 0;
  int _lastDerivedOlderMessagesRevision = -1;
  int _sortOverrideRevision = 0;
  int _lastDerivedSortOverrideRevision = -1;
  bool _isLoadingOlder = false;
  bool _hasMoreMessages = true;
  bool _olderLoadArmed = true;
  String _derivedMessagesFingerprint = '';
  InputPanelMode _inputPanelMode = InputPanelMode.none;
  double? _inputChromeHeight;
  double _panelBaselineHeight = 0;
  double _expandedPickerHeight = 0;
  bool _isPickerResizing = false;
  Timer? _pickerResizeTimer;
  Timer? _sentNoticeTimer;
  Timer? _forwardNoticeTimer;
  bool _showLatestMessageControl = false;
  bool _showSentNotice = false;
  ChatRoom? _forwardNoticeRoom;
  final Set<String> _insertionAnimationIds = {};

  /// Remote event ids that have already been matched with a local outgoing
  /// message. Keeps duplicate sends of the same payload from being incorrectly
  /// collapsed onto the same remote event.
  final Set<String> _consumedRemoteIds = {};

  /// Maps a remote event id to the stable flight id of the local message it
  /// replaced. Used to keep [SendFlightTarget] state alive across the
  /// local-to-remote transition.
  final Map<String, String> _remoteToLocalFlightId = {};

  /// Maps a matched remote event id to the optimistic local timestamp it
  /// replaced. This keeps rapid sends visually ordered by send intent while
  /// the server copy takes over from the local optimistic row.
  final Map<String, int> _remoteToLocalSortTimestamp = {};
  bool _keepPickerDuringKeyboardOpen = false;
  bool _keyboardWasVisible = false;

  static const double _olderLoadTriggerMinDistance = 1200.0;
  static const double _olderLoadTriggerViewportMultiplier = 2.0;
  static const double _olderLoadRearmDistance = 480.0;
  static const double _baseInputChromeHeight = 60.0;
  static const int _maxMessagesPerRenderGroup = 12;
  static const Duration _sentNoticeDuration = Duration(milliseconds: 2800);
  static const Duration _forwardNoticeDuration = Duration(seconds: 4);
  static const Duration _insertionAnimationLifetime = Duration(
    milliseconds: 500,
  );

  void _setInputPanelMode(InputPanelMode mode) {
    if (_inputPanelMode == mode) return;
    final pickerIsOpen =
        _inputPanelMode == InputPanelMode.emoji ||
        _inputPanelMode == InputPanelMode.attachment;
    final opensPicker =
        mode == InputPanelMode.emoji || mode == InputPanelMode.attachment;
    setState(() {
      _keepPickerDuringKeyboardOpen =
          pickerIsOpen && mode == InputPanelMode.keyboard;
      if (mode == InputPanelMode.none) {
        _keepPickerDuringKeyboardOpen = false;
      }
      if (!opensPicker || (pickerIsOpen && _inputPanelMode != mode)) {
        _expandedPickerHeight = 0;
      }
      _inputPanelMode = mode;
    });
  }

  @override
  void initState() {
    super.initState();
    _currentRoomIdNotifier = ref.read(currentRoomIdProvider.notifier);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(replyingToProvider(widget.roomId).notifier).value = null;
      _activateRoom();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route == _route) return;
    if (_route != null) chatRouteObserver.unsubscribe(this);
    _route = route;
    if (route != null) chatRouteObserver.subscribe(this, route);
  }

  @override
  void didPopNext() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _activateRoom();
    });
  }

  void _activateRoom() {
    _currentRoomIdNotifier.value = widget.roomId;
    unawaited(
      subscribeTypingForRoom(roomId: widget.roomId).catchError((e) {
        debugPrint('subscribeTypingForRoom failed: $e');
      }),
    );
    unawaited(
      subscribeRoomForReceipts(roomId: widget.roomId).catchError((e) {
        debugPrint('subscribeRoomForReceipts failed: $e');
      }),
    );
    unawaited(_primeAndRefreshMessages());
  }

  Future<void> _primeAndRefreshMessages() async {
    await primeMessageCache(ref, widget.roomId);
    if (!mounted || _currentRoomIdNotifier.value != widget.roomId) return;
    await refreshMessagesFromNetwork(ref, widget.roomId);
  }

  Map<String, String?> _buildAvatarMap(List<Contact> members) {
    final map = <String, String?>{};
    for (final m in members) {
      map[m.id] = m.avatarUrl;
    }
    return map;
  }

  @override
  void dispose() {
    chatRouteObserver.unsubscribe(this);
    final currentRoomIdNotifier = _currentRoomIdNotifier;
    final roomId = widget.roomId;
    Future.microtask(() {
      if (currentRoomIdNotifier.value == roomId) {
        currentRoomIdNotifier.value = null;
      }
    });
    unawaited(
      unsubscribeTyping(roomId: roomId).catchError((e) {
        debugPrint('unsubscribeTyping failed: $e');
      }),
    );
    unawaited(
      unsubscribeRoomForReceipts(roomId: roomId).catchError((e) {
        debugPrint('unsubscribeRoomForReceipts failed: $e');
      }),
    );
    _pickerResizeTimer?.cancel();
    _sentNoticeTimer?.cancel();
    _forwardNoticeTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  double _distanceFromLatest(ScrollMetrics metrics) {
    return math.max(0, metrics.pixels - metrics.minScrollExtent);
  }

  double _distanceFromOlderEdge(ScrollMetrics metrics) {
    return math.max(0, metrics.maxScrollExtent - metrics.pixels);
  }

  double _olderLoadTriggerDistance(ScrollMetrics metrics) {
    return math.max(
      _olderLoadTriggerMinDistance,
      metrics.viewportDimension * _olderLoadTriggerViewportMultiplier,
    );
  }

  void _updateLatestMessageControl(ScrollMetrics metrics) {
    final shouldShow = shouldShowLatestMessageControl(
      distanceFromLatest: _distanceFromLatest(metrics),
      viewportDimension: metrics.viewportDimension,
      currentlyVisible: _showLatestMessageControl,
    );
    if (shouldShow == _showLatestMessageControl) return;

    if (!shouldShow) {
      _sentNoticeTimer?.cancel();
    }
    setState(() {
      _showLatestMessageControl = shouldShow;
      if (!shouldShow) _showSentNotice = false;
    });
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    final metrics = notification.metrics;
    _updateLatestMessageControl(metrics);
    _maybeLoadOlderMessages(metrics);
    return false;
  }

  void _maybeLoadOlderMessages(ScrollMetrics metrics) {
    final distanceFromOlderEdge = _distanceFromOlderEdge(metrics);
    final triggerDistance = _olderLoadTriggerDistance(metrics);
    if (distanceFromOlderEdge > triggerDistance + _olderLoadRearmDistance) {
      _olderLoadArmed = true;
    }

    if (_olderLoadArmed &&
        !_isLoadingOlder &&
        _hasMoreMessages &&
        _displayedMessages.isNotEmpty &&
        distanceFromOlderEdge <= triggerDistance) {
      _olderLoadArmed = false;
      unawaited(_loadOlderMessages());
    }
  }

  bool _handleScrollMetricsNotification(
    ScrollMetricsNotification notification,
  ) {
    _updateLatestMessageControl(notification.metrics);
    _maybeLoadOlderMessages(notification.metrics);
    return false;
  }

  void _scrollToLatest() {
    _sentNoticeTimer?.cancel();
    if (_showSentNotice) {
      setState(() => _showSentNotice = false);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scrollController.hasClients) return;
      final position = _scrollController.position;
      _scrollController.animateTo(
        position.minScrollExtent,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
    });
  }

  MessageSendPresentation _resolveSendPresentation() {
    if (!_scrollController.hasClients) {
      return MessageSendPresentation.flight;
    }
    final position = _scrollController.position;
    return resolveMessageSendPresentation(
      distanceFromLatest: _distanceFromLatest(position),
      viewportDimension: position.viewportDimension,
    );
  }

  void _handleMessageQueued(
    String stableMessageId,
    MessageSendPresentation presentation,
  ) {
    if (presentation == MessageSendPresentation.quiet) return;
    if (presentation == MessageSendPresentation.insert) {
      setState(() => _insertionAnimationIds.add(stableMessageId));
      Future<void>.delayed(_insertionAnimationLifetime, () {
        if (!mounted || !_insertionAnimationIds.contains(stableMessageId)) {
          return;
        }
        setState(() => _insertionAnimationIds.remove(stableMessageId));
      });
    }
    _scrollToLatest();
  }

  void _showMessageSentNotice() {
    _sentNoticeTimer?.cancel();
    setState(() {
      _showLatestMessageControl = true;
      _showSentNotice = true;
    });
    _sentNoticeTimer = Timer(_sentNoticeDuration, () {
      if (!mounted) return;
      setState(() => _showSentNotice = false);
    });
  }

  void _handleMessageSent(
    MessageSendPresentation presentation,
    bool insertedOptimistically,
  ) {
    if (presentation == MessageSendPresentation.quiet) {
      _showMessageSentNotice();
      return;
    }
    if (!insertedOptimistically) {
      _scrollToLatest();
    }
  }

  void _showForwardNotice(ChatRoom room) {
    _forwardNoticeTimer?.cancel();
    setState(() => _forwardNoticeRoom = room);
    _forwardNoticeTimer = Timer(_forwardNoticeDuration, () {
      if (!mounted) return;
      setState(() => _forwardNoticeRoom = null);
    });
  }

  void _openForwardNoticeRoom() {
    final room = _forwardNoticeRoom;
    if (room == null) return;
    _forwardNoticeTimer?.cancel();
    setState(() => _forwardNoticeRoom = null);
    if (room.id == widget.roomId) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ChatDetailPage(
          roomId: room.id,
          roomName: room.name,
          avatarUrl: room.avatarUrl,
          isDm: room.roomType == 'dm',
          subtitle: room.unreadCount > 0 ? '${room.unreadCount} 条未读消息' : '在线',
        ),
      ),
    );
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreMessages || _displayedMessages.isEmpty) {
      return;
    }

    final fromEventId = _displayedMessages.first.id;
    setState(() => _isLoadingOlder = true);
    try {
      final older = await getMessagesBefore(
        roomId: widget.roomId,
        fromEventId: fromEventId,
        limit: 100,
      );
      if (!mounted) return;

      final knownIds = _displayedMessages.map((message) => message.id).toSet();
      final newMessages = older
          .where((message) => !knownIds.contains(message.id))
          .toList();
      final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
      final allowDiskCache = !await isRoomEncrypted(roomId: widget.roomId);
      final currentCache = ref.read(messageCacheProvider(widget.roomId));
      final mergedCache = mergeMessageSnapshotAdditions(currentCache, older);
      if (!identical(mergedCache, currentCache)) {
        ref.read(messageCacheOwnerProvider(widget.roomId).notifier).value =
            namespace;
        ref.read(messageCacheProvider(widget.roomId).notifier).value =
            mergedCache;
        unawaited(
          saveCachedMessages(
            namespace: namespace,
            roomId: widget.roomId,
            messages: mergedCache,
            persistToDisk: allowDiskCache,
          ),
        );
      }
      setState(() {
        _olderMessages.insertAll(0, newMessages);
        if (newMessages.isNotEmpty) {
          _olderMessagesRevision++;
          _olderLoadArmed = true;
        }
        _hasMoreMessages = older.isNotEmpty;
        _isLoadingOlder = false;
      });
      if (newMessages.isNotEmpty) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scrollController.hasClients) return;
          _maybeLoadOlderMessages(_scrollController.position);
        });
      }
    } catch (error) {
      if (!mounted) return;
      setState(() => _isLoadingOlder = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载更早消息失败: $error')));
    }
  }

  List<ChatMessage> _mergeMessages(List<ChatMessage> latestMessages) {
    final byId = <String, ChatMessage>{
      for (final message in _olderMessages) message.id: message,
      for (final message in latestMessages) message.id: message,
    };
    final messages = byId.values.toList()
      ..sort(
        (a, b) => compareChatMessagesWithOverrides(
          a,
          b,
          _remoteToLocalSortTimestamp,
          _remoteToLocalFlightId,
        ),
      );
    return messages;
  }

  List<ChatMessage> _mergeLocalOutgoingMessages(
    List<ChatMessage> latestMessages,
    List<LocalOutgoingMessage> localMessages,
  ) {
    if (localMessages.isEmpty) return latestMessages;
    final matchResult = _matchedLocalOutgoingIds(latestMessages, localMessages);
    final matchedLocalIds = matchResult.localIds;
    if (matchedLocalIds.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        for (final id in matchedLocalIds) {
          LocalOutgoingMessage? local;
          for (final message in localMessages) {
            if (message.message.id == id) {
              local = message;
              break;
            }
          }
          rememberResolvedMxcUrl(
            ref,
            local?.sourceImageUrl,
            local?.message.imageUrl,
          );
          removeLocalOutgoingMessage(ref, widget.roomId, id);
        }
      });
    }

    return [
      ...latestMessages,
      ...localMessages
          .where((message) => !matchedLocalIds.contains(message.message.id))
          .map((message) => message.message),
    ];
  }

  List<ChatMessage> _timelineMessagesFor(
    List<ChatMessage> latestMessages,
    List<LocalOutgoingMessage> localMessages,
  ) {
    if (identical(latestMessages, _lastMessageMergeInput) &&
        identical(localMessages, _lastLocalMergeInput)) {
      return _lastTimelineMessages;
    }
    _lastMessageMergeInput = latestMessages;
    _lastLocalMergeInput = localMessages;
    _lastTimelineMessages = _mergeLocalOutgoingMessages(
      latestMessages,
      localMessages,
    );
    return _lastTimelineMessages;
  }

  LocalOutgoingMatchResult _matchedLocalOutgoingIds(
    List<ChatMessage> latestMessages,
    List<LocalOutgoingMessage> localMessages,
  ) {
    final result = matchLocalOutgoingMessages(
      latestMessages,
      localMessages,
      _consumedRemoteIds,
    );
    _remoteToLocalFlightId.addAll(result.remoteToLocalFlightId);
    var sortOverridesChanged = false;
    for (final entry in result.remoteToLocalSortTimestamp.entries) {
      if (_remoteToLocalSortTimestamp[entry.key] != entry.value) {
        sortOverridesChanged = true;
      }
      _remoteToLocalSortTimestamp[entry.key] = entry.value;
    }
    if (sortOverridesChanged) {
      _sortOverrideRevision++;
    }
    return result;
  }

  List<MessageGroup> _groupMessages(List<ChatMessage> messages) {
    final groups = <MessageGroup>[];
    for (final message in messages) {
      final startsNewCluster =
          groups.isEmpty ||
          groups.last.senderId != message.senderId ||
          chatDateKey(groups.last.messages.last.timestamp) !=
              chatDateKey(message.timestamp);
      final startsNewRenderGroup =
          startsNewCluster ||
          groups.last.messages.length >= _maxMessagesPerRenderGroup;
      if (startsNewRenderGroup) {
        if (!startsNewCluster && groups.isNotEmpty) {
          groups.last.endsCluster = false;
        }
        groups.add(
          MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: message.isMe,
            messages: [message],
            startsCluster: startsNewCluster,
          ),
        );
      } else {
        groups.last.messages.add(message);
      }
    }
    return groups;
  }

  String _messagesFingerprint(List<ChatMessage> latestMessages) {
    final buffer = StringBuffer()
      ..write('older=')
      ..write(_olderMessages.length)
      ..write(';latest=')
      ..write(latestMessages.length);
    for (final message in _olderMessages) {
      buffer
        ..write('|o:')
        ..write(message.id)
        ..write('@')
        ..write(message.timestamp)
        ..write('#')
        ..write(message.content)
        ..write('#')
        ..write(message.formattedBody ?? '')
        ..write('#')
        ..write(message.caption ?? '')
        ..write('#')
        ..write(message.captionFormattedBody ?? '');
      final localSortTimestamp = _remoteToLocalSortTimestamp[message.id];
      if (localSortTimestamp != null) {
        buffer
          ..write('#localSort=')
          ..write(localSortTimestamp);
      }
    }
    for (final message in latestMessages) {
      buffer
        ..write('|l:')
        ..write(message.id)
        ..write('@')
        ..write(message.timestamp)
        ..write('#')
        ..write(message.content)
        ..write('#')
        ..write(message.formattedBody ?? '')
        ..write('#')
        ..write(message.caption ?? '')
        ..write('#')
        ..write(message.captionFormattedBody ?? '')
        ..write('#')
        ..write(message.isEdited ? 1 : 0)
        ..write('#')
        ..write(message.reactions.length)
        ..write('#')
        ..write(message.totalMembers)
        ..write('#')
        ..writeAll(message.readers.map((reader) => reader.userId), ',');
      final localSortTimestamp = _remoteToLocalSortTimestamp[message.id];
      if (localSortTimestamp != null) {
        buffer
          ..write('#localSort=')
          ..write(localSortTimestamp);
      }
    }
    return buffer.toString();
  }

  void _rebuildDerivedMessages(List<ChatMessage> latestMessages) {
    if (identical(_lastDerivedMessagesInput, latestMessages) &&
        _lastDerivedOlderMessagesRevision == _olderMessagesRevision &&
        _lastDerivedSortOverrideRevision == _sortOverrideRevision) {
      return;
    }
    final fingerprint = _messagesFingerprint(latestMessages);
    if (_derivedMessagesFingerprint == fingerprint) {
      _lastDerivedMessagesInput = latestMessages;
      _lastDerivedOlderMessagesRevision = _olderMessagesRevision;
      _lastDerivedSortOverrideRevision = _sortOverrideRevision;
      return;
    }
    _derivedMessagesFingerprint = fingerprint;
    _lastDerivedMessagesInput = latestMessages;
    _lastDerivedOlderMessagesRevision = _olderMessagesRevision;
    _lastDerivedSortOverrideRevision = _sortOverrideRevision;
    final displayedMessages = _mergeMessages(latestMessages);
    _displayedMessages = displayedMessages;
    _messageIndex
      ..clear()
      ..addEntries(
        displayedMessages.map((message) => MapEntry(message.id, message)),
      );
    // Drop flight-id mappings for remote messages that are no longer on screen.
    _remoteToLocalFlightId.removeWhere(
      (remoteId, _) => !_messageIndex.containsKey(remoteId),
    );
    _remoteToLocalSortTimestamp.removeWhere(
      (remoteId, _) => !_messageIndex.containsKey(remoteId),
    );
    _groupedMessages
      ..clear()
      ..addAll(_groupMessages(displayedMessages));
    _timelineEntries
      ..clear()
      ..addAll(_buildTimelineEntries(_groupedMessages));
    _timelineEntryIndexByKey
      ..clear()
      ..addEntries(
        _timelineEntries.asMap().entries.map(
          (entry) => MapEntry(entry.value.itemKey, entry.key),
        ),
      );
    _hasTimelineGroups = _timelineEntries.any(
      (entry) => entry.type == _TimelineEntryType.group,
    );
    _floatingDateBoundariesCache = _buildFloatingDateBoundaries(
      _timelineEntries,
    );
    _floatingDateSeparatorKeysCache = _buildFloatingDateSeparatorKeys(
      _timelineEntries,
    );
  }

  List<_TimelineEntry> _buildTimelineEntries(List<MessageGroup> groups) {
    final entries = <_TimelineEntry>[];
    final activeDateIds = <String>{};
    for (var i = groups.length - 1; i >= 0; i--) {
      final group = groups[i];
      final dateKey = chatDateKey(group.messages.first.timestamp);
      final anchorId =
          '$dateKey:${group.senderId}:${group.messages.first.id}:${group.messages.last.id}';
      entries.add(
        _TimelineEntry.group(
          group,
          formatChatDate(group.messages.first.timestamp),
          ValueKey(anchorId),
        ),
      );
      if (i == 0 ||
          chatDateKey(groups[i - 1].messages.first.timestamp) !=
              chatDateKey(group.messages.first.timestamp)) {
        activeDateIds.add(dateKey);
        entries.add(
          _TimelineEntry.date(
            formatChatDate(group.messages.first.timestamp),
            _dateSeparatorKeys.putIfAbsent(dateKey, GlobalKey.new),
          ),
        );
      }
    }
    _dateSeparatorKeys.removeWhere((key, _) => !activeDateIds.contains(key));
    return entries;
  }

  void _handlePickerHeightChanged(double height, double baseHeight) {
    if (!mounted ||
        (_inputPanelMode != InputPanelMode.emoji &&
            _inputPanelMode != InputPanelMode.attachment)) {
      return;
    }
    _pickerResizeTimer?.cancel();
    final nextHeight = math.max(baseHeight, height);
    if ((_expandedPickerHeight - nextHeight).abs() >= 0.5 ||
        !_isPickerResizing) {
      setState(() {
        _isPickerResizing = true;
        _expandedPickerHeight = nextHeight;
      });
    }
    _pickerResizeTimer = Timer(const Duration(milliseconds: 80), () {
      if (mounted && _isPickerResizing) {
        setState(() => _isPickerResizing = false);
      }
    });
  }

  bool _isEventGroup(MessageGroup group) {
    return group.messages.every((m) => m.msgType == MessageType.event);
  }

  bool _needsStickyAvatar(MessageGroup group) {
    return !widget.isDm && !group.isMe && !_isEventGroup(group);
  }

  Widget _buildTimelineEntry(
    _TimelineEntry entry,
    Map<String, String?> avatarMap,
    Map<String, Contact> membersById,
    Map<String, ChatMessage> messageIndex,
    double stickyBottomInset,
  ) {
    switch (entry.type) {
      case _TimelineEntryType.group:
        final group = entry.group!;
        return MessageGroupWidget(
          key: entry.anchorKey,
          group: group,
          roomId: widget.roomId,
          messageIndex: messageIndex,
          remoteToLocalFlightId: _remoteToLocalFlightId,
          insertionAnimationIds: _insertionAnimationIds,
          membersById: membersById,
          showAvatar: _needsStickyAvatar(group),
          compact: widget.isDm,
          senderAvatarUrl: avatarMap[group.senderId],
          scrollController: _scrollController,
          scrollViewportKey: _scrollViewportKey,
          stickyBottomInset: stickyBottomInset,
          onImageLoaded: null,
          onReplyRequested: () => _setInputPanelMode(InputPanelMode.keyboard),
          onMessageForwarded: _showForwardNotice,
        );
      case _TimelineEntryType.date:
        return DateSeparator(
          key: entry.separatorKey,
          dateLabel: entry.dateLabel!,
        );
    }
  }

  int? _findTimelineEntryIndex(Key key) {
    return _timelineEntryIndexByKey[key];
  }

  @override
  Widget build(BuildContext context) {
    // Watch the in-memory snapshot so the timeline never blanks during a
    // network fetch; the cache is primed from disk in initState and kept in
    // sync by refreshMessagesFromNetwork / syncStreamProvider.
    final cachedMessages = ref.watch(messageCacheProvider(widget.roomId));
    final messageCachePrimed = ref.watch(
      messageCachePrimedProvider(widget.roomId),
    );
    final messageCacheOwner = ref.watch(
      messageCacheOwnerProvider(widget.roomId),
    );
    final activeUserId = ref.watch(activeUserIdProvider) ?? 'anonymous';
    final membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    final cachedTotalMembers = cachedMessages.fold<int>(
      0,
      (count, message) => math.max(count, message.totalMembers),
    );
    final totalMembers =
        membersAsync.asData?.value.length ?? cachedTotalMembers;
    ref.watch(typingStreamProvider);
    final localOutgoingMessages = ref.watch(
      localOutgoingMessagesProvider(widget.roomId),
    );
    final keyboardHeight = MediaQuery.viewInsetsOf(context).bottom;
    if (keyboardHeight > 0 && keyboardHeight > _panelBaselineHeight) {
      _panelBaselineHeight = keyboardHeight;
    }
    final keyboardVisible = keyboardHeight > 0;
    if (keyboardVisible) {
      _keyboardWasVisible = true;
    } else if (_keyboardWasVisible &&
        _inputPanelMode == InputPanelMode.keyboard &&
        !_keepPickerDuringKeyboardOpen) {
      _keyboardWasVisible = false;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || _inputPanelMode != InputPanelMode.keyboard) return;
        setState(() => _inputPanelMode = InputPanelMode.none);
      });
    }
    final keepsStablePicker =
        _inputPanelMode == InputPanelMode.emoji ||
        _inputPanelMode == InputPanelMode.attachment ||
        _keepPickerDuringKeyboardOpen;
    final pickerBaseHeight = _panelBaselineHeight > 0
        ? _panelBaselineHeight
        : ComposerPickerPanel.baseHeight;
    final pickerFullHeight = keepsStablePicker
        ? math.max(pickerBaseHeight, _expandedPickerHeight)
        : pickerBaseHeight;
    final mediaQuery = MediaQuery.of(context);
    final inputChromeHeight =
        _inputChromeHeight ??
        _baseInputChromeHeight + mediaQuery.padding.bottom;
    final pickerMaxHeight = math.max(
      pickerBaseHeight,
      mediaQuery.size.height -
          mediaQuery.padding.top -
          mediaQuery.padding.bottom -
          kToolbarHeight -
          inputChromeHeight -
          8,
    );
    final pickerHeight = keepsStablePicker
        ? math.max(0.0, pickerFullHeight - keyboardHeight)
        : 0.0;
    final bottomOffset =
        (_inputPanelMode == InputPanelMode.keyboard || keepsStablePicker)
        ? keyboardHeight
        : 0.0;
    final panelReservedHeight = keepsStablePicker
        ? pickerFullHeight
        : (_inputPanelMode == InputPanelMode.keyboard ? keyboardHeight : 0.0);
    final messageBottomPadding = inputChromeHeight + panelReservedHeight;
    final animatePanelChange = !keyboardVisible && !_isPickerResizing;

    if (_keepPickerDuringKeyboardOpen &&
        keyboardHeight >= pickerFullHeight - 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_keepPickerDuringKeyboardOpen) return;
        setState(() => _keepPickerDuringKeyboardOpen = false);
      });
    }

    return PopScope(
      canPop: _inputPanelMode == InputPanelMode.none && !keyboardVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _setInputPanelMode(InputPanelMode.none);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: AppColors.background,
        appBar: AppBar(
          backgroundColor: AppColors.background.withValues(alpha: 0.92),
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(
              Icons.arrow_back_rounded,
              color: AppColors.onBackground,
            ),
            onPressed: () => Navigator.of(context).pop(),
          ),
          titleSpacing: 0,
          title: Row(
            children: [
              AppAvatar(
                fallback: widget.roomName,
                size: 36,
                radius: AppRadii.content,
                url: widget.avatarUrl,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.roomName,
                      style: const TextStyle(
                        color: AppColors.onBackground,
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      widget.subtitle,
                      style: const TextStyle(
                        color: AppColors.onSurfaceVariant,
                        fontSize: 12,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            IconButton(
              tooltip: '搜索暂未提供',
              icon: const Icon(
                Icons.search_rounded,
                color: AppColors.onBackground,
              ),
              onPressed: null,
            ),
            IconButton(
              icon: const Icon(
                Icons.more_vert_rounded,
                color: AppColors.onBackground,
              ),
              onPressed: () {
                _showRoomDetails(context);
              },
            ),
          ],
        ),
        body: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: AppColors.background),
            ),
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final messages = messageCacheOwner == activeUserId
                      ? cachedMessages
                      : const <ChatMessage>[];
                  // Do not expose the timeline until its initial insets and
                  // member-dependent labels are stable enough for layout.
                  if ((!messageCachePrimed &&
                          messages.isEmpty &&
                          localOutgoingMessages.isEmpty) ||
                      _inputChromeHeight == null ||
                      (membersAsync.isLoading && !membersAsync.hasValue)) {
                    return const Center(
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    );
                  }
                  final timelineMessages = _timelineMessagesFor(
                    messages,
                    localOutgoingMessages,
                  );
                  _rebuildDerivedMessages(timelineMessages);
                  final timelineEntries = _timelineEntries;
                  final messageIndex = _messageIndex;
                  final avatarMap = membersAsync.maybeWhen(
                    data: _buildAvatarMap,
                    orElse: () => const <String, String?>{},
                  );
                  final membersById = <String, Contact>{
                    for (final member
                        in membersAsync.asData?.value ?? const <Contact>[])
                      member.id: member,
                  };
                  return TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: messageBottomPadding),
                    duration: animatePanelChange
                        ? const Duration(milliseconds: 180)
                        : Duration.zero,
                    curve: Curves.easeOutCubic,
                    builder: (context, animatedBottomPadding, _) {
                      return NotificationListener<ScrollMetricsNotification>(
                        onNotification: _handleScrollMetricsNotification,
                        child: NotificationListener<ScrollNotification>(
                          onNotification: _handleScrollNotification,
                          child: CustomScrollView(
                            key: _scrollViewportKey,
                            reverse: true,
                            controller: _scrollController,
                            slivers: [
                              SliverPadding(
                                padding: EdgeInsets.only(
                                  bottom: 8 + animatedBottomPadding,
                                ),
                              ),
                              SliverList(
                                delegate: SliverChildBuilderDelegate(
                                  (context, index) => _buildTimelineEntry(
                                    timelineEntries[index],
                                    avatarMap,
                                    membersById,
                                    messageIndex,
                                    8 + animatedBottomPadding,
                                  ),
                                  childCount: timelineEntries.length,
                                  findChildIndexCallback:
                                      _findTimelineEntryIndex,
                                ),
                              ),
                              const SliverPadding(
                                padding: EdgeInsets.only(top: 8),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    child: const SizedBox.shrink(),
                  );
                },
              ),
            ),
            // Telegram-style floating date that tracks the day at the top edge
            // of the viewport while scrolling, then fades out.
            if (_hasTimelineGroups)
              FloatingDateHeader(
                scrollController: _scrollController,
                scrollViewportKey: _scrollViewportKey,
                boundaries: _floatingDateBoundariesCache,
                separatorKeys: _floatingDateSeparatorKeysCache,
              ),
            AnimatedPositioned(
              right: 16,
              bottom: messageBottomPadding + 12,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: LatestMessageControl(
                visible:
                    _showLatestMessageControl && _forwardNoticeRoom == null,
                showSentNotice: _showSentNotice,
                onPressed: _scrollToLatest,
              ),
            ),
            if (_forwardNoticeRoom case final room?)
              ForwardSuccessNoticeOverlay(
                key: const ValueKey('forward-success-position'),
                bottomInset: messageBottomPadding,
                roomName: room.name,
                onRoomTap: _openForwardNoticeRoom,
              ),
            AnimatedPositioned(
              left: 0,
              right: 0,
              bottom: bottomOffset,
              duration: Duration.zero,
              curve: Curves.easeOutCubic,
              child: _MeasuredSize(
                onChanged: (size) {
                  final chromeHeight = math.max(
                    0.0,
                    size.height - pickerHeight,
                  );
                  if (_inputChromeHeight == null) {
                    setState(() => _inputChromeHeight = chromeHeight);
                    return;
                  }
                  if ((inputChromeHeight - chromeHeight).abs() < 0.5) {
                    return;
                  }
                  setState(() => _inputChromeHeight = chromeHeight);
                },
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildTypingIndicator(),
                    MessageInput(
                      key: ValueKey('msg_input_${widget.roomId}'),
                      roomId: widget.roomId,
                      totalMembers: totalMembers,
                      panelMode: _inputPanelMode,
                      pickerHeight: pickerHeight,
                      pickerFullHeight: pickerFullHeight,
                      pickerBaseHeight: pickerBaseHeight,
                      pickerMaxHeight: pickerMaxHeight,
                      animatePickerHeight: animatePanelChange,
                      onPanelModeChanged: _setInputPanelMode,
                      onPickerHeightChanged: (height) =>
                          _handlePickerHeightChanged(height, pickerBaseHeight),
                      resolveSendPresentation: _resolveSendPresentation,
                      onMessageQueued: _handleMessageQueued,
                      onMessageSent: _handleMessageSent,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Day boundaries (oldest → newest) for the floating date header.
  List<DateBoundary> _buildFloatingDateBoundaries(
    List<_TimelineEntry> timelineEntries,
  ) {
    final labels = <String>[];
    for (final entry in timelineEntries) {
      if (entry.type == _TimelineEntryType.date && entry.dateLabel != null) {
        labels.add(entry.dateLabel!);
      }
    }
    final reversed = labels.reversed.toList();
    return [
      for (var i = 0; i < reversed.length; i++)
        DateBoundary(
          label: reversed[i],
          // A synthetic monotonic key is enough to order boundaries; the real
          // positioning comes from the separator geometry.
          leadingTimestamp: '${i + 1}',
        ),
    ];
  }

  /// Date separator anchors ordered oldest → newest.
  List<GlobalKey> _buildFloatingDateSeparatorKeys(
    List<_TimelineEntry> timelineEntries,
  ) {
    final keys = <GlobalKey>[];
    for (final entry in timelineEntries) {
      if (entry.type == _TimelineEntryType.date && entry.separatorKey != null) {
        keys.add(entry.separatorKey!);
      }
    }
    return keys.reversed.toList();
  }

  /// "… is typing" indicator shown above the message input.
  Widget _buildTypingIndicator() {
    final activeUserId = ref.watch(activeUserIdProvider);
    final typing = ref
        .watch(typingUsersProvider(widget.roomId))
        .where((id) => id != activeUserId)
        .toSet();
    if (typing.isEmpty) return const SizedBox.shrink();

    // Derive display names from user ids (localpart fallback).
    final names = typing.map((id) {
      final part = id.split(':').first;
      return part.startsWith('@') ? part.substring(1) : part;
    }).toList();

    final String text;
    if (names.length == 1) {
      text = '${names.first} 正在输入…';
    } else if (names.length == 2) {
      text = '${names[0]} 和 ${names[1]} 正在输入…';
    } else {
      text = '${names.length} 人正在输入…';
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: AppColors.onSurfaceVariant,
                fontSize: 12.5,
                fontStyle: FontStyle.italic,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _showRoomDetails(BuildContext context) {
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
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    AppAvatar(
                      fallback: widget.roomName,
                      size: 56,
                      url: widget.avatarUrl,
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.roomName,
                            style: const TextStyle(
                              color: AppColors.onBackground,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            widget.roomId,
                            style: const TextStyle(
                              color: AppColors.onSurfaceVariant,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(color: AppColors.surfaceVariant, height: 0.5),
              // Room members preview
              Consumer(
                builder: (context, ref, _) {
                  final membersAsync = ref.watch(
                    roomMembersProvider(widget.roomId),
                  );
                  return membersAsync.when(
                    data: (members) {
                      return Column(
                        children: [
                          _DetailMenuItem(
                            icon: Icons.people_rounded,
                            label: '成员 (${members.length})',
                            onTap: () => Navigator.of(context).pop(),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 8,
                            ),
                            child: SizedBox(
                              height: 44,
                              child: ListView.separated(
                                scrollDirection: Axis.horizontal,
                                itemCount: members.length > 10
                                    ? 10
                                    : members.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final member = members[index];
                                  return AppAvatar(
                                    fallback: member.name,
                                    size: 40,
                                    radius: 20,
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                    loading: () => const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        color: AppColors.primary,
                        strokeWidth: 2,
                      ),
                    ),
                    error: (_, _) => const SizedBox.shrink(),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

enum _TimelineEntryType { group, date }

class _TimelineEntry {
  final _TimelineEntryType type;
  final MessageGroup? group;
  final String? dateLabel;

  /// GlobalKey of the rendered [DateSeparator], used by the floating date
  /// header to read on-screen positions. Null for group entries.
  final GlobalKey? separatorKey;
  final Key? anchorKey;

  Key get itemKey => anchorKey ?? separatorKey!;

  const _TimelineEntry._({
    required this.type,
    this.group,
    this.dateLabel,
    this.separatorKey,
    this.anchorKey,
  });

  factory _TimelineEntry.group(
    MessageGroup group,
    String dateLabel,
    Key anchorKey,
  ) {
    return _TimelineEntry._(
      type: _TimelineEntryType.group,
      group: group,
      dateLabel: dateLabel,
      anchorKey: anchorKey,
    );
  }

  factory _TimelineEntry.date(String label, GlobalKey key) {
    return _TimelineEntry._(
      type: _TimelineEntryType.date,
      dateLabel: label,
      separatorKey: key,
    );
  }
}

class _DetailMenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _DetailMenuItem({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, color: AppColors.onSurface, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: const TextStyle(
                color: AppColors.onBackground,
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

class _MeasuredSize extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onChanged;

  const _MeasuredSize({required this.onChanged, required super.child});

  @override
  RenderObject createRenderObject(BuildContext context) {
    return _RenderMeasuredSize(onChanged);
  }

  @override
  void updateRenderObject(
    BuildContext context,
    covariant _RenderMeasuredSize renderObject,
  ) {
    renderObject.onChanged = onChanged;
  }
}

class _RenderMeasuredSize extends RenderProxyBox {
  ValueChanged<Size> onChanged;
  Size? _oldSize;

  _RenderMeasuredSize(this.onChanged);

  @override
  void performLayout() {
    super.performLayout();
    final newSize = child?.size ?? Size.zero;
    if (_oldSize == newSize) return;
    _oldSize = newSize;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      onChanged(newSize);
    });
  }
}
