import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/neu_surface.dart';

/// Presentation for the existing private-chat, create-group and join flows.
class MaterialCreateChatForm extends StatelessWidget {
  const MaterialCreateChatForm({
    super.key,
    required this.controller,
    required this.isCreating,
    required this.onCreateDm,
    required this.onCreateGroup,
    required this.onJoinRoom,
  });

  final TextEditingController controller;
  final bool isCreating;
  final ValueChanged<String> onCreateDm;
  final VoidCallback onCreateGroup;
  final VoidCallback onJoinRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hero = materialProfileCardStyle(theme, detail: true);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Card(
          color: hero.fill,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.forum_outlined, color: hero.foreground, size: 32),
                const SizedBox(height: 16),
                Text('开始新的对话', style: hero.title),
                const SizedBox(height: 8),
                Text('发起私聊，或与大家在房间中交流。', style: hero.subtitle),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        MaterialDetailCard(
          title: '私聊',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  labelText: 'Matrix 用户 ID',
                  hintText: '输入 @用户 ID 发起私聊',
                  helperText: '例如 @alice:example.org',
                  prefixIcon: Icon(Icons.person_outline_rounded),
                ),
                textInputAction: TextInputAction.go,
                onSubmitted: onCreateDm,
              ),
              const SizedBox(height: 16),
              NeuButton(
                accent: true,
                onPressed: isCreating
                    ? null
                    : () => onCreateDm(controller.text),
                child: isCreating
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          color: context.neu.onAccent,
                          strokeWidth: 2,
                        ),
                      )
                    : const Text('发起私聊'),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        GroupedRows(
          children: [
            ListTile(
              leading: const Icon(Icons.group_add_outlined),
              title: const Text('创建群组'),
              subtitle: const Text('创建一个新的群聊房间'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onCreateGroup,
            ),
            ListTile(
              leading: const Icon(Icons.meeting_room_outlined),
              title: const Text('通过地址加入'),
              subtitle: const Text('输入房间 ID、别名或粘贴 Matrix 链接'),
              trailing: const Icon(Icons.chevron_right_rounded),
              onTap: onJoinRoom,
            ),
          ],
        ),
      ],
    );
  }
}
