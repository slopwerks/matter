import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../theme/material_theme.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/material_press.dart';
import '../../widgets/max_content_width.dart';

/// Viewer controls stay outside the draggable and zoomable image canvas.
class ImageViewerIconButton extends StatelessWidget {
  const ImageViewerIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    required this.icon,
  });

  final String tooltip;
  final VoidCallback? onPressed;
  final Widget icon;

  @override
  Widget build(BuildContext context) {
    if (!context.isMaterial) {
      return IconButton(tooltip: tooltip, onPressed: onPressed, icon: icon);
    }
    return MaterialPress(
      builder: (states) => IconButton.filledTonal(
        statesController: states,
        style: materialMediaViewerStyle(Theme.of(context)).control,
        tooltip: tooltip,
        onPressed: onPressed,
        icon: icon,
      ),
    );
  }
}

class ImageViewerFooter extends StatelessWidget {
  const ImageViewerFooter({
    super.key,
    required this.description,
    required this.pageLabel,
    required this.previousTooltip,
    required this.loadingOlder,
    required this.onPrevious,
    required this.onNext,
    this.onRetryCaption,
  });

  final String? description;
  final String pageLabel;
  final String previousTooltip;
  final bool loadingOlder;
  final VoidCallback? onPrevious;
  final VoidCallback? onNext;
  final VoidCallback? onRetryCaption;

  @override
  Widget build(BuildContext context) {
    final style = materialMediaViewerStyle(Theme.of(context));
    return MaxContentWidth(
      maxWidth: context.isMaterial ? 720 : double.infinity,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (description?.trim().isNotEmpty == true)
            Container(
              key: const ValueKey('image-viewer-caption'),
              margin: const EdgeInsets.symmetric(horizontal: 16),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              constraints: BoxConstraints(
                maxHeight: MediaQuery.sizeOf(context).height * .25,
              ),
              decoration: context.isMaterial
                  ? style.captionDecoration
                  : BoxDecoration(
                      color: Colors.black.withValues(alpha: .75),
                      borderRadius: BorderRadius.circular(12),
                    ),
              child: SingleChildScrollView(
                child: SelectableText(
                  description!,
                  style: context.isMaterial
                      ? style.caption
                      : const TextStyle(color: Colors.white, fontSize: 15),
                ),
              ),
            ),
          if (onRetryCaption != null)
            ImageViewerIconButton(
              tooltip: '重试描述',
              onPressed: onRetryCaption,
              icon: const Icon(
                CupertinoIcons.arrow_clockwise,
                color: Colors.white,
              ),
            ),
          Padding(
            padding: EdgeInsets.only(top: context.isMaterial ? 8 : 0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                ImageViewerIconButton(
                  tooltip: previousTooltip,
                  onPressed: onPrevious,
                  icon: loadingOlder
                      ? const SizedBox.square(
                          dimension: 20,
                          child: CircularProgressIndicator(
                            color: Colors.white,
                            strokeWidth: 2,
                          ),
                        )
                      : Icon(
                          CupertinoIcons.chevron_left,
                          color: context.isMaterial ? null : Colors.white,
                          size: 22,
                        ),
                ),
                if (context.isMaterial)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(pageLabel, style: style.caption),
                  ),
                ImageViewerIconButton(
                  tooltip: '下一张',
                  onPressed: onNext,
                  icon: Icon(
                    CupertinoIcons.chevron_right,
                    color: context.isMaterial ? null : Colors.white,
                    size: 22,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
