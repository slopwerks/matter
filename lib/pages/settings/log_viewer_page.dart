import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../theme/app_theme.dart';

/// Provider that accumulates log entries from the Rust stream.
final logEntriesProvider = StateProvider<List<rust.AppLogEntry>>((ref) => []);

/// Whether the log stream is active.
final logStreamActiveProvider = StateProvider<bool>((ref) => false);

class LogViewerPage extends ConsumerStatefulWidget {
  const LogViewerPage({super.key});

  @override
  ConsumerState<LogViewerPage> createState() => _LogViewerPageState();
}

class _LogViewerPageState extends ConsumerState<LogViewerPage> {
  final _scrollController = ScrollController();
  bool _autoScroll = true;
  String? _levelFilter;
  String? _tagFilter;
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
      ref.read(logEntriesProvider.notifier).state = history;
    }

    // Start live stream
    final stream = rust.watchAppLogs();
    ref.read(logStreamActiveProvider.notifier).state = true;
    _logSubscription = stream.listen((entry) {
      final current = ref.read(logEntriesProvider);
      if (current.length > 500) {
        ref.read(logEntriesProvider.notifier).state = [
          ...current.skip(current.length - 499),
          entry,
        ];
      } else {
        ref.read(logEntriesProvider.notifier).state = [...current, entry];
      }
    });
  }

  @override
  void dispose() {
    _logSubscription?.cancel();
    _scrollController.dispose();
    super.dispose();
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

    final filtered = allLogs.where((log) {
      if (_levelFilter != null && log.level != _levelFilter) return false;
      if (_tagFilter != null && log.tag != _tagFilter) return false;
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
        title: const Text(
          '日志',
          style: TextStyle(
            color: AppColors.onBackground,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
        actions: [
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
              const PopupMenuItem(value: 'error', child: Text('❌ Error')),
              const PopupMenuItem(value: 'warn', child: Text('⚠️ Warn')),
              const PopupMenuItem(value: 'info', child: Text('ℹ️ Info')),
            ],
          ),
          IconButton(
            icon: const Icon(
              Icons.delete_outline_rounded,
              color: AppColors.onSurfaceVariant,
              size: 20,
            ),
            onPressed: () {
              ref.read(logEntriesProvider.notifier).state = [];
            },
            tooltip: '清空日志',
          ),
        ],
      ),
      body: Column(
        children: [
          // Status bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: AppColors.surfaceVariant.withValues(alpha: 0.3),
            child: Row(
              children: [
                _buildFilterChip(
                  label: '全部',
                  selected: _tagFilter == null,
                  onTap: () => setState(() => _tagFilter = null),
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  label: 'auth',
                  selected: _tagFilter == 'auth',
                  onTap: () => setState(() => _tagFilter = 'auth'),
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  label: 'sync',
                  selected: _tagFilter == 'sync',
                  onTap: () => setState(() => _tagFilter = 'sync'),
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  label: 'rooms',
                  selected: _tagFilter == 'rooms',
                  onTap: () => setState(() => _tagFilter = 'rooms'),
                ),
                const SizedBox(width: 6),
                _buildFilterChip(
                  label: 'media',
                  selected: _tagFilter == 'media',
                  onTap: () => setState(() => _tagFilter = 'media'),
                ),
              ],
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
