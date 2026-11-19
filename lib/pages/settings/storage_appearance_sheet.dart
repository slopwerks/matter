import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/storage/storage_appearance.dart';
import '../../features/storage/storage_breakdown.dart';
import '../../features/storage/storage_models.dart';
import '../../features/storage/storage_providers.dart';
import '../../features/storage/storage_settings.dart';
import '../../theme/storage_visual_theme.dart';
import 'storage_charts.dart';

Future<void> showStorageAppearance(
  BuildContext context, {
  StorageSnapshot? snapshot,
}) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  useSafeArea: true,
  builder: (_) => _StorageAppearanceSheet(snapshot: snapshot),
);

class _StorageAppearanceSheet extends ConsumerStatefulWidget {
  final StorageSnapshot? snapshot;
  const _StorageAppearanceSheet({this.snapshot});
  @override
  ConsumerState<_StorageAppearanceSheet> createState() =>
      _StorageAppearanceSheetState();
}

class _StorageAppearanceSheetState
    extends ConsumerState<_StorageAppearanceSheet> {
  bool _saving = false;
  @override
  Widget build(BuildContext context) {
    final settings =
        ref.watch(storageSettingsProvider).asData?.value ??
        const StorageSettings();
    final palette = settings.chartPalette;
    final visuals = StorageVisualTheme.of(context);
    final buckets = widget.snapshot == null
        ? const [
            StorageBucket(key: 'image', label: '图片', bytes: 45, colorIndex: 0),
            StorageBucket(key: 'video', label: '视频', bytes: 35, colorIndex: 1),
            StorageBucket(key: 'other', label: '其他', bytes: 20, colorIndex: 2),
          ]
        : storageBreakdown(widget.snapshot!);
    return ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(context).height * .85,
      ),
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.all(24),
        children: [
          Text('图表配色', style: Theme.of(context).textTheme.headlineSmall),
          const SizedBox(height: 8),
          const Text('颜色随明暗主题调整，选择后立即预览。'),
          const SizedBox(height: 12),
          Center(
            child: SizedBox.square(
              dimension: 154,
              child: StorageRingChart(
                buckets: buckets,
                palette: palette,
                child: Center(
                  child: Text(widget.snapshot == null ? '配色示意' : '实时预览'),
                ),
              ),
            ),
          ),
          RadioGroup<StoragePalette>(
            groupValue: palette,
            onChanged: (value) async {
              if (value == null || _saving) return;
              setState(() => _saving = true);
              try {
                await ref
                    .read(storageSettingsProvider.notifier)
                    .save(settings.copyWith(chartPalette: value));
              } catch (error) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context)
                      .showSnackBar(SnackBar(content: Text('保存配色失败：$error')));
                }
              } finally {
                if (mounted) setState(() => _saving = false);
              }
            },
            child: Column(
              children: [
                for (final preset in StoragePalette.values)
                  RadioListTile<StoragePalette>(
                    value: preset,
                    enabled: !_saving,
                    title: Text(preset.label),
                    secondary: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (var i = 0; i < 4; i++)
                          Padding(
                            padding: const EdgeInsets.only(left: 5),
                            child: CircleAvatar(
                              radius: 8,
                              backgroundColor: visuals.color(i, preset),
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('完成'),
          ),
        ],
      ),
    );
  }
}
