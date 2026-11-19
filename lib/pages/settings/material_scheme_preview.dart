import 'package:flutter/material.dart';

import '../../theme/material_theme.dart';

class MaterialSchemePreview extends StatelessWidget {
  const MaterialSchemePreview({super.key, required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => _PreviewTheme(
    scheme: scheme,
    child: const AspectRatio(
      aspectRatio: 2 / 3,
      child: FittedBox(
        child: SizedBox(width: 180, height: 270, child: _ChatPreview()),
      ),
    ),
  );
}

class MaterialSchemeThumbnail extends StatelessWidget {
  const MaterialSchemeThumbnail({super.key, required this.scheme});

  final ColorScheme scheme;

  @override
  Widget build(BuildContext context) => _PreviewTheme(
    scheme: scheme,
    child: Builder(
      builder: (context) {
        final theme = Theme.of(context);
        final colors = theme.colorScheme;
        return SizedBox(
          width: 44,
          height: 40,
          child: Material(
            color: theme.scaffoldBackgroundColor,
            shape: materialPreviewThumbnailShape,
            clipBehavior: Clip.antiAlias,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: 4,
                children: [
                  Expanded(
                    child: Material(
                      color: theme.cardTheme.color,
                      shape: materialPreviewThumbnailShape,
                    ),
                  ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: SizedBox(
                      width: 20,
                      height: 8,
                      child: Material(
                        color: colors.primaryContainer,
                        shape: materialPreviewThumbnailShape,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}

class _PreviewTheme extends StatelessWidget {
  const _PreviewTheme({required this.scheme, required this.child});

  final ColorScheme scheme;
  final Widget child;

  @override
  Widget build(BuildContext context) => AnimatedTheme(
    data: buildMaterialTheme(scheme.brightness, colorScheme: scheme),
    duration: MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : const Duration(milliseconds: 300),
    curve: Curves.easeInOutCubic,
    child: ExcludeSemantics(child: MediaQuery.withNoTextScaling(child: child)),
  );
}

class _ChatPreview extends StatelessWidget {
  const _ChatPreview();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Material(
      color: theme.scaffoldBackgroundColor,
      shape: theme.cardTheme.shape,
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              spacing: 6,
              children: [
                Icon(
                  Icons.arrow_back_rounded,
                  size: 16,
                  color: colors.onSurface,
                ),
                CircleAvatar(
                  radius: 13,
                  backgroundColor: colors.tertiaryContainer,
                  child: Icon(
                    Icons.spa_rounded,
                    size: 16,
                    color: colors.onTertiaryContainer,
                  ),
                ),
                Expanded(
                  child: Text('Matter', style: theme.textTheme.titleSmall),
                ),
                Icon(
                  Icons.more_horiz_rounded,
                  size: 18,
                  color: colors.onSurface,
                ),
              ],
            ),
            const SizedBox(height: 16),
            Center(child: Text('今天', style: theme.textTheme.labelSmall)),
            const SizedBox(height: 12),
            const _PreviewBubble(text: '你好，Matter'),
            const SizedBox(height: 8),
            const _PreviewBubble(text: '一起聊聊', outgoing: true),
            const SizedBox(height: 8),
            const _PreviewBubble(text: '让灵感发生'),
            const Spacer(),
            Material(
              color: theme.cardTheme.color,
              shape: theme.filledButtonTheme.style?.shape?.resolve({}),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 6, 6, 6),
                child: Row(
                  spacing: 8,
                  children: [
                    Icon(
                      Icons.add_rounded,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    Expanded(
                      child: Text('消息', style: theme.textTheme.bodySmall),
                    ),
                    CircleAvatar(
                      radius: 14,
                      backgroundColor: colors.primary,
                      child: Icon(
                        Icons.arrow_upward_rounded,
                        size: 18,
                        color: colors.onPrimary,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PreviewBubble extends StatelessWidget {
  const _PreviewBubble({required this.text, this.outgoing = false});

  final String text;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Material(
        color: outgoing ? colors.primaryContainer : theme.cardTheme.color,
        shape: materialPreviewBubbleShape,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          child: Text(
            text,
            style: theme.textTheme.bodySmall?.copyWith(
              color: outgoing ? colors.onPrimaryContainer : colors.onSurface,
            ),
          ),
        ),
      ),
    );
  }
}
