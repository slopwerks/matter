import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/widgets/predictive_home_back.dart';

import 'selected_chat_navigator_test.dart' show gesture;

void main() {
  testWidgets(
    'native home eligibility follows root, child route and keyboard',
    (tester) async {
      final eligibility = <bool>[];
      const channel = MethodChannel('moe.aks.matter/home_back');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        expect(call.method, 'setEligible');
        eligibility.add(call.arguments as bool);
        return null;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      final navigator = GlobalKey<NavigatorState>();
      final pageKey = GlobalKey();
      var keyboard = false;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigator,
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
              },
            ),
          ),
          builder: (context, child) => StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  viewInsets: EdgeInsets.only(bottom: keyboard ? 200 : 0),
                ),
                child: PredictiveHomeBack(enabled: true, child: child!),
              );
            },
          ),
          home: StatefulBuilder(
            key: pageKey,
            builder: (_, _) => const Scaffold(body: Text('Home')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final homeState = pageKey.currentState;
      expect(eligibility.last, true);
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Detail')),
        ),
      );
      await tester.pumpAndSettle();
      expect(eligibility.last, false);
      expect(await gesture(tester, 'startBackGesture', 0), true);
      await gesture(tester, 'updateBackGestureProgress', .5);
      await gesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(find.text('Detail'), findsNothing);
      expect(eligibility.last, true);
      expect(pageKey.currentState, same(homeState));
      update(() => keyboard = true);
      await tester.pumpAndSettle();
      expect(eligibility.last, false);
      update(() => keyboard = false);
      await tester.pumpAndSettle();
      expect(eligibility.last, true);
      await tester.pumpWidget(const SizedBox());
      expect(eligibility.last, false);
    },
    variant: const TargetPlatformVariant({TargetPlatform.android}),
  );
}
