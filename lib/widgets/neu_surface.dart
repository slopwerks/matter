import 'package:flutter/material.dart';

import '../providers/chat_visual_settings_provider.dart';
import '../theme/neu_colors.dart';
import 'material_press.dart';
import 'neu_action.dart';
import 'neu_decoration.dart';

/// 静态新拟物容器。
class NeuSurface extends StatelessWidget {
  const NeuSurface({
    super.key,
    this.depth = NeuDepth.raised,
    this.radius = NeuRadius.content,
    this.color,
    this.accent = false,
    this.intensity = 1,
    this.borderColor,
    this.padding,
    this.width,
    this.height,
    required this.child,
  });

  final NeuDepth depth;
  final double radius;
  final Color? color;
  final bool accent;
  final double intensity;
  final Color? borderColor;
  final EdgeInsetsGeometry? padding;
  final double? width;
  final double? height;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return Material(
        color: accent ? context.neu.accent : (color ?? context.neu.surface),
        shape: RoundedSuperellipseBorder(
          borderRadius: BorderRadius.circular(radius),
          side: borderColor == null
              ? BorderSide.none
              : BorderSide(color: borderColor!),
        ),
        child: SizedBox(
          width: width,
          height: height,
          child: Padding(padding: padding ?? EdgeInsets.zero, child: child),
        ),
      );
    }
    return Container(
      width: width,
      height: height,
      padding: padding,
      decoration: NeuDecoration(
        colors: context.neu,
        superellipseEnabled: ChatVisualSettingsScope.of(context)
            .superellipseBorderEnabled,
        depth: depth,
        radius: radius,
        color: color,
        accent: accent,
        intensity: intensity,
        borderColor: borderColor,
      ),
      child: child,
    );
  }
}

/// 可按压的新拟物按钮:按下时凸起 → 凹陷,带微缩放。
class NeuButton extends StatefulWidget {
  const NeuButton({
    super.key,
    this.onPressed,
    this.accent = false,
    this.radius = NeuRadius.button,
    this.padding = const EdgeInsets.symmetric(horizontal: 20, vertical: 13),
    this.intensity = 1,
    this.icon,
    required this.child,
  });

  final VoidCallback? onPressed;
  final bool accent;
  final double radius;
  final EdgeInsetsGeometry padding;

  /// 阴影强度系数(小控件用 0.6~0.8,避免阴影比本体还重)。
  final double intensity;
  final Widget? icon;
  final Widget child;

  @override
  State<NeuButton> createState() => _NeuButtonState();
}

class _NeuButtonState extends State<NeuButton> {
  bool _pressed = false;

  void _set(bool v) {
    if (widget.onPressed == null || _pressed == v) return;
    setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    if (context.isMaterial) {
      final style = MaterialPress.feedbackStyle.copyWith(
        padding: WidgetStatePropertyAll(widget.padding),
      );
      final content = widget.icon == null
          ? widget.child
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                widget.icon!,
                const SizedBox(width: 8),
                Flexible(child: widget.child),
              ],
            );
      return MaterialPress(
        builder: (states) => widget.accent
            ? FilledButton(
                statesController: states,
                onPressed: widget.onPressed,
                style: style,
                child: content,
              )
            : FilledButton.tonal(
                statesController: states,
                onPressed: widget.onPressed,
                style: style,
                child: content,
              ),
      );
    }
    final enabled = widget.onPressed != null;
    var child = DefaultTextStyle.merge(
      style: Theme.of(context).textTheme.labelLarge
          ?.copyWith(color: widget.accent ? colors.onAccent : colors.text),
      child: IconTheme.merge(
        data: IconThemeData(
          size: 18,
          color: widget.accent ? colors.onAccent : colors.textSecondary,
        ),
        // Center:父级给定宽度(如全宽按钮)时内容居中;
        // 无界时收缩到内容大小,行为不变。
        child: Center(
          widthFactor: 1,
          child: widget.icon == null
              ? widget.child
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    widget.icon!,
                    const SizedBox(width: 8),
                    Flexible(child: widget.child),
                  ],
                ),
        ),
      ),
    );

    return NeuAction(
      onTap: widget.onPressed,
      onPressedChanged: _set,
      radius: widget.radius,
      child: AnimatedScale(
        scale: _pressed ? 0.975 : 1,
        duration: const Duration(milliseconds: 110),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: widget.padding,
          decoration: NeuDecoration(
            colors: colors,
            superellipseEnabled: ChatVisualSettingsScope.of(context)
                .superellipseBorderEnabled,
            depth: !enabled
                ? NeuDepth.flat
                : _pressed
                ? NeuDepth.pressed
                : NeuDepth.raised,
            radius: widget.radius,
            accent: widget.accent,
            intensity: widget.intensity,
            color: !enabled ? colors.base : null,
          ),
          child: Opacity(opacity: enabled ? 1 : .45, child: child),
        ),
      ),
    );
  }
}

/// 图标按钮(圆形超椭圆)。
class NeuIconButton extends StatefulWidget {
  const NeuIconButton({
    super.key,
    required this.icon,
    this.onPressed,
    this.size = 44,
    this.accent = false,
    this.selected = false,
    this.badge = false,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback? onPressed;
  final double size;
  final bool accent;
  final bool selected;
  final bool badge;
  final String? tooltip;

  @override
  State<NeuIconButton> createState() => _NeuIconButtonState();
}

class _NeuIconButtonState extends State<NeuIconButton> {
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    if (context.isMaterial) {
      final style = IconButton.styleFrom(
        minimumSize: Size.square(widget.size),
        maximumSize: Size.square(widget.size),
        padding: EdgeInsets.zero,
        iconSize: widget.size * .44,
      ).merge(MaterialPress.feedbackStyle);
      final icon = widget.badge
          ? Badge(child: Icon(widget.icon))
          : Icon(widget.icon);
      return MaterialPress(
        builder: (states) {
          if (widget.accent) {
            return IconButton.filled(
              statesController: states,
              style: style,
              onPressed: widget.onPressed,
              tooltip: widget.tooltip,
              icon: icon,
            );
          }
          if (widget.selected) {
            return IconButton.filledTonal(
              statesController: states,
              style: style,
              isSelected: true,
              onPressed: widget.onPressed,
              tooltip: widget.tooltip,
              icon: icon,
            );
          }
          return IconButton(
            statesController: states,
            style: style,
            onPressed: widget.onPressed,
            tooltip: widget.tooltip,
            icon: icon,
          );
        },
      );
    }
    final enabled = widget.onPressed != null;
    final active = enabled && (widget.accent || widget.selected);
    final fg = active ? colors.onAccent : colors.textSecondary;

    Widget button = NeuAction(
      onTap: widget.onPressed,
      label: widget.tooltip,
      selected: widget.selected ? true : null,
      radius: widget.size / 2.6,
      onPressedChanged: (value) => setState(() => _pressed = value),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 110),
        width: widget.size,
        height: widget.size,
        decoration: NeuDecoration(
          colors: colors,
          superellipseEnabled: ChatVisualSettingsScope.of(context)
              .superellipseBorderEnabled,
          depth: !enabled
              ? NeuDepth.flat
              : _pressed
              ? NeuDepth.pressed
              : NeuDepth.raised,
          radius: widget.size / 2.6,
          accent: active,
          intensity: .8,
        ),
        child: Icon(
          widget.icon,
          size: widget.size * .44,
          color: enabled ? fg : fg.withValues(alpha: .45),
        ),
      ),
    );

    if (widget.badge) {
      button = Stack(
        clipBehavior: Clip.none,
        children: [
          button,
          Positioned(
            right: 2,
            top: 2,
            child: Container(
              width: 9,
              height: 9,
              decoration: BoxDecoration(
                color: colors.error,
                shape: BoxShape.circle,
                border: Border.all(color: colors.base, width: 1.6),
              ),
            ),
          ),
        ],
      );
    }
    if (widget.tooltip != null) {
      button = Tooltip(
        message: widget.tooltip!,
        excludeFromSemantics: true,
        child: button,
      );
    }
    return button;
  }
}

/// 单段选中态小药丸(筛选、Tab)。
class NeuChip extends StatelessWidget {
  const NeuChip({
    super.key,
    required this.label,
    this.selected = false,
    this.onTap,
    this.onLongPress,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return GestureDetector(
        onLongPress: onLongPress,
        child: FilterChip(
          label: Text(label),
          selected: selected,
          avatar: icon == null ? null : Icon(icon, size: 18),
          onSelected: onTap == null ? null : (_) => onTap!(),
        ),
      );
    }
    return Semantics(
      selected: selected,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: NeuButton(
          onPressed: onTap,
          accent: selected,
          radius: NeuRadius.nav,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
          intensity: .7,
          icon: icon == null ? null : Icon(icon),
          child: Text(label),
        ),
      ),
    );
  }
}
