import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../features/diagnostics/diagnostic_exporter.dart';
import '../../providers/mutable_state.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

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
  bool _exporting = false;
  String? _levelFilter;
  String? _tagFilter;
  String _searchQuery = '';
  StreamSubscription<rust.AppLogEntry>? _logSubscription;

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

  Future<void> _exportDiagnostics() async {
    if (_exporting) return;
    setState(() => _exporting = true);
    try {
      final saved = await const DiagnosticExporter().export();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(saved ? '诊断报告已导出' : '已取消导出')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('导出诊断报告失败：$error')));
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
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
      backgroundColor: AppColors.background,
      appBar: AppBar(
        backgroundColor: AppColors.background,
        elevation: 0,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_rounded,
            color: AppColors.onBackground,
          ),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          '日志 (${allLogs.length})',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
          _exporting
              ? const Padding(
                  padding: EdgeInsets.all(12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : IconButton(
                  icon: const Icon(
                    Icons.file_download_outlined,
                    color: AppColors.onSurfaceVariant,
                    size: 20,
                  ),
                  onPressed: _exportDiagnostics,
                  tooltip: '导出诊断报告',
                ),
          IconButton(
            icon: Icon(
              _autoScroll
                  ? Icons.vertical_align_bottom_rounded
                  : Icons.vertical_align_top_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            onPressed: () => setState(() => _autoScroll = !_autoScroll),
            tooltip: _autoScroll ? '自动滚动: 开' : '自动滚动: 关',
          ),
          PopupMenuButton<String>(
            icon: const Icon(
              Icons.filter_list_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            color: AppColors.surface,
            onSelected: (value) {
              setState(() {
                if (value == 'all') {
                  _levelFilter = null;
                } else {
                  _levelFilter = value;
                }
              });
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'all', child: Text('全部级别')),
              const PopupMenuItem(value: 'error', child: Text('错误')),
              const PopupMenuItem(value: 'warn', child: Text('警告')),
              const PopupMenuItem(value: 'info', child: Text('信息')),
            ],
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            onPressed: allLogs.isEmpty ? null : _clearLogs,
            tooltip: '清空日志',
          ),
        ],
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.surfaceVariant.withValues(alpha: 0.3),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '显示 ${filtered.length}/${allLogs.length} 条${errorCount > 0 ? '，错误 $errorCount 条' : ''}',
                  style: const TextStyle(
                    color: AppColors.onSurfaceVariant,
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 8),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildFilterChip(
                        label: '全部',
                        selected: _tagFilter == null,
                        onTap: () => setState(() => _tagFilter = null),
                      ),
                      for (final tag in tags) ...[
                        const SizedBox(width: 6),
                        _buildFilterChip(
                          label: tag,
                          selected: _tagFilter == tag,
                          onTap: () => setState(() => _tagFilter = tag),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              controller: _searchController,
              onChanged: (value) => setState(() => _searchQuery = value),
              style: const TextStyle(
                color: AppColors.onBackground,
                fontSize: 13,
              ),
              decoration: InputDecoration(
                hintText: '搜索日志内容或标签',
                hintStyle: const TextStyle(
                  color: AppColors.onSurfaceVariant,
                  fontSize: 13,
                ),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  color: AppColors.onSurfaceVariant,
                  size: 20,
                ),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        color: AppColors.onSurfaceVariant,
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                        tooltip: '清除搜索',
                      ),
                filled: true,
                fillColor: AppColors.surfaceVariant.withValues(alpha: 0.45),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide.none,
                ),
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.article_outlined,
                          color: AppColors.onSurfaceVariant,
                          size: 48,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          allLogs.isEmpty ? '等待日志...' : '无匹配日志',
                          style: const TextStyle(
                            color: AppColors.onSurfaceVariant,
                            fontSize: 15,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: filtered.length,
                    itemBuilder: (context, index) {
                      return _LogEntryTile(entry: filtered[index]);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterChip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppColors.primary : AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadii.tag),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: selected ? Colors.white : AppColors.onSurfaceVariant,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          ),
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
    final time = DateTime.fromMillisecondsSinceEpoch(entry.timestamp.toInt());
    final timeStr =
        '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}.${time.millisecond.toString().padLeft(3, '0')}';

    final levelColor = switch (entry.level) {
      'error' => AppColors.error,
      'warn' => const Color(0xFFFFA726),
      _ => AppColors.onSurfaceVariant,
    };

    final levelIcon = switch (entry.level) {
      'error' => '❌',
      'warn' => '⚠️',
      _ => 'ℹ️',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
      child: GestureDetector(
        onLongPress: () {
          // Copy log entry
          final text =
              '[$timeStr] [${entry.level.toUpperCase()}] [${entry.tag}] ${entry.message}';
          Clipboard.setData(ClipboardData(text: text));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('已复制'),
              duration: Duration(seconds: 1),
            ),
          );
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: entry.level == 'error'
                ? AppColors.error.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 70,
                child: Text(
                  timeStr,
                  style: TextStyle(
                    color: AppColors.onSurfaceVariant.withValues(alpha: 0.6),
                    fontSize: 10.5,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              SizedBox(
                width: 20,
                child: Text(levelIcon, style: const TextStyle(fontSize: 10)),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: AppColors.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  entry.tag,
                  style: TextStyle(
                    color: AppColors.primary.withValues(alpha: 0.8),
                    fontSize: 9.5,
                    fontWeight: FontWeight.w600,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  entry.message,
                  style: TextStyle(
                    color: levelColor,
                    fontSize: 12,
                    fontFamily: 'monospace',
                    height: 1.3,
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
