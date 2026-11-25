import 'dart:async';
import 'dart:convert';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/desktop_notification_runtime.dart';
import 'package:matter/features/push/desktop_notification_settings.dart';
import 'package:matter/src/rust/api/matrix/desktop_notifications.dart' as rust;
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
}
