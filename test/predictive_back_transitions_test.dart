import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/native_snapshot_transitions.dart';
import 'package:cupertino_ui/cupertino_ui.dart'
    show CupertinoPageTransitionsBuilder;
import 'package:matter/widgets/material_adaptive_shell.dart';
import 'package:matter/widgets/material_list_detail.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> gesture(
  WidgetTester tester,
  String method, [
  Map<String, Object>? args,
]) async {
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    'flutter/backgesture',
    const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
    (_) {},
  );
  await tester.pump();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'Android uses native predictive builder without changing iOS/desktop',
    () {
      final material = buildMaterialTheme(Brightness.light)
          .pageTransitionsTheme
          .builders;
      expect(
        material[TargetPlatform.android],
        isA<NativeSnapshotPageTransitionsBuilder>(),
      );
      expect(
        material[TargetPlatform.iOS],
        isA<CupertinoPageTransitionsBuilder>(),
      );
      expect(
        material[TargetPlatform.linux],
        isA<FadeForwardsPageTransitionsBuilder>(),
      );
    },
  );
  for (final cancel in [true, false]) {
    testWidgets('compact secondary predictive gesture cancel=$cancel', (
      tester,
    ) async {
      final position = ValueNotifier<double>(0);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light)
              .copyWith(platform: TargetPlatform.android),
          home: MaterialAdaptiveShell(
            window: MaterialWindowClass.compact,
            index: 0,
            onNavigate: (_) {},
            position: position,
            profile: const SizedBox(),
            railAccount: const SizedBox(),
            railActions: (_) => const SizedBox(),
            railSpaces: const SizedBox(),
            unreadCount: 0,
            chatOpen: false,
            dockBlurEnabled: false,
            pages: [
              MaterialListDetail(
                emptyLabel: 'Empty',
                emptyIcon: Icons.settings,
                list: Builder(
                  builder: (context) => Center(
                    child: TextButton(
                      onPressed: () => MaterialListDetail.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => const Scaffold(
                            body: Center(child: Text('Detail')),
                          ),
                        ),
                      ),
                      child: const Text('Open'),
                    ),
                  ),
                ),
              ),
              const SizedBox(),
              const SizedBox(),
              const SizedBox(),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsOneWidget);
      await gesture(tester, 'startBackGesture', {
        'touchOffset': <double>[5, 300],
        'progress': 0.0,
        'swipeEdge': 0,
      });
      await gesture(tester, 'updateBackGestureProgress', {
        'touchOffset': <double>[150, 300],
        'progress': 0.5,
        'swipeEdge': 0,
      });
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) => w.runtimeType.toString().contains(
            'PredictiveBackSharedElementPageTransition',
          ),
        ),
        findsWidgets,
      );
      expect(find.text('Open'), findsOneWidget);
      await gesture(tester, cancel ? 'cancelBackGesture' : 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('Detail'), cancel ? findsOneWidget : findsNothing);
      if (cancel) {
        await tester.binding.handlePopRoute();
        await tester.pumpAndSettle();
      }
      expect(find.text('Open'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      position.dispose();
    }, variant: const TargetPlatformVariant({TargetPlatform.android}));
  }
}
