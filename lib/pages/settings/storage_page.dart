import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_breakdown.dart';
import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../features/storage/storage_service.dart';
import '../../features/storage/storage_settings.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';
import 'storage_charts.dart';
import 'storage_chats_page.dart';
import 'storage_detail_page.dart';
import 'storage_overview_card.dart';
import 'storage_rooms_section.dart';
import 'storage_section.dart';
import 'storage_settings_page.dart';

class StoragePage extends ConsumerStatefulWidget {
  const StoragePage({super.key});
  @override
  ConsumerState<StoragePage> createState() => _StoragePageState();
}

class _StoragePageState extends ConsumerState<StoragePage> {
  bool _cleaning = false;
  void _open(Widget page) =>
      Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  void _openBucket(StorageBucket bucket) => _open(
    StorageDetailPage(
      title: bucket.label,
      kind: bucket.kind,
      chatType: bucket.chatType,
      crossTypeShared: bucket.crossTypeShared,
      applicationData: bucket.applicationData,
    ),
  );
  Future<void> _refresh() async {
    ref.invalidate(storageSnapshotProvider);
    await ref.read(storageSnapshotProvider.future);
  }

  Future<void> _runPolicy() async {
    setState(() => _cleaning = true);
    try {
      final result = await storageService.enforce(await loadStorageSettings());
      ref.read(storageLastCleanupProvider.notifier).set(result);
      await _refresh();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '已释放 ${formatStorageBytes(result.releasedBytes)}${result.errors.isEmpty ? '' : ' · ${result.errors.length} 项未完成'}',
            ),
          ),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('检查失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _cleaning = false);
    }
  }

  Widget _body(StorageSnapshot snapshot) {
    final settings =
        ref.watch(storageSettingsProvider).asData?.value ??
        const StorageSettings();
    final last = ref.watch(storageLastCleanupProvider);
    final overview = StorageOverviewCard(
      snapshot: snapshot,
      onExplain: () => showStorageAccounting(context, snapshot),
    );
    final composition = StorageCompositionCard(
      snapshot: snapshot,
      palette: settings.chartPalette,
      onOpen: _openBucket,
      onOpenAll: () => _open(const StorageDetailPage(title: '全部文件')),
    );
    final sharedBytes = snapshot.files
        .where((file) => file.owners.length > 1)
        .fold<int>(0, (sum, file) => sum + file.bytes);
    final otherBytes = snapshot.files
        .where((file) => file.owners.isEmpty && !file.applicationData)
        .fold<int>(0, (sum, file) => sum + file.bytes);
    final applicationBytes = snapshot.files
        .where((file) => file.applicationData)
        .fold<int>(0, (sum, file) => sum + file.bytes);
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.paddingOf(context).top + kToolbarHeight + 12,
          16,
          24,
        ),
        children: [
          LayoutBuilder(
            builder: (context, constraints) => constraints.maxWidth >= 840
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: overview),
                      const SizedBox(width: 16),
                      Expanded(child: composition),
                    ],
                  )
                : Column(
                    children: [
                      overview,
                      const SizedBox(height: 16),
                      composition,
                    ],
                  ),
          ),
          if (snapshot.warnings.isNotEmpty) ...[
            const SizedBox(height: 16),
            GroupedRows(
              children: [
                ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: Text('${snapshot.warnings.length} 项未完成统计'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('统计详情'),
                      content: SingleChildScrollView(
                        child: SelectableText(snapshot.warnings.join('\n\n')),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context),
                          child: const Text('关闭'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ],
          StorageRoomsSection(
            snapshot: snapshot,
            compact: true,
            onOpen: (key, name) =>
                _open(StorageDetailPage(title: name, room: key)),
            onOpenAll: () => _open(const StorageChatsPage()),
          ),
          StorageSection(
            title: '其他存储',
            child: GroupedRows(
              children: [
                ListTile(
                  leading: const Icon(Icons.folder_shared_outlined),
                  title: const Text('共用缓存'),
                  subtitle: Text(formatStorageBytes(sharedBytes)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(
                    const StorageDetailPage(title: '共用缓存', shared: true),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_open_outlined),
                  title: const Text('其他媒体'),
                  subtitle: Text(formatStorageBytes(otherBytes)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(
                    const StorageDetailPage(title: '其他媒体', unassigned: true),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.storage_outlined),
                  title: const Text('公共应用数据'),
                  subtitle: Text(formatStorageBytes(applicationBytes)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(
                    const StorageDetailPage(
                      title: '公共应用数据',
                      applicationData: true,
                    ),
                  ),
                ),
              ],
            ),
          ),
          StorageSection(
            title: '设置',
            child: GroupedRows(
              children: [
                ListTile(
                  leading: const Icon(Icons.tune),
                  title: const Text('下载与存储设置'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _open(const StorageSettingsPage()),
                ),
              ],
            ),
          ),
          if (last != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
              child: Text(
                '最近清理 ${formatStorageBytes(last.releasedBytes)} · ${last.removedFiles} 项',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(storageSnapshotProvider);
    final value = snapshot.hasValue ? snapshot.requireValue : null;
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(
        title: const Text('存储与数据'),
        actions: [
          IconButton(
            tooltip: '下载与存储设置',
            onPressed: () => _open(const StorageSettingsPage()),
            icon: const Icon(Icons.tune),
          ),
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (action) {
              if (action == 'refresh') {
                ref.invalidate(storageSnapshotProvider);
              } else if (action == 'policy') {
                _runPolicy();
              } else if (value != null) {
                showStorageAccounting(context, value);
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'refresh', child: Text('刷新统计')),
              PopupMenuItem(
                value: 'policy',
                enabled: !_cleaning,
                child: const Text('执行保留策略'),
              ),
              PopupMenuItem(
                value: 'help',
                enabled: value != null,
                child: const Text('统计说明'),
              ),
            ],
          ),
        ],
      ),
      body: MaxContentWidth(
        maxWidth: 960,
        child: snapshot.when(
          skipLoadingOnReload: true,
          data: _body,
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: FilledButton.icon(
              onPressed: () => ref.invalidate(storageSnapshotProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('读取失败，重试'),
            ),
          ),
        ),
      ),
      bottomNavigationBar: value == null
          ? null
          : SafeArea(
              top: false,
              child: Center(
                heightFactor: 1,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 960),
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: value.cleanableBytes == 0
                            ? null
                            : () => _open(
                                const StorageDetailPage(
                                  title: '可清理缓存',
                                  cleanableOnly: true,
                                ),
                              ),
                        icon: const Icon(Icons.cleaning_services_outlined),
                        label: Text(
                          value.cleanableBytes == 0
                              ? '暂无可清理缓存'
                              : '清理缓存 · ${formatStorageBytes(value.cleanableBytes)}',
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}
