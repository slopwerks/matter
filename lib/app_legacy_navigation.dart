part of 'app.dart';

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
