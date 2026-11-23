import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/theme/material_theme.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets('Material sent notice fits a narrow view with enlarged text', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(
            body: Center(
              child: LatestMessageControl(
                visible: true,
                showSentNotice: true,
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(Ink)).width, lessThanOrEqualTo(288));
    expect(
      tester.getSize(find.byType(InkWell)).height,
      greaterThanOrEqualTo(48),
    );
    expect(
      tester.widget<InkWell>(find.byType(InkWell)).customBorder,
      isA<StadiumBorder>(),
    );
    await tester.tap(find.bySemanticsLabel('消息已发送，查看最新消息'));
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });

  group('latest-message thresholds', () {
    test('selects flight, insertion, and quiet presentations', () {
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 100,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.flight,
      );
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 101,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.insert,
      );
      expect(
        resolveMessageSendPresentation(
          distanceFromLatest: 801,
          viewportDimension: 1000,
        ),
        MessageSendPresentation.quiet,
      );
    });

    test('auto-scrolls within 80 percent of the viewport', () {
      expect(
        shouldAutoScrollToLatest(
          distanceFromLatest: 799,
          viewportDimension: 1000,
        ),
        isTrue,
      );
      expect(
        shouldAutoScrollToLatest(
          distanceFromLatest: 801,
          viewportDimension: 1000,
        ),
        isFalse,
      );
    });

    test('uses hysteresis to keep the latest button stable', () {
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 501,
          viewportDimension: 1000,
          currentlyVisible: false,
        ),
        isTrue,
      );
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 300,
          viewportDimension: 1000,
          currentlyVisible: true,
        ),
        isTrue,
      );
      expect(
        shouldShowLatestMessageControl(
          distanceFromLatest: 149,
          viewportDimension: 1000,
          currentlyVisible: true,
        ),
        isFalse,
      );
    });
  });

  testWidgets('updates the latest-message action after sending', (
    tester,
  ) async {
    Future<void> pumpControl(bool showSentNotice) {
      return tester.pumpWidget(
        MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: Center(
              child: LatestMessageControl(
                visible: true,
                showSentNotice: showSentNotice,
                onPressed: () {},
              ),
            ),
          ),
        ),
      );
    }

    await pumpControl(false);
    expect(find.byIcon(Icons.keyboard_arrow_down_rounded), findsOneWidget);

    await pumpControl(true);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.bySemanticsLabel('消息已发送，查看最新消息'), findsOneWidget);

    await pumpControl(false);
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.bySemanticsLabel('滚动到最新消息'), findsOneWidget);
  });
}
