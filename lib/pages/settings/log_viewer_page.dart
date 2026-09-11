import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/neu_colors.dart';
import '../../widgets/neu_chip_tray.dart';
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

  static const _levelOptions = [
    (null, '全部'),
    ('error', '错误'),
    ('warn', '警告'),
    ('info', '信息'),
  ];

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
    final tags = allLogs.map((log) => log.tag).toSet().toList()..sort();
    final errorCount = allLogs.where((log) => log.level == 'error').length;
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
      appBar: AppBar(
        backgroundColor: colors.base,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Text('日志 (${allLogs.length})', style: textTheme.titleMedium),
        actions: [
          NeuIconButton(
            icon: _autoScroll
                ? Icons.vertical_align_bottom_rounded
                : Icons.vertical_align_top_rounded,
            size: 40,
            tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
          ),
          const SizedBox(width: 4),
          NeuIconButton(
            icon: Icons.delete_outline_rounded,
            size: 40,
            tooltip: '清空日志',
            onPressed: allLogs.isEmpty ? null : _clearLogs,
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              NeuSpacing.sm,
              NeuSpacing.lg,
              0,
            ),
            child: NeuTextField(
              controller: _searchController,
              hint: '搜索日志内容或标签',
              leading: const Icon(Icons.search_rounded),
              trailing: _searchQuery.isEmpty
                  ? null
                  : NeuIconButton(
                      icon: Icons.close_rounded,
                      size: 32,
                      tooltip: '清除搜索',
                      onPressed: () {
                        _searchController.clear();
                        setState(() => _searchQuery = '');
                      },
                    ),
              onChanged: (value) => setState(() => _searchQuery = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              NeuSpacing.md,
              NeuSpacing.lg,
              0,
            ),
            child: Row(
              children: [
                for (final (value, label) in _levelOptions) ...[
                  NeuChip(
                    label: label,
                    selected: _levelFilter == value,
                    onTap: () => setState(() => _levelFilter = value),
                  ),
                  const SizedBox(width: NeuSpacing.sm),
                ],
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              NeuSpacing.lg,
              NeuSpacing.md,
              NeuSpacing.lg,
              NeuSpacing.sm,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '显示 ${filtered.length}/${allLogs.length} 条${errorCount > 0 ? '，错误 $errorCount 条' : ''}',
                  style: textTheme.bodySmall,
                ),
                const SizedBox(height: NeuSpacing.sm),
                NeuChipTray(
                  children: [
                    NeuChip(
                      label: '全部',
                      selected: _tagFilter == null,
                      onTap: () => setState(() => _tagFilter = null),
                    ),
                    for (final tag in tags)
                      NeuChip(
                        label: tag,
                        selected: _tagFilter == tag,
                        onTap: () => setState(() => _tagFilter = tag),
                      ),
                  ],
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
                padding: const EdgeInsets.all(NeuSpacing.md),
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

    final levelColor = switch (entry.level) {
      'error' => colors.error,
      'warn' => colors.warning,
      _ => colors.textSecondary,
    };

    final levelIcon = switch (entry.level) {
      'error' => '❌',
      'warn' => '⚠️',
      _ => 'ℹ️',
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
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: entry.level == 'error'
              ? colors.error.withValues(alpha: 0.08)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(NeuRadius.tag),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 70,
              child: Text(
                timeStr,
                style: textTheme.labelSmall?.copyWith(
                  color: colors.textTertiary,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            SizedBox(
              width: 20,
              child: Text(levelIcon, style: textTheme.labelSmall),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: colors.accentSoft,
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                entry.tag,
                style: textTheme.labelSmall?.copyWith(
                  color: colors.accent,
                  fontWeight: FontWeight.w600,
                  fontFamily: 'monospace',
                ),
              ),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                entry.message,
                style: textTheme.bodySmall?.copyWith(
                  color: levelColor,
                  fontFamily: 'monospace',
                  height: 1.3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
