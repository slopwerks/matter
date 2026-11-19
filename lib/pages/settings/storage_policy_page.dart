import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../features/storage/storage_settings.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';
import 'storage_actions.dart';
import 'storage_number_picker.dart';
import 'storage_section.dart';

class StoragePolicyPage extends ConsumerStatefulWidget {
  const StoragePolicyPage({super.key});
  @override
  ConsumerState<StoragePolicyPage> createState() => _StoragePolicyPageState();
}

class _StoragePolicyPageState extends ConsumerState<StoragePolicyPage> {
  bool _saving = false;
  Future<void> _edit(StorageChatType type, {required bool days}) async {
    final settings = ref.read(storageSettingsProvider).asData?.value;
    if (settings == null) return;
    final policy = settings.policy(type);
    final value = await pickStorageNumber(
      context,
      '${type.label} · ${days ? '保留时长' : '空间上限'}',
      days ? policy.keepDays : policy.maxBytes ~/ storageMiB,
      days
          ? {0: '永久保留', 3: '3 天', 7: '7 天', 30: '30 天', 90: '90 天'}
          : storageCachePresets,
      unit: days ? '天' : 'MiB',
    );
    if (value == null || !mounted) return;
    final latest = ref.read(storageSettingsProvider).requireValue;
    final current = latest.policy(type);
    setState(() => _saving = true);
    try {
      await ref
          .read(storageSettingsProvider.notifier)
          .save(
            latest.copyWith(
              policies: {
                ...latest.policies,
                type: ChatStoragePolicy(
                  keepDays: days ? value : current.keepDays,
                  maxBytes: days ? current.maxBytes : value * storageMiB,
                ),
              },
            ),
          );
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('保存失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: context.neu.base,
    appBar: buildFloatingAppBar(
      title: const Text('保留策略'),
      actions: [
        IconButton(
          tooltip: '策略说明',
          onPressed: () => showStorageHelp(
            context,
            '保留策略',
            '按最近使用时间清理过期或超限的缓存。\n正在使用的文件暂不清理。\n聊天记录、密钥、草稿和已保存文件会保留。',
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
            data: (settings) => ListView(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
              children: [
                SizedBox(
                  height: 4,
                  child: _saving ? const LinearProgressIndicator() : null,
                ),
                for (final type in StorageChatType.values)
                  StorageSection(
                    title: type.label,
                    child: GroupedRows(
                      children: [
                        ListTile(
                          title: const Text('保留时长'),
                          subtitle: Text(
                            settings.policy(type).keepDays == 0
                                ? '永久保留'
                                : '${settings.policy(type).keepDays} 天',
                          ),
                          trailing: const Icon(Icons.unfold_more),
                          onTap: _saving ? null : () => _edit(type, days: true),
                        ),
                        ListTile(
                          title: const Text('空间上限'),
                          subtitle: Text(
                            settings.policy(type).maxBytes == 0
                                ? '不单独限制'
                                : formatStorageBytes(
                                    settings.policy(type).maxBytes,
                                  ),
                          ),
                          trailing: const Icon(Icons.unfold_more),
                          onTap: _saving
                              ? null
                              : () => _edit(type, days: false),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
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
