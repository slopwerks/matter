part of 'settings_page.dart';

enum _SettingsCategory {
  appearance('外观与显示'),
  general('通用与输入'),
  chat('聊天与通知'),
  account('账号与安全'),
  devices('设备与连接'),
  storage('存储与缓存'),
  about('帮助与关于');

  const _SettingsCategory(this.label);
  final String label;
}

extension _MaterialSettingsDirectory on _SettingsPageState {
  Future<void> _choosePreference<T>(
    List<T> options,
    T current,
    String Function(T) label,
    ValueChanged<T> select,
  ) async {
    final selected = await showNeuSheet<T>(
      context: context,
      child: Builder(
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final option in options)
              NeuSheetItem(
                icon: option == current
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                label: label(option),
                onTap: () => Navigator.pop(sheet, option),
              ),
          ],
        ),
      ),
    );
    if (mounted && selected != null) select(selected);
  }

  Widget _materialDirectory(
    Widget profile,
    Map<_SettingsCategory, List<_SettingItem>> groups,
  ) {
    final query = _query.trim().toLowerCase();
    final sections = <Widget>[];
    for (final category in _SettingsCategory.values) {
      final items = groups[category] ?? const <_SettingItem>[];
      final matches = category.label.toLowerCase().contains(query)
          ? items
          : items
                .where(
                  (item) => '${item.title} ${item.subtitle} ${item.keywords}'
                      .toLowerCase()
                      .contains(query),
                )
                .toList();
      if (matches.isNotEmpty) {
        sections.add(_buildGroup(title: category.label, items: matches));
      }
    }
    return Scaffold(
      resizeToAvoidBottomInset: false,
      body: MaterialSearchDirectory(
        title: '设置',
        hint: '搜索设置或开关',
        query: _query,
        searchBuilder: (focus) => AppSearchField(
          controller: _searchController,
          focusNode: focus,
          hint: '搜索设置或开关',
          onChanged: (value) => _setSettingsQuery(value),
          trailing: _query.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  icon: const Icon(Icons.close_rounded),
                  onPressed: () {
                    _searchController.clear();
                    _setSettingsQuery('');
                  },
                ),
        ),

        body: ListView(
          padding: EdgeInsets.fromLTRB(
            NeuSpacing.lg,
            NeuSpacing.lg,
            NeuSpacing.lg,
            math.max(
              NeuSpacing.floatingDockClearance +
                  MediaQuery.paddingOf(context).bottom,
              MediaQuery.viewInsetsOf(context).bottom + NeuSpacing.lg,
            ),
          ),
          children: [
            if (query.isEmpty) ...[
              profile,
              const SizedBox(height: NeuSpacing.lg),
            ],
            if (sections.isEmpty)
              const Center(child: Text('没有匹配的设置项'))
            else
              for (final section in sections) ...[
                section,
                const SizedBox(height: NeuSpacing.xl),
              ],
          ],
        ),
      ),
    );
  }
}
