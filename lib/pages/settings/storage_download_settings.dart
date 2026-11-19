import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_download_policy.dart';
import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_settings.dart';
import '../../widgets/grouped_rows.dart';

class StorageDownloadSettings extends ConsumerStatefulWidget {
  const StorageDownloadSettings({
    super.key,
    required this.settings,
    required this.saving,
    required this.onChanged,
    required this.onEditLimit,
  });
  final StorageSettings settings;
  final bool saving;
  final ValueChanged<StorageSettings> onChanged;
  final void Function(DownloadProfile, StorageKind) onEditLimit;
  @override
  ConsumerState<StorageDownloadSettings> createState() =>
      _StorageDownloadSettingsState();
}

class _StorageDownloadSettingsState
    extends ConsumerState<StorageDownloadSettings> {
  DownloadProfile _profile = DownloadProfile.wifi;
  void _save(DownloadRules rules) => widget.onChanged(
    _profile == DownloadProfile.wifi
        ? widget.settings.copyWith(wifiDownloads: rules)
        : widget.settings.copyWith(mobileDownloads: rules),
  );

  @override
  Widget build(BuildContext context) {
    final connection =
        ref.watch(storageConnectionProvider).asData?.value ??
        StorageConnection.unknown;
    final rules = widget.settings.downloads(_profile);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<DownloadProfile>(
          segments: const [
            ButtonSegment(
              value: DownloadProfile.wifi,
              icon: Icon(Icons.wifi),
              label: Text('Wi-Fi / 有线'),
            ),
            ButtonSegment(
              value: DownloadProfile.mobile,
              icon: Icon(Icons.signal_cellular_alt),
              label: Text('移动数据'),
            ),
          ],
          selected: {_profile},
          onSelectionChanged: (value) =>
              setState(() => _profile = value.single),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Row(
            children: [
              Icon(switch (connection) {
                StorageConnection.wifi => Icons.wifi,
                StorageConnection.mobile => Icons.signal_cellular_alt,
                StorageConnection.offline => Icons.wifi_off,
                StorageConnection.unknown => Icons.network_check,
              }, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '当前：${connection.label}',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
        GroupedRows(
          children: [
            SwitchListTile(
              title: const Text('自动下载'),
              value: rules.enabled,
              onChanged: widget.saving
                  ? null
                  : (value) => _save(rules.copyWith(enabled: value)),
            ),
            for (final kind in downloadKinds)
              ListTile(
                leading: Icon(switch (kind) {
                  StorageKind.image => Icons.photo_outlined,
                  StorageKind.video => Icons.smart_display_outlined,
                  StorageKind.audio => Icons.headphones_outlined,
                  _ => Icons.insert_drive_file_outlined,
                }),
                title: Text(kind == StorageKind.image ? '图片原图' : kind.label),
                subtitle: Text(
                  (rules.limits[kind] ?? 0) == 0
                      ? '点击下载'
                      : '单个 ≤ ${formatStorageBytes(rules.limits[kind]!)}',
                ),
                trailing: const Icon(Icons.unfold_more),
                enabled: !widget.saving,
                onTap: widget.saving
                    ? null
                    : () => widget.onEditLimit(_profile, kind),
              ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 8, 0),
          child: Text('快速预设', style: theme.textTheme.bodySmall),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              ActionChip(
                avatar: const Icon(Icons.data_saver_on_outlined, size: 18),
                label: const Text('省流量'),
                onPressed: widget.saving
                    ? null
                    : () => _save(
                        const DownloadRules(
                          limits: {
                            StorageKind.image: storageMiB,
                            StorageKind.video: 0,
                            StorageKind.audio: 2 * storageMiB,
                            StorageKind.document: 0,
                          },
                        ),
                      ),
              ),
              ActionChip(
                avatar: const Icon(Icons.download_outlined, size: 18),
                label: const Text('常用'),
                onPressed: widget.saving
                    ? null
                    : () => _save(
                        const DownloadRules(
                          limits: {
                            StorageKind.image: 8 * storageMiB,
                            StorageKind.video: 20 * storageMiB,
                            StorageKind.audio: 5 * storageMiB,
                            StorageKind.document: 5 * storageMiB,
                          },
                        ),
                      ),
              ),
              ActionChip(
                avatar: const Icon(Icons.wifi, size: 18),
                label: const Text('宽松'),
                onPressed: widget.saving
                    ? null
                    : () => _save(
                        const DownloadRules(
                          limits: {
                            StorageKind.image: 50 * storageMiB,
                            StorageKind.video: 200 * storageMiB,
                            StorageKind.audio: 50 * storageMiB,
                            StorageKind.document: 50 * storageMiB,
                          },
                        ),
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
