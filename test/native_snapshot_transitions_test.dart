import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/widgets/native_snapshot_transitions.dart';
import 'package:matter/widgets/selected_chat_navigator.dart';

import 'selected_chat_navigator_test.dart' show gesture;

void main() {
  for (final available in [false, true]) {
    testWidgets(
      'Flutter never owns snapshot-route gesture available=$available',
      (tester) async {
        const channel = MethodChannel('moe.aks.matter/route_back');
        final calls = <MethodCall>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            calls.add(call);
            return available && call.method == 'prepare';
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            theme: ThemeData(
              platform: TargetPlatform.android,
              pageTransitionsTheme: const PageTransitionsTheme(
                builders: {
                  TargetPlatform.android:
                      NativeSnapshotPageTransitionsBuilder(),
                },
              ),
            ),
            home: const Scaffold(body: Text('List')),
          ),
        );
        final route = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Detail')),
        );
        navigator.currentState!.push(route);
        await tester.pump();
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 80));
        });
        await tester.pumpAndSettle();
        expect(await gesture(tester, 'startBackGesture', 0), false);
        await gesture(tester, 'cancelBackGesture');
        expect(find.text('Detail'), findsOneWidget);
        await tester.pump(const Duration(milliseconds: 200));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
        expect(calls.any((call) => call.method == 'prepare'), true);
        expect(await gesture(tester, 'startBackGesture', 0), false);
        await gesture(tester, 'updateBackGestureProgress', .5);
        await tester.pump();
        expect(route.popGestureInProgress, false);
        expect(route.animation!.value, 1);
        await gesture(tester, 'commitBackGesture');
        await tester.pump();
        expect(find.text('Detail'), findsNothing);
        expect(find.text('List'), findsOneWidget);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'image back gesture closes viewer without popping selected chat',
    (tester) async {
      final root = GlobalKey<NavigatorState>();
      String? room;
      late StateSetter update;
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: root,
          navigatorObservers: [NativeSnapshotNavigationObserver()],
          theme: ThemeData(
            platform: TargetPlatform.android,
            pageTransitionsTheme: const PageTransitionsTheme(
              builders: {
                TargetPlatform.android: NativeSnapshotPageTransitionsBuilder(),
              },
            ),
          ),
          home: StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return SelectedChatNavigator(
                roomId: room,
                list: const Scaffold(body: Text('List')),
                detail: const Scaffold(body: Text('Chat')),
                onChatPopped: () => setState(() => room = null),
              );
            },
          ),
        ),
      );
      update(() => room = 'room');
      await tester.pumpAndSettle();
      root.currentState!.push(
        PageRouteBuilder<void>(
          opaque: false,
          pageBuilder: (_, _, _) => const Scaffold(body: Text('Image viewer')),
        ),
      );
      await tester.pumpAndSettle();
      expect(await gesture(tester, 'startBackGesture', 0), false);
      await gesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(room, 'room');
      expect(find.text('Image viewer'), findsOneWidget);
      expect(await gesture(tester, 'startBackGesture', 0), false);
      await gesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(room, 'room');
      expect(find.text('Image viewer'), findsNothing);
      expect(find.text('Chat'), findsOneWidget);
      expect(await gesture(tester, 'startBackGesture', 0), false);
      await gesture(tester, 'updateBackGestureProgress', .5);
      await gesture(tester, 'cancelBackGesture');
      await tester.pumpAndSettle();
      expect(room, 'room');
      expect(await gesture(tester, 'startBackGesture', 0), false);
      await gesture(tester, 'commitBackGesture');
      await tester.pumpAndSettle();
      expect(room, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('root image viewer cannot commit the underlying chat snapshot', (
    tester,
  ) async {
    const channel = MethodChannel('moe.aks.matter/route_back');
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'prepare' ? true : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final root = GlobalKey<NavigatorState>();
    final inner = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: root,
        navigatorObservers: [NativeSnapshotNavigationObserver()],
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: NativeSnapshotPageTransitionsBuilder(),
            },
          ),
        ),
        home: Navigator(
          key: inner,
          onGenerateRoute: (_) => MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('List')),
          ),
        ),
      ),
    );
    inner.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Chat')),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    final generation =
        (calls.lastWhere((call) => call.method == 'prepare').arguments
            as Map)['generation'];
    final coverCalls = calls.length;
    root.currentState!.push(
      PageRouteBuilder<void>(
        opaque: false,
        pageBuilder: (_, _, _) => const Scaffold(body: Text('Image viewer')),
      ),
    );
    await tester.pump();
    expect(
      calls
          .skip(coverCalls)
          .any(
            (call) =>
                call.method == 'setActive' &&
                (call.arguments as Map)['eligible'] == false,
          ),
      true,
    );
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    expect(
      calls.skip(coverCalls).where((call) => call.method == 'prepare'),
      isEmpty,
    );
    Object? result;
    unawaited(
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'moe.aks.matter/route_back',
        const StandardMethodCodec().encodeMethodCall(
          MethodCall('commit', {'generation': generation}),
        ),
        (data) {
          result = const StandardMethodCodec().decodeEnvelope(data!);
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(result, false);
    expect(inner.currentState!.canPop(), true);
    expect(find.text('Image viewer'), findsOneWidget);
    final uncoverCalls = calls.length;
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.text('Image viewer'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    expect(inner.currentState!.canPop(), true);
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(
      calls
          .skip(uncoverCalls)
          .any(
            (call) =>
                call.method == 'refresh' &&
                (call.arguments as Map)['generation'] == generation,
          ),
      true,
    );
    expect(
      calls
          .skip(uncoverCalls)
          .any(
            (call) =>
                call.method == 'setActive' &&
                (call.arguments as Map)['eligible'] == true,
          ),
      true,
    );
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('native snapshots prepare and commit only the active route', (
    tester,
  ) async {
    const channel = MethodChannel('moe.aks.matter/route_back');
    final calls = <MethodCall>[];
    Completer<bool>? refreshReply;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      return call.method == 'prepare' ? true : null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        channel,
        null,
      ),
    );
    final navigator = GlobalKey<NavigatorState>();
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
      call,
    ) async {
      calls.add(call);
      if (call.method == 'refresh' && refreshReply != null) {
        return refreshReply.future;
      }
      return call.method == 'prepare';
    });
    var blocked = false;
    late StateSetter updateGuard;
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: ThemeData(
          platform: TargetPlatform.android,
          pageTransitionsTheme: const PageTransitionsTheme(
            builders: {
              TargetPlatform.android: NativeSnapshotPageTransitionsBuilder(),
            },
          ),
        ),
        home: const Scaffold(body: Text('List')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => StatefulBuilder(
          builder: (context, setState) {
            updateGuard = setState;
            return PopScope(
              canPop: !blocked,
              child: const Scaffold(body: Text('Detail')),
            );
          },
        ),
      ),
    );
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
    });
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    final prepare = calls.where((c) => c.method == 'prepare').toList();
    expect(prepare, isNotEmpty);
    final args = prepare.last.arguments as Map;
    expect(args['foreground'], isNotEmpty);
    expect(args['background'], isNotEmpty);
    expect(
      calls.where(
        (c) =>
            c.method == 'setActive' && (c.arguments as Map)['eligible'] == true,
      ),
      isNotEmpty,
    );
    updateGuard(() => blocked = true);
    await tester.pump();
    Object? blockedResult;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'moe.aks.matter/route_back',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('commit', {'generation': args['generation']}),
      ),
      (data) {
        blockedResult = const StandardMethodCodec().decodeEnvelope(data!);
      },
    );
    expect(blockedResult, false);
    expect(find.text('Detail'), findsOneWidget);
    updateGuard(() => blocked = false);
    await tester.pump();
    Object? staleResult;
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      'moe.aks.matter/route_back',
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('commit', {'generation': (args['generation'] as int) - 1}),
      ),
      (data) {
        staleResult = const StandardMethodCodec().decodeEnvelope(data!);
      },
    );
    expect(staleResult, false);
    expect(find.text('Detail'), findsOneWidget);
    refreshReply = Completer<bool>();
    await tester.tap(find.text('Detail'));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    final refresh = calls.lastWhere((call) => call.method == 'refresh');
    expect((refresh.arguments as Map)['generation'], args['generation']);
    expect(
      calls.where((call) => call.method == 'prepare').length,
      prepare.length,
    );
    Object? result;
    final response = const StandardMethodCodec().encodeMethodCall(
      MethodCall('commit', {'generation': args['generation']}),
    );
    unawaited(
      tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'moe.aks.matter/route_back',
        response,
        (data) {
          result = const StandardMethodCodec().decodeEnvelope(data!);
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.pump();
    expect(find.text('Detail'), findsNothing);
    expect(find.text('List'), findsOneWidget);
    expect(result, true);
    expect(calls.any((c) => c.method == 'finish'), true);
    refreshReply.complete(false);
    await tester.pump();
    expect(calls.where((call) => call.method == 'clear'), isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
