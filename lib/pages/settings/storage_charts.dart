import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../features/storage/storage_appearance.dart';
import '../../features/storage/storage_breakdown.dart';
import '../../features/storage/storage_models.dart';
import '../../theme/storage_visual_theme.dart';
import '../../widgets/grouped_rows.dart';

class StorageRingChart extends StatelessWidget {
  const StorageRingChart({
    super.key,
    required this.buckets,
    required this.palette,
    this.selected,
    this.onSelected,
    this.child,
  });
  final List<StorageBucket> buckets;
  final StoragePalette palette;
  final String? selected;
  final ValueChanged<String?>? onSelected;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final total = buckets.fold<int>(0, (sum, bucket) => sum + bucket.bytes);
    final visuals = StorageVisualTheme.of(context);
    return Semantics(
      label:
          '存储占比图，${buckets.map((b) => '${b.label} ${formatStorageBytes(b.bytes)}').join('，')}',
      child: LayoutBuilder(
        builder: (context, constraints) => GestureDetector(
          onTapUp: onSelected == null
              ? null
              : (details) {
                  final center = Offset(
                    constraints.maxWidth / 2,
                    constraints.maxHeight / 2,
                  );
                  final offset = details.localPosition - center;
                  final radius =
                      math.min(constraints.maxWidth, constraints.maxHeight) / 2;
                  if (total == 0 ||
                      offset.distance < radius - 35 ||
                      offset.distance > radius) {
                    onSelected!(null);
                    return;
                  }
                  final angle =
                      (math.atan2(offset.dy, offset.dx) +
                          math.pi / 2 +
                          2 * math.pi) %
                      (2 * math.pi);
                  var cursor = 0.0;
                  for (final bucket in buckets) {
                    cursor += bucket.bytes / total * math.pi * 2;
                    if (angle < cursor) {
                      onSelected!(bucket.key);
                      return;
                    }
                  }
                },
          child: CustomPaint(
            painter: _RingPainter(buckets, palette, selected, visuals),
            child: Center(
              child: Padding(padding: const EdgeInsets.all(30), child: child),
            ),
          ),
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  final List<StorageBucket> buckets;
  final StoragePalette palette;
  final String? selected;
  final StorageVisualTheme visuals;
  _RingPainter(this.buckets, this.palette, this.selected, this.visuals);
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero);
    final radius = math.min(size.width, size.height) / 2 - 13;
    final rect = Rect.fromCircle(center: center, radius: radius);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 18
      ..color = visuals.chartTrack;
    canvas.drawCircle(center, radius, paint);
    final total = buckets.fold<int>(0, (sum, bucket) => sum + bucket.bytes);
    var start = -math.pi / 2;
    for (final bucket in buckets) {
      if (total == 0) break;
      final sweep = math.pi * 2 * bucket.bytes / total;
      final gap = math.min(.035, sweep * .15);
      paint
        ..strokeWidth = selected == bucket.key ? 24 : 18
        ..color = visuals.color(bucket.colorIndex, palette);
      canvas.drawArc(rect, start + gap / 2, sweep - gap, false, paint);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _RingPainter old) =>
      old.buckets != buckets ||
      old.palette != palette ||
      old.selected != selected ||
      old.visuals != visuals;
}

class StorageCompositionCard extends StatefulWidget {
  const StorageCompositionCard({
    super.key,
    required this.snapshot,
    required this.palette,
    required this.onOpen,
    required this.onOpenAll,
  });
  final StorageSnapshot snapshot;
  final StoragePalette palette;
  final ValueChanged<StorageBucket> onOpen;
  final VoidCallback onOpenAll;
  @override
  State<StorageCompositionCard> createState() => _StorageCompositionCardState();
}

class _StorageCompositionCardState extends State<StorageCompositionCard> {
  bool _byChat = false;
  String? _selected;
  @override
  Widget build(BuildContext context) {
    final buckets = storageBreakdown(widget.snapshot, byChat: _byChat);
    final selected = buckets
        .where((bucket) => bucket.key == _selected)
        .firstOrNull;
    final total = widget.snapshot.totalBytes;
    final theme = Theme.of(context);
    final visuals = StorageVisualTheme.of(context);
    return GroupedRows(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  const Icon(Icons.donut_large_outlined),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('空间分布', style: theme.textTheme.titleMedium),
                  ),
                  TextButton(
                    onPressed: widget.onOpenAll,
                    child: const Text('全部文件'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(value: false, label: Text('文件类型')),
                  ButtonSegment(value: true, label: Text('聊天类型')),
                ],
                selected: {_byChat},
                onSelectionChanged: (value) => setState(() {
                  _byChat = value.single;
                  _selected = null;
                }),
              ),
              const SizedBox(height: 16),
              if (buckets.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Column(
                    children: [
                      Icon(Icons.folder_open_outlined, size: 48),
                      SizedBox(height: 8),
                      Text('暂无文件，下载的内容会显示在这里'),
                    ],
                  ),
                )
              else
                Row(
                  children: [
                    SizedBox.square(
                      dimension: 154,
                      child: StorageRingChart(
                        buckets: buckets,
                        palette: widget.palette,
                        selected: selected?.key,
                        onSelected: (key) => setState(() => _selected = key),
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                selected == null
                                    ? '${widget.snapshot.files.length}'
                                    : '${(selected.bytes / total * 100).toStringAsFixed(1)}%',
                                style: theme.textTheme.headlineSmall,
                              ),
                              Text(
                                selected == null ? '个文件' : '占应用文件',
                                style: visuals.secondaryLabel(theme),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            selected?.label ?? '应用文件占用',
                            style: theme.textTheme.titleSmall,
                          ),
                          const SizedBox(height: 6),
                          FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              formatStorageBytes(selected?.bytes ?? total),
                              style: theme.textTheme.titleLarge,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            selected == null ? '点击圆环查看分类' : '点击下方分类可查看和清理文件',
                            style: visuals.secondaryLabel(theme),
                          ),
                          TextButton.icon(
                            onPressed: selected == null
                                ? widget.onOpenAll
                                : () => widget.onOpen(selected),
                            icon: const Icon(Icons.arrow_forward, size: 18),
                            label: const Text('查看文件'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              if (buckets.isNotEmpty) ...[
                const SizedBox(height: 16),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final columns = constraints.maxWidth > 550 ? 3 : 2;
                    final width =
                        (constraints.maxWidth - 8 * (columns - 1)) / columns;
                    return Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final bucket in buckets)
                          SizedBox(
                            width: width,
                            child: Material(
                              color: visuals.tint(
                                bucket.colorIndex,
                                widget.palette,
                              ),
                              shape: visuals.previewShape,
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => widget.onOpen(bucket),
                                child: Padding(
                                  padding: const EdgeInsets.all(10),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Padding(
                                            padding: const EdgeInsets.only(
                                              top: 4,
                                            ),
                                            child: SizedBox.square(
                                              dimension: 9,
                                              child: DecoratedBox(
                                                decoration: BoxDecoration(
                                                  color: visuals.color(
                                                    bucket.colorIndex,
                                                    widget.palette,
                                                  ),
                                                  shape: BoxShape.circle,
                                                ),
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 6),
                                          Expanded(
                                            child: Text(
                                              bucket.label,
                                              style: theme.textTheme.bodyMedium,
                                              maxLines: 2,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 6),
                                      Wrap(
                                        spacing: 6,
                                        children: [
                                          Text(
                                            formatStorageBytes(bucket.bytes),
                                            style: theme.textTheme.labelLarge,
                                          ),
                                          Text(
                                            '${(bucket.bytes / total * 100).toStringAsFixed(1)}%',
                                            style: visuals.secondaryLabel(
                                              theme,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                if (_byChat)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      '同类型共用文件只计一次，跨类型共用单列；各色块相加等于应用文件总量。',
                      style: visuals.secondaryLabel(theme),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
