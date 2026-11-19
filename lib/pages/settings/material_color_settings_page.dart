import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/material_color_provider.dart';
import '../../theme/material_theme.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_press.dart';
import '../../widgets/max_content_width.dart';
import 'material_color_palette.dart';
import 'material_scheme_preview.dart';

const _colorStyles = [
  (
    value: DynamicSchemeVariant.tonalSpot,
    label: '柔和',
    description: '低饱和度，柔和耐看',
  ),
  (value: DynamicSchemeVariant.vibrant, label: '生动', description: '更饱满的主题色'),
  (
    value: DynamicSchemeVariant.expressive,
    label: '鲜明',
    description: '对比色搭配，更有表现力',
  ),
  (value: DynamicSchemeVariant.neutral, label: '中性', description: '少量色彩，接近中性色'),
];

class MaterialColorSettingsPage extends ConsumerWidget {
  const MaterialColorSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(materialColorSettingsProvider);
    final schemes = ref.watch(materialColorSchemesProvider);
    final baseSchemes = ref.watch(materialBaseColorSchemesProvider);
    final system = ref.watch(systemMaterialColorsProvider);
    final theme = Theme.of(context);
    final notifier = ref.read(materialColorSettingsProvider.notifier);
    final systemScheme = theme.brightness == Brightness.dark
        ? system.asData?.value?.dark
        : system.asData?.value?.light;
    final systemStyle = settings.followSystem && system.asData?.value != null;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('配色')),
      body: MaxContentWidth(
        maxWidth: 600,
        child: Builder(
          builder: (context) => ListView(
            padding: EdgeInsets.fromLTRB(
              16,
              MediaQuery.paddingOf(context).top + 16,
              16,
              MediaQuery.paddingOf(context).bottom + 24,
            ),
            children: [
              _Section(
                title: '配色预览',
                icon: Icons.preview_rounded,
                child: Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      spacing: 16,
                      children: [
                        for (final scheme in [schemes.light, schemes.dark])
                          Expanded(
                            child: Column(
                              spacing: 12,
                              children: [
                                MaterialSchemePreview(scheme: scheme),
                                Text(
                                  scheme.brightness == Brightness.light
                                      ? '浅色'
                                      : '深色',
                                  style: theme.textTheme.labelLarge,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
              _Section(
                title: '主题色',
                icon: Icons.palette_outlined,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  spacing: 8,
                  children: [
                    MaterialColorPalette(
                      settings: settings,
                      systemColor:
                          systemScheme?.primary ?? theme.colorScheme.primary,
                      onSelectSystem: () => notifier.setFollowSystem(true),
                      onSelectSeed: notifier.setSeedColor,
                      onAddCustom: notifier.addCustomColor,
                      onDeleteCustom: notifier.removeCustomColor,
                    ),
                    GroupedRows(
                      children: [
                        ListTile(
                          leading: const Icon(Icons.auto_awesome_rounded),
                          title: Text(
                            settings.followSystem ? '跟随系统配色' : '自选主题色',
                          ),
                          subtitle: Text(
                            !settings.followSystem
                                ? '使用所选颜色生成配色'
                                : system.isLoading
                                ? '正在读取系统配色'
                                : system.asData?.value != null
                                ? '使用系统壁纸或强调色'
                                : '系统未提供配色，使用所选主题色',
                          ),
                        ),
                        ListTile(
                          leading: const Icon(Icons.tonality_rounded),
                          title: const Text('色彩风格'),
                          subtitle: systemStyle ? const Text('由系统配色决定') : null,
                          enabled: !systemStyle,
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            spacing: 4,
                            children: [
                              Text(
                                systemStyle
                                    ? '系统'
                                    : _colorStyles
                                          .firstWhere(
                                            (style) =>
                                                style.value ==
                                                settings.colorStyle,
                                            orElse: () => _colorStyles.first,
                                          )
                                          .label,
                                style: theme.textTheme.bodyMedium,
                              ),
                              const Icon(Icons.unfold_more_rounded, size: 20),
                            ],
                          ),
                          onTap: systemStyle
                              ? null
                              : () => _showColorStyles(
                                  context,
                                  settings,
                                  notifier.setColorStyle,
                                ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              for (final brightness in [Brightness.light, Brightness.dark]) ...[
                _Section(
                  title: brightness == Brightness.light ? '浅色背景' : '深色背景',
                  icon: brightness == Brightness.light
                      ? Icons.light_mode_outlined
                      : Icons.dark_mode_outlined,
                  child: GroupedRows(
                    dividerIndent: 68,
                    children: [
                      for (final background in MaterialBackground.values)
                        _ChoiceTile(
                          label: _backgroundLabel(background, brightness),
                          selected:
                              background ==
                              (brightness == Brightness.light
                                  ? settings.lightBackground
                                  : settings.darkBackground),
                          leading: MaterialSchemeThumbnail(
                            scheme: applyMaterialBackground(
                              brightness == Brightness.light
                                  ? baseSchemes.light
                                  : baseSchemes.dark,
                              background,
                            ),
                          ),
                          onTap: () =>
                              notifier.setBackground(brightness, background),
                        ),
                    ],
                  ),
                ),
                if (brightness == Brightness.light) const SizedBox(height: 24),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

String _backgroundLabel(MaterialBackground background, Brightness brightness) =>
    switch (background) {
      MaterialBackground.tonal => '随主题色',
      MaterialBackground.pure => brightness == Brightness.light ? '纯白' : '纯黑',
      MaterialBackground.soft => brightness == Brightness.light ? '淡米白' : '极深灰',
    };

class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    required this.icon,
    required this.child,
  });

  final String title;
  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 12,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Row(
            spacing: 8,
            children: [
              Icon(icon, size: 18, color: theme.colorScheme.primary),
              Text(title, style: theme.textTheme.titleSmall),
            ],
          ),
        ),
        child,
      ],
    );
  }
}

class _ChoiceTile extends StatelessWidget {
  const _ChoiceTile({
    required this.label,
    required this.leading,
    required this.selected,
    required this.onTap,
    this.subtitle,
  });

  final String label;
  final Widget leading;
  final bool selected;
  final VoidCallback onTap;
  final String? subtitle;

  @override
  Widget build(BuildContext context) {
    final duration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 220);
    return Semantics(
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: MaterialPress(
        builder: (states) => ListTile(
          statesController: states,
          leading: leading,
          title: Text(label),
          subtitle: subtitle == null ? null : Text(subtitle!),
          trailing: AnimatedScale(
            scale: selected ? 1 : 0,
            duration: duration,
            curve: Curves.easeOutBack,
            child: Icon(
              Icons.check_rounded,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          onTap: onTap,
        ),
      ),
    );
  }
}

Future<void> _showColorStyles(
  BuildContext context,
  MaterialColorSettings settings,
  ValueChanged<DynamicSchemeVariant> onChanged,
) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (context) => SafeArea(
    top: false,
    child: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        spacing: 16,
        children: [
          Text('色彩风格', style: Theme.of(context).textTheme.headlineSmall),
          GroupedRows(
            dividerIndent: 68,
            children: [
              for (final style in _colorStyles)
                _ChoiceTile(
                  label: style.label,
                  subtitle: style.description,
                  selected: settings.colorStyle == style.value,
                  leading: MaterialSchemeThumbnail(
                    scheme: ColorScheme.fromSeed(
                      seedColor: settings.seedColor,
                      brightness: Theme.of(context).brightness,
                      dynamicSchemeVariant: style.value,
                    ),
                  ),
                  onTap: () {
                    onChanged(style.value);
                    Navigator.of(context).pop();
                  },
                ),
            ],
          ),
        ],
      ),
    ),
  ),
);
