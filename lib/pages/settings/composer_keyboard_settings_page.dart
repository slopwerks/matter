import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/composer_keyboard_settings_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';

class ComposerKeyboardSettingsPage extends ConsumerWidget {
  const ComposerKeyboardSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settings = ref.watch(composerKeyboardSettingsProvider);
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
          children: [
            GroupedRows(
              children: [
                for (final shortcut in ComposerEnterShortcut.values)
                  ListTile(
                    title: Text(switch (shortcut) {
                      ComposerEnterShortcut.enter => 'Enter',
                      ComposerEnterShortcut.shiftEnter => 'Shift+Enter',
                      ComposerEnterShortcut.altEnter => 'Alt+Enter',
                    }),
                    trailing: DropdownButtonHideUnderline(
                      child: DropdownButton<ComposerEnterAction>(
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
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '适用于桌面端聊天输入框，修改后立即生效并保存在此设备。\n'
              '输入法候选确认始终优先；补全列表打开时，发送键先选择补全，换行键直接换行。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
