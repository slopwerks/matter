import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import 'chat_timestamp.dart';

/// The shared message summary used by search and pinned-message streams.
class MaterialMessagePreview extends StatelessWidget {
  const MaterialMessagePreview({
    super.key,
    required this.senderName,
    required this.timestamp,
    required this.body,
    required this.onTap,
    this.edited = false,
    this.trailing,
  });

  final String senderName;
  final String timestamp;
  final Widget body;
  final VoidCallback? onTap;
  final bool edited;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return NeuAction(
      radius: materialSurfaceRadius,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                AppAvatar(
                  fallback: senderName,
                  size: materialDenseListAvatarSize,
                ),
                const SizedBox(width: materialListContentGap),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        senderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: materialListTitleStyle(theme),
                      ),
                      Text(
                        '${formatChatListTime(timestamp)}${edited ? ' · 已编辑' : ''}',
                        style: theme.textTheme.labelSmall,
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
            const SizedBox(height: 12),
            body,
          ],
        ),
      ),
    );
  }
}
