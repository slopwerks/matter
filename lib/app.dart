import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/chat/chat_detail_page.dart';
import 'pages/chat/chat_page.dart';
import 'pages/chat/desktop_room_details_panel.dart';
import 'pages/chat/room_metadata_patch.dart';
import 'pages/chat/room_state_edit_tracker.dart';
import 'pages/chat/space_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/settings/encryption_page.dart';
import 'pages/settings/settings_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/navigation_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'theme/neu_colors.dart';
import 'widgets/app_avatar.dart';
import 'widgets/glass.dart';
import 'widgets/neu_action.dart';
import 'widgets/neu_surface.dart';
import 'widgets/max_content_width.dart';
import 'widgets/sheets.dart';

enum _DesktopRoomSource { directMessages, ungroupedRooms, space }

class MatterApp extends ConsumerStatefulWidget {
  const MatterApp({super.key});

  @override
  ConsumerState<MatterApp> createState() => _MatterAppState();
}

class _MatterAppState extends ConsumerState<MatterApp> {
  final _pageController = PageController();
  Timer? _verificationTimer;
  bool _checkingVerification = false;
  bool _verificationDialogOpen = false;
  bool? _lastLayoutWasDesktop;
  final Set<String> _handledVerificationFlows = {};
  rust.ChatRoom? _selectedRoom;
  rust.Space? _selectedDesktopSpace;
  _DesktopRoomSource _desktopRoomSource = _DesktopRoomSource.directMessages;
  bool _showRoomDetails = false;
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
    _pageController.dispose();
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
        await Navigator.of(
          context,
        ).push(MaterialPageRoute(builder: (_) => const EncryptionPage()));
      } else {
        await rust.cancelDeviceVerification(mismatch: false);
      }
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('处理设备验证失败：$error')));
    }
  }

  void _onItemTapped(int index) {
    if (ref.read(navigationIndexProvider) != index) {
      ref.read(navigationIndexProvider.notifier).value = index;
    }
    if (_pageController.hasClients) {
      _pageController.animateToPage(
        index,
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOutCubic,
      );
    }
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

  void _selectRoom(rust.ChatRoom room) {
    if (room.roomType == 'space') {
      _showSpace(
        rust.Space(id: room.id, name: room.name, avatarUrl: room.avatarUrl),
      );
      return;
    }
    if (_selectedRoom?.id == room.id) {
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
    setState(() => _selectedRoom = room);
  }

  Future<void> _markSelectedRoomAsRead(rust.ChatRoom room) async {
    // The receipts are written for the account that starts this call.
    final accountUserId = ref.read(activeUserIdProvider);
    // No account yet (deep-link before login completed): skip — a write
    // with an empty account id would be rejected by the Rust guard anyway.
    if (accountUserId == null) return;
    try {
      final cleared = await rust.markRoomAsRead(
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
      ref.invalidate(chatRoomsProvider);
      ref.invalidate(ungroupedRoomsProvider);
      ref.invalidate(spaceChildrenProvider);
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

  void _showDirectMessages() {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.directMessages;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
  }

  void _showUngroupedRooms() {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.ungroupedRooms;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
  }

  void _showSpace(rust.Space space) {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.space;
      _selectedDesktopSpace = space;
      _selectedRoom = null;
      _clearSelectedRoomDetailsEdits();
    });
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
        _syncMobilePageAfterLayoutChange(isDesktop);
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
    if (previousUserId == null || previousUserId == activeUserId) return;

    _selectedRoom = null;
    _clearSelectedRoomDetailsEdits();
    _selectedDesktopSpace = null;
    _desktopRoomSource = _DesktopRoomSource.directMessages;
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
    _selectedRoom = _reconcileSelectedRoomDetails(selectedRoom, refreshedRoom);
  }

  void _syncMobilePageAfterLayoutChange(bool isDesktop) {
    if (_lastLayoutWasDesktop == isDesktop) return;
    _lastLayoutWasDesktop = isDesktop;
    if (isDesktop) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _pageController.hasClients) {
        _pageController.jumpToPage(ref.read(navigationIndexProvider));
      }
    });
  }

  Widget _buildMobileLayout() {
    return Scaffold(
      extendBody: true,
      body: PageView(
        controller: _pageController,
        children: _pages,
        onPageChanged: (index) {
          if (ref.read(navigationIndexProvider) != index) {
            ref.read(navigationIndexProvider.notifier).value = index;
          }
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        minimum: const EdgeInsets.fromLTRB(14, 8, 14, 10),
        child: GlassPanel(
          radius: NeuRadius.nav,
          padding: const EdgeInsets.all(6),
          child: Row(
            children: [
              Expanded(
                child: _NavItem(
                  icon: Icons.chat_bubble_outline_rounded,
                  activeIcon: Icons.chat_bubble_rounded,
                  label: '聊天',
                  isActive: ref.watch(navigationIndexProvider) == 0,
                  onTap: () => _onItemTapped(0),
                ),
              ),
              Expanded(
                child: _NavItem(
                  icon: Icons.account_tree_outlined,
                  activeIcon: Icons.account_tree_rounded,
                  label: '空间',
                  isActive: ref.watch(navigationIndexProvider) == 1,
                  onTap: () => _onItemTapped(1),
                ),
              ),
              Expanded(
                child: _NavItem(
                  icon: Icons.people_outline_rounded,
                  activeIcon: Icons.people_rounded,
                  label: '通讯录',
                  isActive: ref.watch(navigationIndexProvider) == 2,
                  onTap: () => _onItemTapped(2),
                ),
              ),
              Expanded(
                child: _NavItem(
                  icon: Icons.settings_outlined,
                  activeIcon: Icons.settings_rounded,
                  label: '设置',
                  isActive: ref.watch(navigationIndexProvider) == 3,
                  onTap: () => _onItemTapped(3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDesktopLayout(BuildContext context, BoxConstraints constraints) {
    final navigationIndex = ref.watch(navigationIndexProvider);
    final selectedRoom = _selectedRoom;
    // Match the room list's unread display (including the local override
    // for pending mark-read/unread writes) so the pane subtitle and the
    // list's red dot never disagree during the echo window.
    final unreadOverride = selectedRoom == null
        ? null
        : ref.watch(roomUnreadOverrideProvider(selectedRoom.id));
    final syncedHasUnread = selectedRoom == null
        ? false
        : selectedRoom.unreadCount > 0 || selectedRoom.isMarkedUnread;
    final overrideApplies = unreadOverride?.appliesTo(selectedRoom!) ?? false;
    final hasUnread = overrideApplies
        ? unreadOverride!.unread
        : syncedHasUnread;
    final canShowRoomDetails =
        constraints.maxWidth >= _desktopDetailsPaneBreakpoint;
    final showRoomDetails =
        canShowRoomDetails &&
        _showRoomDetails &&
        navigationIndex == 0 &&
        selectedRoom != null;

    return Scaffold(
      body: Row(
        children: [
          _DesktopSidebar(
            navigationIndex: navigationIndex,
            roomSource: _desktopRoomSource,
            selectedSpaceId: _selectedDesktopSpace?.id,
            onDirectMessagesSelected: _showDirectMessages,
            onUngroupedRoomsSelected: _showUngroupedRooms,
            onSpaceSelected: _showSpace,
            onNavigate: _onItemTapped,
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: navigationIndex == 0
                ? Row(
                    children: [
                      SizedBox(width: 348, child: _buildDesktopRoomList()),
                      const VerticalDivider(width: 1, thickness: 1),
                      Expanded(
                        child: selectedRoom == null
                            ? const _DesktopEmptyChat()
                            : ChatDetailPage(
                                key: ValueKey(selectedRoom.id),
                                roomId: selectedRoom.id,
                                roomName: selectedRoom.name,
                                avatarUrl: selectedRoom.avatarUrl,
                                nameEventId: selectedRoom.nameEventId,
                                avatarEventId: selectedRoom.avatarEventId,
                                isDm: selectedRoom.roomType == 'dm',
                                subtitle: hasUnread
                                    ? (selectedRoom.unreadCount > 0
                                          ? '${selectedRoom.unreadCount} 条未读消息'
                                          : '已标记未读')
                                    : '在线',
                                embedded: true,
                                detailsPanelOpen: showRoomDetails,
                                onToggleDetailsPanel: canShowRoomDetails
                                    ? () => setState(
                                        () => _showRoomDetails =
                                            !_showRoomDetails,
                                      )
                                    : null,
                                onRoomLeft: _clearSelectedRoom,
                                onRoomDetailsChanged:
                                    _updateSelectedRoomDetails,
                                onRegisterRoomDetailsHandler:
                                    _registerDesktopRoomDetailsHandler,
                              ),
                      ),
                      if (showRoomDetails) ...[
                        const VerticalDivider(width: 1, thickness: 1),
                        SizedBox(
                          width: 300,
                          child: DesktopRoomDetailsPanel(
                            roomId: selectedRoom.id,
                            roomName: selectedRoom.name,
                            avatarUrl: selectedRoom.avatarUrl,
                            onRoomLeft: _clearSelectedRoom,
                            // Route through the selected page's handler so
                            // the edit arms its sync-echo tracker (the page
                            // then forwards to _updateSelectedRoomDetails).
                            onRoomDetailsChanged: (patch) =>
                                _desktopRoomDetailsHandler?.call(patch),
                          ),
                        ),
                      ],
                    ],
                  )
                : MaxContentWidth(child: _pages[navigationIndex]),
          ),
        ],
      ),
    );
  }

  Widget _buildDesktopRoomList() {
    return switch (_desktopRoomSource) {
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
          style: Theme.of(
            context,
          ).textTheme.bodyMedium?.copyWith(color: neu.textTertiary),
        ),
      ),
    );
  }
}

class _DesktopSidebar extends ConsumerWidget {
  final int navigationIndex;
  final _DesktopRoomSource roomSource;
  final String? selectedSpaceId;
  final VoidCallback onDirectMessagesSelected;
  final VoidCallback onUngroupedRoomsSelected;
  final ValueChanged<rust.Space> onSpaceSelected;
  final ValueChanged<int> onNavigate;

  const _DesktopSidebar({
    required this.navigationIndex,
    required this.roomSource,
    required this.selectedSpaceId,
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
  final VoidCallback onTap;

  const _NavItem({
    required this.icon,
    required this.activeIcon,
    required this.label,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final neu = context.neu;

    return NeuAction(
      selected: isActive,
      radius: NeuRadius.nav - 6,
      onTap: onTap,
      child: isActive
          ? NeuSurface(
              accent: true,
              // 与外层 GlassPanel(radius: nav, padding: 6) 保持同心圆角：
              // 内圆角 = 外圆角 - 内边距，否则药丸与 dock 的曲率明显不匹配。
              radius: NeuRadius.nav - 6,
              padding: const EdgeInsets.symmetric(vertical: 9),
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
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: neu.onAccent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 22, color: neu.textSecondary),
                const SizedBox(height: 2),
                Text(label, style: Theme.of(context).textTheme.labelSmall),
              ],
            ),
    );
  }
}
