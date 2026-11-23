import 'package:material_ui/material_ui.dart';

import '../../widgets/max_content_width.dart';

/// Shared bounds for notices floating above the Material timeline.
class ChatNoticeFrame extends StatelessWidget {
  const ChatNoticeFrame({super.key, required this.child});

  static const shape = RoundedRectangleBorder(
    borderRadius: BorderRadius.all(Radius.circular(12)),
  );
  static const topGap = 4.0;

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(16, topGap, 16, 0),
    child: MaxContentWidth(child: child),
  );
}
