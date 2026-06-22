import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/chat_provider.dart';

void main() {
  test('send flight id stays stable across optimistic states', () {
    expect(sendFlightId('${localOutgoingPendingPrefix}42'), '42');
    expect(sendFlightId('${localOutgoingSentPrefix}42'), '42');
    expect(sendFlightId('${localOutgoingFailedPrefix}42'), '42');
  });

  testWidgets('send flight reveals the target after reaching it', (
    tester,
  ) async {
    const messageId = '${localOutgoingPendingPrefix}flight-test';
    const sourceKey = ValueKey('flight-source');
    const targetKey = ValueKey('flight-target');
    registerSendFlight(
      messageId,
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 180, 44),
        kind: SendFlightKind.text,
        child: ColoredBox(key: sourceKey, color: Colors.blue),
      ),
    );

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomRight,
            child: SendFlightTarget(
              messageId: messageId,
              child: SizedBox(key: targetKey, width: 90, height: 40),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byKey(sourceKey), findsOneWidget);
    final hiddenTarget = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(targetKey), matching: find.byType(Opacity)),
    );
    expect(hiddenTarget.opacity, 0);

    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byKey(sourceKey), findsNothing);
    final visibleTarget = tester.widget<Opacity>(
      find.ancestor(of: find.byKey(targetKey), matching: find.byType(Opacity)),
    );
    expect(visibleTarget.opacity, 1);

    await tester.pump(const Duration(seconds: 2));
  });
}
