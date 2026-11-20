part of 'app.dart';

/// M3 assembly uses the existing room selection and metadata contracts.
/// It stays separate from the legacy skin's draggable desktop layout.
extension _MaterialAppLayout on _MatterAppState {
  Widget _buildMaterialLayout(MaterialWindowClass window) {
    final navigationIndex = ref.watch(navigationIndexProvider);
    final room = _selectedRoom;
    final detailsVisible =
        room != null &&
        (_materialDetailsVisible ?? window == MaterialWindowClass.extraLarge);
    final modalDetails =
        detailsVisible &&
        window != MaterialWindowClass.extraLarge &&
        navigationIndex == 0;
    final singleChat = room != null && !window.hasSplit && navigationIndex == 0;
    final me = ref.watch(currentUserProvider);
    final spaces = window.hasRail
        ? ref.watch(spacesProvider).value ?? const <rust.Space>[]
        : const <rust.Space>[];
    void newChat() => Navigator.of(context)
        .push(MaterialPageRoute<void>(builder: (_) => const CreateChatPage()));
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
        railActions: (extended) {
          final create = MaterialPress(
            builder: (states) => extended
                ? FilledButton.icon(
                    statesController: states,
                    onPressed: newChat,
                    icon: const Icon(Icons.add),
                    label: const Text(
                      '新建会话',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                  )
                : IconButton.filled(
                    statesController: states,
                    tooltip: '新建会话',
                    onPressed: newChat,
                    icon: const Icon(Icons.add),
                    style: IconButton.styleFrom(
                      fixedSize: const Size.square(48),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
          );
          final join = IconButton.filledTonal(
            tooltip: '加入房间',
            onPressed: () => CreateChatPage.showJoinRoomDialog(context, ref),
            icon: const Icon(Icons.meeting_room_outlined),
          );
          return Padding(
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
            child: extended
                ? Row(
                    spacing: 6,
                    children: [
                      Expanded(child: create),
                      join,
                    ],
                  )
                : Column(spacing: 8, children: [create, join]),
          );
        },
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
      final unread = override != null && override.appliesTo(room)
          ? override.unread
          : room.isMarkedUnread || room.unreadCount > 0;
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
          label: const Text('私聊'),
          selected: _desktopRoomSource == _DesktopRoomSource.directMessages,
          onSelected: (_) => _showDirectMessages(),
        ),
        ChoiceChip(
          label: const Text('未归属群组'),
          selected: _desktopRoomSource == _DesktopRoomSource.ungroupedRooms,
          onSelected: (_) => _showUngroupedRooms(),
        ),
        if (!expandedRail && spaces.isNotEmpty)
          MenuAnchor(
            menuChildren: [
              for (final space in spaces)
                MenuItemButton(
                  onPressed: () => _showSpace(space),
                  child: Text(space.name),
                ),
            ],
            builder: (_, menu, _) => ActionChip(
              label: Text(
                _desktopRoomSource == _DesktopRoomSource.space
                    ? _selectedDesktopSpace?.name ?? '按空间筛选'
                    : '按空间筛选',
              ),
              avatar: const Icon(Icons.arrow_drop_down),
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          )
        else if (!expandedRail &&
            _desktopRoomSource == _DesktopRoomSource.space)
          ChoiceChip(
            label: Text(_selectedDesktopSpace?.name ?? '空间'),
            selected: true,
            onSelected: (_) {},
          ),
      ],
    ),
  );
}
