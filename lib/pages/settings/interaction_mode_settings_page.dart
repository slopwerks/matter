import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/interaction_mode_provider.dart';
import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';

class InteractionModeSettingsPage extends ConsumerWidget {
  const InteractionModeSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(interactionModeProvider);
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('交互模式')),
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
            if (context.isMaterial)
              RadioGroup<InteractionMode>(
                groupValue: selected,
                onChanged: (mode) {
                  if (mode != null) {
                    ref.read(interactionModeProvider.notifier).setMode(mode);
                  }
                },
                child: GroupedRows(
                  children: [
                    for (final mode in InteractionMode.values)
                      RadioListTile<InteractionMode>(
                        key: ValueKey('interaction-mode-${mode.name}'),
                        value: mode,
                        selected: selected == mode,
                        selectedTileColor: materialChoiceFill(
                          Theme.of(context),
                          selected: selected == mode,
                        ),
                        title: Text(mode.label),
                        subtitle: Text(switch (mode) {
                          InteractionMode.auto => '桌面系统使用键鼠，Android / iOS 使用触屏',
                          InteractionMode.touch => '较大的触控按钮，保留消息长按操作',
                          InteractionMode.keyboardMouse => '紧凑工具按钮，支持消息文字划选',
                        }),
                      ),
                  ],
                ),
              )
            else
              GroupedRows(
                children: [
                  for (final mode in InteractionMode.values)
                    ListTile(
                      key: ValueKey('interaction-mode-${mode.name}'),
                      title: Text(mode.label),
                      subtitle: Text(switch (mode) {
                        InteractionMode.auto => '桌面系统使用键鼠，Android / iOS 使用触屏',
                        InteractionMode.touch => '较大的触控按钮，保留消息长按操作',
                        InteractionMode.keyboardMouse => '紧凑工具按钮，支持消息文字划选',
                      }),
                      trailing: selected == mode
                          ? const Icon(Icons.check_rounded)
                          : null,
                      onTap: () => ref
                          .read(interactionModeProvider.notifier)
                          .setMode(mode),
                    ),
                ],
              ),
            const SizedBox(height: 16),
            Text(
              '修改后立即生效，并保存在此设备。\n'
              '单栏、分栏和输入区展开只随窗口宽度变化，不受交互模式影响。\n'
              '所有模式都保留实体键盘快捷键和鼠标右键。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
