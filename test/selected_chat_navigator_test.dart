import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/widgets/selected_chat_navigator.dart';

void main() {
  for (final commit in [false, true]) {
    testWidgets('native chat gesture ${commit ? 'commits' : 'cancels'}', (
      tester,
    ) async {
      String? room;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
              },
            ),
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SelectedChatNavigator(
                roomId: room,
                list: const Scaffold(body: Text('list')),
                detail: const Scaffold(body: Text('chat')),
                onChatPopped: () => setState(() => room = null),
              );
            },
          ),
        ),
      );
      update(() => room = 'room');
      await tester.pumpAndSettle();
      expect(await gesture(tester, 'startBackGesture', 0), isTrue);
      await tester.pump();
      await gesture(tester, 'updateBackGestureProgress', .5);
      await tester.pumpAndSettle();
      await tester.pump();
      expect(find.text('list'), findsOneWidget);
      expect(room, 'room');
      if (commit) {
        await gesture(tester, 'commitBackGesture');
      } else {
        await gesture(tester, 'cancelBackGesture');
      }
      await tester.pumpAndSettle();
      expect(room, commit ? isNull : 'room');
      expect(find.text(commit ? 'list' : 'chat'), findsOneWidget);
    });
  }

  testWidgets('split changes retain chat state and inactive tabs ignore back', (
    tester,
  ) async {
    var split = false;
    var active = true;
    var popped = 0;
    late StateSetter update;
    final detailKey = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SelectedChatNavigator(
              roomId: 'room',
              split: split,
              active: active,
              canPop: !split,
              list: const Scaffold(body: Text('list')),
              detail: StatefulBuilder(
                key: detailKey,
                builder: (_, _) => const Text('chat'),
              ),
              onChatPopped: () => popped++,
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final state = detailKey.currentState;
    update(() => split = true);
    await tester.pumpAndSettle();
    expect(detailKey.currentState, same(state));
    update(() {
      split = false;
      active = false;
    });
    await tester.pumpAndSettle();
    expect(detailKey.currentState, same(state));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(popped, 0);
  });

  for (final startSplit in [true, false]) {
    testWidgets(
      'split list remains visible and tappable startSplit=$startSplit',
      (tester) async {
        var split = startSplit;
        var taps = 0;
        late StateSetter update;
        final detailKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(platform: TargetPlatform.android),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return SelectedChatNavigator(
                  roomId: 'room',
                  split: split,
                  canPop: !split,
                  list: Align(
                    alignment: Alignment.centerLeft,
                    child: SizedBox(
                      width: 200,
                      child: TextButton(
                        onPressed: () => taps++,
                        child: const Text('Select room'),
                      ),
                    ),
                  ),
                  detail: Padding(
                    padding: EdgeInsets.only(left: split ? 220 : 0),
                    child: StatefulBuilder(
                      key: detailKey,
                      builder: (_, _) => const ColoredBox(
                        color: Colors.white,
                        child: Center(child: Text('chat')),
                      ),
                    ),
                  ),
                  onChatPopped: () {},
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        final state = detailKey.currentState;
        update(() => split = true);
        await tester.pumpAndSettle();
        expect(detailKey.currentState, same(state));
        expect(find.text('Select room'), findsOneWidget);
        await tester.tap(find.text('Select room'));
        expect(taps, 1);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets('predictive gesture reuses the chat repaint boundary', (
    tester,
  ) async {
    var paints = 0;
    String? room;
    late StateSetter update;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
            },
          ),
        ),
        home: StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return SelectedChatNavigator(
              roomId: room,
              list: const Scaffold(body: Text('list')),
              detail: CustomPaint(
                painter: _CountPaint(() => paints++),
                child: const SizedBox.expand(),
              ),
              onChatPopped: () => setState(() => room = null),
            );
          },
        ),
      ),
    );
    update(() => room = 'room');
    await tester.pumpAndSettle();
    expect(await gesture(tester, 'startBackGesture', 0), isTrue);
    await gesture(tester, 'updateBackGestureProgress', .2);
    await tester.pumpAndSettle();
    final before = paints;
    await gesture(tester, 'updateBackGestureProgress', .5);
    await tester.pumpAndSettle();
    expect(
      paints,
      before,
      reason: 'drag progress must not repaint the complete chat',
    );
    await gesture(tester, 'cancelBackGesture');
    await tester.pumpAndSettle();
  });

  testWidgets('chat guard vetoes native preview and consumes back first', (
    tester,
  ) async {
    var consumed = 0;
    var popped = 0;
    final key = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: key,
        theme: ThemeData(platform: TargetPlatform.android),
        home: SelectedChatNavigator(
          roomId: 'room',
          list: const Scaffold(body: Text('list')),
          detail: PopScope(
            canPop: false,
            onPopInvokedWithResult: (didPop, _) {
              if (!didPop) consumed++;
            },
            child: const Scaffold(body: Text('chat')),
          ),
          onChatPopped: () => popped++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(await gesture(tester, 'startBackGesture', 0), isFalse);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(consumed, 1);
    expect(popped, 0);
  });
}

class _CountPaint extends CustomPainter {
  _CountPaint(this.onPaint);
  final VoidCallback onPaint;
  @override
  void paint(Canvas canvas, Size size) => onPaint();
  @override
  bool shouldRepaint(_CountPaint oldDelegate) => false;
}

Future<dynamic> gesture(
  WidgetTester tester,
  String method, [
  double? progress,
]) async {
  Object? result;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(
      MethodCall(
        method,
        progress == null
            ? null
            : <String, dynamic>{
                'touchOffset': <double>[progress * 200, 200],
                'progress': progress,
                'swipeEdge': 0,
              },
      ),
    ),
    (data) {
      result = const StandardMethodCodec().decodeEnvelope(data!);
    },
  );
  return result;
}
