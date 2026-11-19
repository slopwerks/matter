import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// The radio selection is immediate; only the highlight follows it.
class MaterialPreferenceOption<T> extends StatelessWidget {
  const MaterialPreferenceOption({
    super.key,
    required this.tileKey,
    required this.value,
    required this.selected,
    required this.title,
    this.subtitle,
  });

  final Key tileKey;
  final T value;
  final bool selected;
  final Widget title;
  final Widget? subtitle;

  @override
  Widget build(BuildContext context) {
    final fill = Theme.of(context).colorScheme.secondaryContainer;
    final reduced = MediaQuery.disableAnimationsOf(context);
    return TweenAnimationBuilder<double>(
      tween: Tween(end: selected ? 1 : 0),
      duration: reduced ? Duration.zero : context.tokens.motion.effectsDuration,
      curve: Curves.easeOut,
      builder: (context, amount, _) {
        final color = fill.withValues(
          alpha: reduced ? (selected ? 1 : 0) : amount,
        );
        return RadioListTile<T>(
          key: tileKey,
          value: value,
          selected: selected,
          tileColor: color,
          selectedTileColor: color,
          title: title,
          subtitle: subtitle,
        );
      },
    );
  }
}
