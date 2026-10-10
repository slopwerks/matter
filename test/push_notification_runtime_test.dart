import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/push_providers.dart';
import 'package:matter/features/push/push_runtime.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _ReadApi implements RustLibApi {
  Completer<bool>? pending;
  Object? error;

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    if (error case final failure?) throw failure;
    return pending?.future ?? false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dexterous.com/flutter/local_notifications');
  const target = PushTarget(
    userId: '@alice:example.org',
    roomId: '!room:example.org',
    eventId: r'$event',
    registrationId: 'current',
  );
  final calls = <MethodCall>[];
  var active = <Map<String, dynamic>>[];
  final api = _ReadApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);

  setUp(() {
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    fcmPushRuntime.configuration = const FirebaseClientConfig(
      apiKey: 'test',
      appId: 'test',
      senderId: 'test',
      projectId: 'test',
    );
    SharedPreferences.setMockInitialValues({
      pushSettingsKey(target.userId): jsonEncode(
        const PushSettings(enabled: true, registrationId: 'current').toJson(),
      ),
      'multi_sessions': jsonEncode([
        {'user_id': target.userId},
      ]),
    });
    calls.clear();
    api.pending = null;
    api.error = null;
    active = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'getActiveNotifications') return active;
          return null;
        });
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    fcmPushRuntime.configuration = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test(
    'focused Matter suppresses notifications, unfocused Matter shows them',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      await showMatrixPush(
        notifications,
        target.toData(),
        isFocused: () => true,
      );
      expect(calls.where((call) => call.method == 'show'), isEmpty);
      await showMatrixPush(
        notifications,
        target.toData(),
        isFocused: () => false,
      );
      expect(calls.where((call) => call.method == 'show'), hasLength(1));
    },
  );

  test(
    'plain messages show JSON-encoded FCM content; encrypted content stays generic',
    () async {
      final notifications = FlutterLocalNotificationsPlugin();
      for (final type in ['m.room.message', 'm.room.encrypted', null]) {
        await showMatrixPush(notifications, {
          ...target.toData(),
          'type': type,
          'content': jsonEncode({'body': '消息正文'}),
        });
        final args = calls.last.arguments as Map;
        expect(args['body'], type == 'm.room.message' ? '消息正文' : '你有一条新消息');
      }
    },
  );

  test(
    'successful receipts cancel notifications even without a marked-unread flag',
    () async {
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      final result = await markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: false,
      );
      expect(result, false);
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    },
  );

  test(
    'notifications arriving during a receipt write survive its completion',
    () async {
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      api.pending = Completer<bool>();
      final read = markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      );
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), isEmpty);
      active.add({
        'id': 2,
        'tag': jsonEncode({...target.toData(), 'event_id': r'$arriving'}),
      });
      api.pending!.complete(true);
      await read;
      final cancelled = calls.where((call) => call.method == 'cancel');
      expect(cancelled, hasLength(1));
      expect((cancelled.single.arguments as Map)['id'], 1);
    },
  );

  test(
    'synced unread count reaching zero cancels room notifications',
    () async {
      rust.ChatRoom room(int count) => rust.ChatRoom(
        id: target.roomId,
        name: 'Room',
        lastMessage: '',
        lastMessageTime: '0',
        lastEventId: target.eventId,
        unreadCount: count,
        isMarkedUnread: false,
        roomType: 'dm',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      var rooms = [room(1)];
      final container = ProviderContainer(
        overrides: [allChatRoomsProvider.overrideWith((ref) async => rooms)],
      );
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value = target.userId;
      container.listen(pushReadStateProvider, (_, _) {}, fireImmediately: true);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      active = [
        {'id': 1, 'tag': jsonEncode(target.toData())},
      ];
      rooms = [room(0)];
      container.invalidate(allChatRoomsProvider);
      await container.read(allChatRoomsProvider.future);
      await pumpEventQueue();
      expect(calls.where((call) => call.method == 'cancel'), hasLength(1));
    },
  );

  test('failed receipts leave notifications intact', () async {
    active = [
      {'id': 1, 'tag': jsonEncode(target.toData())},
    ];
    api.error = StateError('offline');
    await expectLater(
      markRoomAsReadWithPushCleanup(
        accountUserId: target.userId,
        roomId: target.roomId,
        explicit: true,
      ),
      throwsStateError,
    );
    expect(calls.where((call) => call.method == 'cancel'), isEmpty);
  });

  test(
    'dismissal preserves other rooms, accounts and messages arriving during read',
    () async {
      Map<String, dynamic> notification(int id, PushTarget value) => {
        'id': id,
        'tag': jsonEncode(value.toData()),
      };
      const otherRoom = PushTarget(
        userId: '@alice:example.org',
        roomId: '!other:example.org',
        eventId: r'$other',
        registrationId: 'current',
      );
      const otherAccount = PushTarget(
        userId: '@bob:example.org',
        roomId: '!room:example.org',
        eventId: r'$bob',
        registrationId: 'current',
      );
      active = [
        notification(1, target),
        notification(2, otherRoom),
        notification(3, otherAccount),
      ];
      final events = await fcmPushRuntime.roomNotificationEvents(
        target.userId,
        target.roomId,
      );
      expect(events, [target.eventId]);
      const arriving = PushTarget(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$arriving',
        registrationId: 'current',
      );
      active.add(notification(4, arriving));
      await fcmPushRuntime.cancelRoomNotifications(
        target.userId,
        target.roomId,
        events,
      );
      final cancelled = calls.where((call) => call.method == 'cancel');
      expect(cancelled, hasLength(1));
      expect((cancelled.single.arguments as Map)['id'], 1);
      expect(
        (cancelled.single.arguments as Map)['tag'],
        jsonEncode(target.toData()),
      );
    },
  );
}
