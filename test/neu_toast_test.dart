import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/widgets/neu_toast.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  for (final skin in const [false, true]) {
    final label = skin ? 'material' : 'neu';

    testWidgets('the toast stays clear of the composer ($label)', (
      tester,
    ) async {
      final pageContext = await _pumpPage(tester, material: skin);
      showNeuToast(pageContext, '已复制');
      await tester.pump();

      final screen = tester.getSize(find.byType(Scaffold));
      final text = tester.getRect(find.text('已复制'));
      expect(text.bottom, lessThanOrEqualTo(screen.height - neuToastBottomGap));
      expect(text.center.dx, closeTo(screen.width / 2, 1));

      final pill = tester.getSize(
        find
            .ancestor(of: find.text('已复制'), matching: find.byType(DecoratedBox))
            .first,
      );
      expect(pill.width, lessThanOrEqualTo(neuToastMaxWidth));
      expect(pill.width, lessThan(screen.width - 32));

      await tester.pump(const Duration(milliseconds: 1700));
      expect(find.text('已复制'), findsNothing);
    });

    testWidgets('a toast never swallows a tap ($label)', (tester) async {
      final pageContext = await _pumpPage(tester, material: skin);
      showNeuToast(pageContext, '已复制');
      await tester.pump();

      await tester.tapAt(tester.getCenter(find.text('已复制')));
      await tester.pump();
      expect(_backgroundTaps, 1);

      await tester.pump(const Duration(milliseconds: 1700));
    });
  }

  testWidgets('a toast appears when the caller holds the overlay context', (
    tester,
  ) async {
    late BuildContext overlayContext;
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: Builder(
          builder: (context) {
            overlayContext = Overlay.of(context, rootOverlay: true).context;
            return const Scaffold(body: SizedBox.expand());
          },
        ),
      ),
    );

    showNeuToast(overlayContext, '已复制');
    await tester.pump();
    expect(find.text('已复制'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('已复制'), findsNothing);
  });

  testWidgets('a second toast replaces the first', (tester) async {
    final pageContext = await _pumpPage(tester, material: false);
    showNeuToast(pageContext, '已复制');
    await tester.pump();
    showNeuToast(pageContext, '已 +1');
    await tester.pump();

    expect(find.text('已复制'), findsNothing);
    expect(find.text('已 +1'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 1700));
    expect(find.text('已 +1'), findsNothing);
  });
}

int _backgroundTaps = 0;

Future<BuildContext> _pumpPage(
  WidgetTester tester, {
  required bool material,
}) async {
  _backgroundTaps = 0;
  late BuildContext pageContext;
  await tester.pumpWidget(
    MaterialApp(
      theme: neuTestTheme(material: material),
      home: Builder(
        builder: (context) {
          pageContext = context;
          return Scaffold(
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => _backgroundTaps++,
              child: const SizedBox.expand(),
            ),
          );
        },
      ),
    ),
  );
  return pageContext;
}
