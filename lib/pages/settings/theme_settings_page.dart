import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/material_color_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';
import 'material_preference_option.dart';
import 'material_scheme_preview.dart';

class ThemeSettingsPage extends ConsumerStatefulWidget {
  const ThemeSettingsPage({super.key, required this.initial});

  final AppThemeStyle initial;

  @override
  ConsumerState<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends ConsumerState<ThemeSettingsPage> {
  late var family = widget.initial.family;
  late var mode = widget.initial.themeMode;

  @override
  Widget build(BuildContext context) {
    final heading = materialSettingsSectionStyle(Theme.of(context));
    final schemes = family == ThemeFamily.material
        ? ref.watch(materialColorSchemesProvider)
        : null;
    final result = (family: family, themeMode: mode);
    return Scaffold(
      appBar: buildFloatingAppBar(title: const Text('主题')),
      body: SafeArea(
        child: MaxContentWidth(
          child: ListView(
            padding: const EdgeInsets.all(NeuSpacing.lg),
            children: [
              Text('主题风格', style: heading),
              const SizedBox(height: NeuSpacing.sm),
              RadioGroup<ThemeFamily>(
                groupValue: family,
                onChanged: (value) {
                  if (value != null) setState(() => family = value);
                },
                child: GroupedRows(
                  children: [
                    for (final option in ThemeFamily.values)
                      MaterialPreferenceOption(
                        tileKey: ValueKey(option),
                        value: option,
                        selected: family == option,
                        title: Text(option.label),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: NeuSpacing.xl),
              Text('明暗模式', style: heading),
              const SizedBox(height: NeuSpacing.sm),
              RadioGroup<ThemeMode>(
                groupValue: mode,
                onChanged: (value) {
                  if (value != null) setState(() => mode = value);
                },
                child: GroupedRows(
                  children: [
                    for (final option in ThemeMode.values)
                      MaterialPreferenceOption(
                        tileKey: ValueKey(option),
                        value: option,
                        selected: mode == option,
                        title: Text(option.label),
                        secondary: schemes != null && option != ThemeMode.system
                            ? MaterialSchemeThumbnail(
                                scheme: option == ThemeMode.dark
                                    ? schemes.dark
                                    : schemes.light,
                              )
                            : Icon(switch (option) {
                                ThemeMode.system =>
                                  Icons.brightness_auto_outlined,
                                ThemeMode.light => Icons.light_mode_outlined,
                                ThemeMode.dark => Icons.dark_mode_outlined,
                              }),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: NeuSpacing.xl),
              Align(
                alignment: AlignmentDirectional.centerEnd,
                child: FilledButton(
                  onPressed: result == widget.initial
                      ? null
                      : () => Navigator.pop(context, result),
                  child: const Text('应用主题'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
