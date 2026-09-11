import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'neu_decoration.dart';

/// 凹陷托槽:筛选 Chip 的统一容器。
/// 与搜索框同款的凹陷井把一排凸起 Chip 归成一组"控制区",
/// 选中项在凹槽里的对比也更强。内部横向滚动,阴影不硬裁,
/// 槽体留足内边距让 Chip 的投影落在槽面上,不与内阴影打架。
class NeuChipTray extends StatelessWidget {
  const NeuChipTray({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: NeuDecoration(
        colors: context.neu,
        depth: NeuDepth.pressed,
        radius: NeuRadius.nav, // 超出槽高的圆角被钳制成药丸
        intensity: .8,
      ),
      child: SingleChildScrollView(
        clipBehavior: Clip.none,
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) const SizedBox(width: NeuSpacing.sm),
              children[i],
            ],
          ],
        ),
      ),
    );
  }
}
