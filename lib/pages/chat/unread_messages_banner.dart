import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/glass.dart';
import 'chat_notice_frame.dart';

const unreadMessagesBannerHeight = 48.0;

class UnreadMessagesBanner extends StatelessWidget {
  const UnreadMessagesBanner({
    super.key,
    required this.count,
    required this.loading,
    this.failed = false,
    this.unavailable = false,
    this.historyFallback = false,
    required this.onPressed,
    required this.onDismiss,
  });

  final int? count;
  final bool loading;
  final bool failed;
  final bool unavailable;
  final bool historyFallback;
  final VoidCallback onPressed;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final material = context.isMaterial;
    final scheme = Theme.of(context).colorScheme;
    final content = Row(
      children: [
        Expanded(
          child: TextButton.icon(
            style: material
                ? TextButton.styleFrom(
                    foregroundColor: scheme.onSecondaryContainer,
                  )
                : null,
            onPressed: loading || unavailable ? null : onPressed,
            icon: loading
                ? SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: material ? scheme.onSecondaryContainer : null,
                    ),
                  )
                : const Icon(Icons.vertical_align_top_rounded, size: 18),
            label: Text(
              loading
                  ? '正在定位未读消息…'
                  : failed
                  ? '未读消息加载失败 · 点击重试'
                  : unavailable
                  ? '暂无可定位的未读消息'
                  : historyFallback
                  ? '查看较早消息'
                  : count != null
                  ? '$count 条未读 · 跳到最早未读'
                  : '未读消息 · 跳到最早未读',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
        IconButton(
          tooltip: '关闭未读提示',
          color: material ? scheme.onSecondaryContainer : null,
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    );
    if (material) {
      return ChatNoticeFrame(
        child: Material(
          color: scheme.secondaryContainer,
          shape: ChatNoticeFrame.shape,
          clipBehavior: Clip.antiAlias,
          child: SizedBox(height: unreadMessagesBannerHeight, child: content),
        ),
      );
    }
    return GlassPanel(height: unreadMessagesBannerHeight, child: content);
  }
}
