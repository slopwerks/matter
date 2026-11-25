part of 'space_detail_page.dart';

/// Material presentation leaves space writes and account guards in the host.
extension _MaterialSpaceDetail on _SpaceDetailPageState {
  Widget _buildMaterialSpaceDetail(
    BuildContext context,
    SpaceDetails details,
    bool detailsLoaded,
    AsyncValue<List<ChatRoom>> children,
    AsyncValue<List<ChatRoom>> allChildren,
    AsyncValue<List<Contact>> members,
  ) {
    final hero = materialProfileCardStyle(Theme.of(context), detail: true);
    final wide = MediaQuery.sizeOf(context).width >= 600;
    final expandedHeight = wide ? 192.0 : 128.0;
    final tabDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : context.tokens.motion.layoutDuration;
    void manage() => _showSpaceMenu(
      context,
      ref,
      details,
      detailsLoaded,
      allChildren.asData?.value,
    );
    final invite = details.canInvite == true && !_inviting
        ? _inviteSpaceMember
        : null;
    return Scaffold(
      body: SafeArea(
        child: DefaultTabController(
          length: 3,
          initialIndex: _materialSpaceTab,
          animationDuration: tabDuration,
          child: Column(
            children: [
              MaterialHeaderTransition(
                collapsed: _headerCollapsed,
                builder: (context, expansion, _) {
                  double between(double collapsed, double expanded) =>
                      collapsed + (expanded - collapsed) * expansion;
                  final type = Theme.of(context).textTheme;
                  return SizedBox(
                    height: between(kToolbarHeight, expandedHeight),
                    child: Material(
                      color: hero.fill,
                      borderRadius: const BorderRadius.vertical(
                        bottom: Radius.circular(materialSurfaceRadius),
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: MaterialHeaderDecoration(
                              color: materialRootHeaderStyle(
                                Theme.of(context),
                                compact: true,
                              ).decoration,
                            ),
                          ),
                          Container(
                            padding: EdgeInsets.all(
                              between(
                                NeuSpacing.xs,
                                wide ? NeuSpacing.xl : NeuSpacing.md,
                              ),
                            ),
                            alignment: AlignmentDirectional.centerStart,
                            child: Row(
                              children: [
                                if (Navigator.canPop(context) &&
                                    !(MaterialAdaptiveShell.windowOf(context)
                                            ?.hasSplit ??
                                        false))
                                  BackButton(color: hero.foreground),
                                AppAvatar(
                                  fallback: details.name,
                                  size: between(36, wide ? 72 : 56),
                                  materialRadius: wide ? 24 : 16,
                                  url: details.avatarUrl,
                                  fallbackColors: (
                                    fill: Theme.of(context).colorScheme.primary,
                                    foreground: Theme.of(context)
                                        .colorScheme
                                        .onPrimary,
                                  ),
                                ),
                                const SizedBox(width: NeuSpacing.lg),
                                Expanded(
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Flexible(
                                        child: Text(
                                          details.name,
                                          style: TextStyle.lerp(
                                            type.titleMedium,
                                            wide
                                                ? type.headlineLarge
                                                : hero.title,
                                            expansion,
                                          )?.copyWith(color: hero.foreground),
                                          maxLines: expansion == 0 ? 1 : 2,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      if (expansion > 0 &&
                                          (details.topic ?? '').isNotEmpty)
                                        ClipRect(
                                          child: Align(
                                            alignment:
                                                AlignmentDirectional.topStart,
                                            heightFactor: expansion,
                                            child: Opacity(
                                              opacity: expansion,
                                              child: Text(
                                                details.topic!,
                                                style: hero.subtitle,
                                                maxLines: 2,
                                                overflow: TextOverflow.ellipsis,
                                              ),
                                            ),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                IconButton(
                                  onPressed: manage,
                                  color: hero.foreground,
                                  icon: const Icon(Icons.more_horiz),
                                  tooltip: '空间操作',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
              Material(
                color: Theme.of(context).scaffoldBackgroundColor,
                child: TabBar(
                  isScrollable: true,
                  tabAlignment: TabAlignment.start,
                  padding: const EdgeInsets.symmetric(
                    horizontal: NeuSpacing.lg,
                  ),
                  onTap: _selectMaterialSpaceTab,
                  tabs: const [
                    Tab(text: '房间'),
                    Tab(text: '成员'),
                    Tab(text: '关于'),
                  ],
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: tabDuration,
                  switchInCurve: Curves.easeOutCubic,
                  layoutBuilder: (current, outgoing) => Stack(
                    alignment: Alignment.topCenter,
                    children: [
                      if (outgoing.isNotEmpty)
                        ExcludeSemantics(
                          child: ExcludeFocus(
                            child: IgnorePointer(child: outgoing.last),
                          ),
                        ),
                      ?current,
                    ],
                  ),
                  child: HeaderScrollListener(
                    key: ValueKey(_materialSpaceTab),
                    onScroll: (metrics) =>
                        _syncHeader(metrics, expandedHeight - kToolbarHeight),
                    child: CustomScrollView(
                      key: PageStorageKey(
                        'space-tab-$_materialSpaceTab:${widget.space.id}',
                      ),
                      slivers: [
                        SliverToBoxAdapter(
                          child: MaxContentWidth(
                            maxWidth: 1100,
                            child: Padding(
                              padding: EdgeInsets.all(
                                wide ? NeuSpacing.xl : NeuSpacing.lg,
                              ),
                              child: switch (_materialSpaceTab) {
                                0 => children.when(
                                  data: (rooms) =>
                                      _materialRooms(context, rooms, manage),
                                  loading: () => const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                  error: (error, _) => Text('加载房间失败: $error'),
                                ),
                                1 => members.when(
                                  data: (people) => _SpaceMembers(
                                    people: people,
                                    onInvite: invite,
                                  ),
                                  loading: () => const Center(
                                    child: CircularProgressIndicator(),
                                  ),
                                  error: (error, _) => Text('加载成员失败: $error'),
                                ),
                                _ => _SpaceAbout(
                                  details: details,
                                  rooms: children,
                                  onEdit: detailsLoaded
                                      ? (field) => _showEditSpaceDialog(
                                          context,
                                          ref,
                                          details,
                                          field: field,
                                        )
                                      : null,
                                  onManage: manage,
                                  onInvite: invite,
                                  onCopy: _copySpaceLink,
                                  onLeave: () =>
                                      _confirmLeaveSpace(context, ref, details),
                                ),
                              },
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _materialRooms(
    BuildContext context,
    List<ChatRoom> children,
    VoidCallback manage,
  ) {
    final rooms = children.where((room) => room.roomType != 'space').toList();
    final subspaces = children
        .where((room) => room.roomType == 'space')
        .toList();
    final unread = [
      for (final room in rooms)
        if (roomHasUnread(room, ref.watch(roomUnreadOverrideProvider(room.id))))
          room,
    ];
    final count = unread.fold(
      0,
      (n, room) => n + (room.unreadCount > 0 ? room.unreadCount : 1),
    );
    final text = Theme.of(context).textTheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: NeuSpacing.sm,
          runSpacing: NeuSpacing.xs,
          children: [
            FilledButton.icon(
              onPressed: manage,
              icon: const Icon(Icons.settings_outlined),
              label: const Text('管理空间'),
            ),
            OutlinedButton(
              onPressed: unread.isEmpty
                  ? null
                  : () => _openSpaceChild(context, unread.first, true),
              child: Text('未读 $count'),
            ),
            OutlinedButton(
              onPressed: unread.isEmpty || _markingSpaceRead
                  ? null
                  : () => _markSpaceRead(unread),
              child: const Text('全部已读'),
            ),
          ],
        ),
        const SizedBox(height: NeuSpacing.xl),
        if (subspaces.isNotEmpty) ...[
          Text('子空间 ${subspaces.length}', style: text.titleMedium),
          const SizedBox(height: NeuSpacing.sm),
          _spaceRoomGrid(subspaces),
        ],
        Row(
          children: [
            Expanded(
              child: Text('房间 ${rooms.length}', style: text.titleMedium),
            ),
            TextButton.icon(
              onPressed: _creatingRoom ? null : _createSpaceRoom,
              icon: const Icon(Icons.add),
              label: const Text('新建房间'),
            ),
          ],
        ),
        const SizedBox(height: NeuSpacing.sm),
        if (rooms.isEmpty)
          const Text('这个空间下暂时没有可见房间')
        else
          _spaceRoomGrid(rooms),
        const SizedBox(height: NeuSpacing.md),
        Card.outlined(
          child: ListTile(
            leading: Icon(
              Icons.public,
              color: Theme.of(context).colorScheme.primary,
            ),
            title: const Text('发现更多讨论'),
            subtitle: const Text('按房间名或地址查找公开房间。'),
            trailing: FilledButton.tonal(
              onPressed: () => RoomDirectoryPage.open(context),
              child: const Text('探索'),
            ),
            onTap: () => RoomDirectoryPage.open(context),
          ),
        ),
      ],
    );
  }

  Widget _spaceRoomGrid(List<ChatRoom> rooms) => LayoutBuilder(
    builder: (context, constraints) {
      const gap = NeuSpacing.md;
      final columns = ((constraints.maxWidth + gap) / (235 + gap))
          .floor()
          .clamp(1, rooms.length);
      final width = (constraints.maxWidth - gap * (columns - 1)) / columns;
      return Wrap(
        spacing: gap,
        runSpacing: gap,
        children: [
          for (final room in rooms)
            SizedBox(
              width: width,
              child: _SpaceChildTile(
                onSetPrimary: () => _setPrimarySpace(room),
                room: room,
                onRemove: room.roomType == 'space'
                    ? null
                    : () => _confirmRemoveRoom(context, ref, room),
              ),
            ),
        ],
      );
    },
  );
}
