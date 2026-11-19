import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'neu_field.dart';

class AppSearchField extends StatelessWidget {
  const AppSearchField({
    super.key,
    required this.hint,
    this.controller,
    this.focusNode,
    this.trailing,
    this.onChanged,
    this.onSubmitted,
    this.textInputAction,
  });

  final String hint;
  final TextEditingController? controller;
  final FocusNode? focusNode;
  final Widget? trailing;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final TextInputAction? textInputAction;

  @override
  Widget build(BuildContext context) {
    if (context.isMaterial) {
      return SearchBar(
        controller: controller,
        focusNode: focusNode,
        hintText: hint,
        leading: const Icon(Icons.search_rounded),
        trailing: trailing == null ? null : [trailing!],
        onChanged: onChanged,
        onSubmitted: onSubmitted,
        textInputAction: textInputAction,
      );
    }
    return NeuTextField(
      controller: controller,
      focusNode: focusNode,
      hint: hint,
      leading: const Icon(Icons.search_rounded),
      trailing: trailing,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: textInputAction,
    );
  }
}
