part of 'material_theme.dart';

({
  Color fill,
  Color foreground,
  Color supporting,
  Color accent,
  BorderRadius radius,
})
materialTimelinePreviewStyle(ThemeData theme) => (
  fill: theme.colorScheme.surfaceContainerHighest,
  foreground: theme.colorScheme.onSurface,
  supporting: theme.colorScheme.onSurfaceVariant,
  accent: theme.colorScheme.primary,
  radius: const BorderRadius.all(Radius.circular(12)),
);

({Color fill, Color foreground, BorderRadius radius})
materialTimelineAttachmentIconStyle(ThemeData theme, {required bool location}) {
  final colors = theme.colorScheme;
  return (
    fill: location ? colors.tertiaryContainer : colors.secondaryContainer,
    foreground: location
        ? colors.onTertiaryContainer
        : colors.onSecondaryContainer,
    radius: const BorderRadius.all(Radius.circular(10)),
  );
}

({Color selection, Color badge, Color badgeText, Color placeholder})
materialGalleryStyle(ThemeData theme) => (
  selection: theme.colorScheme.secondaryContainer,
  badge: theme.colorScheme.primary,
  badgeText: theme.colorScheme.onPrimary,
  placeholder: theme.colorScheme.surfaceContainerHigh,
);

({Color fill, ShapeBorder shape, TextStyle? title, TextStyle? status})
materialAttachmentStageStyle(ThemeData theme) => (
  fill: theme.colorScheme.surfaceContainerLow,
  shape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(18)),
  ),
  title: theme.textTheme.labelLarge,
  status: theme.textTheme.labelSmall?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  ),
);

({ShapeBorder cellShape, Color fill, Color selected, TextStyle? heading})
materialEmojiPickerStyle(ThemeData theme) => (
  cellShape: const RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(10)),
  ),
  fill: theme.colorScheme.surfaceContainerHigh,
  selected: theme.colorScheme.secondaryContainer,
  heading: theme.textTheme.titleSmall?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  ),
);

({Color fill, ShapeBorder shape}) materialComposerPickerStyle(
  ThemeData theme,
) =>
    (fill: theme.colorScheme.surfaceContainerLow, shape: materialListItemShape);

({
  Color fill,
  Color foreground,
  ShapeBorder shape,
  TextStyle? title,
  TextStyle? preview,
})
materialPinnedStripStyle(ThemeData theme) {
  final foreground = theme.colorScheme.onTertiaryContainer;
  return (
    fill: theme.colorScheme.tertiaryContainer,
    foreground: foreground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    title: theme.textTheme.labelMedium?.copyWith(color: foreground),
    preview: theme.textTheme.bodySmall?.copyWith(color: foreground),
  );
}

({Color fill, Color action, BorderRadius radius, TextStyle? text})
materialForwardNoticeStyle(ThemeData theme) => (
  fill: theme.colorScheme.inverseSurface,
  action: theme.colorScheme.inversePrimary,
  radius: BorderRadius.circular(8),
  text: theme.textTheme.bodyMedium?.copyWith(
    color: theme.colorScheme.onInverseSurface,
  ),
);

TextStyle? materialListTitleStyle(ThemeData theme, {bool unread = false}) =>
    theme.textTheme.titleMedium?.copyWith(
      fontSize: 16,
      fontWeight: unread ? FontWeight.w600 : FontWeight.w500,
    );

TextStyle materialReaderTextStyle(ThemeData theme) =>
    theme.textTheme.bodyLarge!.copyWith(height: 1.65);

({Color base, Color surface, Color text, Color textSecondary, Color accent})
materialMediaChromeStyle(ThemeData theme) => (
  base: theme.colorScheme.surface,
  surface: theme.colorScheme.surfaceContainerHigh,
  text: theme.colorScheme.onSurface,
  textSecondary: theme.colorScheme.onSurfaceVariant,
  accent: theme.colorScheme.primary,
);

({Color fill, Color foreground}) materialImageControlColors(
  ThemeData theme, {
  required bool overPhoto,
}) => overPhoto
    ? (fill: Colors.black.withValues(alpha: .72), foreground: Colors.white)
    : (
        fill: theme.colorScheme.secondaryContainer,
        foreground: theme.colorScheme.onSecondaryContainer,
      );

({Decoration decoration, Color foreground, TextStyle? label})
materialTimelineEventStyle(ThemeData theme) {
  final foreground = theme.colorScheme.onSurfaceVariant;
  return (
    decoration: ShapeDecoration(
      color: theme.colorScheme.surfaceContainer,
      shape: const StadiumBorder(),
    ),
    foreground: foreground,
    label: theme.textTheme.labelMedium?.copyWith(color: foreground),
  );
}

({Color fill, Color foreground}) materialRoomMembershipColors(
  ThemeData theme,
) => (
  fill: theme.colorScheme.tertiaryContainer,
  foreground: theme.colorScheme.onTertiaryContainer,
);

({
  Color background,
  Color foreground,
  Color supporting,
  ButtonStyle control,
  Decoration overlayDecoration,
  TextStyle? caption,
  TextStyle? title,
  TextStyle? counter,
  SliderThemeData slider,
})
materialMediaViewerStyle(ThemeData theme) => (
  background: Colors.black,
  foreground: Colors.white,
  supporting: Colors.white70,
  control: IconButton.styleFrom(
    backgroundColor: Colors.white.withValues(alpha: .14),
    foregroundColor: Colors.white,
    disabledBackgroundColor: Colors.white.withValues(alpha: .06),
    disabledForegroundColor: Colors.white38,
    shape: const StadiumBorder(),
  ),
  overlayDecoration: ShapeDecoration(
    color: Colors.black.withValues(alpha: .75),
    shape: materialListItemShape,
  ),
  caption: theme.textTheme.bodyLarge?.copyWith(color: Colors.white),
  title: theme.textTheme.titleMedium?.copyWith(color: Colors.white),
  counter: theme.textTheme.labelMedium?.copyWith(color: Colors.white),
  slider: theme.sliderTheme.copyWith(
    activeTrackColor: materialMediaProgressColor(theme),
    thumbColor: materialMediaProgressColor(theme),
    inactiveTrackColor: Colors.white24,
  ),
);

Color materialMediaProgressColor(ThemeData theme) =>
    theme.brightness == Brightness.dark
    ? theme.colorScheme.primary
    : theme.colorScheme.inversePrimary;

const materialAttachmentCaptionDecoration = InputDecoration(
  hintText: '添加图片描述',
  filled: false,
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
  isDense: true,
  counterText: '',
);

final materialMarkdownEditorDecoration = materialAttachmentCaptionDecoration
    .copyWith(
      hintText: '用 Markdown 编写消息…',
      contentPadding: const EdgeInsets.all(20),
    );
