import 'package:flutter/material.dart';

import '../../features/storage/storage_models.dart';
import '../../theme/storage_visual_theme.dart';
import '../../widgets/grouped_rows.dart';

class StorageOverviewCard extends StatelessWidget {
  const StorageOverviewCard({
    super.key,
    required this.snapshot,
    required this.onExplain,
  });
  final StorageSnapshot snapshot;
  final VoidCallback onExplain;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visuals = StorageVisualTheme.of(context);
    final systemTotal =
        snapshot.systemDataBytes != null && snapshot.appBytes != null
        ? snapshot.systemDataBytes! + snapshot.appBytes!
        : null;
    return GroupedRows(
      children: [
        Ink(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: visuals.heroColors,
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.storage_rounded, color: visuals.heroInk),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        systemTotal == null ? '本机应用文件' : '系统统计 · 总占用',
                        style: visuals.heroLabel(theme),
                      ),
                    ),
                    IconButton(
                      onPressed: onExplain,
                      tooltip: '用量统计说明',
                      icon: Icon(Icons.info_outline, color: visuals.heroInk),
                    ),
                  ],
                ),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    formatStorageBytes(systemTotal ?? snapshot.totalBytes),
                    style: visuals.heroNumber(theme),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '已扫描 ${snapshot.files.length} 个文件 · ${formatStorageBytes(snapshot.totalBytes)}',
                  style: visuals.heroLabel(theme),
                ),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) => Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      SizedBox(
                        width: (constraints.maxWidth - 16) / 2,
                        child: _metric(
                          context,
                          '当前可清理',
                          formatStorageBytes(snapshot.cleanableBytes),
                          Icons.cleaning_services_outlined,
                        ),
                      ),
                      SizedBox(
                        width: (constraints.maxWidth - 16) / 2,
                        child: _metric(
                          context,
                          snapshot.appBytes == null ? '保留或使用中' : '安装包与本地库',
                          formatStorageBytes(
                            snapshot.appBytes ??
                                snapshot.totalBytes - snapshot.cleanableBytes,
                          ),
                          Icons.apps_rounded,
                        ),
                      ),
                    ],
                  ),
                ),
                if (snapshot.freeBytes != null) ...[
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Icon(
                        Icons.sd_storage_outlined,
                        size: 16,
                        color: visuals.heroInk,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          '设备可用 ${formatStorageBytes(snapshot.freeBytes!)}',
                          style: visuals.heroLabel(theme),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _metric(
    BuildContext context,
    String label,
    String value,
    IconData icon,
  ) {
    final visuals = StorageVisualTheme.of(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(icon, size: 18, color: visuals.heroInk),
            const SizedBox(width: 6),
            Expanded(child: Text(label, style: visuals.heroLabel(theme))),
          ],
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(value, style: visuals.heroMetric(theme)),
        ),
      ],
    );
  }
}

Future<void> showStorageAccounting(
  BuildContext context,
  StorageSnapshot snapshot,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (context) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: .72,
    maxChildSize: .95,
    minChildSize: .4,
    builder: (context, scroll) => ListView(
      controller: scroll,
      padding: const EdgeInsets.all(20),
      children: [
        Text('系统与文件统计', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 12),
        const Text('系统总占用 = 安装文件 + 应用数据。系统缓存已包含在应用数据中，不会再次相加。'),
        const SizedBox(height: 16),
        GroupedRows(
          children: [
            if (snapshot.appBytes != null)
              _accountingRow('安装包与本地库', snapshot.appBytes!),
            if (snapshot.systemDataBytes != null)
              _accountingRow('系统统计 · 应用数据', snapshot.systemDataBytes!),
            if (snapshot.systemCacheBytes != null)
              _accountingRow('其中 · 系统缓存', snapshot.systemCacheBytes!),
            _accountingRow('应用文件扫描', snapshot.totalBytes),
            _accountingRow('可清理缓存', snapshot.cleanableBytes),
            _accountingRow(
              '保留或使用中的文件',
              snapshot.totalBytes - snapshot.cleanableBytes,
            ),
          ],
        ),
        if (snapshot.systemDataBytes != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              '系统数据与已扫描文件相差 ${snapshot.systemDataBytes! < snapshot.totalBytes ? '-' : '+'}${formatStorageBytes((snapshot.systemDataBytes! - snapshot.totalBytes).abs())}。文件分配空间、运行时数据和统计更新延迟会产生差额。',
            ),
          ),
        const Text('数据库、会话密钥、草稿和已保存的用户文件会保留。应用文件按实际字节统计，MiB = 1024² 字节。'),
        const SizedBox(height: 12),
        Text(
          '统计于 ${snapshot.measuredAt.toLocal().toString().split('.').first}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('明白了'),
        ),
      ],
    ),
  ),
);

Widget _accountingRow(String label, int bytes) =>
    ListTile(title: Text(label), trailing: Text(formatStorageBytes(bytes)));
