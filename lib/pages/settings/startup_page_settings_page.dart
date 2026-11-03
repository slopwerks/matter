import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/startup_page_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/max_content_width.dart';

class StartupPageSettingsPage extends ConsumerWidget {
  const StartupPageSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selected = ref.watch(startupPageProvider);
    return Scaffold(
      backgroundColor: context.neu.base,
      extendBodyBehindAppBar: true,
      appBar: buildFloatingAppBar(title: const Text('启动页面')),
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
                for (final page in StartupPage.values)
                  ListTile(
                    key: ValueKey('startup-page-${page.name}'),
                    title: Text(page.label),
                    subtitle: page == StartupPage.remember
                        ? const Text('没有记录或记录失效时显示全部会话')
                        : null,
                    trailing: selected == page
                        ? const Icon(Icons.check_rounded)
                        : null,
                    onTap: () =>
                        ref.read(startupPageProvider.notifier).setPage(page),
                  ),
              ],
            ),
            const SizedBox(height: 16),
            Text(
              '下次启动生效。记住的页面按账号分别保存，不会恢复上次打开的消息或自动发送已读回执。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
