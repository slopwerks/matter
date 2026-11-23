part of 'settings_page.dart';

enum _SettingsCategory {
  account('账号与安全', '账号切换与登录管理', Icons.manage_accounts_outlined),
  devices('设备与验证', '服务器、设备与加密恢复', Icons.devices_outlined),
  general('通用', '启动页面、交互模式与键盘', Icons.tune),
  appearance('外观与显示', '主题、配色与聊天外观', Icons.palette_outlined),
  notifications('通知', '推送与房间免打扰', Icons.notifications_outlined),
  storage('存储与缓存', '空间用量与清理策略', Icons.storage_outlined),
  about('帮助与关于', '版本、许可与诊断', Icons.info_outline);

  const _SettingsCategory(this.label, this.description, this.icon);
  final String label, description;
  final IconData icon;
}

extension _MaterialSettingsDirectory on _SettingsPageState {
  Widget _materialDirectory(
    Widget profile,
    Map<_SettingsCategory, List<_SettingItem>> groups,
    List<Widget> accountActions,
  ) {
    final selected = widget._category;
    if (selected != null) {
      final items = groups[selected] ?? [];
      return Scaffold(
        appBar: buildFloatingAppBar(title: Text(selected.label)),
        body: MaxContentWidth(
          child: ListView(
            padding: const EdgeInsets.all(NeuSpacing.lg),
            children: [
              if (items.isNotEmpty) GroupedRows(children: items),
              if (selected == _SettingsCategory.account) ...accountActions,
            ],
          ),
        ),
      );
    }
    final query = _query.trim().toLowerCase();
    final rows = <Widget>[];
    for (final category in _SettingsCategory.values) {
      final items = groups[category] ?? [];
      if (items.isEmpty &&
          !(category == _SettingsCategory.account &&
              accountActions.isNotEmpty)) {
        continue;
      }
      if (query.isEmpty || category.label.toLowerCase().contains(query)) {
        rows.add(
          _SettingItem(
            icon: category.icon,
            title: category.label,
            subtitle: category.description,
            onTap: () async {
              await MaterialListDetail.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => SettingsPage._detail(category),
                ),
              );
              if (mounted && category == _SettingsCategory.account) {
                await _loadAccounts();
              }
            },
          ),
        );
      } else {
        rows.addAll(
          items.where(
            (item) =>
                '${item.title} ${item.subtitle}'.toLowerCase().contains(query),
          ),
        );
      }
    }
    final header = MaterialRootHeader(
      title: '设置',
      compact: MaterialRootHeader.isCompact(context),
      search: AppSearchField(
        hint: '搜索设置或开关',
        onChanged: (value) => _setSettingsQuery(value),
      ),
    );
    return Scaffold(
      appBar: header,
      extendBodyBehindAppBar: true,
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          NeuSpacing.lg,
          NeuSpacing.lg +
              header.preferredSize.height +
              MediaQuery.paddingOf(context).top,
          NeuSpacing.lg,
          NeuSpacing.floatingDockClearance +
              MediaQuery.paddingOf(context).bottom,
        ),
        children: [
          if (query.isEmpty) ...[
            profile,
            const SizedBox(height: NeuSpacing.lg),
          ],
          if (rows.isEmpty)
            const Center(child: Text('没有匹配的设置项'))
          else
            GroupedRows(children: rows),
        ],
      ),
    );
  }
}
