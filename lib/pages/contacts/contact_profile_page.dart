import 'package:material_ui/material_ui.dart';

import '../../widgets/material_identity_id.dart';

import '../../src/rust/api/matrix.dart';
import '../../theme/material_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/material_detail_card.dart';
import '../../widgets/max_content_width.dart';
import '../../widgets/neu_surface.dart';

/// Material's full profile uses the same guarded conversation action as its row.
class ContactProfilePage extends StatefulWidget {
  const ContactProfilePage({
    super.key,
    required this.contact,
    required this.avatarUrl,
    required this.onMessage,
  });

  final Contact contact;
  final String? avatarUrl;
  final Future<void> Function() onMessage;

  @override
  State<ContactProfilePage> createState() => _ContactProfilePageState();
}

class _ContactProfilePageState extends State<ContactProfilePage> {
  bool _sending = false;

  Future<void> _sendMessage() async {
    if (_sending) return;
    setState(() => _sending = true);
    try {
      await widget.onMessage();
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final contact = widget.contact;
    final theme = Theme.of(context);
    final hero = materialProfileCardStyle(theme, detail: true);
    return Scaffold(
      appBar: buildFloatingAppBar(title: const Text('联系人资料')),
      body: MaxContentWidth(
        child: ListView(
          padding: EdgeInsets.fromLTRB(
            16,
            20,
            16,
            MediaQuery.paddingOf(context).bottom + 32,
          ),
          children: [
            Card(
              color: hero.fill,
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: [
                    AppAvatar(
                      fallback: contact.name,
                      size: 80,
                      url: widget.avatarUrl,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      contact.name,
                      textAlign: TextAlign.center,
                      style: hero.title,
                    ),
                    MaterialIdentityId(contact.id),
                    if (contact.status.isNotEmpty &&
                        contact.status != contact.id)
                      Text(contact.status, style: hero.subtitle),
                    const SizedBox(height: 20),
                    NeuButton(
                      accent: true,
                      onPressed: _sending ? null : _sendMessage,
                      icon: const Icon(Icons.chat_bubble_outline, size: 18),
                      child: Text(_sending ? '正在打开…' : '发消息'),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            MaterialDetailCard(
              title: '联系人信息',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline),
                    title: const Text('显示名称'),
                    subtitle: Text(contact.name),
                  ),
                  const Divider(),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.alternate_email),
                    title: const Text('Matrix ID'),
                    subtitle: SelectableText(contact.id),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
