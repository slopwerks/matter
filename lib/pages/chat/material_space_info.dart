part of 'space_detail_page.dart';

class _SpaceMembers extends StatelessWidget {
  const _SpaceMembers({required this.people, this.onInvite});
  final List<Contact> people;
  final VoidCallback? onInvite;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '成员 · ${people.length}',
                style: theme.textTheme.titleMedium,
              ),
            ),
            TextButton.icon(
              icon: const Icon(Icons.person_add_outlined),
              label: const Text('邀请'),
              onPressed: onInvite,
            ),
          ],
        ),
        if (people.isEmpty) const Text('暂无成员信息'),
        for (final person in people)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: NeuSpacing.md),
            child: MaterialMemberIdentity(
              name: person.name,
              userId: person.id,
              avatarUrl: person.avatarUrl,
              trailing: person.roomRole == null
                  ? null
                  : _RoleLabel(role: person.roomRole!),
            ),
          ),
      ],
    );
  }
}

class _RoleLabel extends StatelessWidget {
  const _RoleLabel({required this.role});
  final MemberRole role;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final elevated =
        role == MemberRole.creator || role == MemberRole.administrator;
    final label = switch (role) {
      MemberRole.creator => '创建者',
      MemberRole.administrator => '管理员',
      MemberRole.moderator => '版主',
      MemberRole.member => '成员',
    };
    return DecoratedBox(
      decoration: ShapeDecoration(
        shape: const StadiumBorder(),
        color: elevated ? scheme.primaryContainer : scheme.surfaceContainerHigh,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NeuSpacing.sm,
          vertical: NeuSpacing.xs,
        ),
        child: Text(
          label,
          style: theme.textTheme.labelSmall?.copyWith(
            color: elevated
                ? scheme.onPrimaryContainer
                : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _SpaceAbout extends StatelessWidget {
  const _SpaceAbout({
    required this.details,
    required this.rooms,
    required this.onEdit,
    required this.onManage,
    required this.onInvite,
    required this.onCopy,
    required this.onLeave,
  });
  final SpaceDetails details;
  final AsyncValue<List<ChatRoom>> rooms;
  final ValueChanged<_SpaceField>? onEdit;
  final VoidCallback? onInvite;
  final VoidCallback onManage, onCopy, onLeave;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final heading = materialSettingsSectionStyle(theme);
    final count = rooms.value?.where((room) => room.roomType != 'space').length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('空间资料', style: heading),
        ),
        GroupedRows(
          dividerIndent: NeuSpacing.lg,
          children: [
            ListTile(
              title: const Text('名称'),
              subtitle: Text(details.name),
              trailing: const Icon(Icons.edit_outlined),
              onTap: onEdit == null ? null : () => onEdit!(_SpaceField.name),
            ),
            ListTile(
              title: const Text('话题'),
              subtitle: Text(
                details.topic?.isNotEmpty == true ? details.topic! : '未设置',
              ),
              trailing: const Icon(Icons.edit_outlined),
              onTap: onEdit == null ? null : () => onEdit!(_SpaceField.topic),
            ),
            ListTile(
              title: const Text('房间'),
              subtitle: Text(
                count != null
                    ? '$count 个可见房间'
                    : rooms.hasError
                    ? '房间数暂不可用'
                    : '加载中…',
              ),
              onTap: onManage,
            ),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NeuSpacing.sm,
                vertical: NeuSpacing.xs,
              ),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: MaterialIdentityId(details.id),
              ),
            ),
          ],
        ),
        const SizedBox(height: NeuSpacing.lg),
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text('共享与管理', style: heading),
        ),
        GroupedRows(
          children: [
            ListTile(
              leading: const Icon(Icons.person_add_outlined),
              title: const Text('邀请成员'),
              subtitle: details.canInvite == false
                  ? const Text('当前账号没有邀请权限')
                  : null,
              enabled: onInvite != null,
              onTap: onInvite,
            ),
            ListTile(
              leading: const Icon(Icons.link),
              title: const Text('复制空间链接'),
              onTap: onCopy,
            ),
            const ListTile(
              leading: Icon(Icons.lock_outline),
              title: Text('隐私与加密'),
              subtitle: Text('每个房间有独立的加入规则与加密状态。'),
            ),
          ],
        ),
        const SizedBox(height: NeuSpacing.lg),
        OutlinedButton.icon(
          onPressed: onLeave,
          style: OutlinedButton.styleFrom(
            foregroundColor: theme.colorScheme.error,
          ),
          icon: const Icon(Icons.logout),
          label: const Text('退出空间'),
        ),
      ],
    );
  }
}
