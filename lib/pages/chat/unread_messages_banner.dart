import 'package:material_ui/material_ui.dart';

import '../../widgets/glass.dart';

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
  Widget build(BuildContext context) => GlassPanel(
    height: unreadMessagesBannerHeight,
    child: Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: loading || unavailable ? null : onPressed,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
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
          onPressed: onDismiss,
          icon: const Icon(Icons.close_rounded, size: 18),
        ),
      ],
    ),
  );
}
