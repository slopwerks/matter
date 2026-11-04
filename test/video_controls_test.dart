import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:matter/pages/chat/video_controls.dart';
import 'package:matter/pages/chat/video_preferences.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/video_test_player.dart';

void main() {
  late VideoTestPlayer player;
  late MediaPlayback playback;
  late List<MethodCall> platformCalls;
  var closed = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    player = VideoTestPlayer();
    playback = MediaPlayback(player: Player(platformPlayer: player));
    closed = 0;
    platformCalls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          platformCalls.add(call);
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.alexmercerind/media_kit_video'),
          (call) async {
            platformCalls.add(call);
            return null;
          },
        );
  });
  tearDown(() async {
    await playback.close();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('com.alexmercerind/media_kit_video'),
          null,
        );
  });

  Widget host({Brightness brightness = Brightness.dark}) => MaterialApp(
    theme: neuTestTheme(dark: brightness == Brightness.dark),
    home: Scaffold(
      backgroundColor: Colors.black,
      body: VideoControls(
        playback: playback,
        onClose: () => closed++,
        videoBuilder: (_, fit) => SizedBox.expand(key: ValueKey(fit)),
      ),
    ),
  );

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await tester.pump();
    await tester.pump();
  }

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 400));
  }

  Offset point(WidgetTester tester, double fraction) {
    final rect = tester.getRect(find.byKey(const ValueKey('video-gestures')));
    return Offset(
      rect.left + rect.width * fraction,
      rect.top + rect.height * 0.35,
    );
  }

  testWidgets(
    'video controls prefer message duration and label a missing total as unknown',
    (tester) async {
      playback.setDurationMetadata(65000);
      await mount(tester);
      expect(find.text('1:00 / 1:05'), findsOneWidget);
      expect(playback.duration, const Duration(seconds: 65));
      player.state = player.state.copyWith(duration: Duration.zero);
      playback.setDurationMetadata(null);
      await tester.pump();
      expect(find.text('1:00 / --:--'), findsOneWidget);
      await unmount(tester);
    },
  );

  testWidgets(
    'chosen long-press speed restores the saved ordinary speed on release',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'video_playback_speed': 1.25,
        'video_hold_speed': 3.0,
      });
      await mount(tester);
      expect(playback.rate, 1.25);
      final gesture = await tester.startGesture(point(tester, 0.7));
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump();
      expect(playback.rate, 3);
      expect(find.text('3× 临时倍速 · 松手恢复'), findsOneWidget);
      await gesture.up();
      await tester.pump();
      expect(playback.rate, 1.25);
      await unmount(tester);
    },
  );

  testWidgets('cancelled long press and route disposal restore speed', (
    tester,
  ) async {
    await mount(tester);
    var gesture = await tester.startGesture(point(tester, 0.7));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(playback.rate, 2);
    await gesture.cancel();
    await tester.pump();
    expect(playback.rate, 1);
    gesture = await tester.startGesture(point(tester, 0.7));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    expect(playback.rate, 2);
    await unmount(tester);
    expect(playback.rate, 1);
    await gesture.cancel();
  });

  testWidgets('backgrounding pauses playback and restores temporary speed', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(point(tester, 0.7));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    expect(playback.isPlaying, isFalse);
    expect(playback.rate, 1);
    await gesture.cancel();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await unmount(tester);
  });

  testWidgets('speed menus persist regular and held speeds independently', (
    tester,
  ) async {
    await mount(tester);
    await tester.tap(find.byTooltip('设置播放速度'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5×'));
    await tester.pumpAndSettle();
    expect(playback.rate, 1.5);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('长按倍速 · 2×'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2.5×'));
    await tester.pumpAndSettle();
    expect(playback.rate, 1.5);
    final preferences = await SharedPreferences.getInstance();
    expect(preferences.getDouble('video_playback_speed'), 1.5);
    expect(preferences.getDouble('video_hold_speed'), 2.5);
    await unmount(tester);
  });

  testWidgets('double tap skips ten seconds and clamps to media bounds', (
    tester,
  ) async {
    await mount(tester);
    Future<void> doubleTapAt(double x) async {
      await tester.tapAt(point(tester, x));
      await tester.pump(const Duration(milliseconds: 60));
      await tester.tapAt(point(tester, x));
      await tester.pump(const Duration(milliseconds: 350));
    }

    await doubleTapAt(0.8);
    expect(playback.position, const Duration(seconds: 70));
    await doubleTapAt(0.2);
    expect(playback.position, const Duration(seconds: 60));
    player.state = player.state.copyWith(
      position: const Duration(seconds: 175),
    );
    await doubleTapAt(0.8);
    expect(playback.position, const Duration(minutes: 3));
    player.state = player.state.copyWith(position: const Duration(seconds: 3));
    await doubleTapAt(0.2);
    expect(playback.position, Duration.zero);
    await unmount(tester);
  });

  testWidgets(
    'horizontal scrub commits once; cancellation keeps the original position',
    (tester) async {
      await mount(tester);
      var gesture = await tester.startGesture(point(tester, 0.4));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      expect(player.seeks, isEmpty);
      await gesture.cancel();
      await tester.pump();
      expect(player.seeks, isEmpty);
      gesture = await tester.startGesture(point(tester, 0.4));
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
      await gesture.moveBy(const Offset(100, 0));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(player.seeks, hasLength(1));
      expect(playback.position, greaterThan(const Duration(minutes: 1)));
      await unmount(tester);
    },
  );

  testWidgets('vertical swipe adjusts volume and clamps at 100 percent', (
    tester,
  ) async {
    await mount(tester);
    final gesture = await tester.startGesture(point(tester, 0.8));
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -400));
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(playback.volume, 1);
    expect(find.text('音量 100%'), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('keyboard controls handle playback, position, volume and close', (
    tester,
  ) async {
    await mount(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(playback.isPlaying, isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(playback.position, const Duration(seconds: 70));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    expect(playback.volume, closeTo(0.55, 0.001));
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(closed, 1);
    await unmount(tester);
  });

  testWidgets('completion exposes replay and starts again from zero', (
    tester,
  ) async {
    await mount(tester);
    player.complete();
    await tester.pump();
    await tester.pump();
    expect(find.byTooltip('重播'), findsWidgets);
    await tester.tap(find.byTooltip('重播').first);
    await tester.pump();
    expect(playback.isPlaying, isTrue);
    expect(playback.position, Duration.zero);
    await unmount(tester);
  });

  testWidgets('fit toggle switches between contain and cover', (tester) async {
    await mount(tester);
    expect(find.byKey(const ValueKey(BoxFit.contain)), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('铺满画面'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(BoxFit.cover)), findsOneWidget);
    await tester.tap(find.byTooltip('更多'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('适应画面'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(BoxFit.contain)), findsOneWidget);
    await unmount(tester);
  });

  testWidgets('one volume entry opens adjustment and mute in its panel', (
    tester,
  ) async {
    await mount(tester);
    expect(find.byTooltip('音量'), findsOneWidget);
    expect(find.byTooltip('静音'), findsNothing);
    await tester.tap(find.byTooltip('音量'));
    await tester.pump();
    expect(find.byType(Slider), findsOneWidget);
    await tester.tap(find.byTooltip('静音'));
    await tester.pump();
    expect(playback.volume, 0);
    expect(find.byTooltip('恢复声音'), findsOneWidget);
    await tester.tap(find.byTooltip('音量'));
    await tester.pump();
    expect(find.byType(Slider), findsNothing);
    await unmount(tester);
  });

  testWidgets(
    'mobile fullscreen restores the app portrait policy on disposal',
    (tester) async {
      await mount(tester);
      await tester.tap(find.byTooltip('横屏全屏'));
      await tester.pump();
      expect(
        platformCalls.any(
          (call) =>
              call.method == 'SystemChrome.setPreferredOrientations' &&
              (call.arguments as List).contains(
                'DeviceOrientation.landscapeLeft',
              ),
        ),
        isTrue,
      );
      await unmount(tester);
      expect(
        platformCalls
            .lastWhere(
              (call) => call.method == 'SystemChrome.setPreferredOrientations',
            )
            .arguments,
        ['DeviceOrientation.portraitUp', 'DeviceOrientation.portraitDown'],
      );
    },
  );

  for (final brightness in Brightness.values) {
    testWidgets('controls fit phone width in ${brightness.name} theme', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(host(brightness: brightness));
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.byTooltip('设置长按倍速'), findsNothing);
      expect(find.byIcon(Icons.tune_rounded), findsNothing);
      expect(find.byTooltip('音量'), findsOneWidget);
      expect(find.byTooltip('设置播放速度'), findsOneWidget);
      expect(find.byTooltip('横屏全屏'), findsOneWidget);
      expect(find.byTooltip('更多'), findsOneWidget);
      expect(
        tester
            .getSize(find.byKey(const ValueKey('video-toolbar-actions')))
            .height,
        lessThanOrEqualTo(48),
      );
      await unmount(tester);
    });
  }

  test('invalid saved speeds fall back to defaults and a late load preserves user edits', () async {
    SharedPreferences.setMockInitialValues({
      'video_playback_speed': 99.0,
      'video_hold_speed': -1.0,
    });
    final preferences = VideoPreferences();
    await preferences.load();
    expect(preferences.speed, 1);
    expect(preferences.heldSpeed, 2);
    final loading = preferences.load();
    await preferences.setSpeed(1.5);
    await preferences.setHeldSpeed(3);
    await loading;
    expect(preferences.speed, 1.5);
    expect(preferences.heldSpeed, 3);
    preferences.dispose();
  });
}
