import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
import '../../widgets/neu_decoration.dart';
import '../../widgets/neu_field.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/sheets.dart';

/// Provider that accumulates log entries from the Rust stream.
final logEntriesProvider =
    NotifierProvider<
      MutableState<List<rust.AppLogEntry>>,
      List<rust.AppLogEntry>
    >(() => MutableState([]));

/// Whether the log stream is active.
final logStreamActiveProvider = NotifierProvider<MutableState<bool>, bool>(
  () => MutableState(false),
);

/// 日志级别展示元数据:颜色、中文名、单字母徽标。
({Color color, String label, String letter}) _levelMeta(
  NeuColors colors,
  String level,
) => switch (level) {
  'error' => (color: colors.error, label: '错误', letter: 'E'),
  'warn' => (color: colors.warning, label: '警告', letter: 'W'),
  'debug' => (color: colors.textTertiary, label: '调试', letter: 'D'),
  _ => (color: colors.accent, label: '信息', letter: 'I'),
};

/// 同一标签使用稳定颜色,扫读时一眼归类。
Color _tagColor(NeuColors colors, String tag) {
  final palette = [
    colors.accent,
    colors.success,
    colors.warning,
    colors.error,
    colors.textSecondary,
  ];
  var hash = 0;
  for (final unit in tag.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return palette[hash % palette.length];
}

class LogViewerPage extends ConsumerStatefulWidget {
  const LogViewerPage({super.key});

  @override
  ConsumerState<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends ConsumerState<LogViewerPage> {
  final _scrollController = ScrollController();
  final _searchController = TextEditingController();
  bool _autoScroll = true;
  String? _levelFilter;
  String? _tagFilter;
  String _searchQuery = '';
  StreamSubscription<rust.AppLogEntry>? _logSubscription;

  /// 级别筛选顺序:按严重程度递减。
  static const _levels = ['error', 'warn', 'info', 'debug'];

  @override
  void initState() {
    super.initState();
    // Defer to avoid modifying providers during build.
    Future.microtask(() => _connectLogStream());
  }

  void _connectLogStream() {
    // Load buffered history first
    final history = rust.getRecentLogs();
    if (history.isNotEmpty) {
      ref.read(logEntriesProvider.notifier).value = history;
    }

    // Start live stream
    final stream = rust.watchAppLogs();
    ref.read(logStreamActiveProvider.notifier).value = true;
    _logSubscription = stream.listen((entry) {
      final current = ref.read(logEntriesProvider);
      if (current.length >= 5000) {
        ref.read(logEntriesProvider.notifier).value = [
          ...current.skip(current.length - 4999),
          entry,
        ];
      } else {
        ref.read(logEntriesProvider.notifier).value = [...current, entry];
      }
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _clearLogs() {
    rust.clearAppLogs();
    ref.read(logEntriesProvider.notifier).value = [];
  }

  void _scrollToBottom() {
    if (_autoScroll && _scrollController.hasClients) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // 回调执行时列表可能已不在树上(筛选后为空、页面已销毁),
        // 必须重新检查挂载状态。
        if (!mounted || !_scrollController.hasClients) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final allLogs = ref.watch(logEntriesProvider);
    final tagCounts = <String, int>{};
    final levelCounts = <String, int>{};
    for (final log in allLogs) {
      tagCounts[log.tag] = (tagCounts[log.tag] ?? 0) + 1;
      levelCounts[log.level] = (levelCounts[log.level] ?? 0) + 1;
    }
    final tags = tagCounts.keys.toList()..sort();
    final query = _searchQuery.trim().toLowerCase();

    final filtered = allLogs.where((log) {
      if (_levelFilter != null && log.level != _levelFilter) return false;
      if (_tagFilter != null && log.tag != _tagFilter) return false;
      if (query.isNotEmpty &&
          !log.message.toLowerCase().contains(query) &&
          !log.tag.toLowerCase().contains(query) &&
          !log.level.toLowerCase().contains(query)) {
        return false;
      }
      return true;
    }).toList();

    // Auto scroll when new logs come in
    _scrollToBottom();

    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(
              title: Text('日志 (${allLogs.length})'),
              actions: [
                IconButton(
                  icon: Icon(
                    _autoScroll
                        ? Icons.vertical_align_bottom
                        : Icons.vertical_align_top,
                  ),
                  tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
                  onPressed: () => setState(() => _autoScroll = !_autoScroll),
                ),
                IconButton(
                  icon: const Icon(Icons.delete_outline),
                  tooltip: '清空日志',
                  onPressed: allLogs.isEmpty ? null : _clearLogs,
                ),
              ],
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: Padding(
              // 标题栏移到上方浮层,内容从它下方开始。
              padding: EdgeInsets.only(
                top: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
              ),
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NeuSpacing.lg,
                      NeuSpacing.sm,
                      NeuSpacing.lg,
                      0,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: NeuTextField(
                            controller: _searchController,
                            hint: '搜索日志内容或标签',
                            radius: context.isMaterial ? 28 : NeuRadius.content,
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            leading: const Icon(Icons.search_rounded),
                            trailing: _searchQuery.isEmpty
                                ? null
                                : GestureDetector(
                                    onTap: () {
                                      _searchController.clear();
                                      setState(() => _searchQuery = '');
                                    },
                                    child: const Icon(Icons.close_rounded),
                                  ),
                            onChanged: (value) =>
                                setState(() => _searchQuery = value),
                          ),
                        ),
                        const SizedBox(width: NeuSpacing.sm),
                        _TagFilterButton(
                          tags: tags,
                          counts: tagCounts,
                          selected: _tagFilter,
                          onSelected: (tag) => setState(() => _tagFilter = tag),
                        ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      NeuSpacing.lg,
                      NeuSpacing.sm,
                      NeuSpacing.lg,
                      NeuSpacing.xs,
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            child: Row(
                              children: [
                                _LevelPill(
                                  label: '全部',
                                  count: allLogs.length,
                                  color: colors.textSecondary,
                                  selected: _levelFilter == null,
                                  onTap: () =>
                                      setState(() => _levelFilter = null),
                                ),
                                for (final level in _levels) ...[
                                  const SizedBox(width: NeuSpacing.xs),
                                  _LevelPill(
                                    label: _levelMeta(colors, level).label,
                                    count: levelCounts[level] ?? 0,
                                    color: _levelMeta(colors, level).color,
                                    selected: _levelFilter == level,
                                    onTap: () =>
                                        setState(() => _levelFilter = level),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(width: NeuSpacing.sm),
                        Text(
                          '${filtered.length}/${allLogs.length}',
                          style: textTheme.labelSmall?.copyWith(
                            color: colors.textTertiary,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(
                        NeuSpacing.lg,
                        NeuSpacing.xs,
                        NeuSpacing.lg,
                        NeuSpacing.lg,
                      ),
                      child: NeuSurface(
                        depth: NeuDepth.pressed,
                        radius: NeuRadius.content,
                        intensity: .8,
                        padding: const EdgeInsets.all(NeuSpacing.sm),
                        child: filtered.isEmpty
                            ? Center(
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.article_outlined,
                                      color: colors.textTertiary,
                                      size: 48,
                                    ),
                                    const SizedBox(height: 12),
                                    Text(
                                      allLogs.isEmpty ? '等待日志...' : '无匹配日志',
                                      style: textTheme.bodyMedium,
                                    ),
                                  ],
                                ),
                              )
                            : ListView.builder(
                                controller: _scrollController,
                                padding: EdgeInsets.zero,
                                itemCount: filtered.length,
                                itemBuilder: (context, index) {
                                  return _LogEntryTile(entry: filtered[index]);
                                },
                              ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: MediaQuery.viewPaddingOf(context).top + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
          // 标题栏移到上方浮层,滚动内容从它下方穿过。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Padding(
                    padding: const EdgeInsets.only(
                      left: NeuSpacing.sm,
                      right: NeuSpacing.md,
                    ),
                    child: Row(
                      children: [
                        NeuIconButton(
                          icon: Icons.arrow_back_ios_new_rounded,
                          size: 36,
                          tooltip: '返回',
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                        const SizedBox(width: NeuSpacing.sm),
                        Expanded(
                          child: Text(
                            '日志 (${allLogs.length})',
                            style: textTheme.titleLarge,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        NeuIconButton(
                          icon: _autoScroll
                              ? Icons.vertical_align_bottom_rounded
                              : Icons.vertical_align_top_rounded,
                          size: 36,
                          tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
                          onPressed: () =>
                              setState(() => _autoScroll = !_autoScroll),
                        ),
                        const SizedBox(width: NeuSpacing.xs),
                        NeuIconButton(
                          icon: Icons.delete_outline_rounded,
                          size: 36,
                          tooltip: '清空日志',
                          onPressed: allLogs.isEmpty ? null : _clearLogs,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 级别筛选小药丸:彩色圆点 + 名称 + 计数,选中时用级别色描边/淡底。
class _LevelPill extends StatelessWidget {
  final String label;
  final int count;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _LevelPill({
    required this.label,
    required this.count,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? color.withValues(alpha: .14) : colors.surface,
          borderRadius: BorderRadius.circular(NeuRadius.nav),
          border: Border.all(
            color: selected ? color : colors.hairline,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 7,
              height: 7,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(
              '$label $count',
              style: textTheme.labelSmall?.copyWith(
                color: selected ? color : colors.textSecondary,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 标签筛选:紧凑按钮 + 弹出菜单(带每个标签的条数)。
class _TagFilterButton extends StatelessWidget {
  final List<String> tags;
  final Map<String, int> counts;
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _TagFilterButton({
    required this.tags,
    required this.counts,
    required this.selected,
    required this.onSelected,
  });

  Future<void> _showMenu(BuildContext context) async {
    final colors = context.neu;
    final box = context.findRenderObject() as RenderBox;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;
    final position = RelativeRect.fromRect(
      Rect.fromPoints(
        box.localToGlobal(Offset.zero, ancestor: overlay),
        box.localToGlobal(box.size.bottomRight(Offset.zero), ancestor: overlay),
      ),
      Offset.zero & overlay.size,
    );
    final textStyle = Theme.of(context).textTheme.bodySmall;
    final picked = await showMenu<String?>(
      context: context,
      position: position,
      constraints: const BoxConstraints(maxHeight: 320),
      items: [
        PopupMenuItem<String?>(
          value: null,
          height: 36,
          child: Text('全部标签', style: textStyle),
        ),
        for (final tag in tags)
          PopupMenuItem<String?>(
            value: tag,
            height: 36,
            child: Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: BoxDecoration(
                    color: _tagColor(colors, tag),
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    tag,
                    style: textStyle,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '${counts[tag]}',
                  style: textStyle?.copyWith(color: colors.textTertiary),
                ),
              ],
            ),
          ),
      ],
    );
    if (picked != null || selected != null) {
      onSelected(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final active = selected != null;
    final color = active ? _tagColor(colors, selected!) : colors.textSecondary;
    return GestureDetector(
      onTap: () => _showMenu(context),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 140),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
        decoration: BoxDecoration(
          color: active ? color.withValues(alpha: .14) : colors.surface,
          borderRadius: BorderRadius.circular(NeuRadius.content),
          border: Border.all(color: active ? color : colors.hairline, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.label_outline_rounded, size: 14, color: color),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                selected ?? '标签',
                style: textTheme.labelSmall?.copyWith(
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: color),
          ],
        ),
      ),
    );
  }
}

class _LogEntryTile extends StatelessWidget {
  final rust.AppLogEntry entry;

  const _LogEntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final time = DateTime.fromMillisecondsSinceEpoch(entry.timestamp.toInt());
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';

    final meta = _levelMeta(colors, entry.level);
    final tagColor = _tagColor(colors, entry.tag);
    final messageColor = switch (entry.level) {
      'error' => colors.error,
      'warn' => colors.warning,
      'debug' => colors.textTertiary,
      _ => colors.textSecondary,
    };

    return GestureDetector(
      onLongPress: () {
        // Copy log entry
        final text =
            '[$timeStr] [${entry.level.toUpperCase()}] [${entry.tag}] ${entry.message}';
        Clipboard.setData(ClipboardData(text: text));
        neuToast(context, '已复制');
      },
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: entry.level == 'error'
              ? colors.error.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(NeuRadius.tag),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 级别徽标:单字母 + 级别色。
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Container(
                width: 17,
                height: 17,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: meta.color.withValues(alpha: .16),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(
                  meta.letter,
                  style: textTheme.labelSmall?.copyWith(
                    color: meta.color,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    height: 1,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        timeStr,
                        style: textTheme.labelSmall?.copyWith(
                          color: colors.textTertiary,
                          fontFamily: 'monospace',
                          fontSize: 10.5,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: tagColor.withValues(alpha: .13),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            entry.tag,
                            style: textTheme.labelSmall?.copyWith(
                              color: tagColor,
                              fontSize: 10.5,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'monospace',
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    entry.message,
                    style: textTheme.bodySmall?.copyWith(
                      color: messageColor,
                      fontFamily: 'monospace',
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
