import 'package:flutter/material.dart';

import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/neu_surface.dart';

/// Opens the full-screen reader for a formatted (markdown) message.
void openMessageReader(
  BuildContext context, {
  required String html,
  required Map<String, String> mentionDisplayNames,
  required ValueChanged<String> onMentionTap,
}) {
  Navigator.of(context, rootNavigator: true).push(
    MaterialPageRoute<void>(
      fullscreenDialog: true,
      builder: (_) => MessageReaderPage(
        html: html,
        mentionDisplayNames: mentionDisplayNames,
        onMentionTap: onMentionTap,
      ),
    ),
  );
}

/// Full-screen reading view for a formatted message. Reuses the same HTML
/// renderer as the bubble (including table recovery), with a comfortable
/// reading width and selectable text.
class MessageReaderPage extends StatelessWidget {
  final String html;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;

  const MessageReaderPage({
    super.key,
    required this.html,
    this.mentionDisplayNames = const {},
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Scaffold(
      backgroundColor: colors.base,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                NeuSpacing.sm,
                NeuSpacing.sm,
                NeuSpacing.lg,
                NeuSpacing.xs,
              ),
              child: Row(
                children: [
                  NeuIconButton(
                    icon: Icons.close_rounded,
                    size: 40,
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: NeuSpacing.sm),
                  Text('阅读', style: Theme.of(context).textTheme.titleLarge),
                ],
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: NeuSpacing.lg,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 680),
                    child: MatrixHtmlMessage(
                      html: html,
                      style: Theme.of(
                        context,
                      ).textTheme.bodyLarge!.copyWith(height: 1.6),
                      accentColor: colors.accent,
                      mentionDisplayNames: mentionDisplayNames,
                      onMentionTap: onMentionTap,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
