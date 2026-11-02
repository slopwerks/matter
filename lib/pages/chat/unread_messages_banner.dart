import 'package:flutter/material.dart';

import '../../widgets/glass.dart';

const unreadMessagesBannerHeight = 48.0;

class UnreadMessagesBanner extends StatelessWidget {
  const UnreadMessagesBanner({
    super.key,
    required this.count,
    required this.hasReadMarker,
    required this.loading,
    required this.onPressed,
    required this.onDismiss,
  });

  final int count;
  final bool hasReadMarker;
  final bool loading;
  final VoidCallback onPressed;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) => GlassPanel(
    height: unreadMessagesBannerHeight,
    child: Row(
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: loading ? null : onPressed,
            icon: loading
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.vertical_align_top_rounded, size: 18),
            label: Text(
              loading
                  ? '正在定位未读消息…'
                  : '$count 条未读 · ${hasReadMarker ? '跳到最早未读' : '查看较早消息'}',
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
