import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/desktop_notification_listener.dart';
import 'package:matter/features/push/desktop_notification_runtime.dart';
import 'package:matter/features/push/desktop_notification_settings.dart';
import 'package:matter/pages/settings/settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as matrix;
import 'package:matter/src/rust/api/matrix/desktop_notifications.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'package:shared_preferences/shared_preferences.dart';

const _alice = '@alice:example.org';
const _bob = '@bob:example.org';
const _roomId = '!chat:example.org';

rust.DesktopNotification _event({String user = _alice, String id = r'$one'}) =>
    rust.DesktopNotification(
      userId: user,
      roomId: _roomId,
      eventId: id,
      roomName: '讨论组',
      senderName: '小明',
      body: '<b>hello</b> & 你好',
    );

matrix.ChatRoom _room({
  int unread = 1,
  bool muted = false,
  String lastEvent = r'$one',
}) => matrix.ChatRoom(
  id: _roomId,
  name: '讨论组',
  lastMessage: 'hello',
  lastMessageTime: '1',
  lastEventId: lastEvent,
  unreadCount: unread,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: false,
  isMuted: muted,
  roomState: 'joined',
);

class _Plugin implements FlutterLocalNotificationsPlugin {
  final shown = <({int id, String? title, String? body, String? payload})>[];
  final canceled = <int>[];
  DidReceiveNotificationResponseCallback? response;
  Completer<bool?>? initializing;
  Completer<void>? showing;
  int initializationCalls = 0;
  bool available = true;
  bool cancelFails = false;
  @override
  Future<bool?> initialize({
    required InitializationSettings settings,
    DidReceiveNotificationResponseCallback? onDidReceiveNotificationResponse,
    DidReceiveBackgroundNotificationResponseCallback?
    onDidReceiveBackgroundNotificationResponse,
  }) async {
    initializationCalls++;
    expect(settings.linux?.defaultActionName, '打开聊天');
    response = onDidReceiveNotificationResponse;
    return initializing == null ? available : await initializing!.future;
  }

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    expect(
      notificationDetails?.linux?.category,
      LinuxNotificationCategory.imReceived,
    );
    shown.add((id: id, title: title, body: body, payload: payload));
    if (showing != null) await showing!.future;
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    if (cancelFails) throw StateError('notification service stopped');
    canceled.add(id);
  }

  void click(int index) {
    final notification = shown[index];
    response!(
      NotificationResponse(
        id: notification.id,
        payload: notification.payload,
        notificationResponseType: NotificationResponseType.selectedNotification,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _Api implements RustLibApi {
  List<matrix.ChatRoom> rooms = [_room()];
  final logs = <({String level, String tag, String message})>[];

  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) => logs.add((level: level, tag: tag, message: message));
  @override
  Future<List<matrix.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    expect(authoritative, isTrue);
    return rooms;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

class _Switch extends AccountSwitchController {
  _Switch(this.ref) : super(ref);
  final Ref ref;
  final switched = <String>[];
  @override
  Future<void> switchTo(String userId) async {
    switched.add(userId);
    ref.read(activeUserIdProvider.notifier).value = userId;
  }
}

class _Harness {
  final plugin = _Plugin();
  final api = _Api();
  final events = StreamController<rust.DesktopNotification>();
  final navigator = GlobalKey<NavigatorState>();
  late final runtime = DesktopNotificationRuntime(plugin: plugin);
  late ProviderContainer container;
  late _Switch switcher;
  final opened = <(String, String?)>[];
  List<matrix.ChatRoom> rooms = [_room()];

  Future<void> mount(WidgetTester tester) async {
    RustLib.initMock(api: api);
    container = ProviderContainer(
      overrides: [
        desktopNotificationRuntimeProvider.overrideWithValue(runtime),
        desktopNotificationEventsProvider.overrideWith((ref) => events.stream),
        allChatRoomsProvider.overrideWith((ref) async => rooms),
        accountSwitchControllerProvider.overrideWith(
          (ref) => switcher = _Switch(ref),
        ),
      ],
    );
    container.read(activeUserIdProvider.notifier).value = _alice;
    container.read(isLoggedInProvider.notifier).value = true;
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(sessionsProvider.notifier).value = [
      for (final user in [_alice, _bob])
        matrix.StoredSession(
          homeserverUrl: 'https://example.org',
          accessToken: 'test-only',
          userId: user,
          deviceId: 'TEST',
        ),
    ];
    container.read(desktopRoomNavigationProvider).open = (room, {messageId}) {
      opened.add((room.id, messageId));
      return true;
    };
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      runtime.dispose();
      await events.close();
      RustLib.dispose();
    });
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigator,
          builder: (context, child) => DesktopNotificationListener(
            navigatorKey: navigator,
            child: child!,
          ),
          home: const Scaffold(body: Text('聊天')),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> deliver(
    WidgetTester tester,
    rust.DesktopNotification event,
  ) async {
    events.add(event);
    await tester.pumpAndSettle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'duplicate events serialize once and escape notification markup',
    () async {
      final plugin = _Plugin();
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      await Future.wait([
        for (var i = 0; i < 2; i++)
          runtime.show(_event(), isCurrent: () => true),
      ]);
      expect(plugin.shown, hasLength(1));
      expect(plugin.shown.single.title, '讨论组');
      expect(plugin.shown.single.body, '小明: &lt;b&gt;hello&lt;/b&gt; &amp; 你好');
      expect(plugin.initializationCalls, 1);
    },
  );

  test(
    'same room replaces notification and stale clicks cannot open old events',
    () async {
      final plugin = _Plugin();
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      final clicked = <String>[];
      final subscription = runtime.opened.listen(
        (target) => clicked.add(target.eventId),
      );
      addTearDown(subscription.cancel);
      await runtime.show(_event(), isCurrent: () => true);
      await runtime.show(_event(id: r'$two'), isCurrent: () => true);
      expect(plugin.shown[0].id, plugin.shown[1].id);
      plugin.click(0);
      plugin.click(1);
      await Future<void>.delayed(Duration.zero);
      expect(clicked, [r'$two']);
    },
  );

  test(
    'account and room identities isolate cancellation and click targets',
    () async {
      final plugin = _Plugin();
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      await runtime.show(_event(), isCurrent: () => true);
      await runtime.show(_event(user: _bob), isCurrent: () => true);
      expect(plugin.shown[0].id, isNot(plugin.shown[1].id));
      expect(jsonDecode(plugin.shown[1].payload!)['user_id'], _bob);
      await runtime.cancelAccount(_alice);
      expect(plugin.canceled, [plugin.shown[0].id]);
      expect(runtime.roomEvents(_bob, _roomId), [r'$one']);
    },
  );

  test('read cleanup snapshot preserves a notification arriving during receipt write', () async {
    final plugin = _Plugin();
    final runtime = DesktopNotificationRuntime(plugin: plugin);
    addTearDown(runtime.dispose);
    await runtime.show(_event(), isCurrent: () => true);
    final snapshot = runtime.roomEvents(_alice, _roomId);
    await runtime.show(_event(id: r'$two'), isCurrent: () => true);
    await runtime.cancelRoom(_alice, _roomId, eventIds: snapshot);
    expect(plugin.canceled, isEmpty);
    await runtime.cancelRoom(_alice, _roomId, eventIds: [r'$two']);
    expect(plugin.canceled, hasLength(1));
  });

  test(
    'notification initialization can recover after unavailable service',
    () async {
      final plugin = _Plugin()..available = false;
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      await expectLater(
        runtime.show(_event(), isCurrent: () => true),
        throwsStateError,
      );
      plugin.available = true;
      await runtime.show(_event(), isCurrent: () => true);
      expect(plugin.initializationCalls, 2);
      expect(plugin.shown, hasLength(1));
    },
  );

  test(
    'account or preference changes while initializing prevent delivery',
    () async {
      final plugin = _Plugin()..initializing = Completer<bool?>();
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      var current = true;
      final pending = runtime.show(_event(), isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      plugin.initializing!.complete(true);
      await pending;
      expect(plugin.shown, isEmpty);
    },
  );

  test(
    'account changes during native show immediately clear the delivered notice',
    () async {
      final plugin = _Plugin()..showing = Completer<void>();
      final runtime = DesktopNotificationRuntime(plugin: plugin);
      addTearDown(runtime.dispose);
      var current = true;
      final pending = runtime.show(_event(), isCurrent: () => current);
      await Future<void>.delayed(Duration.zero);
      current = false;
      plugin.showing!.complete();
      await pending;
      expect(plugin.canceled, [plugin.shown.single.id]);
      expect(runtime.roomEvents(_alice, _roomId), isEmpty);
    },
  );

  test('desktop notification preference persists per account independently of push registration', () async {
    var container = ProviderContainer();
    expect(
      await container.read(desktopNotificationsEnabledProvider(_alice).future),
      isTrue,
    );
    await saveDesktopNotificationsEnabled(_alice, false);
    container.dispose();
    container = ProviderContainer();
    addTearDown(container.dispose);
    expect(
      await container.read(desktopNotificationsEnabledProvider(_alice).future),
      isFalse,
    );
    expect(
      await container.read(desktopNotificationsEnabledProvider(_bob).future),
      isTrue,
    );
  });

  testWidgets(
    'visible owned room suppresses notices but background or different owner does not',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      harness.container.read(currentRoomIdProvider.notifier).value = _roomId;
      harness.container.read(roomViewOwnerProvider(_roomId).notifier).value =
          _alice;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await harness.deliver(tester, _event());
      expect(harness.plugin.shown, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await harness.deliver(tester, _event(id: r'$background'));
      expect(harness.plugin.shown, hasLength(1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      harness.container.read(roomViewOwnerProvider(_roomId).notifier).value =
          _bob;
      await harness.deliver(tester, _event(id: r'$other-owner'));
      expect(harness.plugin.shown, hasLength(2));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'disabled preferences and stale account events suppress delivery',
    (tester) async {
      final harness = _Harness();
      await saveDesktopNotificationsEnabled(_alice, false);
      await harness.mount(tester);
      await harness.deliver(tester, _event());
      await harness.deliver(tester, _event(user: _bob));
      expect(harness.plugin.shown, isEmpty);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'click from another active account switches back and opens the desktop message target',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await harness.deliver(tester, _event());
      harness.container.read(activeUserIdProvider.notifier).value = _bob;
      harness.plugin.click(0);
      await tester.pumpAndSettle();
      expect(harness.switcher.switched, [_alice]);
      expect(harness.container.read(activeUserIdProvider), _alice);
      expect(harness.opened, [(_roomId, r'$one')]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'notification opening errors are persisted with the target and stack',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await harness.deliver(tester, _event());
      harness.api.rooms = [];
      harness.plugin.click(0);
      await tester.pumpAndSettle();

      expect(find.textContaining('打开通知消息失败'), findsOneWidget);
      expect(harness.opened, isEmpty);
      expect(harness.api.logs, hasLength(1));
      final log = harness.api.logs.single;
      expect(log.level, 'error');
      expect(log.tag, 'desktop-notifications');
      for (final detail in [
        _alice,
        _roomId,
        r'$one',
        '房间暂不可用',
        '_openPending',
      ]) {
        expect(log.message, contains(detail));
      }

      harness.api.rooms = [_room()];
      await harness.deliver(tester, _event(id: r'$retry'));
      harness.plugin.click(1);
      await tester.pumpAndSettle();
      expect(harness.opened, [(_roomId, r'$retry')]);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets('notification service failures are persisted and can recover', (
    tester,
  ) async {
    final harness = _Harness();
    harness.plugin.available = false;
    await harness.mount(tester);
    await harness.deliver(tester, _event());
    expect(find.textContaining('系统通知暂不可用'), findsOneWidget);
    expect(harness.api.logs, hasLength(1));
    expect(harness.api.logs.single.message, contains(_roomId));
    expect(harness.api.logs.single.message, contains(r'$one'));
    expect(harness.api.logs.single.message, contains('_notify'));
    harness.plugin.available = true;
    await harness.deliver(tester, _event(id: r'$service-retry'));
    expect(harness.plugin.shown, hasLength(1));
  }, variant: TargetPlatformVariant.only(TargetPlatform.linux));

  testWidgets('settings toggle persists and clears existing account notices', (
    tester,
  ) async {
    final plugin = _Plugin();
    final runtime = DesktopNotificationRuntime(plugin: plugin);
    final container = ProviderContainer(
      overrides: [
        desktopNotificationRuntimeProvider.overrideWithValue(runtime),
      ],
    );
    addTearDown(() {
      container.dispose();
      runtime.dispose();
    });
    await runtime.show(_event(), isCurrent: () => true);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
          home: Scaffold(body: DesktopNotificationSettingsTile(userId: _alice)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('桌面消息通知'));
    await tester.pumpAndSettle();
    expect(
      await container.read(desktopNotificationsEnabledProvider(_alice).future),
      isFalse,
    );
    expect(
      await container.read(desktopNotificationsEnabledProvider(_bob).future),
      isTrue,
    );
    expect(plugin.canceled, [plugin.shown.single.id]);
  });

  testWidgets(
    'notification cleanup service errors do not escape into chat navigation',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await harness.deliver(tester, _event());
      harness.plugin.cancelFails = true;
      harness.container.read(roomViewOwnerProvider(_roomId).notifier).value =
          _alice;
      harness.container.read(currentRoomIdProvider.notifier).value = _roomId;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(harness.api.logs, hasLength(1));
      expect(harness.api.logs.single.message, contains('cleanup'));
      expect(harness.api.logs.single.message, contains('_dismiss'));
      harness.plugin.cancelFails = false;
      harness.container.read(currentRoomIdProvider.notifier).value = null;
      await harness.deliver(tester, _event(id: r'$after-service-recovery'));
      expect(harness.plugin.shown, hasLength(2));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );

  testWidgets(
    'read snapshots, mute and removed sessions clear only matching notices',
    (tester) async {
      final harness = _Harness();
      await harness.mount(tester);
      await harness.deliver(tester, _event(id: r'$newer'));
      harness.rooms = [_room(unread: 0, lastEvent: r'$older')];
      harness.container.invalidate(allChatRoomsProvider);
      await tester.pumpAndSettle();
      expect(harness.plugin.canceled, isEmpty);
      harness.rooms = [_room(unread: 0, lastEvent: r'$newer')];
      harness.container.invalidate(allChatRoomsProvider);
      await tester.pumpAndSettle();
      expect(harness.plugin.canceled, hasLength(1));
      await harness.deliver(tester, _event(id: r'$after-read'));
      harness.rooms = [_room(muted: true)];
      harness.container.invalidate(allChatRoomsProvider);
      await tester.pumpAndSettle();
      expect(harness.plugin.canceled, hasLength(2));
      await harness.deliver(tester, _event(id: r'$while-muted'));
      expect(harness.plugin.shown, hasLength(2));
      harness.rooms = [_room()];
      harness.container.invalidate(allChatRoomsProvider);
      await tester.pumpAndSettle();
      await harness.deliver(tester, _event(id: r'$before-logout'));
      harness.container.read(sessionsProvider.notifier).value = [];
      await tester.pumpAndSettle();
      expect(harness.plugin.canceled, hasLength(3));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}
