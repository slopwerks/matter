import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';

enum ConversationRowLayout { inlineStatus, trailingStatus }

/// Theme-owned presentation decisions for stream rows and floating controls.
/// Layout policies switch at the same midpoint as the compatibility palette;
/// geometry interpolates continuously during a theme transition.
class AppComponentTheme extends ThemeExtension<AppComponentTheme> {
  const AppComponentTheme({
    required this.conversationLayout,
    required this.rowRadius,
    required this.rowHorizontalPadding,
    required this.avatarSize,
    required this.denseAvatarSize,
    required this.toolbarStyle,
  });

  final ConversationRowLayout conversationLayout;
  final double rowRadius;
  final double rowHorizontalPadding;
  final double avatarSize;
  final double denseAvatarSize;
  final ButtonStyle? toolbarStyle;

  ShapeBorder rowShape({required bool superellipse}) =>
      conversationLayout == ConversationRowLayout.trailingStatus ||
          !superellipse
      ? RoundedRectangleBorder(borderRadius: BorderRadius.circular(rowRadius))
      : RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(rowRadius),
        );

  double dividerIndent({required bool dense}) =>
      rowHorizontalPadding + (dense ? denseAvatarSize : avatarSize) + 12;

  @override
  AppComponentTheme copyWith({
    ConversationRowLayout? conversationLayout,
    double? rowRadius,
    double? rowHorizontalPadding,
    double? avatarSize,
    double? denseAvatarSize,
    ButtonStyle? toolbarStyle,
  }) => AppComponentTheme(
    conversationLayout: conversationLayout ?? this.conversationLayout,
    rowRadius: rowRadius ?? this.rowRadius,
    rowHorizontalPadding: rowHorizontalPadding ?? this.rowHorizontalPadding,
    avatarSize: avatarSize ?? this.avatarSize,
    denseAvatarSize: denseAvatarSize ?? this.denseAvatarSize,
    toolbarStyle: toolbarStyle ?? this.toolbarStyle,
  );

  @override
  AppComponentTheme lerp(covariant AppComponentTheme? other, double t) =>
      other == null
      ? this
      : AppComponentTheme(
          conversationLayout: t < .5
              ? conversationLayout
              : other.conversationLayout,
          rowRadius: lerpDouble(rowRadius, other.rowRadius, t)!,
          rowHorizontalPadding: lerpDouble(
            rowHorizontalPadding,
            other.rowHorizontalPadding,
            t,
          )!,
          avatarSize: lerpDouble(avatarSize, other.avatarSize, t)!,
          denseAvatarSize: lerpDouble(
            denseAvatarSize,
            other.denseAvatarSize,
            t,
          )!,
          toolbarStyle: t < .5 ? toolbarStyle : other.toolbarStyle,
        );

  static AppComponentTheme of(BuildContext context) =>
      Theme.of(context).extension<AppComponentTheme>()!;
}
