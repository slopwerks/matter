import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/neu_colors.dart';

/// 为自绘控件提供统一的键盘操作、焦点轮廓和读屏状态。
class NeuAction extends StatefulWidget {
  const NeuAction({
    super.key,
    required this.onTap,
    required this.child,
    this.onPressedChanged,
    this.onLongPress,
    this.onSecondaryTap,
    this.label,
    this.selected,
    this.toggled,
    this.radius = NeuRadius.button,
  });

  final VoidCallback? onTap;
  final ValueChanged<bool>? onPressedChanged;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final String? label;
  final bool? selected;
  final bool? toggled;
  final double radius;
  final Widget child;

  @override
  State<NeuAction> createState() => _NeuActionState();
}

class _NeuActionState extends State<NeuAction> {
  bool _focusVisible = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Semantics(
      button: widget.toggled == null,
      enabled: enabled,
      label: widget.label,
      selected: widget.selected,
      toggled: widget.toggled,
      onTap: widget.onTap,
      onLongPress: widget.onLongPress,
      child: FocusableActionDetector(
        enabled: enabled,
        mouseCursor: enabled
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onShowFocusHighlight: (value) => setState(() => _focusVisible = value),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(
            onInvoke: (_) {
              widget.onTap?.call();
              return null;
            },
          ),
        },
        child: GestureDetector(
          excludeFromSemantics: true,
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          onLongPress: enabled ? widget.onLongPress : null,
          onSecondaryTap: enabled ? widget.onSecondaryTap : null,
          onTapDown: enabled
              ? (_) => widget.onPressedChanged?.call(true)
              : null,
          onTapUp: enabled ? (_) => widget.onPressedChanged?.call(false) : null,
          onTapCancel: enabled
              ? () => widget.onPressedChanged?.call(false)
              : null,
          child: Container(
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            foregroundDecoration: ShapeDecoration(
              shape: RoundedSuperellipseBorder(
                borderRadius: BorderRadius.circular(widget.radius),
                side: BorderSide(
                  color: enabled && _focusVisible
                      ? context.neu.accent
                      : Colors.transparent,
                  width: 2,
                ),
              ),
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
