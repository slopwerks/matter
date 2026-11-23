import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../../providers/chat_visual_settings_provider.dart';
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../theme/tokens.dart';

Color outgoingBubbleForeground(BuildContext context) => context.isMaterial
    ? Theme.of(context).colorScheme.onPrimaryContainer
    : context.neu.onAccent;

Color messageBubbleFill(BuildContext context, {required bool isMe}) => isMe
    ? context.tokens.surfaces.bubbleOutgoing
    : context.tokens.surfaces.bubbleIncoming;

/// Joined corners follow cluster position, not render-block position. Media
/// collections and send-flight targets consume the same geometry as text.
BorderRadius timelineBubbleBorderRadius(
  BuildContext context, {
  required bool isMe,
  required bool isFirst,
  required bool isLast,
}) {
  final radii = context.tokens.radii;
  final outer = Radius.circular(radii.bubble);
  final joined = Radius.circular(context.isMaterial ? 4 : 6);
  final tail = Radius.circular(radii.tag);
  if (isMe) {
    return BorderRadius.only(
      topLeft: outer,
      topRight: isFirst ? outer : joined,
      bottomLeft: outer,
      bottomRight: isLast ? tail : joined,
    );
  }
  return BorderRadius.only(
    topLeft: isFirst ? outer : joined,
    topRight: outer,
    bottomLeft: isLast ? tail : joined,
    bottomRight: outer,
  );
}

/// Neumorphic decoration, or the existing solid Material fill. Gradient,
/// superellipse and shadow switches still follow ChatVisualSettingsScope.
Decoration neuBubbleDecoration(
  BuildContext context,
  NeuColors colors, {
  required bool isMe,
  required BorderRadius borderRadius,
}) {
  const offset = 3.8 * .7;
  final settings = ChatVisualSettingsScope.of(context);
  final surfaces = context.tokens.surfaces;
  final base = isMe ? surfaces.bubbleOutgoing : surfaces.bubbleIncoming;
  return ShapeDecoration(
    color: context.isMaterial ? base : null,
    shape: settings.superellipseBorderEnabled
        ? RoundedSuperellipseBorder(borderRadius: borderRadius)
        : RoundedRectangleBorder(borderRadius: borderRadius),
    gradient: settings.bubbleGradientEnabled
        ? LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isMe
                ? [neuShift(base, .08), neuShift(base, -.06)]
                : [neuShift(base, .055), neuShift(base, -.05)],
          )
        : null,
    shadows: settings.bubbleShadowsEnabled
        ? neuBubbleShadows(
            colors,
            offset: offset,
            reduced: settings.shadowBlurOptimizationEnabled,
          )
        : const [],
  );
}

/// Raised/intensity .7 shadows, shared by media bubbles without their own
/// geometry changes. Reduced blur retains the original light/dark treatment.
List<BoxShadow> neuBubbleShadows(
  NeuColors colors, {
  double offset = 2.66,
  bool reduced = false,
}) => [
  BoxShadow(
    color: colors.shadowDark.withValues(alpha: .72),
    blurRadius: offset * (reduced ? 1.45 : 2.3),
    offset: Offset(offset, offset),
  ),
  BoxShadow(
    color: colors.shadowLight.withValues(alpha: colors.highlightAlpha),
    blurRadius: offset * (reduced ? 1.0 : 1.5),
    offset: Offset(-offset, -offset),
  ),
];

ShapeBorder neuBubbleShape(BuildContext context, BorderRadius borderRadius) =>
    ChatVisualSettingsScope.of(context).superellipseBorderEnabled
    ? RoundedSuperellipseBorder(borderRadius: borderRadius)
    : RoundedRectangleBorder(borderRadius: borderRadius);

List<BoxShadow> enabledNeuBubbleShadows(
  BuildContext context,
  NeuColors colors, {
  double offset = 2.66,
}) => ChatVisualSettingsScope.of(context).bubbleShadowsEnabled
    ? neuBubbleShadows(
        colors,
        offset: offset,
        reduced: ChatVisualSettingsScope.of(context)
            .shadowBlurOptimizationEnabled,
      )
    : const [];

ShapeDecoration attachmentBubbleDecoration(
  BuildContext context, {
  required bool isMe,
  BorderRadius? borderRadius,
}) {
  final radius = context.isMaterial
      ? borderRadius ??
            timelineBubbleBorderRadius(
              context,
              isMe: isMe,
              isFirst: true,
              isLast: true,
            )
      : BorderRadius.circular(NeuRadius.content);
  return ShapeDecoration(
    shape: neuBubbleShape(context, radius),
    color: messageBubbleFill(context, isMe: isMe),
    shadows: enabledNeuBubbleShadows(context, context.neu),
  );
}

/// The leading badge for downloadable files and shared locations.
class AttachmentBubbleIcon extends StatelessWidget {
  const AttachmentBubbleIcon({
    super.key,
    required this.icon,
    required this.isMe,
    this.location = false,
  });

  final IconData icon;
  final bool isMe;
  final bool location;

  @override
  Widget build(BuildContext context) {
    if (!context.isMaterial) {
      return Icon(
        icon,
        size: 30,
        color: isMe ? outgoingBubbleForeground(context) : context.neu.accent,
      );
    }
    final style = materialTimelineAttachmentIconStyle(
      Theme.of(context),
      location: location,
    );
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(color: style.fill, borderRadius: style.radius),
      child: Icon(icon, size: 20, color: style.foreground),
    );
  }
}

/// Text bubble surface only: content, metadata, gestures, menu anchors and
/// send-flight targets stay outside this widget at their existing boundaries.
class TimelineBubbleFrame extends StatelessWidget {
  const TimelineBubbleFrame({
    super.key,
    required this.isMe,
    required this.isFirst,
    required this.isLast,
    required this.child,
    this.bubbleKey,
  });

  final bool isMe;
  final bool isFirst;
  final bool isLast;
  final Widget child;
  final Key? bubbleKey;

  static double maxWidth(BuildContext context) => context.isMaterial
      ? math.min(MediaQuery.sizeOf(context).width, 720) * .75
      : math.min(MediaQuery.sizeOf(context).width * .68, 520);

  @override
  Widget build(BuildContext context) => Container(
    key: bubbleKey,
    constraints: BoxConstraints(maxWidth: maxWidth(context)),
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: neuBubbleDecoration(
      context,
      context.neu,
      isMe: isMe,
      borderRadius: timelineBubbleBorderRadius(
        context,
        isMe: isMe,
        isFirst: isFirst,
        isLast: isLast,
      ),
    ),
    child: child,
  );
}
