import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import 'sheets.dart';

/// One copy target attached directly to the Matrix identifier.
class MaterialIdentityId extends StatelessWidget {
  const MaterialIdentityId(this.value, {super.key});
  final String value;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () async {
      await Clipboard.setData(ClipboardData(text: value));
      if (context.mounted) neuToast(context, '已复制 Matrix ID');
    },
    icon: const Icon(Icons.copy_outlined),
    label: Text(value, textAlign: TextAlign.center),
  );
}
