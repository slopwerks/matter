import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_surface.dart';

/// Presentation only; the host owns the log stream, filtering and scrolling.
class MaterialLogView extends StatelessWidget {
  const MaterialLogView({
    super.key,
    required this.total,
    required this.filteredCount,
    required this.scrollController,
    required this.searchController,
    required this.query,
    required this.levels,
    required this.selectedLevel,
    required this.tags,
    required this.tagCounts,
    required this.selectedTag,
    required this.onSearch,
    required this.onClearSearch,
    required this.onLevelSelected,
    required this.onTagSelected,
    required this.itemBuilder,
  });

  final int total;
  final int filteredCount;
  final ScrollController scrollController;
  final TextEditingController searchController;
  final String query;
  final List<({String? value, String label, int count})> levels;
  final String? selectedLevel;
  final List<String> tags;
  final Map<String, int> tagCounts;
  final String? selectedTag;
  final ValueChanged<String> onSearch;
  final VoidCallback onClearSearch;
  final ValueChanged<String?> onLevelSelected;
  final ValueChanged<String?> onTagSelected;
  final IndexedWidgetBuilder itemBuilder;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      top: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
    ),
    child: MaxContentWidth(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: SearchBar(
                    controller: searchController,
                    hintText: '搜索日志内容或标签',
                    leading: const Icon(Icons.search_rounded),
                    onChanged: onSearch,
                    trailing: [
                      if (query.isNotEmpty)
                        NeuIconButton(
                          icon: Icons.close_rounded,
                          tooltip: '清除搜索',
                          size: 36,
                          onPressed: onClearSearch,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                MenuAnchor(
                  style: const MenuStyle(
                    maximumSize: WidgetStatePropertyAll(Size(320, 360)),
                  ),
                  menuChildren: [
                    MenuItemButton(
                      onPressed: () => onTagSelected(null),
                      child: const Text('全部标签'),
                    ),
                    for (final tag in tags)
                      MenuItemButton(
                        onPressed: () => onTagSelected(tag),
                        leadingIcon: selectedTag == tag
                            ? const Icon(Icons.check_rounded)
                            : null,
                        child: SizedBox(
                          width: 200,
                          child: Text(
                            '$tag · ${tagCounts[tag]}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                  ],
                  builder: (context, controller, child) => NeuIconButton(
                    icon: Icons.label_outline_rounded,
                    tooltip: selectedTag == null ? '筛选标签' : '筛选标签：$selectedTag',
                    selected: selectedTag != null,
                    size: 48,
                    onPressed: controller.isOpen
                        ? controller.close
                        : () => controller.open(),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (var index = 0; index < levels.length; index++) ...[
                    if (index > 0) const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text(
                        '${levels[index].label} ${levels[index].count}',
                      ),
                      selected: selectedLevel == levels[index].value,
                      onSelected: (_) => onLevelSelected(levels[index].value),
                    ),
                  ],
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Row(
              children: [
                Expanded(
                  child: selectedTag == null
                      ? Text(
                          '长按日志可复制',
                          style: Theme.of(context).textTheme.bodySmall,
                        )
                      : Align(
                          alignment: Alignment.centerLeft,
                          child: InputChip(
                            label: Text(
                              selectedTag!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            onDeleted: () => onTagSelected(null),
                            deleteButtonTooltipMessage: '清除标签筛选',
                          ),
                        ),
                ),
                const SizedBox(width: 12),
                Text(
                  '$filteredCount/$total',
                  style: Theme.of(context).textTheme.labelMedium,
                ),
              ],
            ),
          ),
          Expanded(
            child: filteredCount == 0
                ? Center(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.article_outlined, size: 48),
                          const SizedBox(height: 16),
                          Text(
                            total == 0 ? '等待日志...' : '无匹配日志',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            total == 0 ? '新的运行日志会显示在这里。' : '调整搜索内容、级别或标签后重试。',
                            textAlign: TextAlign.center,
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    controller: scrollController,
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      16 + MediaQuery.paddingOf(context).bottom,
                    ),
                    itemCount: filteredCount,
                    itemBuilder: itemBuilder,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                  ),
          ),
        ],
      ),
    ),
  );
}

class MaterialLogEntry extends StatelessWidget {
  const MaterialLogEntry({
    super.key,
    required this.time,
    required this.level,
    required this.levelLabel,
    required this.tag,
    required this.message,
    required this.onCopy,
  });

  final String time;
  final String level;
  final String levelLabel;
  final String tag;
  final String message;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    final style = materialLogEntryStyle(Theme.of(context), level);
    return Material(
      color: style.fill,
      child: InkWell(
        onLongPress: onCopy,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(levelLabel, style: style.level),
                  Text(time, style: style.metadata),
                  Text(
                    tag,
                    style: style.metadata,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(message, style: style.message),
            ],
          ),
        ),
      ),
    );
  }
}
