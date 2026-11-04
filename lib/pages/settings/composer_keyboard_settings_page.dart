import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/composer_keyboard_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';

class ComposerKeyboardSettingsPage extends StatelessWidget {
  const ComposerKeyboardSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('键盘发送与换行')),
      body: MaxContentWidth(
        maxWidth: 600,
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            MediaQuery.paddingOf(context).top + kToolbarHeight + 8,
            16,
            MediaQuery.paddingOf(context).bottom + 24,
          ),
          children: const [ComposerKeyboardSettingsOptions()],
        ),
      ),
    );
  }
}

/// Shared by the settings page and the desktop composer's quick dialog.
class ComposerKeyboardSettingsOptions extends ConsumerWidget {
  const ComposerKeyboardSettingsOptions({super.key, this.grouped = true});
  final bool grouped;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(composerKeyboardSettingsProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Builder(
          builder: (context) {
            final rows = <Widget>[
              for (final shortcut in ComposerEnterShortcut.values)
                ListTile(
                  dense: !grouped,
                  minTileHeight: grouped ? null : 40,
                  contentPadding: grouped ? null : EdgeInsets.zero,
                  title: Text(switch (shortcut) {
                    ComposerEnterShortcut.enter => 'Enter',
                    ComposerEnterShortcut.shiftEnter => 'Shift+Enter',
                    ComposerEnterShortcut.altEnter => 'Alt+Enter',
                  }),
                  trailing: DropdownButtonHideUnderline(
                    child: DropdownButton<ComposerEnterAction>(
                      isDense: !grouped,
                      key: ValueKey('composer-key-action-${shortcut.name}'),
                      value: settings.actionFor(shortcut),
                      items: const [
                        DropdownMenuItem(
                          value: ComposerEnterAction.send,
                          child: Text('发送消息'),
                        ),
                        DropdownMenuItem(
                          value: ComposerEnterAction.newline,
                          child: Text('换行'),
                        ),
                      ],
                      onChanged: (action) {
                        if (action == null) return;
                        ref
                            .read(composerKeyboardSettingsProvider.notifier)
                            .setAction(shortcut, action);
                      },
                    ),
                  ),
                ),
            ];
            return grouped
                ? GroupedRows(children: rows)
                : Column(mainAxisSize: MainAxisSize.min, children: rows);
          },
        ),
        const SizedBox(height: 16),
        Text(
          '适用于桌面端聊天输入框，修改后立即生效并保存在此设备。\n'
          '输入法候选确认始终优先；补全列表打开时，发送键先选择补全，换行键直接换行。',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }
}
