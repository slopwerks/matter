part of 'material_theme.dart';

const materialComposerRadius = BorderRadius.all(Radius.circular(28));

const double materialMessageMenuMaxWidth = 320;

ButtonStyle materialMessageMenuActionStyle(
  ThemeData theme, {
  bool destructive = false,
}) => TextButton.styleFrom(
  foregroundColor: destructive
      ? theme.colorScheme.error
      : theme.colorScheme.onSurface,
  textStyle: theme.textTheme.labelLarge,
  alignment: Alignment.centerLeft,
  minimumSize: const Size(0, 48),
  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
  shape: materialEmojiPickerStyle(theme).cellShape,
);

({Color fill, ShapeBorder shape, double elevation, TextStyle? label})
materialTimelineDateStyle(ThemeData theme, {required bool floating}) => (
  fill: floating
      ? theme.colorScheme.surfaceContainerHigh
      : theme.colorScheme.surfaceContainer,
  shape: const StadiumBorder(),
  elevation: floating ? 1 : 0,
  label: theme.textTheme.labelMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  ),
);

({Color fill, ShapeBorder shape, ButtonStyle action, Color foreground})
materialUnreadBannerStyle(ThemeData theme) => (
  fill: theme.colorScheme.secondaryContainer,
  shape: materialListItemShape,
  foreground: theme.colorScheme.onSecondaryContainer,
  action: TextButton.styleFrom(
    foregroundColor: theme.colorScheme.onSecondaryContainer,
    disabledForegroundColor: theme.colorScheme.onSecondaryContainer.withValues(
      alpha: .38,
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
  ),
);

({Color headerFill, Color headerForeground, Color border})
materialHtmlTableStyle(ThemeData theme) => (
  headerFill: theme.colorScheme.surfaceContainerHighest,
  headerForeground: theme.colorScheme.onSurface,
  border: theme.dividerColor,
);

({Color fill, Color foreground, BorderRadius radius})
materialHtmlImagePlaceholderStyle(ThemeData theme) => (
  fill: theme.colorScheme.surfaceContainerHighest,
  foreground: theme.colorScheme.onSurfaceVariant,
  radius: const BorderRadius.all(Radius.circular(12)),
);

({
  Color fill,
  Color foreground,
  Color divider,
  BorderRadius radius,
  TextStyle? label,
  ButtonStyle copyButton,
})
materialCodeBlockChromeStyle(ThemeData theme) => (
  fill: theme.colorScheme.surfaceContainerHigh,
  foreground: theme.colorScheme.onSurfaceVariant,
  divider: theme.dividerColor,
  radius: const BorderRadius.all(Radius.circular(12)),
  label: theme.textTheme.labelMedium?.copyWith(
    color: theme.colorScheme.onSurfaceVariant,
  ),
  copyButton: TextButton.styleFrom(
    foregroundColor: theme.colorScheme.primary,
    textStyle: theme.textTheme.labelLarge,
  ),
);

const materialTimelinePillInset = 8.0;
const materialTimelinePillIcon = 20.0;

const materialTimelineArrow = 16.0;
const materialTimelineJumpPadding = EdgeInsetsDirectional.only(
  start: 10,
  end: 14,
);

ButtonStyle materialUnreadJumpStyle(BuildContext context) =>
    FilledButton.styleFrom(
      minimumSize: Size(0, materialTimelinePillHeight(context)),
      visualDensity: VisualDensity.standard,
      textStyle: Theme.of(context).textTheme.labelMedium
          ?.copyWith(fontWeight: FontWeight.w600),
      padding: materialTimelineJumpPadding,
      shape: const StadiumBorder(),
    );

double materialTimelinePillHeight(BuildContext context) {
  final label = Theme.of(context).textTheme.labelMedium!;
  final lineHeight =
      MediaQuery.textScalerOf(context).scale(label.fontSize!) * label.height!;
  return lineHeight.clamp(materialTimelinePillIcon, double.infinity) +
      2 * materialTimelinePillInset;
}

({ShapeBorder shape, TextStyle notice, TextStyle action})
materialLatestMessageStyle(ThemeData theme) {
  final notice = theme.textTheme.labelMedium!.copyWith(
    color: theme.colorScheme.onSecondaryContainer,
  );
  return (
    shape: const StadiumBorder(),
    notice: notice,
    action: notice.copyWith(fontWeight: FontWeight.w700),
  );
}

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

({OutlinedBorder cellShape, Color fill, Color selected, TextStyle? heading})
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
  final foreground = theme.colorScheme.primary;
  return (
    fill: theme.colorScheme.surfaceContainerLow,
    foreground: foreground,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.all(Radius.circular(12)),
    ),
    title: theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    ),
    preview: theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurface,
    ),
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

const desktopPickerGroupInset = 6.0;
const desktopPickerGroupSize = 44.0;
const desktopPickerGroupGap = 4.0;
const desktopPickerFooterHeight =
    desktopPickerGroupSize + desktopPickerGroupInset * 2;

double desktopPickerGroupRadius(BuildContext context) =>
    (context.isMaterial ? materialSurfaceRadius : NeuRadius.content) -
    desktopPickerGroupInset;

ButtonStyle desktopPickerGroupButtonStyle(
  BuildContext context, {
  required bool selected,
}) => IconButton.styleFrom(
  fixedSize: const Size.square(desktopPickerGroupSize),
  minimumSize: const Size.square(desktopPickerGroupSize),
  maximumSize: const Size.square(desktopPickerGroupSize),
  padding: EdgeInsets.zero,
  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
  backgroundColor: selected ? context.neu.accentSoft : Colors.transparent,
  shape: RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(desktopPickerGroupRadius(context)),
  ),
);

({Color fill, ShapeBorder shape, double elevation, ButtonStyle tab})
desktopComposerPickerStyle(BuildContext context, {required bool selected}) {
  final theme = Theme.of(context);
  final colors = context.neu;
  return (
    fill: context.isMaterial
        ? theme.colorScheme.surfaceContainerLow
        : colors.surfaceStrong,
    shape: context.isMaterial
        ? materialListItemShape
        : const RoundedRectangleBorder(
            borderRadius: BorderRadius.all(Radius.circular(NeuRadius.content)),
          ),
    elevation: 8,
    tab: TextButton.styleFrom(
      foregroundColor: selected ? colors.accent : colors.textSecondary,
      textStyle: theme.textTheme.labelLarge,
      shape: const RoundedRectangleBorder(),
    ),
  );
}

({
  BoxDecoration decoration,
  TextStyle name,
  TextStyle details,
  EdgeInsets padding,
})
desktopPickerPreviewStyle(BuildContext context) {
  final theme = Theme.of(context);
  final colors = context.neu;
  final material = context.isMaterial;
  final fill = material
      ? theme.colorScheme.surfaceContainerHigh
      : colors.surfaceStrong;
  return (
    decoration: BoxDecoration(
      color: fill,
      borderRadius: BorderRadius.circular(material ? 16 : NeuRadius.content),
      border: Border.all(
        color: material
            ? theme.colorScheme.outlineVariant.withValues(alpha: .5)
            : colors.hairline,
      ),
      gradient: material
          ? null
          : LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [neuShift(fill, .025), fill, neuShift(fill, -.015)],
            ),
      boxShadow: material
          ? [
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: .18),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
              BoxShadow(
                color: theme.colorScheme.shadow.withValues(alpha: .10),
                blurRadius: 4,
                offset: const Offset(0, 2),
              ),
            ]
          : [
              BoxShadow(
                color: colors.shadowLight.withValues(
                  alpha: colors.highlightAlpha,
                ),
                blurRadius: 10,
                offset: const Offset(-3, -3),
              ),
              BoxShadow(
                color: colors.shadowDark.withValues(alpha: .8),
                blurRadius: 18,
                offset: const Offset(5, 7),
              ),
            ],
    ),
    name: theme.textTheme.labelLarge!.copyWith(
      color: material ? theme.colorScheme.onSurface : colors.text,
    ),
    details: theme.textTheme.bodySmall!.copyWith(
      color: material
          ? theme.colorScheme.onSurfaceVariant
          : colors.textSecondary,
    ),
    padding: const EdgeInsets.fromLTRB(14, 10, 14, 14),
  );
}
