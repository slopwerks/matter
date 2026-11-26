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

  /// Picks the app font: the platform font, a system family, or a file.
  Future<void> _chooseFont() async {
    final current = ref.read(appFontProvider);
    final families = await ref.read(systemFontFamiliesProvider.future);
    if (!mounted) return;
    final action = await showNeuSheet<String>(
      context: context,
      child: Builder(
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NeuSheetItem(
              icon: current == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '跟随系统',
              onTap: () => Navigator.pop(sheet, 'system'),
            ),
            if (families.isNotEmpty)
              NeuSheetItem(
                icon: Icons.font_download_outlined,
                label: '系统字体',
                onTap: () => Navigator.pop(sheet, 'families'),
              ),
            NeuSheetItem(
              icon: Icons.folder_open_rounded,
              label: current is PickedFontChoice ? '更换字体文件' : '选择字体文件',
              onTap: () => Navigator.pop(sheet, 'file'),
            ),
            NeuSheetItem(
              icon: Icons.layers_outlined,
              label: '回退字体',
              onTap: () => Navigator.pop(sheet, 'fallback'),
            ),
            if (current != null)
              NeuSheetItem(
                icon: Icons.delete_outline_rounded,
                label: '移除自定义字体',
                onTap: () => Navigator.pop(sheet, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final notifier = ref.read(appFontProvider.notifier);
    switch (action) {
      case 'system':
      case 'remove':
        await notifier.reset();
      case 'families':
        final family = await _chooseSystemFamily(families);
        if (family != null) await notifier.selectSystemFamily(family);
      case 'fallback':
        await _chooseFallbackFont();
      case 'file':
        final picked = await notifier.pickFile();
        if (!mounted) return;
        neuToast(context, picked ? '字体已更新' : '没有读取到字体文件');
    }
  }

  /// Fonts tried when the main font has no glyph, e.g. a Chinese serif used
  /// under a Latin-only family.
  Future<void> _chooseFallbackFont() async {
    final current = ref.read(fallbackFontProvider);
    final families = await ref.read(systemFontFamiliesProvider.future);
    if (!mounted) return;
    final action = await showNeuSheet<String>(
      context: context,
      child: Builder(
        builder: (sheet) => Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            NeuSheetItem(
              icon: current == null
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              label: '跟随系统',
              onTap: () => Navigator.pop(sheet, 'system'),
            ),
            if (families.isNotEmpty)
              NeuSheetItem(
                icon: Icons.font_download_outlined,
                label: '系统字体',
                onTap: () => Navigator.pop(sheet, 'families'),
              ),
            NeuSheetItem(
              icon: Icons.folder_open_rounded,
              label: switch (current) {
                FileFallback(:final name) => '更换字体文件（$name）',
                _ => '选择字体文件',
              },
              onTap: () => Navigator.pop(sheet, 'file'),
            ),
            if (current != null)
              NeuSheetItem(
                icon: Icons.delete_outline_rounded,
                label: '移除回退字体',
                onTap: () => Navigator.pop(sheet, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (!mounted || action == null) return;
    final notifier = ref.read(fallbackFontProvider.notifier);
    switch (action) {
      case 'system':
      case 'remove':
        await notifier.reset();
      case 'families':
        final family = await _pickFamily(families);
        if (family != null) await notifier.selectFamily(family);
      case 'file':
        final picked = await notifier.pickFile();
        if (!mounted) return;
        neuToast(context, picked ? '回退字体已更新' : '没有读取到字体文件');
    }
  }

  /// Family list sheet shared by the main and the fallback picker.
  Future<String?> _pickFamily(List<String> families) {
    final active = switch (ref.read(fallbackFontProvider)) {
      FamilyFallback(:final family) => family,
      _ => null,
    };
    return _chooseSystemFamily(families, active: active);
  }

  Future<String?> _chooseSystemFamily(List<String> families, {String? active}) {
    final current =
        active ??
        switch (ref.read(appFontProvider)) {
          SystemFontChoice(:final family) => family,
          _ => null,
        };
    return showNeuSheet<String>(
      context: context,
      child: Builder(
        builder: (sheet) => ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 420),
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final family in families)
                NeuSheetItem(
                  icon: family == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  label: family,
                  onTap: () => Navigator.pop(sheet, family),
                ),
            ],
          ),
        ),
      ),
    );
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
