import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'pages/chat/chat_detail_page.dart';
import 'pages/chat/chat_page.dart';
import 'pages/chat/desktop_room_details_panel.dart';
import 'pages/chat/space_page.dart';
import 'pages/contacts/contacts_page.dart';
import 'pages/settings/encryption_page.dart';
import 'pages/settings/settings_page.dart';
import 'providers/auth_provider.dart';
import 'providers/chat_provider.dart';
import 'providers/navigation_provider.dart';
import 'src/rust/api/matrix.dart' as rust;
import 'theme/app_theme.dart';
import 'widgets/app_avatar.dart';
import 'widgets/liquid_glass.dart';
import 'widgets/max_content_width.dart';

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

  static const double _desktopBreakpoint = 840;
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
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => AlertDialog(
        title: const Text('设备验证请求'),
        content: Text('设备 ${status.deviceId} 正在请求验证当前设备。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('拒绝'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('接受'),
          ),
        ],
      ),
    );
    _verificationDialogOpen = false;
    if (!mounted) return;

    try {
      if (accepted == true) {
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

  void _selectRoom(rust.ChatRoom room) {
    if (room.roomType == 'space') {
      _showSpace(
        rust.Space(id: room.id, name: room.name, avatarUrl: room.avatarUrl),
      );
      return;
    }
    if (_selectedRoom?.id == room.id) return;
    setState(() => _selectedRoom = room);
  }

  void _showDirectMessages() {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.directMessages;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
    });
  }

  void _showUngroupedRooms() {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.ungroupedRooms;
      _selectedDesktopSpace = null;
      _selectedRoom = null;
    });
  }

  void _showSpace(rust.Space space) {
    ref.read(navigationIndexProvider.notifier).value = 0;
    setState(() {
      _desktopRoomSource = _DesktopRoomSource.space;
      _selectedDesktopSpace = space;
      _selectedRoom = null;
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
    _selectedDesktopSpace = null;
    _desktopRoomSource = _DesktopRoomSource.directMessages;
    _showRoomDetails = false;
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
      bottomNavigationBar: LiquidGlassContainer(
        borderRadius: AppRadii.nav,
        blurSigma: 18,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: SizedBox(
          height: 52,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _NavItem(
                icon: Icons.chat_bubble_outline_rounded,
                activeIcon: Icons.chat_bubble_rounded,
                label: '聊天',
                isActive: ref.watch(navigationIndexProvider) == 0,
                onTap: () => _onItemTapped(0),
              ),
              _NavItem(
                icon: Icons.account_tree_outlined,
                activeIcon: Icons.account_tree_rounded,
                label: '空间',
                isActive: ref.watch(navigationIndexProvider) == 1,
                onTap: () => _onItemTapped(1),
              ),
              _NavItem(
                icon: Icons.people_outline_rounded,
                activeIcon: Icons.people_rounded,
                label: '通讯录',
                isActive: ref.watch(navigationIndexProvider) == 2,
                onTap: () => _onItemTapped(2),
              ),
              _NavItem(
                icon: Icons.settings_outlined,
                activeIcon: Icons.settings_rounded,
                label: '设置',
                isActive: ref.watch(navigationIndexProvider) == 3,
                onTap: () => _onItemTapped(3),
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
                      SizedBox(width: 320, child: _buildDesktopRoomList()),
                      const VerticalDivider(width: 1, thickness: 1),
                      Expanded(
                        child: selectedRoom == null
                            ? const _DesktopEmptyChat()
                            : ChatDetailPage(
                                key: ValueKey(selectedRoom.id),
                                roomId: selectedRoom.id,
                                roomName: selectedRoom.name,
                                avatarUrl: selectedRoom.avatarUrl,
                                isDm: selectedRoom.roomType == 'dm',
                                subtitle: selectedRoom.unreadCount > 0
                                    ? '${selectedRoom.unreadCount} 条未读消息'
                                    : '在线',
                                embedded: true,
                                detailsPanelOpen: showRoomDetails,
                                onToggleDetailsPanel: canShowRoomDetails
                                    ? () => setState(
                                        () => _showRoomDetails =
                                            !_showRoomDetails,
                                      )
                                    : null,
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
    return const ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Text(
          '选择一个聊天开始查看消息',
          style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 14),
        ),
      ),
    );
  }
}

class _DesktopEmptyRoomList extends StatelessWidget {
  const _DesktopEmptyRoomList();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: AppColors.background,
      child: Center(
        child: Text(
          '选择一个空间',
          style: TextStyle(color: AppColors.onSurfaceVariant, fontSize: 14),
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

    return SizedBox(
      width: 80,
      child: ColoredBox(
        color: AppColors.surface,
        child: Column(
          children: [
            const SizedBox(height: 12),
            _DesktopRailButton(
              tooltip: '私聊',
              selected:
                  isRoomsPage &&
                  roomSource == _DesktopRoomSource.directMessages,
              onPressed: onDirectMessagesSelected,
              icon: const Icon(Icons.person_rounded),
            ),
            _DesktopRailButton(
              tooltip: '未归属群组',
              selected:
                  isRoomsPage &&
                  roomSource == _DesktopRoomSource.ungroupedRooms,
              onPressed: onUngroupedRoomsSelected,
              icon: const Icon(Icons.forum_outlined),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1),
            ),
            Expanded(
              child: spacesAsync.when(
                data: (spaces) => ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: spaces.length,
                  itemBuilder: (context, index) {
                    final space = spaces[index];
                    return _DesktopRailButton(
                      tooltip: space.name,
                      selected: isRoomsPage && selectedSpaceId == space.id,
                      onPressed: () => onSpaceSelected(space),
                      icon: AppAvatar(
                        fallback: space.name,
                        size: 36,
                        radius: 12,
                        url: space.avatarUrl,
                      ),
                    );
                  },
                ),
                loading: () => const Center(
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      color: AppColors.primary,
                      strokeWidth: 2,
                    ),
                  ),
                ),
                error: (_, _) => const SizedBox.shrink(),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(height: 1),
            ),
            _DesktopRailButton(
              tooltip: '管理空间',
              selected: navigationIndex == 1,
              onPressed: () => onNavigate(1),
              icon: const Icon(Icons.workspaces_outline),
            ),
            _DesktopRailButton(
              tooltip: '通讯录',
              selected: navigationIndex == 2,
              onPressed: () => onNavigate(2),
              icon: const Icon(Icons.people_outline_rounded),
            ),
            _DesktopRailButton(
              tooltip: '设置',
              selected: navigationIndex == 3,
              onPressed: () => onNavigate(3),
              icon: const Icon(Icons.settings_outlined),
            ),
            const SizedBox(height: 12),
          ],
        ),
      ),
    );
  }
}

class _DesktopRailButton extends StatelessWidget {
  final String tooltip;
  final bool selected;
  final VoidCallback onPressed;
  final Widget icon;

  const _DesktopRailButton({
    required this.tooltip,
    required this.selected,
    required this.onPressed,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: SizedBox(
        width: 80,
        height: 52,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Center(
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  curve: Curves.easeOutCubic,
                  width: 3,
                  height: selected ? 24 : 0,
                  decoration: BoxDecoration(
                    color: AppColors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
            Center(
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: selected ? AppColors.surfaceVariant : null,
                  borderRadius: BorderRadius.circular(AppRadii.tag),
                ),
                child: IconButton(
                  onPressed: onPressed,
                  icon: icon,
                  color: selected ? AppColors.primary : AppColors.onSurface,
                ),
              ),
            ),
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
    final color = isActive ? AppColors.primary : AppColors.onSurfaceVariant;

    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: SizedBox(
        width: 64,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(isActive ? activeIcon : icon, color: color, size: 22),
            const SizedBox(height: 3),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
                height: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
