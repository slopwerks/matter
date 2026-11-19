import 'package:flutter/material.dart';

import '../../../providers/chat_visual_settings_provider.dart';
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../theme/tokens.dart';
import '../../../widgets/neu_decoration.dart';
import '../../../widgets/neu_surface.dart';

/// Retain the preview while it folds into the editor, with only the current
/// reply/edit target available to pointer, keyboard and accessibility actions.
class ComposerQuoteTransition extends StatefulWidget {
  const ComposerQuoteTransition({super.key, required this.banner});
  final ComposerQuoteBanner? banner;

  @override
  State<ComposerQuoteTransition> createState() =>
      _ComposerQuoteTransitionState();
}

class _ComposerQuoteTransitionState extends State<ComposerQuoteTransition> {
  ComposerQuoteBanner? _outgoing;

  @override
  void didUpdateWidget(ComposerQuoteTransition oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.banner != null) {
      _outgoing = widget.banner == null ? oldWidget.banner : null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final hidden = widget.banner == null;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: hidden ? 0 : 1),
      duration: context.tokens.motion.effectsDuration,
      curve: Curves.easeOutCubic,
      onEnd: () {
        if (widget.banner == null && _outgoing != null) {
          setState(() => _outgoing = null);
        }
      },
      builder: (_, progress, child) => ClipRect(
        child: Align(
          alignment: Alignment.bottomCenter,
          heightFactor: progress,
          child: Opacity(opacity: progress, child: child),
        ),
      ),
      child: ExcludeSemantics(
        excluding: hidden,
        child: ExcludeFocus(
          excluding: hidden,
          child: IgnorePointer(
            ignoring: hidden,
            child: widget.banner ?? _outgoing,
          ),
        ),
      ),
    );
  }
}

/// Reply/edit presentation only; the host owns provider updates and draft state.
class ComposerQuoteBanner extends StatelessWidget {
  const ComposerQuoteBanner.reply({
    super.key,
    required String senderName,
    required this.content,
    required this.onCancel,
  }) : title = senderName,
       isEditing = false,
       sendInFlight = false;

  const ComposerQuoteBanner.editing({
    super.key,
    required this.content,
    required this.sendInFlight,
    required this.onCancel,
  }) : title = '编辑中',
       isEditing = true;

  final String title;
  final String content;
  final bool isEditing;
  final bool sendInFlight;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final material = context.isMaterial;
    final accent = material
        ? isEditing
              ? scheme.onTertiaryContainer
              : scheme.onSecondaryContainer
        : isEditing
        ? colors.warning
        : colors.accent;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: material
          ? ShapeDecoration(
              color: isEditing
                  ? scheme.tertiaryContainer
                  : scheme.secondaryContainer,
              shape: theme.popupMenuTheme.shape ?? materialListItemShape,
            )
          : NeuDecoration(
              colors: colors,
              superellipseEnabled: ChatVisualSettingsScope.of(context)
                  .superellipseBorderEnabled,
              depth: NeuDepth.pressed,
              radius: NeuRadius.button,
              intensity: .7,
            ),
      child: Row(
        children: [
          if (material)
            Icon(
              isEditing ? Icons.edit_outlined : Icons.reply_rounded,
              color: accent,
            )
          else
            Container(
              width: 3,
              height: 32,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: material
                      ? theme.textTheme.titleSmall?.copyWith(color: accent)
                      : theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.w700,
                          color: accent,
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  content,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: material ? accent : null,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          if (sendInFlight)
            SizedBox.square(
              dimension: 30,
              child: Center(
                child: SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(
                    color: material ? accent : colors.accent,
                    strokeWidth: 2,
                  ),
                ),
              ),
            )
          else if (material)
            IconButton(
              tooltip: isEditing ? '取消编辑' : '取消回复',
              color: accent,
              onPressed: onCancel,
              icon: const Icon(Icons.close_rounded),
            )
          else
            NeuIconButton(
              icon: Icons.close_rounded,
              size: 30,
              onPressed: onCancel,
            ),
        ],
      ),
    );
  }
}
