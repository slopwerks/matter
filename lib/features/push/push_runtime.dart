import 'dart:async';
import 'package:flutter/foundation.dart';

import '../../src/rust/api/matrix.dart' as rust;
import 'fcm_push_runtime.dart';
import 'push_settings.dart';
import 'web_push_runtime_stub.dart'
    if (dart.library.js_interop) 'web_push_runtime_web.dart'
    as web_push;

bool get pushSupported => kIsWeb || fcmPushSupported;
bool supportsPushBackend(PushBackend backend) =>
    backend == PushBackend.web ? kIsWeb : fcmPushSupported;

Future<void> initializePush() =>
    kIsWeb ? web_push.initialize() : fcmPushRuntime.initialize();
Future<void> requestPushPermission(PushBackend backend) {
  if (!supportsPushBackend(backend)) throw StateError('当前平台不支持此推送接入方式');
  return kIsWeb
      ? web_push.requestPermission()
      : fcmPushRuntime.requestPermission();
}

Future<String> getPushToken(PushSettings settings) {
  if (!supportsPushBackend(settings.backend)) {
    throw StateError('当前平台不支持保存的推送接入方式');
  }
  return kIsWeb ? web_push.getToken(settings) : fcmPushRuntime.getToken();
}

Future<String?> webSubscription(PushSettings settings) async =>
    settings.backend == PushBackend.web
    ? await web_push.subscriptionJson()
    : null;
Stream<PushTarget> get openedPushes =>
    kIsWeb ? web_push.opened : fcmPushRuntime.opened;
PushTarget? takeInitialPushTarget() {
  if (kIsWeb) return web_push.takeInitialTarget();
  final target = fcmPushRuntime.initialTarget;
  fcmPushRuntime.initialTarget = null;
  return target;
}

Future<List<String>> _roomNotificationEvents(
  String userId,
  String roomId,
) async {
  if (!pushSupported) return [];
  try {
    return kIsWeb
        ? await web_push.roomNotificationEvents(userId, roomId)
        : await fcmPushRuntime.roomNotificationEvents(userId, roomId);
  } catch (error) {
    debugPrint(
      'Failed to enumerate Matrix notifications: ${error.runtimeType}',
    );
    return [];
  }
}

Future<void> _cancelRoomNotifications(
  String userId,
  String roomId,
  List<String> eventIds,
) async {
  if (eventIds.isEmpty) return;
  try {
    if (kIsWeb) {
      await web_push.cancelRoomNotifications(userId, roomId, eventIds);
    } else if (fcmPushSupported) {
      await fcmPushRuntime.cancelRoomNotifications(userId, roomId, eventIds);
    }
  } catch (error) {
    debugPrint('Failed to cancel Matrix notifications: ${error.runtimeType}');
  }
}

/// Snapshot before sending receipts so messages arriving during the write keep
/// their notifications. A failed receipt write must leave notifications intact.
Future<bool> markRoomAsReadWithPushCleanup({
  required String accountUserId,
  required String roomId,
  required bool explicit,
}) {
  Future<bool> writeReceipt() => rust.markRoomAsRead(
    accountUserId: accountUserId,
    roomId: roomId,
    explicit: explicit,
  );
  if (!pushSupported || (!kIsWeb && fcmPushRuntime.configuration == null)) {
    return writeReceipt();
  }
  return () async {
    final events = await _roomNotificationEvents(accountUserId, roomId);
    final cleared = await writeReceipt();
    await _cancelRoomNotifications(accountUserId, roomId, events);
    return cleared;
  }();
}

Future<void> dismissReadRoomPushes(String userId, String roomId) async {
  final events = await _roomNotificationEvents(userId, roomId);
  await _cancelRoomNotifications(userId, roomId, events);
}

Future<void> updatePushDeliveryState(String userId, PushSettings settings) =>
    web_push.updateAccount(userId, settings);
