import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// 把一个分组画成一整张卡片,行间细线画在卡片填充**之上**。
///
/// 关键是填充必须连续:整组共用一个 [Material] 提供卡片色,细线是这个色块
/// 内部的分割。如果让每行各自一个色块、把细线夹在两个色块之间,那 1 dp 的
/// 缝隙露出的是页面底色,分组看上去像被切成几段。
///
/// 只给最外层的四个角圆角:首行圆上角、末行圆下角,中间行直角,所以连续的
/// 几行看上去是一整块。
///
/// 只适用于 Material。新拟物的行本身就是凸起块,由调用点用 `NeuSurface`
/// 包住整组。
class GroupedRows extends StatelessWidget {
  const GroupedRows({
    super.key,
    required this.children,
    this.radius,
    this.dividerIndent,
    this.dividerEndIndent,
  });

  final List<Widget> children;
  final double? radius;

  /// 分隔线左缩进,默认对齐行标题。
  final double? dividerIndent;
  final double? dividerEndIndent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Material(
      color: tokens.surfaces.card,
      shape: radius == null
          ? Theme.of(context).cardTheme.shape
          : RoundedSuperellipseBorder(
              borderRadius: BorderRadius.circular(radius!),
            ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0)
              Divider(
                height: 1,
                thickness: 1,
                indent: dividerIndent ?? tokens.spacing.rowTitleInset,
                endIndent: dividerEndIndent ?? tokens.spacing.lg,
                // 细线落在卡片填充上,所以用半透明正文色:它在卡片上读起来
                // 比卡片更亮/更暗一档,而不是露出底下的页面色。
                color: tokens.surfaces.hairline,
              ),
            children[index],
          ],
        ],
      ),
    );
  }
}
