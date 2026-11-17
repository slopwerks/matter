import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../widgets/grouped_rows.dart';
import '../../widgets/material_detail_card.dart';

/// One heading rhythm for storage overview and settings categories.
class StorageSection extends StatelessWidget {
  const StorageSection({
    super.key,
    required this.title,
    required this.child,
    this.action,
  });
  final String title;
  final Widget child;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 20),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              ?action,
            ],
          ),
        ),
        child,
      ],
    ),
  );
}

/// Settings headings and controls share a surface in Material.
class StorageSettingsSection extends StatelessWidget {
  const StorageSettingsSection({
    super.key,
    required this.title,
    required this.child,
    this.description,
  });

  final String title;
  final String? description;
  final Widget child;

  @override
  Widget build(BuildContext context) => context.isMaterial
      ? Padding(
          padding: const EdgeInsets.only(top: 20),
          child: MaterialDetailCard(
            title: title,
            description: description,
            child: ListTileTheme.merge(
              contentPadding: EdgeInsets.zero,
              child: child,
            ),
          ),
        )
      : StorageSection(title: title, child: child);
}

/// The surrounding settings card owns the Material fill and outer shape.
class StorageSettingsRows extends StatelessWidget {
  const StorageSettingsRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => context.isMaterial
      ? Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0) const Divider(height: 1),
              children[index],
            ],
          ],
        )
      : GroupedRows(children: children);
}
