import 'package:flutter/material.dart';

import '../theme/tokens.dart';
import 'material_press.dart';

/// Primary and secondary actions above the Material rail destinations.
class MaterialRailActions extends StatelessWidget {
  const MaterialRailActions({
    super.key,
    required this.extended,
    required this.onCreate,
    required this.onFindRoom,
  });

  final bool extended;
  final VoidCallback onCreate;
  final VoidCallback onFindRoom;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spacing = context.tokens.spacing;
    final scheme = theme.colorScheme;
    const actionSize = Size.square(kMinInteractiveDimension);
    const iconSize = 24.0;
    const actionShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(16)),
    );
    final create = MaterialPress(
      maxGrowth: 3,
      builder: (states) => FilledButton(
        statesController: states,
        onPressed: onCreate,
        style: FilledButton.styleFrom(
          visualDensity: VisualDensity.standard,
          minimumSize: actionSize,
          iconSize: iconSize,
          padding: EdgeInsets.symmetric(horizontal: extended ? spacing.sm : 0),
          shape: actionShape,
          textStyle: theme.textTheme.titleSmall,
        ),
        child: extended
            ? Row(
                mainAxisAlignment: MainAxisAlignment.center,
                spacing: spacing.sm,
                children: [
                  const Icon(Icons.add_rounded),
                  const Flexible(
                    child: Text(
                      '新建会话',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              )
            : const Icon(Icons.add_rounded),
      ),
    );
    final findRoom = MaterialPress(
      maxGrowth: 3,
      builder: (states) => IconButton.filledTonal(
        statesController: states,
        tooltip: '查找房间',
        onPressed: onFindRoom,
        icon: const Icon(Icons.search_rounded),
        style: IconButton.styleFrom(
          fixedSize: actionSize,
          iconSize: iconSize,
          visualDensity: VisualDensity.standard,
          backgroundColor: scheme.surfaceContainerHigh,
          foregroundColor: scheme.onSurfaceVariant,
          shape: actionShape,
        ),
      ),
    );
    return Padding(
      padding: EdgeInsets.fromLTRB(
        extended ? spacing.md : 0,
        spacing.sm,
        extended ? spacing.md : 0,
        spacing.md,
      ),
      child: extended
          ? Row(
              spacing: spacing.sm,
              children: [
                Expanded(child: create),
                findRoom,
              ],
            )
          : Column(
              spacing: spacing.sm,
              children: [
                Tooltip(message: '新建会话', child: create),
                findRoom,
              ],
            ),
    );
  }
}
