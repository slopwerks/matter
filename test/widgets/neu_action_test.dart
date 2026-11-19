import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/widgets/neu_action.dart';
import 'package:matter/widgets/neu_surface.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  testWidgets(
    'disabled Material actions mount and update without build notifications',
    (tester) async {
      var enabled = false;
      var taps = 0;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(material: true),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return NeuAction(
                  onTap: enabled ? () => taps++ : null,
                  child: const Text('Disabled action'),
                );
              },
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Disabled action'));
      expect(taps, 0);
      update(() => enabled = true);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Disabled action'));
      await tester.pumpAndSettle();
      expect(taps, 1);
      update(() => enabled = false);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Disabled action'));
      expect(taps, 1);
    },
  );

  testWidgets('focus border remains visible for keyboard activation', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: Scaffold(
          body: NeuButton(onPressed: () => taps++, child: const Text('Action')),
        ),
      ),
    );
    final container = find.descendant(
      of: find.byType(NeuAction),
      matching: find.byWidgetPredicate(
        (widget) =>
            widget is Container &&
            widget.constraints ==
                const BoxConstraints(minWidth: 44, minHeight: 44),
      ),
    );
    expect(tester.widget<Container>(container).foregroundDecoration, isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(tester.widget<Container>(container).foregroundDecoration, isNotNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    expect(taps, 1);
    await tester.tap(find.text('Action'));
    await tester.pumpAndSettle();
    expect(taps, 2);
    expect(tester.binding.hasScheduledFrame, isFalse);
  });
}
