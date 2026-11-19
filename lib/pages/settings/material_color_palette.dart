import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../providers/material_color_provider.dart';
import '../../theme/material_theme.dart';
import '../../widgets/material_press.dart';

const _themeColors = [
  (label: '蓝色', color: defaultMaterialSeedColor),
  (label: '紫色', color: Color(0xFF8B5CF6)),
  (label: '青色', color: Color(0xFF008577)),
  (label: '绿色', color: Color(0xFF3C8D40)),
  (label: '粉色', color: Color(0xFFBA4C7E)),
  (label: '橙色', color: Color(0xFFE07B36)),
  (label: '蓝灰', color: Color(0xFF4B7399)),
  (label: '棕色', color: Color(0xFF8A6D52)),
];

class MaterialColorPalette extends StatelessWidget {
  const MaterialColorPalette({
    super.key,
    required this.settings,
    required this.systemColor,
    required this.onSelectSystem,
    required this.onSelectSeed,
    required this.onAddCustom,
    required this.onDeleteCustom,
  });

  final MaterialColorSettings settings;
  final Color systemColor;
  final VoidCallback onSelectSystem;
  final ValueChanged<Color> onSelectSeed;
  final ValueChanged<Color> onAddCustom;
  final ValueChanged<Color> onDeleteCustom;

  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: LayoutBuilder(
        builder: (context, constraints) {
          const size = _ColorSwatch.size;
          final columns = math.max(
            1,
            ((constraints.maxWidth + 8) / (size + 8)).floor(),
          );
          final gap = columns > 1
              ? (constraints.maxWidth - columns * size) / (columns - 1)
              : 0.0;
          return Wrap(
            spacing: gap,
            runSpacing: 12,
            children: [
              _ColorSwatch(
                color: systemColor,
                label: '跟随系统配色',
                selected: settings.followSystem,
                icon: Icons.auto_awesome_rounded,
                onPressed: onSelectSystem,
              ),
              for (final choice in _themeColors)
                _ColorSwatch(
                  color: choice.color,
                  label: choice.label,
                  selected:
                      !settings.followSystem &&
                      settings.seedColor == choice.color,
                  onPressed: () => onSelectSeed(choice.color),
                ),
              for (final custom in settings.customColors)
                _ColorSwatch(
                  color: custom,
                  label:
                      '#${(custom.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}',
                  selected:
                      !settings.followSystem && settings.seedColor == custom,
                  onPressed: () => onSelectSeed(custom),
                  onLongPress: () => onDeleteCustom(custom),
                ),
              _ColorSwatch(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                label: '添加自定义颜色',
                selected: false,
                icon: Icons.add_rounded,
                onPressed: () async {
                  final color = await _showAddColorDialog(context);
                  if (color != null && context.mounted) onAddCustom(color);
                },
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _ColorSwatch extends StatelessWidget {
  const _ColorSwatch({
    required this.color,
    required this.label,
    required this.selected,
    required this.onPressed,
    this.icon,
    this.onLongPress,
  });

  static const double size = 48;

  final Color color;
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback onPressed;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    final foreground =
        ThemeData.estimateBrightnessForColor(color) == Brightness.dark
        ? Colors.white
        : Colors.black;
    return Semantics(
      label: label,
      button: true,
      selected: selected,
      onLongPressHint: onLongPress == null ? null : '删除颜色',
      child: Tooltip(
        message: onLongPress == null ? label : '$label (长按删除)',
        excludeFromSemantics: true,
        child: MaterialPress(
          builder: (states) => SizedBox.square(
            dimension: size,
            child: Material(
              type: MaterialType.transparency,
              shape: const CircleBorder(),
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                statesController: states,
                customBorder: const CircleBorder(),
                splashFactory: NoSplash.splashFactory,
                overlayColor: MaterialPress.feedbackStyle.overlayColor,
                onTap: onPressed,
                onLongPress: onLongPress,
                child: ValueListenableBuilder<Set<WidgetState>>(
                  valueListenable: states,
                  builder: (context, values, _) => Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: AnimatedContainer(
                          duration: duration,
                          curve: Curves.easeOutCubic,
                          margin: const EdgeInsets.all(2),
                          decoration: ShapeDecoration(
                            shape: CircleBorder(
                              side: BorderSide(
                                color: selected
                                    ? color
                                    : values.contains(WidgetState.focused)
                                    ? Theme.of(context).colorScheme.primary
                                    : Colors.transparent,
                                width: 2.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                      SizedBox.square(
                        dimension: 32,
                        child: Material(
                          color: color,
                          shape: const CircleBorder(),
                        ),
                      ),
                      if (icon != null && !selected)
                        ExcludeSemantics(
                          child: Icon(icon, size: 18, color: foreground),
                        ),
                      AnimatedScale(
                        scale: selected ? 1 : 0,
                        duration: duration,
                        curve: Curves.easeOutBack,
                        child: ExcludeSemantics(
                          child: Icon(
                            Icons.check_rounded,
                            size: 20,
                            color: foreground,
                          ),
                        ),
                      ),
                    ],
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

Future<Color?> _showAddColorDialog(BuildContext context) => showDialog<Color>(
  context: context,
  builder: (_) => const _CustomColorDialog(),
);

class _CustomColorDialog extends StatefulWidget {
  const _CustomColorDialog();

  @override
  State<_CustomColorDialog> createState() => _CustomColorDialogState();
}

class _CustomColorDialogState extends State<_CustomColorDialog> {
  final _controller = TextEditingController(text: '#');
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    var text = _controller.text.trim().replaceAll('#', '');
    if (text.length == 6) text = 'FF$text';
    final value = int.tryParse(text, radix: 16);
    if (value == null || text.length != 8) {
      setState(() => _error = '请输入有效的 6 位颜色代码');
      return;
    }
    Navigator.of(context).pop(Color(value));
  }

  @override
  Widget build(BuildContext context) {
    const presets = [
      Color(0xFFE91E63),
      Color(0xFF9C27B0),
      Color(0xFF673AB7),
      Color(0xFF009688),
      Color(0xFFFF9800),
      Color(0xFFFF5722),
      Color(0xFF607D8B),
      Color(0xFF795548),
    ];
    return AlertDialog(
      title: const Text('添加主题色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              onSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                hintText: '#RRGGBB',
                errorText: _error,
                prefixIcon: const Icon(Icons.colorize_rounded),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final color in presets)
                  _ColorSwatch(
                    color: color,
                    label:
                        '#${(color.toARGB32() & 0xFFFFFF).toRadixString(16).toUpperCase()}',
                    selected: false,
                    onPressed: () => Navigator.of(context).pop(color),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _submit, child: const Text('确定')),
      ],
    );
  }
}
