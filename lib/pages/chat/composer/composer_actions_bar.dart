import 'package:material_ui/material_ui.dart';

import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/neu_surface.dart';
import '../composer_layout.dart';

/// Composer controls and their layout. Sending, pickers and tool menus remain
/// callbacks owned by the input; menu anchors use the button's own context.
class ComposerActionsBar extends StatelessWidget {
  const ComposerActionsBar({
    super.key,
    required this.expanded,
    required this.compact,
    required this.showMore,
    required this.inlineImages,
    required this.emojiIcon,
    required this.emojiSelected,
    required this.attachmentSelected,
    required this.sendBusy,
    required this.hasText,
    required this.hasImages,
    required this.editor,
    required this.onToggleEmoji,
    required this.onToggleAttachment,
    required this.onShowTools,
    required this.onSend,
    this.attachments,
  });

  final bool expanded;
  final bool compact;
  final bool showMore;
  final bool inlineImages;
  final IconData emojiIcon;
  final bool emojiSelected;
  final bool attachmentSelected;
  final bool sendBusy;
  final bool hasText;
  final bool hasImages;
  final Widget editor;
  final Widget? attachments;
  final VoidCallback onToggleEmoji;
  final VoidCallback onToggleAttachment;
  final ValueChanged<BuildContext> onShowTools;
  final VoidCallback onSend;

  Widget _toolButton({
    required IconData icon,
    String? tooltip,
    bool selected = false,
    VoidCallback? onPressed,
  }) => expanded || showMore
      ? ComposerToolButton(
          compact: compact,
          icon: icon,
          tooltip: tooltip,
          selected: selected,
          onPressed: onPressed,
        )
      : NeuIconButton(
          icon: icon,
          tooltip: tooltip,
          size: 44,
          selected: selected,
          onPressed: onPressed,
        );

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final material = context.isMaterial;
    return ComposerLayout(
      desktop: expanded,
      showMore: showMore && !material,
      attachments: attachments,
      editor: editor,
      emojiButton: _toolButton(
        icon: emojiIcon,
        tooltip: '表情与贴纸',
        selected: emojiSelected,
        onPressed: sendBusy ? null : onToggleEmoji,
      ),
      attachmentButton: Builder(
        builder: (buttonContext) {
          if (material && showMore) {
            return _toolButton(
              icon: Icons.add_rounded,
              tooltip: '附件',
              onPressed: sendBusy ? null : () => onShowTools(buttonContext),
            );
          }
          final imageShortcut = !material && inlineImages;
          return Tooltip(
            message: imageShortcut ? '选择图片' : '附件',
            // The outer long press opens tools instead of showing the tooltip.
            triggerMode: TooltipTriggerMode.manual,
            child: GestureDetector(
              onLongPress: sendBusy ? null : () => onShowTools(buttonContext),
              child: _toolButton(
                icon: imageShortcut ? Icons.image_outlined : Icons.add_rounded,
                selected: attachmentSelected,
                onPressed: sendBusy ? null : onToggleAttachment,
              ),
            ),
          );
        },
      ),
      moreButton: Builder(
        builder: (buttonContext) => _toolButton(
          tooltip: '更多',
          icon: Icons.more_horiz_rounded,
          onPressed: sendBusy ? null : () => onShowTools(buttonContext),
        ),
      ),
      sendButton: expanded
          ? FilledButton.icon(
              key: const ValueKey('send_only'),
              style: composerSendButtonStyle(
                Theme.of(context),
                compact: compact,
              ),
              icon: const Icon(Icons.send_rounded),
              onPressed: sendBusy || (!hasText && !hasImages) ? null : onSend,
              label: sendBusy
                  ? SizedBox.square(
                      dimension: 20,
                      child: CircularProgressIndicator(
                        color: colors.onAccent,
                        strokeWidth: 2,
                      ),
                    )
                  : const Text('发送'),
            )
          : AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              switchInCurve: Curves.easeOutCubic,
              switchOutCurve: Curves.easeInCubic,
              child: hasText || hasImages
                  ? SizedBox.square(
                      key: const ValueKey('send_only'),
                      dimension: material && compact ? 32 : 44,
                      child: sendBusy
                          ? Center(
                              child: SizedBox.square(
                                dimension: material && compact ? 16 : 20,
                                child: CircularProgressIndicator(
                                  color: colors.accent,
                                  strokeWidth: 2,
                                ),
                              ),
                            )
                          : NeuIconButton(
                              icon: Icons.send_rounded,
                              size: material && compact ? 32 : 44,
                              accent: true,
                              onPressed: onSend,
                            ),
                    )
                  : SizedBox.square(
                      key: const ValueKey('voice_only'),
                      dimension: material && compact ? 32 : 44,
                      child: NeuIconButton(
                        tooltip: '语音消息暂未提供',
                        icon: Icons.mic_none_rounded,
                        size: material && compact ? 32 : 44,
                        onPressed: null,
                      ),
                    ),
            ),
    );
  }
}
