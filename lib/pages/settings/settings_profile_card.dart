import 'package:flutter/material.dart';

import '../../providers/auth_provider.dart';
import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';
import '../../widgets/neu_action.dart';
import '../../widgets/neu_surface.dart';

class SettingsProfileCard extends StatelessWidget {
  const SettingsProfileCard({
    super.key,
    required this.user,
    required this.onTap,
  });

  final CurrentUser? user;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (context.isMaterial) {
      final style = materialProfileCardStyle(theme);
      return NeuAction(
        radius: materialSurfaceRadius,
        onTap: onTap,
        child: Card(
          color: style.fill,
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                AppAvatar(
                  fallback: user?.displayName ?? '我',
                  size: 52,
                  url: user?.avatarUrl,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    spacing: 4,
                    children: [
                      Text(
                        user?.displayName ?? '未登录',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style.title,
                      ),
                      Text(
                        user?.id ?? '点击登录你的 Matrix 账号',
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: style.subtitle,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(Icons.edit_outlined, size: 20, color: style.foreground),
              ],
            ),
          ),
        ),
      );
    }
    return NeuAction(
      radius: NeuRadius.surface,
      onTap: onTap,
      child: NeuSurface(
        color: context.neu.card,
        radius: NeuRadius.surface,
        padding: const EdgeInsets.all(NeuSpacing.lg),
        child: Row(
          children: [
            AppAvatar(
              fallback: user?.displayName ?? '我',
              size: 60,
              url: user?.avatarUrl,
            ),
            const SizedBox(width: NeuSpacing.lg),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user?.displayName ?? '未登录',
                    style: theme.textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    user?.id ?? '点击登录你的 Matrix 账号',
                    style: theme.textTheme.bodyMedium,
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
