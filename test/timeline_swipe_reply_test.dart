import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/timeline/timeline_swipe_reply.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

void main() {
  final feedback = <String>[];
  setUp(() {
    feedback.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'HapticFeedback.vibrate') {
            feedback.add(call.arguments as String);
          }
          return null;
        });
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null),
  );

  for (final material in [false, true]) {
    for (final brightness in Brightness.values) {
      final label = '${material ? 'Material' : 'Neu'} $brightness';
      final theme = material
          ? buildMaterialTheme(brightness)
          : buildNeuTheme(
              brightness == Brightness.dark ? NeuColors.dark : NeuColors.light,
              brightness,
            );
      testWidgets(
        '$label clamps drag, rearms haptic feedback and settles without layout changes',
        (tester) async {
          var replies = 0;
          final linked = ValueNotifier(0.0);
          addTearDown(linked.dispose);
          await tester.pumpWidget(
            _app(theme, onReply: () => replies++, linked: linked),
          );
          final before = tester.getRect(find.byType(TimelineSwipeReply));
          final gesture = await tester.startGesture(
            tester.getCenter(find.byType(TimelineSwipeReply)),
          );
          await gesture.moveBy(const Offset(-90, 0));
          await tester.pump();
          expect(_offset(tester), -72);
          expect(linked.value, 72);
          expect(feedback, ['HapticFeedbackType.mediumImpact']);
          await gesture.moveBy(const Offset(30, 0));
          await tester.pump();
          expect(linked.value, 42);
          await gesture.moveBy(const Offset(-20, 0));
          await tester.pump();
          expect(linked.value, 62);
          expect(feedback, hasLength(2));
          expect(replies, 0);
          await gesture.up();
          await tester.pumpAndSettle();
          expect(replies, 1);
          expect(linked.value, 0);
          expect(_offset(tester), 0);
          expect(tester.getRect(find.byType(TimelineSwipeReply)), before);
        },
      );
    }
  }

  testWidgets('right drag and disabled reply do not move or vibrate', (
    tester,
  ) async {
    var replies = 0;
    final theme = buildMaterialTheme(Brightness.light);
    await tester.pumpWidget(_app(theme, onReply: () => replies++));
    await tester.drag(find.byType(TimelineSwipeReply), const Offset(80, 0));
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
    expect(replies, 0);
    expect(feedback, isEmpty);
    await tester.pumpWidget(_app(theme, onReply: null));
    await tester.drag(find.byType(TimelineSwipeReply), const Offset(-80, 0));
    await tester.pumpAndSettle();
    expect(_offset(tester), 0);
    expect(replies, 0);
    expect(feedback, isEmpty);
  });

  testWidgets('right 40dp exclusion remains strict at the boundary', (
    tester,
  ) async {
    var replies = 0;
    await tester.pumpWidget(
      _app(buildMaterialTheme(Brightness.light), onReply: () => replies++),
    );
    final rect = tester.getRect(find.byType(TimelineSwipeReply));
    for (final inset in [20.0, 40.0, 41.0]) {
      final gesture = await tester.startGesture(
        Offset(rect.right - inset, rect.center.dy),
      );
      await gesture.moveBy(const Offset(-70, 0));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(replies, inset > 40 ? 1 : 0);
    }
  });

  testWidgets(
    'replacing linked notifier resets the old owner and disposal resets the new owner',
    (tester) async {
      final old = ValueNotifier(0.0);
      final next = ValueNotifier(0.0);
      addTearDown(old.dispose);
      addTearDown(next.dispose);
      final theme = buildMaterialTheme(Brightness.light);
      await tester.pumpWidget(_app(theme, onReply: () {}, linked: old));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(TimelineSwipeReply)),
      );
      await gesture.moveBy(const Offset(-40, 0));
      await tester.pump();
      expect(old.value, 40);
      await tester.pumpWidget(_app(theme, onReply: () {}, linked: next));
      expect(old.value, 0);
      expect(next.value, 40);
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox());
      expect(next.value, 0);
    },
  );
}

double _offset(WidgetTester tester) => tester
    .widget<Transform>(find.byKey(const ValueKey('swipe-reply-content')))
    .transform
    .storage[12];
Widget _app(
  ThemeData theme, {
  required VoidCallback? onReply,
  ValueNotifier<double>? linked,
}) => MaterialApp(
  theme: theme,
  home: Scaffold(
    body: Align(
      alignment: Alignment.center,
      child: SizedBox(
        width: 300,
        height: 60,
        child: TimelineSwipeReply(
          key: const ValueKey('swipe'),
          onReply: onReply,
          linkedOffset: linked,
          child: const ColoredBox(color: Colors.blue, child: SizedBox.expand()),
        ),
      ),
    ),
  ),
);
