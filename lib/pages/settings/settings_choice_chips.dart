import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';

/// Inline, single-choice preferences wrap inside the actual settings pane.
class SettingsChoiceChips<T> extends StatelessWidget {
  const SettingsChoiceChips({
    super.key,
    required this.options,
    required this.selected,
    required this.label,
    required this.onChanged,
  });
  final List<T> options;
  final T selected;
  final String Function(T) label;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: NeuSpacing.xs),
    child: Wrap(
      spacing: NeuSpacing.sm,
      children: [
        for (final option in options)
          ChoiceChip(
            label: Text(label(option)),
            selected: option == selected,
            onSelected: (_) => onChanged(option),
          ),
      ],
    ),
  );
}
