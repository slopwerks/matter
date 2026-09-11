import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'neu_decoration.dart';

/// 凹陷井式输入框。获取焦点时描一圈主色细边代替 Material 涟漪。
class NeuTextField extends StatelessWidget {
  const NeuTextField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.leading,
    this.trailing,
    this.obscureText = false,
    this.onChanged,
    this.onSubmitted,
    this.maxLines = 1,
    this.radius = NeuRadius.content,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
    this.autofocus = false,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final Widget? leading;
  final Widget? trailing;
  final bool obscureText;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final int maxLines;
  final double radius;
  final EdgeInsetsGeometry padding;
  final bool autofocus;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Focus(
      onFocusChange: (_) {},
      child: Builder(
        builder: (context) {
          final focused = Focus.of(context).hasFocus;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            padding: padding,
            decoration: NeuDecoration(
              colors: colors,
              depth: NeuDepth.pressed,
              radius: radius,
              intensity: .85,
              borderColor: focused ? colors.accent : null,
            ),
            child: Row(
              crossAxisAlignment: maxLines > 1
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.center,
              children: [
                if (leading != null) ...[
                  IconTheme.merge(
                    data: IconThemeData(size: 18, color: colors.textTertiary),
                    child: leading!,
                  ),
                  const SizedBox(width: 10),
                ],
                Expanded(
                  child: TextField(
                    controller: controller,
                    focusNode: focusNode,
                    obscureText: obscureText,
                    maxLines: maxLines,
                    autofocus: autofocus,
                    onChanged: onChanged,
                    onSubmitted: onSubmitted,
                    style: Theme.of(context).textTheme.bodyLarge,
                    cursorColor: colors.accent,
                    decoration: InputDecoration(
                      isCollapsed: true,
                      border: InputBorder.none,
                      hintText: hint,
                      hintStyle: Theme.of(context).textTheme.bodyLarge
                          ?.copyWith(color: colors.textTertiary),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                  ),
                ),
                if (trailing != null) ...[
                  const SizedBox(width: 10),
                  IconTheme.merge(
                    data: IconThemeData(size: 18, color: colors.textTertiary),
                    child: trailing!,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }
}
