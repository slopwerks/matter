import 'package:flutter/material.dart';

import '../../providers/theme_provider.dart';
import '../../theme/material_theme.dart';
import '../../widgets/grouped_rows.dart';
import 'material_scheme_preview.dart';

Future<void> showMaterialThemeStylePicker(
  BuildContext context, {
  required AppThemeStyle current,
  required ColorScheme light,
  required ColorScheme dark,
  required ValueChanged<AppThemeStyle> onChanged,
}) => showModalBottomSheet<void>(
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
          Text('主题', style: Theme.of(context).textTheme.headlineSmall),
          for (final material in [true, false]) ...[
            Text(
              material ? 'Material' : '新拟物',
              style: materialSettingsSectionStyle(Theme.of(context)),
            ),
            GroupedRows(
              dividerIndent: 68,
              children: [
                for (final style in AppThemeStyle.values.where(
                  (style) => style.isMaterial == material,
                ))
                  Semantics(
                    selected: style == current,
                    inMutuallyExclusiveGroup: true,
                    child: ListTile(
                      leading: SizedBox(
                        width: 44,
                        height: 40,
                        child: material
                            ? _ThemeThumbnail(
                                mode: style.themeMode,
                                light: light,
                                dark: dark,
                              )
                            : Icon(switch (style.themeMode) {
                                ThemeMode.light => Icons.light_mode_outlined,
                                ThemeMode.dark => Icons.dark_mode_outlined,
                                ThemeMode.system =>
                                  Icons.brightness_auto_outlined,
                              }),
                      ),
                      title: Text(
                        '${material ? 'Material' : '新拟物'} · ${switch (style.themeMode) {
                          ThemeMode.light => '浅色',
                          ThemeMode.dark => '深色',
                          ThemeMode.system => '跟随系统',
                        }}',
                      ),
                      trailing: style == current
                          ? Icon(
                              Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () {
                        onChanged(style);
                        Navigator.of(context).pop();
                      },
                    ),
                  ),
              ],
            ),
          ],
        ],
      ),
    ),
  ),
);

class _ThemeThumbnail extends StatelessWidget {
  const _ThemeThumbnail({
    required this.mode,
    required this.light,
    required this.dark,
  });

  final ThemeMode mode;
  final ColorScheme light;
  final ColorScheme dark;

  @override
  Widget build(BuildContext context) {
    if (mode != ThemeMode.system) {
      return MaterialSchemeThumbnail(
        scheme: mode == ThemeMode.light ? light : dark,
      );
    }
    return ExcludeSemantics(
      child: FittedBox(
        child: Row(
          spacing: 4,
          children: [
            MaterialSchemeThumbnail(scheme: light),
            MaterialSchemeThumbnail(scheme: dark),
          ],
        ),
      ),
    );
  }
}
