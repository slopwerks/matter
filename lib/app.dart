import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'features/push/push_runtime.dart';
import 'pages/chat/chat_detail_page.dart';
import 'pages/chat/create_chat_page.dart';
import 'pages/chat/chat_page.dart';
import 'pages/chat/desktop_room_details_panel.dart';
import 'pages/chat/desktop_split_view.dart';
import 'pages/chat/room_metadata_patch.dart';
import 'pages/chat/room_state_edit_tracker.dart';
import 'pages/chat/space_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/settings/encryption_page.dart';
import 'pages/settings/settings_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/navigation_provider.dart';
import 'providers/startup_page_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'theme/neu_colors.dart';
import 'widgets/app_avatar.dart';
import 'widgets/glass.dart';
import 'widgets/material_tab_navigation_bar.dart';
import 'widgets/mobile_tab_view.dart';
import 'widgets/neu_action.dart';
import 'widgets/neu_surface.dart';
import 'widgets/max_content_width.dart';
import 'widgets/sheets.dart';

enum _DesktopRoomSource { allChats, directMessages, ungroupedRooms, space }

class MatterApp extends ConsumerStatefulWidget {
  const MatterApp({super.key});

  @override
  ConsumerState<MatterApp> createState() => _MatterAppState();
}

class _MatterAppState extends ConsumerState<MatterApp> {
  final _tabPosition = ValueNotifier(0.0);

  /// 0 at rest, 1 while a dock destination is pressed. Owned here because the
  /// platter that has to scale sits above the bar, in `DockSurface`.
  final _dockLift = ValueNotifier<double>(0);
  Timer? _verificationTimer;
  bool _checkingVerification = false;
  bool _verificationDialogOpen = false;
  final Set<String> _handledVerificationFlows = {};
  rust.ChatRoom? _selectedRoom;
  GlobalKey _selectedChatKey = GlobalKey();
  String? _selectedMessageId;
  bool _waitingForSelectedRoomSync = false;
  late final DesktopRoomNavigation _desktopRoomNavigation;
  rust.Space? _selectedDesktopSpace;
  _DesktopRoomSource _desktopRoomSource = _DesktopRoomSource.allChats;
  int _navigationRevision = 0;
  String? _startupAccount;
  bool _showRoomDetails = false;
  bool _usesDesktopLayout = false;
  String? _lastActiveUserId;
  final _selectedRoomNameEdit = RoomStateEditTracker();
  final _selectedRoomAvatarEdit = RoomStateEditTracker();

  /// The selected ChatDetailPage's room-details handler, registered via its
  /// `onRegisterRoomDetailsHandler` prop. Desktop details-panel edits are
  /// routed through it so they go through the page's sync-echo trackers.
  ValueChanged<RoomMetadataPatch>? _desktopRoomDetailsHandler;

  void _registerDesktopRoomDetailsHandler(
    ValueChanged<RoomMetadataPatch> handler,
  ) {
    _desktopRoomDetailsHandler = handler;
  }

  static const double _desktopBreakpoint = 960;
  static const double _desktopDetailsPaneBreakpoint = 1024;

  static const _pages = [
    ChatPage(),
    SpacePage(),
    ContactsPage(),
    SettingsPage(),
  ];

  @override
  void initState() {
    super.initState();
    _desktopRoomNavigation = ref.read(desktopRoomNavigationProvider)
      ..open = _openRoomInPane;
    _verificationTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => _checkIncomingVerification(),
    );
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _checkIncomingVerification(),
    );
  }

  @override
  void dispose() {
    _verificationTimer?.cancel();
    if (_desktopRoomNavigation.open == _openRoomInPane) {
      _desktopRoomNavigation.open = null;
    }
    _tabPosition.dispose();
    _dockLift.dispose();
    super.dispose();
  }

  Future<void> _checkIncomingVerification() async {
    if (_checkingVerification ||
        _verificationDialogOpen ||
        !mounted ||
        !ref.read(sessionReadyProvider)) {
      return;
    }

    _checkingVerification = true;
    try {
      final status = await rust.getDeviceVerificationStatus();
      if (!mounted ||
          status == null ||
          !status.incoming ||
          status.phase != 'requested' ||
          _handledVerificationFlows.contains(status.flowId)) {
        return;
      }
      _handledVerificationFlows.add(status.flowId);
      // Bound the handled-flow set on long-running sessions: flows are
      // one-shot, so only recent ones can possibly reappear.
      while (_handledVerificationFlows.length > 64) {
        _handledVerificationFlows.remove(_handledVerificationFlows.first);
      }
      await _showVerificationRequest(status);
    } catch (_) {
      // The active client can be temporarily unavailable during account changes.
    } finally {
      _checkingVerification = false;
    }
  }

  Future<void> _showVerificationRequest(
    rust.DeviceVerificationStatus status,
  ) async {
    _verificationDialogOpen = true;
    final accepted = await showNeuConfirm(
      context,
      title: '设备验证请求',
      message: '设备 ${status.deviceId} 正在请求验证当前设备。',
      confirmLabel: '接受',
    );
    _verificationDialogOpen = false;
    if (!mounted) return;

    try {
      if (accepted) {
        await rust.acceptDeviceVerification();
        if (!mounted) return;
        await Navigator.of(context)
            .push(MaterialPageRoute(builder: (_) => const EncryptionPage()));
      } else {
        await rust.cancelDeviceVerification(mismatch: false);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('处理设备验证失败：$error')));
    }
  }

  void _onItemTapped(int index) {
    _navigationRevision++;
    if (!_usesDesktopLayout && index == 0) {
      setState(() {
        _desktopRoomSource = _DesktopRoomSource.allChats;
        _selectedDesktopSpace = null;
      });
    }
    if (ref.read(navigationIndexProvider) != index) {
      ref.read(navigationIndexProvider.notifier).value = index;
    }
    _rememberPage();
  }

  void _rememberPage() {
    final userId = ref.read(activeUserIdProvider);
    if (userId == null) return;
    final index = ref.read(navigationIndexProvider);
    final page = switch (index) {
      1 => NavigationDestinationPage.spaces,
      2 => NavigationDestinationPage.contacts,
      3 => NavigationDestinationPage.settings,
      _ => switch (_desktopRoomSource) {
        _DesktopRoomSource.allChats => NavigationDestinationPage.allChats,
        _DesktopRoomSource.directMessages =>
          NavigationDestinationPage.directMessages,
        _DesktopRoomSource.ungroupedRooms =>
          NavigationDestinationPage.ungroupedRooms,
        _DesktopRoomSource.space => NavigationDestinationPage.space,
      },
    };
    unawaited(
      rememberNavigationPage(
        userId,
        StartupLocation(page, spaceId: _selectedDesktopSpace?.id),
      ),
    );
  }

  Future<void> _restoreStartupPage(String userId, int revision) async {
    var location = await loadStartupLocation(userId);
    if (!mounted ||
        ref.read(activeUserIdProvider) != userId ||
        revision != _navigationRevision) {
      return;
    }
    rust.Space? space;
    if (location.page == NavigationDestinationPage.space) {
      try {
        final spaces = await ref.read(spacesProvider.future);
        space = spaces.where((item) => item.id == location.spaceId).firstOrNull;
      } catch (_) {
        // A failed or stale saved space must not prevent opening conversations.
      }
      if (space == null) {
        location = const StartupLocation(NavigationDestinationPage.allChats);
      }
    }
    if (!mounted ||
        ref.read(activeUserIdProvider) != userId ||
        revision != _navigationRevision) {
      return;
    }
    final index = switch (location.page) {
      NavigationDestinationPage.spaces => 1,
      NavigationDestinationPage.contacts => 2,
      NavigationDestinationPage.settings => 3,
      _ => 0,
    };
    setState(() {
      _desktopRoomSource = switch (location.page) {
        NavigationDestinationPage.directMessages =>
          _DesktopRoomSource.directMessages,
        NavigationDestinationPage.ungroupedRooms =>
          _DesktopRoomSource.ungroupedRooms,
        NavigationDestinationPage.space => _DesktopRoomSource.space,
        _ => _DesktopRoomSource.allChats,
      };
      _selectedDesktopSpace = space;
      _tabPosition.value = index.toDouble();
    });
    ref.read(navigationIndexProvider.notifier).value = index;
  }

  void _clearSelectedRoomDetailsEdits() {
    _selectedRoomNameEdit.clear();
    _selectedRoomAvatarEdit.clear();
  }

  rust.ChatRoom _reconcileSelectedRoomDetails(
    rust.ChatRoom selectedRoom,
    rust.ChatRoom refreshedRoom,
  ) {
    final acceptName = _selectedRoomNameEdit.shouldAccept(
      refreshedRoom.nameEventId,
    );
    final acceptAvatar = _selectedRoomAvatarEdit.shouldAccept(
      refreshedRoom.avatarEventId,
    );
    if (acceptName && acceptAvatar) return refreshedRoom;
    return _roomWithDetails(
      refreshedRoom,
      name: acceptName ? refreshedRoom.name : selectedRoom.name,
      avatarUrl: acceptAvatar
          ? refreshedRoom.avatarUrl
          : selectedRoom.avatarUrl,
      nameEventId: acceptName
          ? refreshedRoom.nameEventId
          : selectedRoom.nameEventId,
      avatarEventId: acceptAvatar
          ? refreshedRoom.avatarEventId
          : selectedRoom.avatarEventId,
    );
  }

  bool _openRoomInPane(rust.ChatRoom room, {String? messageId}) {
    if (!mounted || !_usesDesktopLayout) {
      return false;
    }
    _navigationRevision++;
    ref.read(navigationIndexProvider.notifier).value = 0;
    _desktopRoomSource = room.roomType == 'dm'
        ? _DesktopRoomSource.directMessages
        : _DesktopRoomSource.ungroupedRooms;
    _selectedDesktopSpace = null;
    _selectRoom(room, messageId: messageId);
    // A newly created DM can arrive before its first sync snapshot.
    setState(() => _waitingForSelectedRoomSync = true);
    _rememberPage();
    final shellRoute = ModalRoute.of(context);
    Navigator.of(context).popUntil((route) => route == shellRoute);
    return true;
  }

  void _selectRoom(rust.ChatRoom room, {String? messageId}) {
    _navigationRevision++;
    if (room.roomType == 'space') {
      _showSpace(
        rust.Space(id: room.id, name: room.name, avatarUrl: room.avatarUrl),
      );
      return;
    }
    _waitingForSelectedRoomSync = false;
    if (_selectedRoom?.id == room.id) {
      if (_selectedMessageId != messageId) {
        setState(() => _selectedMessageId = messageId);
      }
      final selectedRoom = _selectedRoom!;
      final refreshedRoom = _reconcileSelectedRoomDetails(selectedRoom, room);
      if (selectedRoom != refreshedRoom) {
        setState(() => _selectedRoom = refreshedRoom);
      }
      final autoReadSuppressed = ref.read(
        roomAutoReadSuppressedProvider(room.id),
      );
      if (!autoReadSuppressed &&
          refreshedRoom.unreadCount == 0 &&
          !refreshedRoom.isMarkedUnread) {
        return;
      }
      if (autoReadSuppressed) {
        setRoomAutoReadSuppressed(ref, room.id, suppressed: false);
      }
      unawaited(_markSelectedRoomAsRead(refreshedRoom));
      return;
    }
    _clearSelectedRoomDetailsEdits();
    setState(() {
      _selectedChatKey = GlobalKey();
      _selectedMessageId = messageId;
      _selectedRoom = room;
    });
  }

  Future<void> _markSelectedRoomAsRead(rust.ChatRoom room) async {
    // The receipts are written for the account that starts this call.
    final accountUserId = ref.read(activeUserIdProvider);
    // No account yet (deep-link before login completed): skip — a write
    // with an empty account id would be rejected by the Rust guard anyway.
    if (accountUserId == null) return;
    try {
      final cleared = await markRoomAsReadWithPushCleanup(
        accountUserId: accountUserId,
        roomId: room.id,
        // Selecting the room is a viewing action: rely on the store-checked
        // inner clear, not the unconditional explicit write.
        explicit: false,
      );
      if (!mounted ||
          _selectedRoom?.id != room.id ||
          // The account may have switched mid-flight: the read bookkeeping
          // must not apply to the new account's session.
          ref.read(activeUserIdProvider) != accountUserId ||
          ref.read(roomAutoReadSuppressedProvider(room.id))) {
        return;
      }
      // Only claim the room is read when the flag was actually cleared (a
      // skipped clear's tail may still fail).
      if (cleared) {
        setRoomUnreadOverride(ref, room, unread: false);
      }
      ref.invalidate(allChatRoomsProvider);
      ref.invalidate(allUngroupedRoomsProvider);
      ref.invalidate(allSpaceChildrenProvider);
      ref.invalidate(searchRoomsProvider);
    } catch (error) {
      debugPrint('markRoomAsRead after room reselection failed: $error');
    }
  }

  void _updateSelectedRoomDetails(RoomMetadataPatch patch) {
    final room = _selectedRoom;
    if (room == null || room.id != patch.roomId) return;
    var name = room.name;
    var avatarUrl = room.avatarUrl;
    var nameEventId = room.nameEventId;
    var avatarEventId = room.avatarEventId;
    switch (patch) {
      case RoomNamePatch():
        _selectedRoomNameEdit.record(
          currentEventId: nameEventId,
          nextEventId: patch.nameEventId,
        );
        name = patch.name;
        nameEventId = patch.nameEventId;
        break;
      case RoomAvatarPatch():
        _selectedRoomAvatarEdit.record(
          currentEventId: avatarEventId,
          nextEventId: patch.avatarEventId,
        );
        avatarUrl = patch.avatarUrl;
        avatarEventId = patch.avatarEventId;
        break;
    }
    setState(() {
      _selectedRoom = _roomWithDetails(
        room,
        name: name,
        avatarUrl: avatarUrl,
        nameEventId: nameEventId,
        avatarEventId: avatarEventId,
      );
    });
  }

  rust.ChatRoom _roomWithDetails(
    rust.ChatRoom room, {
    required String name,
    required String? avatarUrl,
    required String? nameEventId,
    required String? avatarEventId,
  }) {
    return rust.ChatRoom(
      id: room.id,
      name: name,
      avatarUrl: avatarUrl,
      nameEventId: nameEventId,
      avatarEventId: avatarEventId,
      lastMessage: room.lastMessage,
      lastMessageSender: room.lastMessageSender,
      lastMessageTime: room.lastMessageTime,
      lastEventId: room.lastEventId,
      unreadCount: room.unreadCount,
      isMarkedUnread: room.isMarkedUnread,
      roomType: room.roomType,
      isEncrypted: room.isEncrypted,
      isMuted: room.isMuted,
      roomState: room.roomState,
    );
  }

  void _clearSelectedRoom() {
    setState(() {
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
      _showRoomDetails = false;
    });
  }

  void _showAllChats() {
    _navigationRevision++;
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.allChats;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
    _rememberPage();
  }

  void _showDirectMessages() {
    _navigationRevision++;
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.directMessages;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
    _rememberPage();
  }

  void _showUngroupedRooms() {
    _navigationRevision++;
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.ungroupedRooms;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
    _rememberPage();
  }

  void _showSpace(rust.Space space) {
    _navigationRevision++;
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.space;
      _selectedDesktopSpace = space;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
    _rememberPage();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the sync stream listener alive for the app's lifetime.
    // Without watch(), the provider auto-disposes and stops receiving events.
    ref.watch(syncStreamProvider);
    _syncDesktopSelectionAfterAccountChange(ref.watch(activeUserIdProvider));

    return LayoutBuilder(
      builder: (context, constraints) {
        final isDesktop = constraints.maxWidth >= _desktopBreakpoint;
        _usesDesktopLayout = isDesktop;
        if (isDesktop) {
          // Only the desktop layout keeps a selected room whose metadata
          // must follow the room sources; watching them on mobile would
          // rebuild the whole app on every room list refresh for nothing.
          if (_desktopRoomSource == _DesktopRoomSource.space) {
            final spaceId = _selectedDesktopSpace?.id;
            if (spaceId != null) {
              // Space children live in spaceChildrenProvider, not
              // chatRooms: follow that source so a renamed/departed space
              // child updates the panel snapshot.
              _syncSelectedRoomFromRooms(
                ref.watch(spaceChildrenProvider(spaceId)),
              );
            }
          } else {
            _syncSelectedRoomFromRooms(ref.watch(chatRoomsProvider));
          }
          return _buildDesktopLayout(context, constraints);
        }
        return _buildMobileLayout();
      },
    );
  }

  void _syncDesktopSelectionAfterAccountChange(String? activeUserId) {
    final previousUserId = _lastActiveUserId;
    _lastActiveUserId = activeUserId;
    if (_startupAccount != activeUserId) {
      _startupAccount = activeUserId;
      final revision = ++_navigationRevision;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && activeUserId != null) {
          unawaited(_restoreStartupPage(activeUserId, revision));
        }
      });
    }
    if (previousUserId == null || previousUserId == activeUserId) return;

    _selectedRoom = null;
    _selectedChatKey = GlobalKey();
    _clearSelectedRoomDetailsEdits();
    _selectedDesktopSpace = null;
    _desktopRoomSource = _DesktopRoomSource.allChats;
    _showRoomDetails = false;
  }

  void _syncSelectedRoomFromRooms(AsyncValue<List<rust.ChatRoom>> roomsAsync) {
    final selectedRoom = _selectedRoom;
    final rooms = roomsAsync.asData?.value;
    if (selectedRoom == null || rooms == null) return;

    rust.ChatRoom? refreshedRoom;
    for (final room in rooms) {
      if (room.id == selectedRoom.id) {
        refreshedRoom = room;
        break;
      }
    }
    if (refreshedRoom == null) {
      if (_waitingForSelectedRoomSync) return;
      // The selected room no longer exists (e.g. the user left it from the
      // management page while the desktop panel was open). Clear the stale
      // selection so the panel does not keep showing a departed room.
      if (_desktopRoomSource == _DesktopRoomSource.space) {
        // Space children live in spaceChildrenProvider, not chatRooms, so
        // their absence here is not necessarily a departure — but a room
        // removed from the space is gone from chatRooms as well: double-
        // check against the room list before clearing the selection. A
        // list that is still LOADING must not clear it — "unknown" is not
        // "departed" (the room may merely have been moved out of the
        // space, and the room list refetch races the children refetch).
        final allRooms = ref.read(chatRoomsProvider).asData?.value;
        if (allRooms == null) return;
        if (allRooms.any((room) => room.id == selectedRoom.id)) {
          return;
        }
      }
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
      return;
    }
    _waitingForSelectedRoomSync = false;
    _selectedRoom = _reconcileSelectedRoomDetails(selectedRoom, refreshedRoom);
  }

  /// Material 模式的底部导航:悬浮胶囊,不贴底满宽。
  ///
  /// 选中项的内容盘由 `MaterialTabNavigationBar` 自绘(随页面滑动插值),
  /// 外边距和模糊底只在这里加一层,所以两者位置天然对齐。
  Widget _buildMaterialDock(int navigationIndex) {
    final dock = MaterialTabNavigationBar(
      key: const ValueKey('material-dock'),
      position: _tabPosition,
      lift: _dockLift,
      selectedIndex: navigationIndex,
      onDestinationSelected: _onItemTapped,
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_bubble_outline),
          selectedIcon: Icon(Icons.chat_bubble),
          label: '聊天',
        ),
        NavigationDestination(
          icon: Icon(Icons.account_tree_outlined),
          selectedIcon: Icon(Icons.account_tree),
          label: '空间',
        ),
        NavigationDestination(
          icon: Icon(Icons.people_outline),
          selectedIcon: Icon(Icons.people),
          label: '通讯录',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: '设置',
        ),
      ],
    );
    return SafeArea(
      top: false,
      minimum: const EdgeInsets.fromLTRB(14, 8, 14, 10),
      child: DockSurface(radius: NeuRadius.nav, lift: _dockLift, child: dock),
    );
  }

  Widget _buildMobileLayout() {
    final navigationIndex = ref.watch(navigationIndexProvider);
    if (_selectedRoom != null && navigationIndex == 0) {
      return PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (!didPop) _clearSelectedRoom();
        },
        child: _buildSelectedChat(embedded: false),
      );
    }
    if (context.isMaterial) {
      return Scaffold(
        extendBody: true,
        body: MobileTabView(
          key: ValueKey(ref.watch(activeUserIdProvider)),
          index: navigationIndex,
          position: _tabPosition,
          onChanged: _onItemTapped,
          children: [
            _buildMobileChatList(showFloatingActionButton: false),
            const SpacePage(showFloatingActionButton: false),
            _pages[2],
            _pages[3],
          ],
        ),
        // Keep the FAB with the navigation bar and snack bars so Scaffold can
        // position it above both, including the system's bottom safe area.
        floatingActionButton: switch (navigationIndex) {
          0 => FloatingActionButton(
            key: const ValueKey('new-chat-action'),
            tooltip: '新聊天',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => const CreateChatPage()),
            ),
            child: const Icon(Icons.edit_outlined),
          ),
          1 => FloatingActionButton(
            tooltip: '添加空间',
            onPressed: () => SpacePage.showSpaceActions(context),
            child: const Icon(Icons.add),
          ),
          _ => null,
        },
        bottomNavigationBar: _buildMaterialDock(navigationIndex),
      );
    }
    return Scaffold(
      extendBody: true,
      body: MobileTabView(
        key: ValueKey(ref.watch(activeUserIdProvider)),
        index: navigationIndex,
        position: _tabPosition,
        onChanged: _onItemTapped,
        children: [_buildMobileChatList(), ..._pages.skip(1)],
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: GlassPanel(
          key: const ValueKey('mobile-dock'),
          radius: NeuRadius.nav,
          padding: const EdgeInsets.all(6),
          child: AnimatedBuilder(
            animation: _tabPosition,
            builder: (context, _) {
              final page = _tabPosition.value;
              return Stack(
                children: [
                  Positioned.fill(
                    child: IgnorePointer(
                      child: FractionallySizedBox(
                        widthFactor: 1 / _pages.length,
                        alignment: AlignmentDirectional(-1 + 2 * page / 3, 0),
                        child: const NeuSurface(
                          accent: true,
                          // Keep the pill concentric with the dock's padding.
                          radius: NeuRadius.nav - 6,
                          child: SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _NavItem(
                          icon: Icons.chat_bubble_outline_rounded,
                          activeIcon: Icons.chat_bubble_rounded,
                          label: '聊天',
                          isActive: navigationIndex == 0,
                          activation: (1 - page.abs()).clamp(0.0, 1.0),
                          onTap: () => _onItemTapped(0),
                        ),
                      ),
                      Expanded(
                        child: _NavItem(
                          icon: Icons.account_tree_outlined,
                          activeIcon: Icons.account_tree_rounded,
                          label: '空间',
                          isActive: navigationIndex == 1,
                          activation: (1 - (page - 1).abs()).clamp(0.0, 1.0),
                          onTap: () => _onItemTapped(1),
                        ),
                      ),
                      Expanded(
                        child: _NavItem(
                          icon: Icons.people_outline_rounded,
                          activeIcon: Icons.people_rounded,
                          label: '通讯录',
                          isActive: navigationIndex == 2,
                          activation: (1 - (page - 2).abs()).clamp(0.0, 1.0),
                          onTap: () => _onItemTapped(2),
                        ),
                      ),
                      Expanded(
                        child: _NavItem(
                          icon: Icons.settings_outlined,
                          activeIcon: Icons.settings_rounded,
                          label: '设置',
                          isActive: navigationIndex == 3,
                          activation: (1 - (page - 3).abs()).clamp(0.0, 1.0),
                          onTap: () => _onItemTapped(3),
                        ),
                      ),
                    ],
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context, BoxConstraints constraints) {
    final navigationIndex = ref.watch(navigationIndexProvider);
    final selectedRoom = _selectedRoom;
    final canShowRoomDetails =
        constraints.maxWidth >= _desktopDetailsPaneBreakpoint;
    final showRoomDetails =
        canShowRoomDetails &&
        _showRoomDetails &&
        navigationIndex == 0 &&
        selectedRoom != null;

    Widget withTabTransition(Widget child) {
      if (!context.isMaterial) return child;
      return AnimatedSwitcher(
        key: ValueKey(ref.watch(activeUserIdProvider)),
        duration: const Duration(milliseconds: 240),
        switchInCurve: Curves.easeOutCubic,
        switchOutCurve: Curves.easeInCubic,
        layoutBuilder: (currentChild, previousChildren) => Stack(
          fit: StackFit.expand,
          children: [
            for (final previous in previousChildren)
              IgnorePointer(
                child: ExcludeFocus(child: ExcludeSemantics(child: previous)),
              ),
            ?currentChild,
          ],
        ),
        child: KeyedSubtree(key: ValueKey(navigationIndex), child: child),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          _DesktopSidebar(
            navigationIndex: navigationIndex,
            roomSource: _desktopRoomSource,
            selectedSpaceId: _selectedDesktopSpace?.id,
            onAllChatsSelected: _showAllChats,
            onDirectMessagesSelected: _showDirectMessages,
            onUngroupedRoomsSelected: _showUngroupedRooms,
            onSpaceSelected: _showSpace,
            onNavigate: _onItemTapped,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: withTabTransition(
              navigationIndex == 0
                  ? DesktopSplitView(
                      roomList: _buildDesktopRoomList(),
                      chat: selectedRoom == null
                          ? const _DesktopEmptyChat()
                          : _buildSelectedChat(
                              embedded: true,
                              canShowRoomDetails: canShowRoomDetails,
                              showRoomDetails: showRoomDetails,
                            ),
                      details: showRoomDetails
                          ? DesktopRoomDetailsPanel(
                              roomId: selectedRoom.id,
                              roomName: selectedRoom.name,
                              avatarUrl: selectedRoom.avatarUrl,
                              onRoomLeft: _clearSelectedRoom,
                              onRoomDetailsChanged: (patch) =>
                                  _desktopRoomDetailsHandler?.call(patch),
                            )
                          : null,
                    )
                  : MaxContentWidth(child: _pages[navigationIndex]),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSelectedChat({
    required bool embedded,
    bool canShowRoomDetails = false,
    bool showRoomDetails = false,
  }) {
    final room = _selectedRoom!;
    final unreadOverride = ref.watch(roomUnreadOverrideProvider(room.id));
    final hasUnread = unreadOverride?.appliesTo(room) == true
        ? unreadOverride!.unread
        : room.unreadCount > 0 || room.isMarkedUnread;
    return ChatDetailPage(
      key: _selectedChatKey,
      roomId: room.id,
      roomName: room.name,
      avatarUrl: room.avatarUrl,
      nameEventId: room.nameEventId,
      avatarEventId: room.avatarEventId,
      isDm: room.roomType == 'dm',
      initialMessageId: _selectedMessageId,
      subtitle: hasUnread
          ? (room.unreadCount > 0 ? '${room.unreadCount} 条未读消息' : '已标记未读')
          : '在线',
      embedded: embedded,
      onBack: embedded ? null : _clearSelectedRoom,
      detailsPanelOpen: showRoomDetails,
      onToggleDetailsPanel: canShowRoomDetails
          ? () => setState(() => _showRoomDetails = !_showRoomDetails)
          : null,
      onRoomLeft: _clearSelectedRoom,
      onRoomDetailsChanged: _updateSelectedRoomDetails,
      onRegisterRoomDetailsHandler: _registerDesktopRoomDetailsHandler,
    );
  }

  Widget _buildMobileChatList({
    bool showFloatingActionButton = true,
  }) => ChatPage(
    key: ValueKey((
      'mobile-chat-list',
      _desktopRoomSource,
      _selectedDesktopSpace?.id,
    )),
    title: switch (_desktopRoomSource) {
      _DesktopRoomSource.allChats => null,
      _DesktopRoomSource.directMessages => '私聊',
      _DesktopRoomSource.ungroupedRooms => '未归属群组',
      _DesktopRoomSource.space => _selectedDesktopSpace?.name,
    },
    directMessagesOnly: _desktopRoomSource == _DesktopRoomSource.directMessages,
    ungroupedRoomsOnly: _desktopRoomSource == _DesktopRoomSource.ungroupedRooms,
    spaceId: _selectedDesktopSpace?.id,
    showFloatingActionButton: showFloatingActionButton,
  );

  Widget _buildDesktopRoomList() {
    return switch (_desktopRoomSource) {
      _DesktopRoomSource.allChats => ChatPage(
        key: const ValueKey('desktop-all-chats'),
        embedded: true,
        title: '全部会话',
        autoSelectFirstRoom: false,
        selectedRoomId: _selectedRoom?.id,
        onRoomSelected: _selectRoom,
      ),
      _DesktopRoomSource.directMessages => ChatPage(
        key: const ValueKey('desktop-direct-messages'),
        embedded: true,
        title: '私聊',
        emptyLabel: '暂无私聊',
        directMessagesOnly: true,
        selectedRoomId: _selectedRoom?.id,
        onRoomSelected: _selectRoom,
      ),
      _DesktopRoomSource.ungroupedRooms => ChatPage(
        key: const ValueKey('desktop-ungrouped-rooms'),
        embedded: true,
        title: '未归属群组',
        emptyLabel: '暂无未归属群组',
        ungroupedRoomsOnly: true,
        selectedRoomId: _selectedRoom?.id,
        onRoomSelected: _selectRoom,
      ),
      _DesktopRoomSource.space => switch (_selectedDesktopSpace) {
        final space? => ChatPage(
          key: ValueKey('desktop-space:${space.id}'),
          embedded: true,
          title: space.name,
          emptyLabel: '该空间暂无房间',
          spaceId: space.id,
          selectedRoomId: _selectedRoom?.id,
          onRoomSelected: _selectRoom,
        ),
        null => const _DesktopEmptyRoomList(),
      },
    };
  }
}

class _DesktopEmptyChat extends StatelessWidget {
  const _DesktopEmptyChat();

  @override
  Widget build(BuildContext context) {
    final neu = context.neu;
    return ColoredBox(
      color: neu.base,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const NeuIconButton(
              icon: Icons.chat_bubble_outline_rounded,
              size: 92,
              onPressed: null,
            ),
            const SizedBox(height: 18),
            Text('选择一个聊天开始查看消息', style: Theme.of(context).textTheme.bodyMedium),
          ],
        ),
      ),
    );
  }
}

class _DesktopEmptyRoomList extends StatelessWidget {
  const _DesktopEmptyRoomList();

  @override
  Widget build(BuildContext context) {
    final neu = context.neu;
    return ColoredBox(
      color: neu.base,
      child: Center(
        child: Text(
          '选择一个空间',
          style: Theme.of(context).textTheme.bodyMedium
              ?.copyWith(color: neu.textTertiary),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends ConsumerWidget {
  final int navigationIndex;
  final _DesktopRoomSource roomSource;
  final String? selectedSpaceId;
  final VoidCallback onAllChatsSelected;
  final VoidCallback onDirectMessagesSelected;
  final VoidCallback onUngroupedRoomsSelected;
  final ValueChanged<rust.Space> onSpaceSelected;
  final ValueChanged<int> onNavigate;

  const _DesktopSidebar({
    required this.navigationIndex,
    required this.roomSource,
    required this.selectedSpaceId,
    required this.onAllChatsSelected,
    required this.onDirectMessagesSelected,
    required this.onUngroupedRoomsSelected,
    required this.onSpaceSelected,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final spacesAsync = ref.watch(spacesProvider);
    final isRoomsPage = navigationIndex == 0;
    final me = ref.watch(currentUserProvider);

    if (context.isMaterial) {
      return NavigationRail(
        selectedIndex: isRoomsPage
            ? switch (roomSource) {
                _DesktopRoomSource.allChats => 0,
                _DesktopRoomSource.directMessages => 1,
                _DesktopRoomSource.ungroupedRooms => 2,
                _DesktopRoomSource.space => null,
              }
            : navigationIndex + 2,
        onDestinationSelected: (index) {
          if (index == 0) {
            onAllChatsSelected();
          } else if (index == 1) {
            onDirectMessagesSelected();
          } else if (index == 2) {
            onUngroupedRoomsSelected();
          } else {
            onNavigate(index - 2);
          }
        },
        leading: IconButton(
          tooltip: '个人资料与设置',
          onPressed: () => onNavigate(3),
          icon: AppAvatar(
            fallback: me?.displayName ?? '',
            size: 40,
            url: me?.avatarUrl,
          ),
        ),
        trailing: Expanded(
          child: SizedBox(
            width: 72,
            child: spacesAsync.when(
              data: (spaces) => ListView(
                children: [
                  for (final space in spaces)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: IconButton.filledTonal(
                        tooltip: space.name,
                        isSelected: isRoomsPage && selectedSpaceId == space.id,
                        onPressed: () => onSpaceSelected(space),
                        icon: AppAvatar(
                          fallback: space.name,
                          size: 32,
                          url: space.avatarUrl,
                        ),
                      ),
                    ),
                ],
              ),
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, _) => const SizedBox.shrink(),
            ),
          ),
        ),
        destinations: const [
          NavigationRailDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: Text('全部会话'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: Text('私聊'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.forum_outlined),
            selectedIcon: Icon(Icons.forum),
            label: Text('未归属群组'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.workspaces_outline),
            selectedIcon: Icon(Icons.workspaces),
            label: Text('空间'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.people_outline),
            selectedIcon: Icon(Icons.people),
            label: Text('通讯录'),
          ),
          NavigationRailDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: Text('设置'),
          ),
        ],
      );
    }
    return SizedBox(
      width: 76,
      child: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 16),
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              // 头像 → 设置页（资料入口在设置页顶部）。
              onTap: () => onNavigate(3),
              child: AppAvatar(
                fallback: me?.displayName ?? '',
                size: 48,
                radius: NeuRadius.content,
                url: me?.avatarUrl,
              ),
            ),
            const SizedBox(height: 18),
            NeuIconButton(
              tooltip: '全部会话',
              selected:
                  isRoomsPage && roomSource == _DesktopRoomSource.allChats,
              onPressed: onAllChatsSelected,
              icon: Icons.chat_bubble_outline,
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              tooltip: '私聊',
              selected:
                  isRoomsPage &&
                  roomSource == _DesktopRoomSource.directMessages,
              onPressed: onDirectMessagesSelected,
              icon: Icons.person_rounded,
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              tooltip: '未归属群组',
              selected:
                  isRoomsPage &&
                  roomSource == _DesktopRoomSource.ungroupedRooms,
              onPressed: onUngroupedRoomsSelected,
              icon: Icons.forum_outlined,
            ),
            const SizedBox(height: 18),
            Expanded(
              child: spacesAsync.when(
                data: (spaces) => ListView.builder(
                  clipBehavior: Clip.none, // 空间图标阴影不被视口硬裁
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: spaces.length,
                  itemExtent: 54,
                  itemBuilder: (context, index) {
                    final space = spaces[index];
                    final selected = isRoomsPage && selectedSpaceId == space.id;
                    return Center(
                      child: Tooltip(
                        message: space.name,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onSpaceSelected(space),
                          child: NeuSurface(
                            width: 44,
                            height: 44,
                            radius: 22,
                            accent: selected,
                            padding: const EdgeInsets.all(4),
                            child: AppAvatar(
                              fallback: space.name,
                              size: 36,
                              radius: 18,
                              url: space.avatarUrl,
                            ),
                          ),
                        ),
                      ),
                    );
                  },
                ),
                loading: () => Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: context.neu.accent,
                      strokeWidth: 2,
                    ),
                  ),
                ),
                error: (_, _) => const SizedBox.shrink(),
              ),
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              tooltip: '管理空间',
              selected: navigationIndex == 1,
              onPressed: () => onNavigate(1),
              icon: Icons.workspaces_outline,
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              tooltip: '通讯录',
              selected: navigationIndex == 2,
              onPressed: () => onNavigate(2),
              icon: Icons.people_outline_rounded,
            ),
            const SizedBox(height: 10),
            NeuIconButton(
              tooltip: '设置',
              selected: navigationIndex == 3,
              onPressed: () => onNavigate(3),
              icon: Icons.settings_outlined,
            ),
            const SizedBox(height: 14),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final String label;
  final bool isActive;
  final double activation;
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.activation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final neu = context.neu;

    return NeuAction(
      label: label,
      selected: isActive,
      radius: NeuRadius.nav - 6,
      onTap: onTap,
      child: ExcludeSemantics(
        child: SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Opacity(
                opacity: 1 - activation,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(icon, size: 22, color: neu.textSecondary),
                    const SizedBox(height: 2),
                    Text(label, style: Theme.of(context).textTheme.labelSmall),
                  ],
                ),
              ),
              Opacity(
                opacity: activation,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(activeIcon, size: 20, color: neu.onAccent),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(
                                fontWeight: FontWeight.w600,
                                color: neu.onAccent,
                              ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
