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
    return Scaffold(
      appBar: buildFloatingAppBar(
        title: const Text('空间详情'),
        actions: [
          IconButton(
            tooltip: '添加房间',
            icon: const Icon(Icons.playlist_add),
            onPressed: () => _showAddRoomDialog(context, ref),
          ),
          IconButton(
            tooltip: '更多',
            icon: const Icon(Icons.more_horiz_rounded),
            onPressed: () => _showSpaceMenu(
              context,
              ref,
              details,
              detailsLoaded,
              allChildren.asData?.value,
            ),
          ),
        ],
      ),
      body: MaxContentWidth(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            20,
            16,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            Card(
              color: hero.fill,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        AppAvatar(
                          fallback: details.name,
                          size: 56,
                          url: details.avatarUrl,
                        ),
                        const SizedBox(width: 16),
                        Expanded(child: Text(details.name, style: hero.title)),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SelectableText(details.id, style: hero.subtitle),
                    if ((details.topic ?? '').isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(details.topic!, style: hero.subtitle),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SegmentedButton<int>(
              showSelectedIcon: false,
              expandedInsets: EdgeInsets.zero,
              segments: const [
                ButtonSegment(value: 0, label: Text('房间')),
                ButtonSegment(value: 1, label: Text('成员')),
                ButtonSegment(value: 2, label: Text('关于')),
              ],
              selected: {_materialSpaceTab},
              onSelectionChanged: (selection) =>
                  _selectMaterialSpaceTab(selection.single),
            ),
            const SizedBox(height: 20),
            switch (_materialSpaceTab) {
              0 => children.when(
                data: (rooms) => _materialRooms(context, rooms),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Text('加载房间失败: $error'),
              ),
              1 => members.when(
                data: (people) => Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('成员', style: Theme.of(context).textTheme.titleSmall),
                    const SizedBox(height: 12),
                    people.isEmpty
                        ? const Text('暂无成员信息')
                        : Column(
                            children: [
                              for (final (index, person)
                                  in people.take(8).indexed) ...[
                                if (index > 0)
                                  const Divider(
                                    height: 1,
                                    indent:
                                        materialListAvatarSize +
                                        materialListContentGap,
                                  ),
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 12,
                                  ),
                                  child: MaterialMemberIdentity(
                                    name: person.name,
                                    userId: person.id,
                                    avatarUrl: person.avatarUrl,
                                  ),
                                ),
                              ],
                              if (people.length > 8)
                                Text('还有 ${people.length - 8} 位成员'),
                            ],
                          ),
                  ],
                ),
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => Text('加载成员失败: $error'),
              ),
              _ => MaterialDetailCard(
                title: '空间管理',
                child: Column(
                  children: [
                    _ActionSettingRow(
                      icon: Icons.edit_rounded,
                      label: '编辑空间',
                      value: '修改名称与说明',
                      onTap: () => _showEditSpaceDialog(context, ref, details),
                    ),
                    const Divider(),
                    _ActionSettingRow(
                      icon: Icons.exit_to_app_rounded,
                      label: '退出空间',
                      value: '离开当前空间',
                      danger: true,
                      onTap: () => _confirmLeaveSpace(context, ref, details),
                    ),
                  ],
                ),
              ),
            },
          ],
        ),
      ),
    );
  }

  Widget _materialRooms(BuildContext context, List<ChatRoom> rooms) {
    if (rooms.isEmpty) {
      return MaterialDetailCard(
        title: '房间列表',
        description: '这个空间下暂时没有可见房间',
        child: Align(
          alignment: AlignmentDirectional.centerStart,
          child: NeuButton(
            onPressed: () => _showAddRoomDialog(context, ref),
            icon: const Icon(Icons.add),
            child: const Text('添加房间'),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '房间列表 · ${rooms.length}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (context, constraints) {
            final columns = constraints.maxWidth >= 640 ? 2 : 1;
            final width = (constraints.maxWidth - (columns - 1) * 12) / columns;
            return Wrap(
              spacing: 12,
              children: [
                for (final room in rooms)
                  SizedBox(
                    width: width,
                    child: _SpaceChildTile(
                      room: room,
                      onRemove: room.roomType == 'space'
                          ? null
                          : () => _confirmRemoveRoom(context, ref, room),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}
