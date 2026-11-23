part of 'app.dart';

/// M3 assembly uses the existing room selection and metadata contracts.
/// It stays separate from the legacy skin's draggable desktop layout.
extension _MaterialAppLayout on _MatterAppState {
  Widget _buildMaterialLayout(MaterialWindowClass window) {
    final navigationIndex = ref.watch(navigationIndexProvider);
    final room = _selectedRoom;
    final detailsVisible =
        room != null &&
        !_conversationRoutesOpen &&
        (_materialDetailsVisible ?? window == MaterialWindowClass.extraLarge);
    final modalDetails =
        detailsVisible &&
        window != MaterialWindowClass.extraLarge &&
        navigationIndex == 0;
    final singleChat =
        room != null &&
        !_conversationRoutesOpen &&
        !window.hasSplit &&
        navigationIndex == 0;
    final me = ref.watch(currentUserProvider);
    final spaces = window.hasRail
        ? ref.watch(spacesProvider).value ?? const <rust.Space>[]
        : const <rust.Space>[];
    void openChatTool(Widget page) {
      final navigator = _conversationNavigator;
      _onItemTapped(0);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || ref.read(navigationIndexProvider) != 0) return;
        navigator.currentState?.pushAndRemoveUntil(
          MaterialPageRoute<void>(builder: (_) => page),
          (route) => route.isFirst,
        );
      });
    }

    void newChat() => openChatTool(const CreateChatPage());
    final avatar = AppAvatar(
      fallback: me?.displayName ?? '',
      size: 36,
      url: me?.avatarUrl,
    );
    return PopScope(
      canPop: !singleChat && !modalDetails,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (modalDetails) {
          _setMaterialDetails(false);
        } else if (singleChat) {
          _clearSelectedRoom();
        }
      },
      child: MaterialAdaptiveShell(
        window: window,
        index: navigationIndex,
        onNavigate: _onItemTapped,
        position: _tabPosition,
        pagesKey: ValueKey(ref.watch(activeUserIdProvider)),
        chatOpen: room != null,
        floatingActionButton:
            window.hasRail || (navigationIndex == 0 && room != null)
            ? null
            : switch (navigationIndex) {
                0 => FloatingActionButton(
                  key: const ValueKey('new-chat-action'),
                  tooltip: '新聊天',
                  onPressed: newChat,
                  child: const Icon(Icons.edit_outlined),
                ),
                1 => FloatingActionButton(
                  tooltip: '添加空间',
                  onPressed: () => SpacePage.showSpaceActions(context),
                  child: const Icon(Icons.add),
                ),
                _ => null,
              },
        profile: IconButton(
          tooltip: '个人资料与设置',
          onPressed: () => _onItemTapped(3),
          icon: avatar,
        ),
        railAccount: ListTile(
          leading: avatar,
          title: Text(
            me?.displayName ?? '当前账号',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            me?.id ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          onTap: () => _onItemTapped(3),
        ),
        railActions: (extended) => MaterialRailActions(
          extended: extended,
          onCreate: newChat,
          onFindRoom: () => openChatTool(const RoomDirectoryPage()),
        ),
        unreadCount: window.hasRail
            ? _railUnreadCount(ref.watch(inboxRoomsProvider).value ?? const [])
            : 0,
        railSpaces: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (spaces.isNotEmpty) ...[
              const Divider(indent: 16, endIndent: 16),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 0, 4),
                child: Text(
                  '空间',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ),
            ],
            for (final space in spaces)
              ListTile(
                dense: true,
                leading: AppAvatar(
                  fallback: space.name,
                  url: space.avatarUrl,
                  size: 30,
                ),
                title: Text(
                  space.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                selected:
                    navigationIndex == 0 &&
                    _selectedDesktopSpace?.id == space.id,
                onTap: () => _showSpace(space),
              ),
          ],
        ),
        pages: [
          MaterialConversationLayout(
            navigator: _conversationNavigator,
            routesOpen: _conversationRoutesOpen,
            active: navigationIndex == 0,
            onRoutesChanged: _setConversationRoutesOpen,
            window: window,
            list: _buildDesktopRoomList(
              filters: Builder(
                builder: (context) => _materialConversationFilters(
                  spaces,
                  expandedRail: MaterialAdaptiveShell.expandedRailOf(context),
                ),
              ),
            ),
            roomId: room?.id,
            detail: room == null
                ? const _DesktopEmptyChat()
                : _buildSelectedChat(
                    embedded: window.hasSplit,
                    paneVisible:
                        !_conversationRoutesOpen && navigationIndex == 0,
                    canShowRoomDetails: true,
                    showRoomDetails: detailsVisible,
                    onToggleDetailsPanel: () =>
                        _setMaterialDetails(!detailsVisible),
                  ),
            supporting: detailsVisible
                ? DesktopRoomDetailsPanel(
                    roomId: room.id,
                    roomName: room.name,
                    avatarUrl: room.avatarUrl,
                    onTimelineAction: (action) {
                      if (modalDetails) _setMaterialDetails(false);
                      ChatDetailPage.openPanelAction(_selectedChatKey, action);
                    },
                    onRoomLeft: _clearSelectedRoom,
                    onRoomDetailsChanged: (patch) =>
                        _desktopRoomDetailsHandler?.call(patch),
                  )
                : null,
            onCloseSupporting: () => _setMaterialDetails(false),
          ),
          MaterialListDetail(
            active: navigationIndex == 1,
            list: SpacePage(showFloatingActionButton: window.hasRail),
            emptyLabel: '选择一个空间',
            emptyIcon: Icons.workspaces_outline,
          ),
          MaterialListDetail(
            active: navigationIndex == 2,
            list: const ContactsPage(),
            emptyLabel: '选择一位联系人',
            emptyIcon: Icons.person_outline,
          ),
          MaterialListDetail(
            active: navigationIndex == 3,
            list: const SettingsPage(),
            emptyLabel: '选择一项设置',
            emptyIcon: Icons.tune,
          ),
        ],
      ),
    );
  }

  int _railUnreadCount(List<rust.ChatRoom> rooms) {
    var count = 0;
    for (final room in rooms) {
      if (room.roomState != 'joined') continue;
      final override = ref.watch(roomUnreadOverrideProvider(room.id));
      final unread = roomHasUnread(room, override);
      if (unread) count += room.unreadCount > 0 ? room.unreadCount : 1;
    }
    return count;
  }

  Widget _materialConversationFilters(
    List<rust.Space> spaces, {
    required bool expandedRail,
  }) => SingleChildScrollView(
    scrollDirection: Axis.horizontal,
    padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
    child: Row(
      spacing: 8,
      children: [
        ChoiceChip(
          label: const Text('全部'),
          selected: _desktopRoomSource == _DesktopRoomSource.allChats,
          onSelected: (_) => _showAllChats(),
        ),
        ChoiceChip(
          label: const Text('未读'),
          selected: _desktopRoomSource == _DesktopRoomSource.unread,
          onSelected: (_) => _showAllChats(unreadOnly: true),
        ),
        ChoiceChip(
          label: const Text('私聊'),
          selected: _desktopRoomSource == _DesktopRoomSource.directMessages,
          onSelected: (_) => _showDirectMessages(),
        ),
        MenuAnchor(
          menuChildren: [
            MenuItemButton(
              onPressed: _showUngroupedRooms,
              child: const Text('未归属群组'),
            ),
            if (!expandedRail)
              for (final space in spaces)
                MenuItemButton(
                  onPressed: () => _showSpace(space),
                  child: Text(space.name),
                ),
          ],
          builder: (_, menu, _) => ActionChip(
            label: Text(switch (_desktopRoomSource) {
              _DesktopRoomSource.space => _selectedDesktopSpace?.name ?? '空间',
              _DesktopRoomSource.ungroupedRooms => '未归属群组',
              _ => '更多筛选',
            }),
            avatar: const Icon(Icons.arrow_drop_down),
            onPressed: () => menu.isOpen ? menu.close() : menu.open(),
          ),
        ),
      ],
    ),
  );
}
