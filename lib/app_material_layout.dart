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
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const CreateChatPage(),
                    ),
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
        profile: IconButton(
          tooltip: '个人资料与设置',
          onPressed: () => _onItemTapped(3),
          icon: AppAvatar(
            fallback: me?.displayName ?? '',
            size: 40,
            url: me?.avatarUrl,
          ),
        ),
        pages: [
          MaterialConversationLayout(
            window: window,
            list: _buildDesktopRoomList(
              filters: _materialConversationFilters(
                window.hasRail
                    ? ref.watch(spacesProvider).value ?? const []
                    : const [],
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

  Widget _materialConversationFilters(List<rust.Space> spaces) =>
      SingleChildScrollView(
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
            if (spaces.isNotEmpty)
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
            else if (_desktopRoomSource == _DesktopRoomSource.space)
              ChoiceChip(
                label: Text(_selectedDesktopSpace?.name ?? '空间'),
                selected: true,
                onSelected: (_) {},
              ),
          ],
        ),
      );
}
