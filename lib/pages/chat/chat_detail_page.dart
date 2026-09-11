import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

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
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';
import 'chat_timestamp.dart';
import 'composer_picker_panel.dart';
import 'date_separator.dart';
import 'floating_date_header.dart';
import 'forward_message_sheet.dart';
import 'latest_message_control.dart';
import 'local_outgoing_matcher.dart';
import 'message_group.dart';
import 'message_input.dart';
import 'pinned_messages_page.dart';
import 'pinned_messages_stack.dart';
import 'room_management_page.dart';
import 'room_metadata_patch.dart';
import 'room_state_edit_tracker.dart';
import 'search_page.dart';
import 'send_flight.dart';

final chatRouteObserver = _ChatRouteObserver();

class _ChatRouteObserver extends RouteObserver<ModalRoute<dynamic>> {
  final _coveringRoutes = <ModalRoute<dynamic>, Route<dynamic>>{};

  bool isCoveredByPopup(ModalRoute<dynamic>? route) =>
      route != null && _coveringRoutes[route] is PopupRoute<dynamic>;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    if (previousRoute case final ModalRoute<dynamic> previousModalRoute) {
      _coveringRoutes[previousModalRoute] = route;
    }
    super.didPush(route, previousRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forgetRoute(route);
    super.didPop(route, previousRoute);
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    _forgetRoute(route);
    super.didRemove(route, previousRoute);
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) {
      final coveringRoute = _coveringRoutes.remove(oldRoute);
      if (newRoute case final ModalRoute<dynamic> newModalRoute) {
        if (coveringRoute != null) {
          _coveringRoutes[newModalRoute] = coveringRoute;
        }
      }
      for (final entry in _coveringRoutes.entries.toList()) {
        if (identical(entry.value, oldRoute)) {
          if (newRoute == null) {
            _coveringRoutes.remove(entry.key);
          } else {
            _coveringRoutes[entry.key] = newRoute;
          }
        }
      }
    }
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
  }

  void _forgetRoute(Route<dynamic> route) {
    _coveringRoutes.remove(route);
    _coveringRoutes.removeWhere((_, covering) => identical(covering, route));
  }
}

class ChatDetailPage extends ConsumerStatefulWidget {
  final String roomId;
  final String roomName;
  final String? avatarUrl;
  final String? nameEventId;
  final String? avatarEventId;
  final String subtitle;
  final bool isDm;
  final String? initialMessageId;
  final bool embedded;
  final bool detailsPanelOpen;
  final VoidCallback? onToggleDetailsPanel;
  final VoidCallback? onRoomLeft;
  final ValueChanged<RoomMetadataPatch>? onRoomDetailsChanged;

  /// Lets an external owner (the desktop details panel is a sibling of this
  /// page in the desktop layout) route room-details edits through this
  /// page's [_roomNameEdit]/[_roomAvatarEdit] trackers, so edits made
  /// outside this page get the same sync-echo rollback protection as edits
  /// made from the room management page inside it.
  final void Function(ValueChanged<RoomMetadataPatch>)?
  onRegisterRoomDetailsHandler;

  const ChatDetailPage({
    super.key,
    required this.roomId,
    required this.roomName,
    this.avatarUrl,
    this.nameEventId,
    this.avatarEventId,
    this.subtitle = '在线',
    this.isDm = false,
    this.initialMessageId,
    this.embedded = false,
    this.detailsPanelOpen = false,
    this.onToggleDetailsPanel,
    this.onRoomLeft,
    this.onRoomDetailsChanged,
    this.onRegisterRoomDetailsHandler,
  });

  @override
  ConsumerState<ChatDetailPage> createState() => _ChatDetailPageState();
}

class _ChatDetailPageState extends ConsumerState<ChatDetailPage>
    with RouteAware, WidgetsBindingObserver {
  /// Monotonic counter for room activations across page instances. The
  /// dispose microtask clears the global current-room only when THIS page
  /// still holds the latest activation: a re-push of the same room during
  /// the pop animation must not have its activation wiped by the dying
  /// page (its microtask would otherwise match the shared room id).
  static int _activationCounter = 0;

  /// The activation id this page last wrote (0 = never activated).
  int _activationId = 0;

  final _scrollController = ScrollController();
  final _scrollViewportKey = GlobalKey();
  final _messageInputKey = GlobalKey<MessageInputState>();
  final Map<String, GlobalKey> _messageAnchorKeys = {};
  final Map<String, GlobalKey> _stableMessageAnchorKeys = {};
  late final MutableState<String?> _currentRoomIdNotifier;

  /// Latest live notifier, retained only for the deferred dispose cleanup.
  /// Normal writes re-read the family because session invalidation disposes
  /// its previous notifier while this page can remain mounted.
  MutableState<String?>? _roomViewOwnerStateForDispose;

  Future<void> _subscriptionLifecycle = Future.value();
  bool _subscriptionsDesired = false;
  bool _viewSuspended = false;

  /// The account the subscriptions were (last) opened under; used to detect
  /// an account switch-back that must re-subscribe.
  String? _subscriptionsAccount;
  String? _typingSubscriptionId;
  String? _roomSubscriptionId;
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
  late String _roomName;
  String? _avatarUrl;
  String? _nameEventId;
  String? _avatarEventId;

  /// State-event IDs distinguish repeated values (A → B → A), so a cached A
  /// cannot be mistaken for the final A's echo.
  final _roomNameEdit = RoomStateEditTracker();
  final _roomAvatarEdit = RoomStateEditTracker();
  List<ChatMessage>? _lastMessageMergeInput;
  List<LocalOutgoingMessage>? _lastLocalMergeInput;
  RoomAccountKey? _lastLocalRoomAccountKey;
  List<ChatMessage> _lastTimelineMessages = const [];
  List<ChatMessage>? _lastDerivedMessagesInput;
  int _olderMessagesRevision = 0;
  int _lastDerivedOlderMessagesRevision = -1;
  int _sortOverrideRevision = 0;
  int _lastDerivedSortOverrideRevision = -1;
  bool _isLoadingOlder = false;
  bool _hasMoreMessages = true;
  bool _olderLoadArmed = true;
  bool _automaticOlderLoadBlocked = false;
  bool _olderLoadBlockedByError = false;
  // Set when the auto-pagination block was decided while the ignore list
  // was still unknown (first load with no snapshot): "no visible messages"
  // computed without the filter must not block the room forever. The build
  // clears it once the list arrives (see _rebuildDerivedMessages / the
  // ignored-list watch).
  bool _olderLoadBlockedWithUnknownList = false;
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
  final Set<String> _lateralInsertionAnimationIds = {};
  int _messageJumpGeneration = 0;
  int _pinnedStackVisibleCount = 0;

  /// Measured height of the floating top bar (SafeArea + panel included).
  /// Null until the first layout; [build] falls back to the design estimate
  /// [_headerChromeHeight] before that.
  double? _measuredHeaderHeight;

  /// True while the timeline shows a detached history slice loaded by
  /// [_loadMessageContext] instead of the live window. The slice does not
  /// connect to the live window (pagination only walks backwards, so the gap
  /// between them could never be filled), therefore the live window stays
  /// hidden until [_exitFocusedBrowsing] runs.
  bool _focusedBrowsing = false;
  bool _initialMessageJumpPending = false;
  bool _searchRouteOpen = false;

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
  // Floating glass header: 12pt gap above a ~54pt panel (38pt row + v8
  // padding), then an 8pt gap before the pinned stack / timeline clearance.
  // The panel height is measured at runtime (CJK text metrics can exceed the
  // estimate); these constants are only the first-frame fallback.
  static const double _headerTopGap = 12.0;
  static const double _headerPanelHeight = 54.0;
  static const double _headerBottomGap = 8.0;
  static const double _headerChromeHeight =
      _headerTopGap + _headerPanelHeight + _headerBottomGap;
  static const double _headerCompactBreakpoint = 480.0;
  static const double _pinnedStackFadeHeight = 40.0;
  static const int _maxMessagesPerRenderGroup = 12;
  static const Duration _sentNoticeDuration = Duration(milliseconds: 2800);
  static const Duration _forwardNoticeDuration = Duration(seconds: 4);
  static const Duration _insertionAnimationLifetime = Duration(
    milliseconds: 500,
  );
  static const Duration _sendFlightBurstSuppression = Duration(
    milliseconds: 450,
  );
  DateTime _sendFlightSuppressedUntil = DateTime.fromMillisecondsSinceEpoch(0);

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
    widget.onRegisterRoomDetailsHandler?.call(_handleRoomDetailsChanged);
    WidgetsBinding.instance.addObserver(this);
    _roomName = widget.roomName;
    _avatarUrl = widget.avatarUrl;
    _nameEventId = widget.nameEventId;
    _avatarEventId = widget.avatarEventId;
    _currentRoomIdNotifier = ref.read(currentRoomIdProvider.notifier);
    if (widget.initialMessageId != null) {
      _initialMessageJumpPending = true;
    }
    final roomAccountKey = activeRoomAccountKey(ref, widget.roomId);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(replyingToProvider(roomAccountKey).notifier).value = null;
      _activateRoom(resetAutoReadSuppression: true);
      if (widget.initialMessageId case final messageId?) {
        unawaited(_jumpToInitialMessage(messageId));
      }
    });
    // Switching away clears the Rust-side room/typing subscriptions; coming
    // back to the original account must re-subscribe (and re-mark the room
    // as being viewed under the right account). `_activateRoom`'s
    // `_setSubscriptionsDesired` early-returns when the desired flag already
    // matches, so reset it first. Switching to another account (defense in
    // depth: navigation usually already deactivates) drops the view
    // ownership so no auto-read or subscription runs under the new account.
    ref.listenManual(activeUserIdProvider, (_, next) {
      if (!mounted) return;
      if (_subscriptionsAccount == null && next != null) {
        // Opened before login completed: adopt the first account and
        // activate under it (same as the management/pinned pages), instead
        // of misreading it as a switch-away and tearing down forever.
        // `_activateRoom`'s `_setSubscriptionsDesired` early-returns when
        // the desired flag already matches, so reset it first — a pre-login
        // postFrame activation may have registered subscriptions against
        // the pending (account-less) client, and they must be rebuilt under
        // the real account (same discipline as the switch-back branch).
        if (_subscriptionsDesired) {
          _setSubscriptionsDesired(false);
        }
        _subscriptionsAccount = next;
        _activateRoom(resetAutoReadSuppression: true);
      } else if (next == _subscriptionsAccount) {
        // Back on the original account: re-subscribe and re-mark the room
        // as being viewed. `_activateRoom`'s `_setSubscriptionsDesired`
        // early-returns when the desired flag already matches, so reset it
        // first — through the real unsubscribe path so the old subscription
        // ids are torn down, not by clobbering the flag.
        if (_subscriptionsDesired) {
          _setSubscriptionsDesired(false);
        }
        _activateRoom(resetAutoReadSuppression: true);
      } else if (next != null) {
        // Switched to another account: drop the view ownership so no
        // auto-read or subscription runs under the new account.
        _exitFocusedBrowsing(scrollToLatest: false);
        if (_currentRoomIdNotifier.value == widget.roomId) {
          _currentRoomIdNotifier.value = null;
          _setRoomViewOwner(null);
        }
        _setSubscriptionsDesired(false);
      } else {
        // Logged out entirely: same teardown as switching away.
        _exitFocusedBrowsing(scrollToLatest: false);
        if (_currentRoomIdNotifier.value == widget.roomId) {
          _currentRoomIdNotifier.value = null;
          _setRoomViewOwner(null);
        }
        _setSubscriptionsDesired(false);
      }
    });
  }

  @override
  void didUpdateWidget(covariant ChatDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.roomName != widget.roomName) {
      _roomName = widget.roomName;
    }
    if (oldWidget.avatarUrl != widget.avatarUrl) {
      _avatarUrl = widget.avatarUrl;
    }
    if (oldWidget.nameEventId != widget.nameEventId) {
      _nameEventId = widget.nameEventId;
    }
    if (oldWidget.avatarEventId != widget.avatarEventId) {
      _avatarEventId = widget.avatarEventId;
    }
  }

  void _handleRoomDetailsChanged(RoomMetadataPatch patch) {
    if (!mounted || patch.roomId != widget.roomId) return;
    setState(() {
      switch (patch) {
        case RoomNamePatch():
          _roomNameEdit.record(
            currentEventId: _nameEventId,
            nextEventId: patch.nameEventId,
          );
          _roomName = patch.name;
          _nameEventId = patch.nameEventId;
          break;
        case RoomAvatarPatch():
          _roomAvatarEdit.record(
            currentEventId: _avatarEventId,
            nextEventId: patch.avatarEventId,
          );
          _avatarUrl = patch.avatarUrl;
          _avatarEventId = patch.avatarEventId;
          break;
      }
    });
    widget.onRoomDetailsChanged?.call(patch);
  }

  void _applySyncedRoomMeta(
    ({
      String name,
      String? avatarUrl,
      String? nameEventId,
      String? avatarEventId,
    })?
    meta,
  ) {
    if (meta == null) return;
    if (_roomNameEdit.shouldAccept(meta.nameEventId)) {
      _roomName = meta.name;
      _nameEventId = meta.nameEventId;
    }
    if (_roomAvatarEdit.shouldAccept(meta.avatarEventId)) {
      _avatarUrl = meta.avatarUrl;
      _avatarEventId = meta.avatarEventId;
    }
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
      if (mounted && (_route?.isCurrent ?? false)) {
        if (_viewSuspended) {
          _resumeSuspendedRoom();
        } else {
          _activateRoom();
        }
      }
    });
  }

  @override
  void didPushNext() {
    if (chatRouteObserver.isCoveredByPopup(_route)) {
      _suspendRoomView();
    } else {
      // A full page replaces this chat, so tear down its room subscriptions.
      _deactivateRoom();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (mounted) {
          if (_viewSuspended) {
            _resumeSuspendedRoom();
          } else if (_currentRoomIdNotifier.value != widget.roomId) {
            _activateRoom();
          }
        }
      case AppLifecycleState.inactive:
        // Transient focus loss (notification shade, system prompt) pauses
        // read ownership without rebuilding the room subscriptions.
        _suspendRoomView();
      case AppLifecycleState.paused ||
          AppLifecycleState.hidden ||
          AppLifecycleState.detached:
        // While the app is not visible the room must not be treated as
        // "being viewed": background sync would otherwise mark incoming
        // messages as read.
        _deactivateRoom();
    }
  }

  void _suspendRoomView() {
    if (_currentRoomIdNotifier.value != widget.roomId) return;
    _setRoomViewOwner(null);
    _viewSuspended = true;
  }

  void _setRoomViewOwner(String? accountUserId) {
    final state = ref.read(roomViewOwnerProvider(widget.roomId).notifier);
    state.value = accountUserId;
    _roomViewOwnerStateForDispose = state;
  }

  void _resumeSuspendedRoom() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    if (!(_route?.isCurrent ?? ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    final activeAccount = ref.read(activeUserIdProvider);
    if (_subscriptionsAccount != null &&
        activeAccount != _subscriptionsAccount) {
      return;
    }
    _viewSuspended = false;
    _activationId = ++_activationCounter;
    _setRoomViewOwner(activeAccount);
    if (!ref.read(roomAutoReadSuppressedProvider(widget.roomId))) {
      unawaited(_markRoomReadAndRefreshList());
    }
  }

  void _deactivateRoom() {
    _viewSuspended = false;
    if (_currentRoomIdNotifier.value == widget.roomId) {
      _currentRoomIdNotifier.value = null;
      _setRoomViewOwner(null);
    }
    _setSubscriptionsDesired(false);
  }

  void _activateRoom({bool resetAutoReadSuppression = false}) {
    // Never activate unless the app itself is in the foreground: a route
    // callback (e.g. a cover popped while inactive/paused) must not make the
    // room "being viewed" again in the background. A null lifecycle state
    // means no event has been delivered yet (app start, tests); the first
    // real transition will re-evaluate activation either way.
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    if (!(_route?.isCurrent ?? ModalRoute.of(context)?.isCurrent ?? false)) {
      return;
    }
    // The page belongs to the account it was first subscribed under (or the
    // one it switched back to). Reactivation after an account switch (route
    // pop, app resume) must not activate — and advance receipts — under a
    // different account: the switch-away listener already tore down the
    // ownership, and only the switch-back listener may re-activate.
    final activeAccount = ref.read(activeUserIdProvider);
    if (_subscriptionsAccount != null &&
        activeAccount != _subscriptionsAccount) {
      return;
    }
    _currentRoomIdNotifier.value = widget.roomId;
    _viewSuspended = false;
    _activationId = ++_activationCounter;
    _setRoomViewOwner(activeAccount);
    if (resetAutoReadSuppression) {
      setRoomAutoReadSuppressed(ref, widget.roomId, suppressed: false);
    }
    _setSubscriptionsDesired(true);
    unawaited(_primeAndRefreshMessages());
  }

  void _setSubscriptionsDesired(bool desired) {
    if (_subscriptionsDesired == desired) return;
    _subscriptionsDesired = desired;
    final roomId = widget.roomId;
    final accountUserId = desired ? ref.read(activeUserIdProvider) : null;
    // Only record the account when subscribing: on teardown the account must
    // stay at the last opened one so a switch-back listener can detect it.
    if (desired) {
      _subscriptionsAccount = accountUserId;
    }
    _subscriptionLifecycle = _subscriptionLifecycle.then((_) async {
      await Future.wait([
        _updateTypingSubscription(
          roomId,
          accountUserId: accountUserId,
          subscribe: desired,
        ),
        _updateRoomSubscription(
          roomId,
          accountUserId: accountUserId,
          subscribe: desired,
        ),
      ]);
    });
    unawaited(_subscriptionLifecycle);
  }

  Future<void> _updateTypingSubscription(
    String roomId, {
    required String? accountUserId,
    required bool subscribe,
  }) async {
    try {
      if (subscribe) {
        _typingSubscriptionId = await subscribeTypingForRoom(
          roomId: roomId,
          accountUserId: accountUserId,
        );
      } else {
        final subscriptionId = _typingSubscriptionId;
        _typingSubscriptionId = null;
        if (subscriptionId != null) {
          await unsubscribeTyping(
            roomId: roomId,
            subscriptionId: subscriptionId,
            accountUserId: _subscriptionsAccount,
          );
        }
      }
    } catch (error) {
      debugPrint(
        '${subscribe ? 'subscribe' : 'unsubscribe'}Typing failed: $error',
      );
    }
  }

  Future<void> _updateRoomSubscription(
    String roomId, {
    required String? accountUserId,
    required bool subscribe,
  }) async {
    try {
      if (subscribe) {
        _roomSubscriptionId = await subscribeRoomForReceipts(
          roomId: roomId,
          accountUserId: accountUserId,
        );
      } else {
        final subscriptionId = _roomSubscriptionId;
        _roomSubscriptionId = null;
        if (subscriptionId != null) {
          await unsubscribeRoomForReceipts(
            roomId: roomId,
            subscriptionId: subscriptionId,
            accountUserId: _subscriptionsAccount,
          );
        }
      }
    } catch (error) {
      debugPrint(
        '${subscribe ? 'subscribe' : 'unsubscribe'}RoomForReceipts failed: '
        '$error',
      );
    }
  }

  Future<void> _primeAndRefreshMessages() async {
    await primeMessageCache(ref, widget.roomId);
    if (!mounted || _currentRoomIdNotifier.value != widget.roomId) return;
    // Fire the read marker without blocking the timeline: awaiting it first
    // delays message rendering on a slow network, and awaiting the refresh
    // first would leave the room marked unread for the whole refresh
    // duration (and permanently, if the user leaves mid-refresh).
    if (!ref.read(roomAutoReadSuppressedProvider(widget.roomId))) {
      unawaited(_markRoomReadAndRefreshList());
    }
    await refreshMessagesFromNetwork(ref, widget.roomId);
  }

  Future<void> _markRoomReadAndRefreshList() async {
    // The receipts are written for the account that starts this call:
    // capture it before the await, and require the room's current viewer to
    // be that same account — both before sending (a switch between
    // activation and the call must not advance receipts for an account the
    // user is not looking at) and after (the local unread bookkeeping must
    // not apply to a different account that took over the room meanwhile).
    final startAccount = ref.read(activeUserIdProvider);
    // No account yet (deep-link before login completed): skip — a write
    // with an empty account id would be rejected by the Rust guard anyway
    // (same guard as clearViewedMarkedUnread / the flush path).
    if (startAccount == null) return;
    if (ref.read(roomViewOwnerProvider(widget.roomId)) != startAccount) {
      return;
    }
    try {
      final cleared = await markRoomAsRead(
        accountUserId: startAccount,
        roomId: widget.roomId,
        // Opening the room clears a marked-unread flag via the store-checked
        // inner path (and our own pending override) — not the unconditional
        // explicit write, which is reserved for the explicit "标记为已读"
        // actions to avoid a per-open account-data write.
        explicit: false,
      );
      if (!mounted ||
          _currentRoomIdNotifier.value != widget.roomId ||
          ref.read(roomViewOwnerProvider(widget.roomId)) != startAccount ||
          ref.read(roomAutoReadSuppressedProvider(widget.roomId))) {
        return;
      }
      // Only claim the room is read when the flag was actually cleared (a
      // skipped clear's tail may still fail).
      if (cleared) {
        setRoomUnreadOverrideById(ref, widget.roomId, unread: false);
      }
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spaceChildrenProvider);
      ref.invalidate(searchRoomsProvider);
    } catch (error) {
      debugPrint('markRoomAsRead failed: $error');
    }
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
    WidgetsBinding.instance.removeObserver(this);
    chatRouteObserver.unsubscribe(this);
    final currentRoomIdNotifier = _currentRoomIdNotifier;
    final roomId = widget.roomId;
    final roomViewOwnerState = _roomViewOwnerStateForDispose;
    // Riverpod forbids touching providers during dispose; defer both the
    // active-room and the view-owner clears to a microtask (the same batch
    // the sync stream observes, so an auto-read cannot slip in between).
    Future.microtask(() {
      if (currentRoomIdNotifier.mounted &&
          _activationId == _activationCounter &&
          currentRoomIdNotifier.value == roomId) {
        _activationId = 0;
        currentRoomIdNotifier.value = null;
        // The cached notifier may already be released if its container was
        // torn down; guard before touching it.
        if (roomViewOwnerState case final state? when state.mounted) {
          state.value = null;
        }
      }
    });
    _setSubscriptionsDesired(false);
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
      // Re-arm the auto-load when the user scrolls away from the older
      // edge — but do NOT clear the automatic-load block: an all-ignored
      // page set it to stop auto-paginating through ignored history, and
      // scrolling away must not let each return to the top pull another
      // page. The manual retry entry and the ignore-list arrival re-arm
      // it instead.
      _olderLoadArmed = true;
      if (_olderLoadBlockedByError) {
        _olderLoadBlockedByError = false;
        _automaticOlderLoadBlocked = false;
      }
    }

    if (_olderLoadArmed &&
        !_automaticOlderLoadBlocked &&
        !_isLoadingOlder &&
        _hasMoreMessages &&
        _paginationAnchorId() != null &&
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

  void _mentionUser(String userId) {
    _messageInputKey.currentState?.insertMention(userId);
    _setInputPanelMode(InputPanelMode.keyboard);
  }

  int? _timelineEntryIndexForMessage(String messageId) {
    for (var index = 0; index < _timelineEntries.length; index++) {
      if (_timelineEntries[index].group?.messages.any(
            (message) => message.id == messageId,
          ) ??
          false) {
        return index;
      }
    }
    return null;
  }

  List<int> _builtMessageEntryIndices() {
    final indices = <int>[];
    for (var index = 0; index < _timelineEntries.length; index++) {
      final group = _timelineEntries[index].group;
      if (group == null) continue;
      if (group.messages.any(
        (message) => _messageAnchorKeys[message.id]?.currentContext != null,
      )) {
        indices.add(index);
      }
    }
    return indices;
  }

  Future<bool> _loadMessageContext(String messageId, int generation) async {
    final contextMessages = await getMessagesAround(
      roomId: widget.roomId,
      eventId: messageId,
      limit: 60,
    );
    if (!contextMessages.any((message) => message.id == messageId)) {
      return false;
    }
    if (!mounted || generation != _messageJumpGeneration) return false;
    final knownIds = {
      ..._displayedMessages.map((message) => message.id),
      ..._olderMessages.map((message) => message.id),
      ...ref
          .read(messageCacheProvider(widget.roomId))
          .map((message) => message.id),
    };
    final connected = contextMessages.any(
      (message) => knownIds.contains(message.id),
    );
    if (connected) {
      final additions = contextMessages
          .where((message) => !knownIds.contains(message.id))
          .toList();
      if (additions.isNotEmpty) {
        setState(() {
          _olderMessages.addAll(additions);
          _olderMessages.sort(compareChatMessages);
          _olderMessagesRevision++;
        });
        await WidgetsBinding.instance.endOfFrame;
      }
    } else {
      // The slice does not touch the loaded window. Merging it in would leave
      // a permanent gap between the slice and the live messages (pagination
      // only walks backwards), so detach into a focused history view: the
      // live window stays hidden until _exitFocusedBrowsing.
      setState(() {
        _focusedBrowsing = true;
        _olderMessages
          ..clear()
          ..addAll(contextMessages);
        _olderMessages.sort(compareChatMessages);
        _olderMessagesRevision++;
        // The pagination anchor moves to the slice's oldest message; blocks
        // decided against the old window do not apply to it.
        _hasMoreMessages = true;
        _automaticOlderLoadBlocked = false;
        _olderLoadBlockedByError = false;
        _olderLoadArmed = true;
      });
      await WidgetsBinding.instance.endOfFrame;
    }
    return mounted && generation == _messageJumpGeneration;
  }

  void _exitFocusedBrowsing({
    bool scrollToLatest = true,
    bool cancelPendingJump = true,
  }) {
    if (cancelPendingJump) _messageJumpGeneration++;
    if (!_focusedBrowsing) return;
    setState(() {
      _focusedBrowsing = false;
      // Drop the detached slice so the merged timeline is the pure live
      // window again — keeping it would re-expose the gap below the slice.
      _olderMessages.clear();
      _olderMessagesRevision++;
      _automaticOlderLoadBlocked = false;
      _olderLoadBlockedByError = false;
    });
    if (scrollToLatest) _scrollToLatest();
  }

  Future<void> _jumpToMessage(String messageId) async {
    final generation = ++_messageJumpGeneration;
    try {
      if (!_messageIndex.containsKey(messageId)) {
        if (_focusedBrowsing &&
            ref
                .read(messageCacheProvider(widget.roomId))
                .any((message) => message.id == messageId)) {
          // The target lives in the live window that focused browsing hides:
          // return to the live timeline instead of detaching again.
          _exitFocusedBrowsing(scrollToLatest: false, cancelPendingJump: false);
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted || generation != _messageJumpGeneration) return;
        }
        if (!_messageIndex.containsKey(messageId)) {
          final loaded = await _loadMessageContext(messageId, generation);
          if (!loaded || !mounted || generation != _messageJumpGeneration) {
            return;
          }
        }
      }
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted || generation != _messageJumpGeneration) return;
      final targetIndex = _timelineEntryIndexForMessage(messageId);
      if (targetIndex == null || !_scrollController.hasClients) {
        throw StateError('目标消息不可用或已被删除');
      }

      BuildContext? targetContext =
          _messageAnchorKeys[messageId]?.currentContext;
      if (targetContext == null) {
        final position = _scrollController.position;
        final denominator = math.max(1, _timelineEntries.length - 1);
        final estimatedOffset =
            position.maxScrollExtent * targetIndex / denominator;
        _scrollController.jumpTo(
          estimatedOffset.clamp(
            position.minScrollExtent,
            position.maxScrollExtent,
          ),
        );
        var previousOffset = double.nan;
        var previousMaxExtent = double.nan;
        for (var attempt = 0; attempt < 24; attempt++) {
          await WidgetsBinding.instance.endOfFrame;
          if (!mounted || generation != _messageJumpGeneration) return;
          targetContext = _messageAnchorKeys[messageId]?.currentContext;
          if (targetContext != null) break;
          final builtIndices = _builtMessageEntryIndices();
          if (builtIndices.isEmpty) continue;
          final firstBuilt = builtIndices.first;
          final lastBuilt = builtIndices.last;
          final direction = targetIndex < firstBuilt
              ? -1.0
              : targetIndex > lastBuilt
              ? 1.0
              : 0.0;
          // The target's group is built but its row is not laid out yet —
          // give the next frame a chance instead of failing immediately.
          if (direction == 0) continue;
          final offset = _scrollController.offset;
          // Stuck at a scroll edge with no extent growth: further jumps move
          // nothing, so stop instead of burning the remaining attempts.
          if (offset == previousOffset &&
              position.maxScrollExtent == previousMaxExtent) {
            break;
          }
          previousOffset = offset;
          previousMaxExtent = position.maxScrollExtent;
          final distance = direction < 0
              ? firstBuilt - targetIndex
              : targetIndex - lastBuilt;
          final builtSpan = math.max(1, lastBuilt - firstBuilt + 1);
          final viewportSteps = (distance / builtSpan).clamp(0.75, 4.0);
          final nextOffset =
              offset + direction * position.viewportDimension * viewportSteps;
          _scrollController.jumpTo(
            nextOffset.clamp(
              position.minScrollExtent,
              position.maxScrollExtent,
            ),
          );
        }
      }
      if (targetContext == null) {
        throw StateError('无法定位目标消息');
      }
      if (!targetContext.mounted) {
        throw StateError('目标消息已离开时间线');
      }
      await Scrollable.ensureVisible(
        targetContext,
        alignment: 0.5,
        duration: const Duration(milliseconds: 260),
        curve: Curves.easeOutCubic,
      );
      if (!mounted || generation != _messageJumpGeneration) return;
      HapticFeedback.selectionClick();
      if (_focusedBrowsing) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('正在浏览历史消息，点右下角按钮回到最新'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (error) {
      if (!mounted || generation != _messageJumpGeneration) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('无法跳转到该消息: $error')));
    }
  }

  Future<void> _jumpToInitialMessage(String messageId) async {
    try {
      await _jumpToMessage(messageId);
    } finally {
      if (mounted) {
        if (_focusedBrowsing && !_messageIndex.containsKey(messageId)) {
          _exitFocusedBrowsing(scrollToLatest: false, cancelPendingJump: false);
        }
        setState(() => _initialMessageJumpPending = false);
      }
    }
  }

  Future<void> _openMessageSearch() async {
    if (_searchRouteOpen) return;
    _searchRouteOpen = true;
    try {
      final messageId = await Navigator.of(context).push<String>(
        MaterialPageRoute(
          builder: (_) => ChatSearchPage(roomId: widget.roomId),
        ),
      );
      if (messageId != null && mounted) {
        await _jumpToMessage(messageId);
      }
    } finally {
      _searchRouteOpen = false;
    }
  }

  Future<void> _openPinnedMessages() async {
    final messageId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PinnedMessagesPage(roomId: widget.roomId),
      ),
    );
    if (messageId != null && mounted) {
      await _jumpToMessage(messageId);
    }
  }

  /// Narrow header: the pinned/details actions collapse into this sheet.
  void _showMoreActions() {
    showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NeuSheetItem(
              icon: Icons.push_pin_outlined,
              label: '置顶消息',
              onTap: () {
                Navigator.of(sheetContext).pop();
                unawaited(_openPinnedMessages());
              },
            ),
            if (!widget.embedded) ...[
              const NeuSheetDivider(),
              NeuSheetItem(
                icon: Icons.info_outline_rounded,
                label: '房间详情',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _showRoomDetails(context);
                },
              ),
            ],
          ],
        ),
      ),
    );
  }

  MessageSendPresentation _resolveSendPresentation() {
    final presentation = !_scrollController.hasClients
        ? MessageSendPresentation.flight
        : resolveMessageSendPresentation(
            distanceFromLatest: _distanceFromLatest(_scrollController.position),
            viewportDimension: _scrollController.position.viewportDimension,
          );
    if (presentation == MessageSendPresentation.quiet) return presentation;

    final now = DateTime.now();
    if (hasOngoingSendFlight) {
      _sendFlightSuppressedUntil = now.add(_sendFlightBurstSuppression);
      cancelOngoingSendFlights();
      return MessageSendPresentation.insert;
    }
    if (presentation == MessageSendPresentation.flight &&
        now.isBefore(_sendFlightSuppressedUntil)) {
      _sendFlightSuppressedUntil = now.add(_sendFlightBurstSuppression);
      return MessageSendPresentation.insert;
    }
    return presentation;
  }

  void _handleMessageQueued(
    String stableMessageId,
    MessageSendPresentation presentation,
  ) {
    // A send commits to the live timeline: leave focused history browsing so
    // the optimistic bubble and its echo are actually visible.
    _exitFocusedBrowsing();
    if (presentation == MessageSendPresentation.quiet) return;
    setState(() {
      _insertionAnimationIds.add(stableMessageId);
      if (presentation == MessageSendPresentation.insert) {
        _lateralInsertionAnimationIds.add(stableMessageId);
      }
    });
    Future<void>.delayed(_insertionAnimationLifetime, () {
      if (!mounted || !_insertionAnimationIds.contains(stableMessageId)) {
        return;
      }
      setState(() {
        _insertionAnimationIds.remove(stableMessageId);
        _lateralInsertionAnimationIds.remove(stableMessageId);
      });
    });
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
          nameEventId: room.nameEventId,
          avatarEventId: room.avatarEventId,
          isDm: room.roomType == 'dm',
          // Override-aware like the room list (the pushed page's header
          // recomputes live, but the snapshot must not claim "在线" for a
          // marked-unread target).
          subtitle: (() {
            final unreadOverride = ref.read(
              roomUnreadOverrideProvider(room.id),
            );
            final overrideApplies = unreadOverride?.appliesTo(room) ?? false;
            final hasUnread = overrideApplies
                ? unreadOverride!.unread
                : room.unreadCount > 0 || room.isMarkedUnread;
            return hasUnread
                ? (room.unreadCount > 0 ? '${room.unreadCount} 条未读消息' : '已标记未读')
                : '在线';
          })(),
        ),
      ),
    );
  }

  Future<void> _loadOlderMessages() async {
    if (_isLoadingOlder || !_hasMoreMessages) {
      return;
    }

    final fromEventId = _paginationAnchorId();
    if (fromEventId == null) return;
    final revisionAtStart = _olderMessagesRevision;
    final accountAtStart = ref.read(activeUserIdProvider);
    setState(() => _isLoadingOlder = true);
    try {
      final older = await getMessagesBefore(
        roomId: widget.roomId,
        fromEventId: fromEventId,
        limit: 100,
      );
      if (!mounted) return;
      if (_olderMessagesRevision != revisionAtStart ||
          ref.read(activeUserIdProvider) != accountAtStart) {
        // A jump entered/exited focused browsing mid-flight and replaced the
        // window: this page is relative to the old anchor and would not
        // connect to the new one. Drop it; the next trigger refetches.
        setState(() => _isLoadingOlder = false);
        return;
      }

      final knownIds = {
        ..._displayedMessages.map((message) => message.id),
        ..._olderMessages.map((message) => message.id),
      };
      final newMessages = older
          .where((message) => !knownIds.contains(message.id))
          .toList();
      // A page that yields no visible messages (every sender is ignored) must
      // not keep auto-paginating: in a room dominated by ignored senders this
      // would pull the whole history page by page. Manual retries still work.
      // While the ignore list is unknown (first load with no snapshot) the
      // filtering is undefined, so behave as if nothing is visible: the page
      // stops auto-pagination instead of racing ahead of the filter.
      final ignoredUserIds = ref.read(ignoredUserIdsProvider).value;
      final producedVisibleMessages =
          ignoredUserIds != null &&
          newMessages.any(
            (message) =>
                message.isMe || !ignoredUserIds.contains(message.senderId),
          );
      final namespace = ref.read(activeUserIdProvider) ?? 'anonymous';
      // The encryption check only decides whether the page may be persisted
      // to disk; a failure there must not discard an already-fetched page.
      var allowDiskCache = false;
      try {
        allowDiskCache = !await isRoomEncrypted(roomId: widget.roomId);
      } catch (_) {
        allowDiskCache = false;
      }
      if (!mounted) return;
      if (_olderMessagesRevision != revisionAtStart ||
          ref.read(activeUserIdProvider) != accountAtStart) {
        setState(() => _isLoadingOlder = false);
        return;
      }
      final currentCache = ref.read(messageCacheProvider(widget.roomId));
      // Pages fetched while focused-browsing are relative to the detached
      // slice, not the live window: persisting them into the live cache would
      // leave them stranded (with a gap up to the live edge) once the slice
      // is dropped on exit. Keep them local to _olderMessages instead.
      final mergedCache = _focusedBrowsing
          ? currentCache
          : mergeMessageSnapshotAdditions(currentCache, older);
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
        // Stop automatic back-pagination once a page yields nothing visible;
        // an empty timeline then shows the manual retry affordance instead of
        // looping through the whole room history.
        _olderLoadBlockedByError = false;
        _automaticOlderLoadBlocked = !producedVisibleMessages;
        // A decision made without the filter (ignore list still unknown)
        // must not stick: remember it so the build re-arms auto-pagination
        // once the list arrives.
        _olderLoadBlockedWithUnknownList =
            ignoredUserIds == null && _automaticOlderLoadBlocked;
        // A page whose messages are ALL already known (the bounded
        // anchor-fallback page can sit entirely within the caller's loaded
        // set) makes no progress: end history loading instead of looping
        // on the same page forever. (A page that yields new but invisible
        // messages — every sender ignored — still counts as progress: the
        // anchor advances and manual retries keep working.)
        _hasMoreMessages = older.isNotEmpty && newMessages.isNotEmpty;
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
      setState(() {
        _isLoadingOlder = false;
        _olderLoadArmed = false;
        _olderLoadBlockedByError = true;
        _automaticOlderLoadBlocked = true;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('加载更早消息失败: $error')));
    }
  }

  void _retryOlderMessages() {
    setState(() {
      _olderLoadBlockedByError = false;
      _automaticOlderLoadBlocked = false;
      _olderLoadArmed = true;
    });
    unawaited(_loadOlderMessages());
  }

  String? _paginationAnchorId() {
    if (_olderMessages.isNotEmpty) return _olderMessages.first.id;
    final cachedMessages = ref.read(messageCacheProvider(widget.roomId));
    if (cachedMessages.isNotEmpty) return cachedMessages.first.id;
    if (_displayedMessages.isNotEmpty) return _displayedMessages.first.id;
    return null;
  }

  List<ChatMessage> _mergeMessages(
    List<ChatMessage> latestMessages,
    Set<String> ignoredUserIds,
  ) {
    final byId = <String, ChatMessage>{
      for (final message in _olderMessages)
        if (message.isMe || !ignoredUserIds.contains(message.senderId))
          message.id: message,
      // Focused history browsing hides the live window: merging it back in
      // would show the unfillable gap between the slice and the live edge.
      if (!_focusedBrowsing)
        for (final message in latestMessages)
          if (message.isMe || !ignoredUserIds.contains(message.senderId))
            message.id: message,
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
    RoomAccountKey roomAccountKey,
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
          removeLocalOutgoingMessage(ref, roomAccountKey, id);
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
    RoomAccountKey roomAccountKey,
  ) {
    if (identical(latestMessages, _lastMessageMergeInput) &&
        identical(localMessages, _lastLocalMergeInput) &&
        roomAccountKey == _lastLocalRoomAccountKey) {
      return _lastTimelineMessages;
    }
    _lastMessageMergeInput = latestMessages;
    _lastLocalMergeInput = localMessages;
    _lastLocalRoomAccountKey = roomAccountKey;
    _lastTimelineMessages = _mergeLocalOutgoingMessages(
      latestMessages,
      localMessages,
      roomAccountKey,
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

  String _messagesFingerprint(
    List<ChatMessage> latestMessages,
    Set<String> ignoredUserIds,
  ) {
    final sortedIgnoredUserIds = ignoredUserIds.toList()..sort();
    final buffer = StringBuffer()
      ..write('older=')
      ..write(_olderMessages.length)
      ..write(';latest=')
      ..write(latestMessages.length)
      ..write(';focused=')
      ..write(_focusedBrowsing ? 1 : 0)
      ..write(';ignored=')
      ..writeAll(sortedIgnoredUserIds, ',');
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

  void _rebuildDerivedMessages(
    List<ChatMessage> latestMessages,
    Set<String> ignoredUserIds,
  ) {
    if (identical(_lastDerivedMessagesInput, latestMessages) &&
        _lastDerivedOlderMessagesRevision == _olderMessagesRevision &&
        _lastDerivedSortOverrideRevision == _sortOverrideRevision) {
      return;
    }
    final fingerprint = _messagesFingerprint(latestMessages, ignoredUserIds);
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
    final displayedMessages = _mergeMessages(latestMessages, ignoredUserIds);
    _displayedMessages = displayedMessages;
    _messageIndex
      ..clear()
      ..addEntries(
        displayedMessages.map((message) => MapEntry(message.id, message)),
      );
    final activeAnchorIds = <String>{};
    _messageAnchorKeys.clear();
    for (final message in displayedMessages) {
      final anchorId =
          messageSendFlightId(message.id, _remoteToLocalFlightId) ?? message.id;
      activeAnchorIds.add(anchorId);
      _messageAnchorKeys[message.id] = _stableMessageAnchorKeys.putIfAbsent(
        anchorId,
        GlobalKey.new,
      );
    }
    _stableMessageAnchorKeys.removeWhere(
      (anchorId, _) => !activeAnchorIds.contains(anchorId),
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
      // Keep the sliver element alive across optimistic reconciliation.
      final firstMessageId =
          messageSendFlightId(
            group.messages.first.id,
            _remoteToLocalFlightId,
          ) ??
          group.messages.first.id;
      final anchorId = '$dateKey:${group.senderId}:$firstMessageId';
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
          messageAnchorKeys: _messageAnchorKeys,
          remoteToLocalFlightId: _remoteToLocalFlightId,
          insertionAnimationIds: _insertionAnimationIds,
          lateralInsertionAnimationIds: _lateralInsertionAnimationIds,
          membersById: membersById,
          showAvatar: _needsStickyAvatar(group),
          compact: widget.isDm,
          senderAvatarUrl: avatarMap[group.senderId],
          scrollController: _scrollController,
          scrollViewportKey: _scrollViewportKey,
          stickyBottomInset: stickyBottomInset,
          onImageLoaded: null,
          onReplyRequested: () => _setInputPanelMode(InputPanelMode.keyboard),
          onMentionRequested: _mentionUser,
          onMessageJumpRequested: (messageId) =>
              unawaited(_jumpToMessage(messageId)),
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
    final ignoredUserIdsAsync = ref.watch(ignoredUserIdsProvider);
    // Re-arm auto-pagination once the ignore list becomes known: the block
    // may have been decided without the filter (see _rebuildDerivedMessages),
    // and no further page load will happen on its own to re-decide it.
    if (_olderLoadBlockedWithUnknownList &&
        _automaticOlderLoadBlocked &&
        _hasMoreMessages &&
        ignoredUserIdsAsync.value != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_scrollController.hasClients) return;
        setState(() {
          _olderLoadBlockedWithUnknownList = false;
          _automaticOlderLoadBlocked = false;
          // The blocked load consumed the armed flag; re-arm it so the
          // immediate _maybeLoadOlderMessages below actually loads (the
          // user is at the top, where the scroll handler would otherwise
          // never re-arm).
          _olderLoadArmed = true;
        });
        _maybeLoadOlderMessages(_scrollController.position);
      });
    }
    final membersAsync = ref.watch(roomMembersProvider(widget.roomId));
    // Follow server-side renames/avatar changes for this room. select() keeps
    // unrelated room list churn from rebuilding the timeline.
    final syncedRoom = ref.watch(
      chatRoomsProvider.select((roomsAsync) {
        final rooms = roomsAsync.value;
        if (rooms == null) return null;
        for (final room in rooms) {
          if (room.id == widget.roomId) return room;
        }
        return null;
      }),
    );
    _applySyncedRoomMeta(
      syncedRoom == null
          ? null
          : (
              name: syncedRoom.name,
              avatarUrl: syncedRoom.avatarUrl,
              nameEventId: syncedRoom.nameEventId,
              avatarEventId: syncedRoom.avatarEventId,
            ),
    );
    // Match the room list's unread display (including the local override
    // for pending mark-read/unread writes) so the header subtitle and the
    // list's red dot never disagree during the echo window. syncedRoom can
    // be null while the room list is in its error state — the override
    // must not crash the page then.
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(widget.roomId));
    final overrideApplies = syncedRoom == null
        ? false
        : unreadOverride?.appliesTo(syncedRoom) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : (syncedRoom?.unreadCount ?? 0) > 0 ||
              (syncedRoom?.isMarkedUnread ?? false);
    final cachedTotalMembers = cachedMessages.fold<int>(
      0,
      (count, message) => math.max(count, message.totalMembers),
    );
    final totalMembers =
        membersAsync.asData?.value.length ?? cachedTotalMembers;
    ref.watch(typingStreamProvider);
    final roomAccountKey = activeRoomAccountKey(ref, widget.roomId);
    final localOutgoingMessages = ref.watch(
      localOutgoingMessagesProvider(roomAccountKey),
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
    final colors = context.neu;
    // The floating header hangs below the status bar; the pinned stack and
    // the timeline's oldest-end clearance are measured from its bottom edge.
    // Prefer the measured panel height (CJK title metrics can exceed the
    // estimate and would otherwise eat the gap above the pinned stack).
    final headerInset = _measuredHeaderHeight != null
        ? _measuredHeaderHeight! + _headerBottomGap
        : mediaQuery.padding.top + _headerChromeHeight;
    final inputChromeHeight =
        _inputChromeHeight ??
        _baseInputChromeHeight + mediaQuery.padding.bottom;
    final pickerMaxHeight = math.max(
      pickerBaseHeight,
      mediaQuery.size.height -
          mediaQuery.padding.top -
          mediaQuery.padding.bottom -
          _headerChromeHeight -
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
    final pinnedStackHeight =
        kPinnedMessageRowHeight * _pinnedStackVisibleCount;
    // With a visible pinned stack the timeline viewport starts below it;
    // otherwise it runs under the floating glass header (like the prototype)
    // and only clears the status-bar strip above the header's top gap.
    final timelineTopInset = _pinnedStackVisibleCount > 0
        ? headerInset + pinnedStackHeight
        : mediaQuery.padding.top + _headerTopGap;

    if (_keepPickerDuringKeyboardOpen &&
        keyboardHeight >= pickerFullHeight - 1) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_keepPickerDuringKeyboardOpen) return;
        setState(() => _keepPickerDuringKeyboardOpen = false);
      });
    }

    // Live unread state (override-aware, matching the room list), not the
    // push-time snapshot: the snapshot would stay stale (e.g. "3 条未读消息")
    // after the auto-read fired or the user marked the room read/unread.
    final headerSubtitle = syncedRoom == null
        ? widget.subtitle
        : hasUnread
        ? (syncedRoom.unreadCount > 0
              ? '${syncedRoom.unreadCount} 条未读消息'
              : '已标记未读')
        : '在线';

    return PopScope(
      canPop:
          !widget.embedded &&
          _inputPanelMode == InputPanelMode.none &&
          !keyboardVisible,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        SystemChannels.textInput.invokeMethod<void>('TextInput.hide');
        _setInputPanelMode(InputPanelMode.none);
      },
      child: Scaffold(
        resizeToAvoidBottomInset: false,
        backgroundColor: colors.base,
        body: Stack(
          children: [
            Positioned.fill(child: ColoredBox(color: colors.base)),
            Positioned.fill(
              top: timelineTopInset,
              child: Builder(
                builder: (context) {
                  final messages = messageCacheOwner == activeUserId
                      ? cachedMessages
                      : const <ChatMessage>[];
                  // The account switched while this page stayed mounted:
                  // the old account's messages must not render (the gate
                  // above) and the empty timeline must not mislead with its
                  // retry affordances — show a neutral placeholder instead
                  // (same discipline as the sibling pages).
                  if (messageCacheOwner != activeUserId &&
                      messageCacheOwner != null) {
                    return Center(
                      child: Text(
                        '账号已切换',
                        style: TextStyle(color: colors.textTertiary),
                      ),
                    );
                  }
                  final ignoredUserIds = ignoredUserIdsAsync.value;
                  // An unknown ignore list (first load, or a failed load
                  // without any snapshot) must not degrade into "nobody is
                  // ignored" and re-expose messages from ignored senders.
                  if (ignoredUserIds == null) {
                    if (ignoredUserIdsAsync.hasError) {
                      return Center(
                        child: TextButton.icon(
                          onPressed: () =>
                              ref.invalidate(ignoredUserIdsProvider),
                          icon: Icon(
                            Icons.refresh_rounded,
                            color: colors.accent,
                          ),
                          label: Text(
                            '无法加载忽略列表，消息已隐藏',
                            style: TextStyle(color: colors.textSecondary),
                          ),
                        ),
                      );
                    }
                    return Center(
                      child: CircularProgressIndicator(
                        color: colors.accent,
                        strokeWidth: 2,
                      ),
                    );
                  }
                  // Do not expose the timeline until its initial insets and
                  // member-dependent labels are stable enough for layout.
                  if ((!messageCachePrimed &&
                          messages.isEmpty &&
                          localOutgoingMessages.isEmpty) ||
                      _inputChromeHeight == null ||
                      (membersAsync.isLoading && !membersAsync.hasValue)) {
                    return Center(
                      child: CircularProgressIndicator(
                        color: colors.accent,
                        strokeWidth: 2,
                      ),
                    );
                  }
                  final visibleMessages = ignoredUserIds.isEmpty
                      ? messages
                      : messages
                            .where(
                              (message) =>
                                  message.isMe ||
                                  !ignoredUserIds.contains(message.senderId),
                            )
                            .toList();
                  final timelineMessages = _timelineMessagesFor(
                    visibleMessages,
                    localOutgoingMessages,
                    roomAccountKey,
                  );
                  _rebuildDerivedMessages(timelineMessages, ignoredUserIds);
                  if (_displayedMessages.isEmpty &&
                      !_initialMessageJumpPending &&
                      !_automaticOlderLoadBlocked &&
                      !_isLoadingOlder &&
                      _hasMoreMessages &&
                      _paginationAnchorId() != null) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) unawaited(_loadOlderMessages());
                    });
                  }
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
                  final timeline = TweenAnimationBuilder<double>(
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
                              if (_automaticOlderLoadBlocked &&
                                  _hasMoreMessages)
                                if (timelineEntries.isEmpty)
                                  SliverFillRemaining(
                                    hasScrollBody: false,
                                    child: Center(
                                      child: TextButton.icon(
                                        onPressed: _retryOlderMessages,
                                        icon: const Icon(Icons.refresh_rounded),
                                        label: const Text('重试加载更早消息'),
                                      ),
                                    ),
                                  )
                                else
                                  SliverToBoxAdapter(
                                    child: Center(
                                      child: TextButton.icon(
                                        onPressed: _retryOlderMessages,
                                        icon: const Icon(
                                          Icons.refresh_rounded,
                                          size: 16,
                                        ),
                                        label: const Text('加载更早消息'),
                                      ),
                                    ),
                                  ),
                              SliverPadding(
                                padding: EdgeInsets.only(
                                  // With no pinned stack the timeline runs
                                  // under the floating header; keep the
                                  // oldest end clear of the glass.
                                  top: _pinnedStackVisibleCount > 0
                                      ? 8
                                      : headerInset + 4,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    child: const SizedBox.shrink(),
                  );
                  if (!_initialMessageJumpPending) return timeline;
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: Opacity(opacity: 0, child: timeline),
                      ),
                      Center(
                        child: CircularProgressIndicator(
                          color: colors.accent,
                          strokeWidth: 2,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
            // Floating glass header — the only persistent glass layer.
            Positioned(
              left: 0,
              top: 0,
              right: 0,
              child: _MeasuredSize(
                onChanged: (size) {
                  if (_measuredHeaderHeight == size.height) return;
                  setState(() => _measuredHeaderHeight = size.height);
                },
                child: _buildTopBar(headerSubtitle),
              ),
            ),
            Positioned(
              left: 12,
              top: headerInset,
              right: 12,
              child: PinnedMessagesStack(
                roomId: widget.roomId,
                onMessageTap: (messageId) =>
                    unawaited(_jumpToMessage(messageId)),
                onVisibleCountChanged: (count) {
                  if (mounted && _pinnedStackVisibleCount != count) {
                    setState(() => _pinnedStackVisibleCount = count);
                  }
                },
              ),
            ),
            // Progressive blur below the pinned stack: the timeline viewport
            // starts right at its bottom edge, and a hard clip there reads
            // as the content being sliced off. Fade blur+background out over
            // a short strip so messages dissolve instead.
            if (_pinnedStackVisibleCount > 0)
              Positioned(
                left: 0,
                right: 0,
                top: headerInset + pinnedStackHeight,
                height: _pinnedStackFadeHeight,
                child: const _TimelineTopFade(),
              ),
            // Telegram-style floating date that tracks the day at the top edge
            // of the viewport while scrolling, then fades out.
            if (_hasTimelineGroups)
              FloatingDateHeader(
                scrollController: _scrollController,
                scrollViewportKey: _scrollViewportKey,
                boundaries: _floatingDateBoundariesCache,
                separatorKeys: _floatingDateSeparatorKeysCache,
                topInset: headerInset + pinnedStackHeight,
              ),
            AnimatedPositioned(
              right: 16,
              bottom: messageBottomPadding + 12,
              duration: const Duration(milliseconds: 180),
              curve: Curves.easeOutCubic,
              child: LatestMessageControl(
                visible:
                    !_initialMessageJumpPending &&
                    (_showLatestMessageControl || _focusedBrowsing) &&
                    _forwardNoticeRoom == null,
                showSentNotice: _showSentNotice,
                onPressed: _focusedBrowsing
                    ? () => _exitFocusedBrowsing()
                    : _scrollToLatest,
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
                    // The input panel belongs to the account the page was
                    // opened under. After a switch-away the timeline is
                    // cleared (messageCacheOwner mismatch) and subscriptions
                    // are torn down, but the panel itself would remain
                    // usable — typing or sending then would act as the new
                    // account. Hide it until the switch-back listener
                    // re-activates the page.
                    if (_subscriptionsAccount == null ||
                        activeUserId == _subscriptionsAccount)
                      MessageInput(
                        key: _messageInputKey,
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
                            _handlePickerHeightChanged(
                              height,
                              pickerBaseHeight,
                            ),
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

  /// Floating glass top bar: back/avatar/title plus the room actions. The
  /// only persistent glass layer on this page (see GlassPanel discipline).
  Widget _buildTopBar(String subtitle) {
    final colors = context.neu;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, _headerTopGap, 12, 0),
        child: GlassPanel(
          radius: NeuRadius.surface,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < _headerCompactBreakpoint;
              final hasDetailsToggle =
                  widget.embedded && widget.onToggleDetailsPanel != null;
              return Row(
                children: [
                  if (!widget.embedded) ...[
                    NeuIconButton(
                      icon: Icons.arrow_back_rounded,
                      size: 38,
                      tooltip: '返回',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                    const SizedBox(width: 4),
                  ],
                  AppAvatar(
                    fallback: _roomName,
                    size: 36,
                    radius: NeuRadius.content,
                    url: _avatarUrl,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _roomName,
                          style: Theme.of(context).textTheme.titleMedium,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          subtitle,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: colors.textTertiary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 4),
                  NeuIconButton(
                    icon: Icons.search_rounded,
                    size: 38,
                    tooltip: '搜索消息',
                    onPressed: () => unawaited(_openMessageSearch()),
                  ),
                  const SizedBox(width: 6),
                  if (compact) ...[
                    if (hasDetailsToggle) ...[
                      NeuIconButton(
                        icon: Icons.people_outline_rounded,
                        size: 38,
                        tooltip: widget.detailsPanelOpen ? '隐藏详情' : '显示详情',
                        selected: widget.detailsPanelOpen,
                        onPressed: widget.onToggleDetailsPanel,
                      ),
                      const SizedBox(width: 6),
                    ],
                    NeuIconButton(
                      icon: Icons.more_horiz_rounded,
                      size: 38,
                      tooltip: '更多',
                      onPressed: _showMoreActions,
                    ),
                  ] else ...[
                    NeuIconButton(
                      icon: Icons.push_pin_outlined,
                      size: 38,
                      tooltip: '置顶消息',
                      onPressed: () => unawaited(_openPinnedMessages()),
                    ),
                    const SizedBox(width: 6),
                    if (hasDetailsToggle)
                      NeuIconButton(
                        icon: Icons.people_outline_rounded,
                        size: 38,
                        tooltip: widget.detailsPanelOpen ? '隐藏详情' : '显示详情',
                        selected: widget.detailsPanelOpen,
                        onPressed: widget.onToggleDetailsPanel,
                      )
                    else
                      NeuIconButton(
                        icon: Icons.more_vert_rounded,
                        size: 38,
                        onPressed: () => _showRoomDetails(context),
                      ),
                  ],
                ],
              );
            },
          ),
        ),
      ),
    );
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
              color: context.neu.textTertiary.withValues(alpha: 0.6),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                color: context.neu.textTertiary,
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
    showNeuSheet<void>(
      context: context,
      child: Builder(
        builder: (sheetContext) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  AppAvatar(fallback: _roomName, size: 56, url: _avatarUrl),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _roomName,
                          style: Theme.of(context).textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          widget.roomId,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: context.neu.textTertiary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const NeuSheetDivider(),
            NeuSheetItem(
              icon: Icons.settings_rounded,
              label: '房间管理',
              onTap: () {
                Navigator.of(sheetContext).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => RoomManagementPage(
                      roomId: widget.roomId,
                      roomName: _roomName,
                      avatarUrl: _avatarUrl,
                      onRoomClosed: widget.onRoomLeft,
                      onRoomDetailsChanged: _handleRoomDetailsChanged,
                    ),
                  ),
                );
              },
            ),
            // Room members preview
            Consumer(
              builder: (context, ref, _) {
                final membersAsync = ref.watch(
                  roomMembersProvider(widget.roomId),
                );
                return membersAsync.when(
                  data: (members) {
                    return Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NeuSheetItem(
                          icon: Icons.people_rounded,
                          label: '成员 (${members.length})',
                          onTap: () {
                            Navigator.of(sheetContext).pop();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => RoomManagementPage(
                                  roomId: widget.roomId,
                                  roomName: _roomName,
                                  avatarUrl: _avatarUrl,
                                  onRoomClosed: widget.onRoomLeft,
                                  onRoomDetailsChanged:
                                      _handleRoomDetailsChanged,
                                ),
                              ),
                            );
                          },
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
                  loading: () => Padding(
                    padding: const EdgeInsets.all(16),
                    child: CircularProgressIndicator(
                      color: context.neu.accent,
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

/// Progressive blur strip directly below the pinned-message stack: strongest
/// (and closest to the background color) at the top, fully clear at the
/// bottom, so messages scrolled under the stack dissolve instead of being
/// clipped at a hard edge.
class _TimelineTopFade extends StatelessWidget {
  const _TimelineTopFade();

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return IgnorePointer(
      child: ClipRect(
        child: ShaderMask(
          blendMode: BlendMode.dstIn,
          shaderCallback: (rect) => const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.white, Colors.transparent],
          ).createShader(rect),
          child: BackdropFilter(
            filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
            child: ColoredBox(color: colors.base.withValues(alpha: 0.55)),
          ),
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
