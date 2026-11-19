import 'package:flutter/material.dart';

import '../../features/matrix_html/matrix_html_renderer.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/floating_app_bar.dart';
import '../../widgets/glass.dart';
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
  final String title;
  final List<Widget> actions;
  final Map<String, String> mentionDisplayNames;
  final ValueChanged<String>? onMentionTap;

  const MessageReaderPage({
    super.key,
    required this.html,
    this.title = '阅读',
    this.actions = const [],
    this.mentionDisplayNames = const {},
    this.onMentionTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final viewPaddingTop = MediaQuery.viewPaddingOf(context).top;
    return Scaffold(
      backgroundColor: colors.base,
      extendBodyBehindAppBar: context.isMaterial,
      appBar: context.isMaterial
          ? buildFloatingAppBar(
              title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
              actions: actions,
              leading: IconButton(
                icon: const Icon(Icons.close),
                tooltip: '关闭',
                onPressed: () => Navigator.of(context).pop(),
              ),
            )
          : null,
      body: Stack(
        children: [
          Positioned.fill(
            child: SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                20,
                viewPaddingTop + kToolbarHeight + NeuSpacing.lg,
                20,
                NeuSpacing.lg,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 680),
                  child: MatrixHtmlMessage(
                    html: html,
                    style: Theme.of(context).textTheme.bodyLarge!
                        .copyWith(height: 1.6),
                    accentColor: colors.accent,
                    mentionDisplayNames: mentionDisplayNames,
                    onMentionTap: onMentionTap,
                  ),
                ),
              ),
            ),
          ),
          // 渐变模糊层:柔和过渡从标题栏下方滚过的内容。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              height: viewPaddingTop + kToolbarHeight,
              child: const TopFadeBlur(useShader: true),
            ),
          // 标题栏移到上方浮层,阅读内容从它下方穿过。
          if (!context.isMaterial)
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: SizedBox(
                  height: kToolbarHeight,
                  child: Padding(
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
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                        ),
                        ...actions,
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
