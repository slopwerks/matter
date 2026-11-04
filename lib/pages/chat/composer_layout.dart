import 'package:flutter/material.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';

/// A full-width editor surface on desktop/tablet, with no nested card or blur.
class ComposerSurface extends StatelessWidget {
  const ComposerSurface({
    super.key,
    required this.expanded,
    required this.compact,
    required this.child,
  });

  final bool expanded;
  final bool compact;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (expanded) {
      return Material(
        key: const ValueKey('message-input-surface'),
        color: Theme.of(context).scaffoldBackgroundColor,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Divider(height: 1),
            Padding(
              padding: EdgeInsets.fromLTRB(8, compact ? 4 : 8, 8, 4),
              child: child,
            ),
          ],
        ),
      );
    }
    return Padding(
      padding: context.isMaterial
          ? const EdgeInsets.all(4)
          : const EdgeInsets.fromLTRB(10, 4, 10, 12),
      child: GlassPanel(
        key: const ValueKey('message-input-surface'),
        radius: NeuRadius.nav,
        opacity: context.isMaterial ? 0 : 1,
        blur: 18,
        padding: EdgeInsets.symmetric(
          horizontal: context.isMaterial ? 0 : 6,
          vertical: 4,
        ),
        child: child,
      ),
    );
  }
}

class ComposerToolButton extends StatelessWidget {
  const ComposerToolButton({
    super.key,
    required this.compact,
    required this.icon,
    this.tooltip,
    this.selected = false,
    this.onPressed,
  });
  final bool compact;
  final IconData icon;
  final String? tooltip;
  final bool selected;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: tooltip,
    icon: Icon(icon, size: compact ? 20 : 24),
    isSelected: selected,
    style: composerIconButtonStyle(Theme.of(context), compact: compact),
    onPressed: onPressed,
  );
}

/// Desktop editors have their own row; compact inputs keep tools beside text.
class ComposerLayout extends StatelessWidget {
  const ComposerLayout({
    super.key,
    required this.desktop,
    required this.editor,
    required this.emojiButton,
    required this.attachmentButton,
    required this.moreButton,
    required this.sendButton,
    this.attachments,
    this.showMore = false,
  });

  final bool desktop;
  final Widget editor;
  final Widget emojiButton;
  final Widget attachmentButton;
  final Widget moreButton;
  final Widget sendButton;
  final Widget? attachments;
  final bool showMore;

  @override
  Widget build(BuildContext context) {
    if (desktop) {
      return Column(
        key: const ValueKey('desktop-composer-layout'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ?attachments,
          editor,
          const SizedBox(height: 4),
          Row(
            key: const ValueKey('desktop-composer-toolbar'),
            children: [
              emojiButton,
              attachmentButton,
              moreButton,
              const Spacer(),
              sendButton,
            ],
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ?attachments,
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            emojiButton,
            SizedBox(width: context.isMaterial ? 2 : 6),
            Expanded(child: editor),
            SizedBox(width: context.isMaterial ? 2 : 6),
            SizedBox(
              width: showMore
                  ? 140
                  : context.isMaterial
                  ? 92
                  : 94,
              height: showMore ? 48 : 44,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  attachmentButton,
                  if (showMore) moreButton,
                  sendButton,
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
