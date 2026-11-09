import 'package:flutter/material.dart';

import '../../../features/markdown/markdown_format_toolbar.dart';
import '../../../providers/chat_visual_settings_provider.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/neu_decoration.dart';

/// Inline editor presentation. The host owns focus, keyboard handling, drafts
/// and the keyed send-flight boundary wrapped around this widget.
class ComposerTextField extends StatelessWidget {
  const ComposerTextField({
    super.key,
    required this.controller,
    required this.focusNode,
    required this.expanded,
    required this.compact,
    required this.readOnly,
    required this.onTap,
    this.onPaste,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final bool expanded;
  final bool compact;
  final bool readOnly;
  final VoidCallback onTap;
  final VoidCallback? onPaste;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    return Container(
      constraints: BoxConstraints(
        minHeight: expanded ? (compact ? 80 : 96) : 44,
        maxHeight: expanded
            ? (MediaQuery.sizeOf(context).height * .3).clamp(
                compact ? 80.0 : 96.0,
                240.0,
              )
            : 120,
      ),
      decoration: expanded || context.isMaterial
          ? null
          : NeuDecoration(
              colors: colors,
              superellipseEnabled: ChatVisualSettingsScope.of(context)
                  .superellipseBorderEnabled,
              depth: NeuDepth.pressed,
              radius: NeuRadius.content,
              intensity: .85,
              borderColor: focusNode.hasFocus ? colors.accent : null,
            ),
      child: TextField(
        controller: controller,
        focusNode: focusNode,
        readOnly: readOnly,
        contextMenuBuilder: (context, editable) =>
            markdownSelectionContextMenuBuilder(
              context,
              editable,
              onPaste: onPaste,
            ),
        style: Theme.of(context).textTheme.bodyLarge,
        cursorColor: colors.accent,
        decoration: InputDecoration(
          hintText: '消息',
          hintStyle: Theme.of(context).textTheme.bodyLarge
              ?.copyWith(color: colors.textTertiary),
          filled: expanded ? false : null,
          contentPadding: EdgeInsets.symmetric(
            horizontal: expanded ? 8 : 14,
            vertical: expanded ? 6 : 11,
          ),
          border: context.isMaterial && !expanded
              ? const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
                )
              : InputBorder.none,
          enabledBorder: context.isMaterial && !expanded
              ? const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
                )
              : InputBorder.none,
          focusedBorder: context.isMaterial && !expanded
              ? const OutlineInputBorder(
                  borderRadius: BorderRadius.all(Radius.circular(28)),
                  borderSide: BorderSide.none,
                )
              : InputBorder.none,
          isDense: true,
        ),
        minLines: expanded ? 3 : null,
        maxLines: null,
        textInputAction: TextInputAction.newline,
        keyboardType: TextInputType.multiline,
        onTap: onTap,
      ),
    );
  }
}
