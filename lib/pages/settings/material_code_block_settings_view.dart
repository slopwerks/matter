import 'package:flutter/material.dart';

import '../../features/matrix_html/matrix_code_block.dart';
import '../../providers/code_block_settings_provider.dart';
import '../../theme/material_theme.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/max_content_width.dart';

class MaterialCodeBlockSettingsView extends StatelessWidget {
  const MaterialCodeBlockSettingsView({
    super.key,
    required this.settings,
    required this.previewMode,
    required this.previewScheme,
    required this.sampleCode,
    required this.onPreviewModeChanged,
    required this.onOpacityChanged,
    required this.onLineNumbersChanged,
    required this.onDarkThemeChanged,
    required this.onLightThemeChanged,
  });

  final CodeBlockSettings settings;
  final int previewMode;
  final ColorScheme previewScheme;
  final String sampleCode;
  final ValueChanged<int> onPreviewModeChanged;
  final ValueChanged<double> onOpacityChanged;
  final ValueChanged<bool> onLineNumbersChanged;
  final ValueChanged<String> onDarkThemeChanged;
  final ValueChanged<String> onLightThemeChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final opacityLabel = '${(settings.opacity * 100).round()}%';
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('代码块设置')),
      body: MaxContentWidth(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: [
            MaterialDetailCard(
              title: '效果实时预览',
              description: '切换明暗只影响此处预览，下面的设置会同步应用。',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final mode in const [
                        (value: 0, label: '系统'),
                        (value: 1, label: '浅色'),
                        (value: 2, label: '深色'),
                      ])
                        ChoiceChip(
                          label: Text(mode.label),
                          selected: previewMode == mode.value,
                          onSelected: (_) => onPreviewModeChanged(mode.value),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  _CodePreview(
                    scheme: previewScheme,
                    settings: settings,
                    sampleCode: sampleCode,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            MaterialDetailCard(
              title: '背景透明度',
              description: '100% 为实体高对比卡片，调低可透出底层气泡颜色',
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text('卡片不透明度', style: theme.textTheme.bodyLarge),
                      ),
                      const SizedBox(width: 12),
                      Text(opacityLabel, style: theme.textTheme.labelLarge),
                    ],
                  ),
                  Slider(
                    value: settings.opacity,
                    min: 0.1,
                    max: 1,
                    divisions: 18,
                    label: opacityLabel,
                    onChanged: onOpacityChanged,
                  ),
                  const Divider(height: 1),
                  SwitchListTile.adaptive(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('代码行号'),
                    subtitle: const Text('多行代码左侧显示行号'),
                    value: settings.showLineNumbers,
                    onChanged: onLineNumbersChanged,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            _ThemeChoices(
              title: '暗色模式高亮主题',
              description: '深色界面中使用的代码配色。',
              choices: darkCodeThemes.values,
              selected: settings.darkTheme,
              onChanged: onDarkThemeChanged,
            ),
            const SizedBox(height: 16),
            _ThemeChoices(
              title: '浅色模式高亮主题',
              description: '浅色界面中使用的代码配色。',
              choices: lightCodeThemes.values,
              selected: settings.lightTheme,
              onChanged: onLightThemeChanged,
            ),
          ],
        ),
      ),
    );
  }
}

class _CodePreview extends StatelessWidget {
  const _CodePreview({
    required this.scheme,
    required this.settings,
    required this.sampleCode,
  });

  final ColorScheme scheme;
  final CodeBlockSettings settings;
  final String sampleCode;

  @override
  Widget build(BuildContext context) => AnimatedTheme(
    data: buildMaterialTheme(scheme.brightness, colorScheme: scheme),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300),
    curve: Curves.easeInOutCubic,
    child: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final style = materialCodePreviewStyle(theme);
        return Material(
          color: style.fill,
          shape: materialPreviewBubbleShape,
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  theme.brightness == Brightness.dark ? '模拟深色消息气泡' : '模拟浅色消息气泡',
                  style: style.label,
                ),
                const SizedBox(height: 8),
                MatrixCodeBlock(
                  code: sampleCode,
                  language: 'dart',
                  width: double.infinity,
                  baseStyle: style.code,
                  accentColor: style.accent,
                  settingsOverride: settings,
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

class _ThemeChoices extends StatelessWidget {
  const _ThemeChoices({
    required this.title,
    required this.description,
    required this.choices,
    required this.selected,
    required this.onChanged,
  });

  final String title;
  final String description;
  final Iterable<CodeHighlightThemeInfo> choices;
  final String selected;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) => MaterialDetailCard(
    title: title,
    description: description,
    child: RadioGroup<String>(
      groupValue: selected,
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
      child: Column(
        children: [
          for (final (index, choice) in choices.indexed) ...[
            if (index > 0) const Divider(height: 1),
            RadioListTile<String>.adaptive(
              contentPadding: EdgeInsets.zero,
              value: choice.id,
              selected: selected == choice.id,
              selectedTileColor: materialChoiceFill(
                Theme.of(context),
                selected: selected == choice.id,
              ),
              title: Text(choice.name),
              subtitle: Text(choice.id),
              secondary: CircleAvatar(
                radius: 8,
                backgroundColor: choice.backgroundColor,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}
