import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/timeline/timeline_message_actions.dart';

void main() {
  testWidgets('the menu action context survives menu dismissal', (tester) async {
    BuildContext? menuContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            menuContext = Overlay.of(context, rootOverlay: true).context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(menuContext, isNotNull);
    final resolved = overlayActionContext(menuContext!);
    expect(resolved, same(menuContext));
    expect(resolved.mounted, isTrue);
  });

  testWidgets('a bubble context still resolves to the root overlay', (tester) async {
    BuildContext? bubbleContext;
    BuildContext? menuContext;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            bubbleContext = context;
            menuContext = Overlay.of(context, rootOverlay: true).context;
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(overlayActionContext(bubbleContext!), same(menuContext));
  });
}
