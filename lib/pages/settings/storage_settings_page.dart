import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_locations.dart';
import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../features/storage/storage_settings.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';
import 'storage_actions.dart';
import 'storage_appearance_sheet.dart';
import 'storage_download_settings.dart';
import 'storage_number_picker.dart';
import 'storage_policy_page.dart';
import 'storage_section.dart';

class StorageSettingsPage extends ConsumerStatefulWidget {
  const StorageSettingsPage({super.key});
  @override
  ConsumerState<StorageSettingsPage> createState() =>
      _StorageSettingsPageState();
}

class _StorageSettingsPageState extends ConsumerState<StorageSettingsPage> {
  bool _saving = false;
  Future<void> _save(StorageSettings settings) async {
    setState(() => _saving = true);
    try {
      await ref.read(storageSettingsProvider.notifier).save(settings);
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editLimit(
    StorageSettings settings,
    DownloadProfile profile,
    StorageKind kind,
  ) async {
    final rules = settings.downloads(profile);
    final value = await pickStorageNumber(
      context,
      '${profile.label} · ${kind == StorageKind.image ? '图片原图' : kind.label}',
      (rules.limits[kind] ?? 0) ~/ storageMiB,
      {
        0: '点击下载',
        1: '1 MiB',
        5: '5 MiB',
        10: '10 MiB',
        20: '20 MiB',
        50: '50 MiB',
        100: '100 MiB',
        500: '500 MiB',
      },
      zeroLabel: '关闭自动下载',
    );
    if (value == null || !mounted) return;
    final updated = rules.copyWith(
      limits: {...rules.limits, kind: value * storageMiB},
    );
    await _save(
      profile == DownloadProfile.wifi
          ? settings.copyWith(wifiDownloads: updated)
          : settings.copyWith(mobileDownloads: updated),
    );
  }

  Widget _body(StorageSettings settings) => ListView(
    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
    children: [
      // Keep list indices stable so saving cannot recreate the network controls.
      SizedBox(
        height: 4,
        child: _saving ? const LinearProgressIndicator() : null,
      ),
      StorageSection(
        title: '自动下载',
        child: StorageDownloadSettings(
          settings: settings,
          saving: _saving,
          onChanged: _save,
          onEditLimit: (profile, kind) => _editLimit(settings, profile, kind),
        ),
      ),
      StorageSection(
        title: '保存位置',
        child: GroupedRows(
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open_outlined),
              title: const Text('下载目录'),
              subtitle: Text(
                settings.downloadDirectoryLabel ??
                    (supportsPersistentDownloadDirectory ? '系统下载目录' : '由系统选择'),
              ),
              trailing: supportsPersistentDownloadDirectory
                  ? const Icon(Icons.unfold_more)
                  : null,
              onTap: !supportsPersistentDownloadDirectory || _saving
                  ? null
                  : () async {
                      try {
                        final directory = await chooseDownloadDirectory();
                        if (directory != null && mounted) {
                          await _save(
                            settings.copyWith(
                              downloadDirectory: directory.path,
                              downloadDirectoryLabel: directory.label,
                            ),
                          );
                        }
                      } catch (error) {
                        if (mounted) {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('选择目录失败：$error')),
                          );
                        }
                      }
                    },
            ),
            if (settings.downloadDirectory != null)
              ListTile(
                leading: const Icon(Icons.restore),
                title: const Text('恢复系统目录'),
                onTap: _saving
                    ? null
                    : () => _save(settings.copyWith(resetDirectory: true)),
              ),
            if (supportsPersistentDownloadDirectory)
              SwitchListTile(
                title: const Text('每次询问保存位置'),
                value: settings.askSaveLocation,
                onChanged: _saving
                    ? null
                    : (value) =>
                          _save(settings.copyWith(askSaveLocation: value)),
              ),
          ],
        ),
      ),
      StorageSection(
        title: '缓存管理',
        child: GroupedRows(
          children: [
            ListTile(
              leading: const Icon(Icons.storage_outlined),
              title: const Text('空间上限'),
              subtitle: Text(
                settings.maxCacheBytes == 0
                    ? '不限制'
                    : formatStorageBytes(settings.maxCacheBytes),
              ),
              trailing: const Icon(Icons.unfold_more),
              onTap: _saving
                  ? null
                  : () async {
                      final value = await pickStorageNumber(
                        context,
                        '缓存空间上限',
                        settings.maxCacheBytes ~/ storageMiB,
                        storageCachePresets,
                      );
                      if (value != null && mounted) {
                        await _save(
                          settings.copyWith(maxCacheBytes: value * storageMiB),
                        );
                      }
                    },
            ),
            ListTile(
              leading: const Icon(Icons.auto_delete_outlined),
              title: const Text('保留策略'),
              subtitle: const Text('按聊天类型管理'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const StoragePolicyPage(),
                ),
              ),
            ),
          ],
        ),
      ),
      StorageSection(
        title: '外观',
        child: GroupedRows(
          children: [
            ListTile(
              leading: const Icon(Icons.palette_outlined),
              title: const Text('图表配色'),
              subtitle: Text(settings.chartPalette.label),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => showStorageAppearance(
                context,
                snapshot: ref.read(storageSnapshotProvider).asData?.value,
              ),
            ),
          ],
        ),
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.neu.base,
    appBar: buildFloatingAppBar(
      title: const Text('下载与存储设置'),
      actions: [
        IconButton(
          tooltip: '设置说明',
          onPressed: () => showStorageHelp(
            context,
            '下载与存储',
            '自动下载的文件进入应用缓存。\n未知大小需手动下载，未知网络采用更严格的规则。\n保存目录仅影响之后保存的文件。',
          ),
          icon: const Icon(Icons.info_outline),
        ),
      ],
    ),
    body: MaxContentWidth(
      maxWidth: 720,
      child: ref
          .watch(storageSettingsProvider)
          .when(
            data: _body,
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => Center(
              child: TextButton(
                onPressed: () => ref.invalidate(storageSettingsProvider),
                child: const Text('加载失败，重试'),
              ),
            ),
          ),
    ),
  );
}
