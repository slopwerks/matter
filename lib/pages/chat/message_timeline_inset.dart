import 'package:flutter/widgets.dart';

/// Composer clearance shared only with position-sensitive timeline children.
/// Message bodies do not depend on it and can survive keyboard frames unchanged.
class MessageTimelineInset extends InheritedWidget {
  const MessageTimelineInset({
    super.key,
    required this.bottom,
    required super.child,
  });

  final double bottom;

  static double? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MessageTimelineInset>()
      ?.bottom;

  @override
  bool updateShouldNotify(MessageTimelineInset oldWidget) =>
      bottom != oldWidget.bottom;
}
