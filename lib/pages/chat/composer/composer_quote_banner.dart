import 'package:flutter/material.dart';

import '../../../providers/chat_visual_settings_provider.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/neu_decoration.dart';
import '../../../widgets/neu_surface.dart';

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
    final accent = isEditing ? colors.warning : colors.accent;
    return Container(
      margin: const EdgeInsets.fromLTRB(10, 4, 10, 4),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: NeuDecoration(
        colors: colors,
        superellipseEnabled: ChatVisualSettingsScope.of(context)
            .superellipseBorderEnabled,
        depth: NeuDepth.pressed,
        radius: NeuRadius.button,
        intensity: .7,
      ),
      child: Row(
        children: [
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
                  style: Theme.of(context).textTheme.bodySmall
                      ?.copyWith(fontWeight: FontWeight.w700, color: accent),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  content,
                  style: Theme.of(context).textTheme.bodySmall,
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
                    color: colors.accent,
                    strokeWidth: 2,
                  ),
                ),
              ),
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
