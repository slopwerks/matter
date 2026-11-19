import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/pages/settings/timeline_event_settings_page.dart';
import 'package:matter/providers/timeline_event_settings_provider.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildTestApp({ProviderContainer? container}) {
    return UncontrolledProviderScope(
      container: container ?? ProviderContainer(),
      child: MaterialApp(
        theme: neuTestTheme(dark: false),
        home: const TimelineEventSettingsPage(),
      ),
    );
  }

  testWidgets('renders all preset cards and event sections', (tester) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() => tester.view.resetPhysicalSize());

    await tester.pumpWidget(buildTestApp());
    await tester.pumpAndSettle();

    expect(find.text('时间线事件显示'), findsOneWidget);
    expect(find.text('懒人预设'), findsOneWidget);
    expect(find.text('推荐模式'), findsOneWidget);
    expect(find.text('全部显示'), findsOneWidget);
    expect(find.text('极简模式'), findsOneWidget);
    expect(find.text('全部隐藏'), findsOneWidget);

    expect(find.text('成员个人资料'), findsOneWidget);
    expect(find.text('成员个人头像变更'), findsOneWidget);
    expect(find.text('成员昵称变更'), findsOneWidget);

    expect(find.text('成员进出与关系'), findsOneWidget);
    expect(find.text('成员加入与离开'), findsOneWidget);
    expect(find.text('成员邀请、移出与封禁'), findsOneWidget);

    expect(find.text('房间信息与外观'), findsOneWidget);
    expect(find.text('房间头像变更'), findsOneWidget);
    expect(find.text('房间名称、主题与别名'), findsOneWidget);

    expect(find.text('房间规则与安全'), findsOneWidget);
    expect(find.text('加密规则与权限级别'), findsOneWidget);

    expect(find.text('通话与系统状态'), findsOneWidget);
    expect(find.text('通话邀请事件'), findsOneWidget);
    expect(find.text('其他系统状态事件'), findsOneWidget);
  });

  testWidgets('tapping preset updates switches and preset state', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(buildTestApp(container: container));
    await tester.pumpAndSettle();

    // Tap "极简模式"
    await tester.tap(find.text('极简模式'));
    await tester.pumpAndSettle();

    final state = container.read(timelineEventSettingsProvider);
    expect(state.preset, TimelineEventPreset.minimal);
    expect(state.showMemberAvatar, isFalse);
    expect(state.showMemberJoinLeave, isFalse);
    expect(state.showMemberInviteBan, isTrue);
    expect(state.showRoomAvatar, isTrue);

    // Tap "全部隐藏"
    await tester.tap(find.text('全部隐藏'));
    await tester.pumpAndSettle();

    final offState = container.read(timelineEventSettingsProvider);
    expect(offState.preset, TimelineEventPreset.off);
    expect(offState.showMemberAvatar, isFalse);
    expect(offState.showRoomAvatar, isFalse);
  });

  testWidgets('toggling switch switches preset to custom', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(buildTestApp(container: container));
    await tester.pumpAndSettle();

    // In default recommended preset, toggling on member avatar switch
    final memberAvatarSwitch = find.byType(Switch).first;
    await tester.tap(memberAvatarSwitch);
    await tester.pumpAndSettle();

    expect(find.text('当前为自定义模式'), findsOneWidget);
    final state = container.read(timelineEventSettingsProvider);
    expect(state.preset, TimelineEventPreset.custom);
    expect(state.showMemberAvatar, isTrue);
  });

  testWidgets('room mode supports enabling and toggling room override', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const roomId = '!test:example.org';
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(dark: false),
          home: const TimelineEventSettingsPage(
            roomId: roomId,
            roomName: '测试群聊',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('测试群聊 事件显示'), findsOneWidget);
    expect(find.text('单独配置此房间'), findsOneWidget);
    expect(
      find.text(
        '当前房间正在跟随全局设置。开启上方的「单独配置此房间」后，可为此群单独定制状态事件过滤规则（如在大群中隐藏进退与改名，或在工作群中全开）。',
      ),
      findsOneWidget,
    );

    // Enable override
    await tester.tap(find.byType(Switch).first);
    await tester.pumpAndSettle();

    final state = container.read(timelineEventSettingsProvider);
    expect(state.hasRoomOverride(roomId), isTrue);
    expect(find.text('极简模式'), findsOneWidget);

    // Tap minimal preset for this room
    await tester.tap(find.text('极简模式'));
    await tester.pumpAndSettle();

    final roomSettings = container.read(
      roomTimelineEventSettingsProvider(roomId),
    );
    expect(roomSettings.preset, TimelineEventPreset.minimal);
    expect(roomSettings.showMemberAvatar, isFalse);

    // Global settings remained untouched
    expect(state.global.preset, TimelineEventPreset.recommended);
    expect(state.global.showMemberAvatar, isFalse);
    expect(state.global.showRoomAvatar, isTrue);
  });
}
