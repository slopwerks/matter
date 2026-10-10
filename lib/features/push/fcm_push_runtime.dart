import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_client_config.dart';
import 'push_settings.dart';

const _channelId = 'matrix_messages';
const _initializationSettings = InitializationSettings(
  android: AndroidInitializationSettings('ic_notification'),
);

bool get fcmPushSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

@pragma('vm:entry-point')
Future<void> handleFcmBackgroundMessage(RemoteMessage message) async {
  await Firebase.initializeApp();
  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(settings: _initializationSettings);
  await showMatrixPush(notifications, message.data);
}

Future<bool> acceptsPushTarget(PushTarget target) async {
  final settings = await PushSettingsStore().load(target.userId);
  if (!target.acceptedBy(settings)) return false;
  final prefs = await SharedPreferences.getInstance();
  final removedKey =
      'matrix_session_removed_${base64Url.encode(utf8.encode(target.userId))}';
  if (prefs.containsKey(removedKey)) return false;
  final sessions =
      jsonDecode(prefs.getString('multi_sessions') ?? '[]') as List;
  return sessions.any((session) => session['user_id'] == target.userId);
}

int pushNotificationId(PushTarget target) {
  final bytes = sha256
      .convert(utf8.encode('${target.userId}\n${target.eventId}'))
      .bytes;
  return ((bytes[0] << 24) | (bytes[1] << 16) | (bytes[2] << 8) | bytes[3]) &
      0x7fffffff;
}

Future<void> showMatrixPush(
  FlutterLocalNotificationsPlugin notifications,
  Map<String, dynamic> data, {
  bool Function()? isFocused,
}) async {
  final target = PushTarget.fromData(data);
  // Counts-only updates do not represent a new event. Ignore stale pushes
  // from an old gateway, disabled setting or removed account, too.
  if (target == null ||
      !await acceptsPushTarget(target) ||
      (isFocused?.call() ?? false)) {
    return;
  }
  var body = '你有一条新消息';
  if (data['type'] == 'm.room.message' || data['type'] == 'm.sticker') {
    dynamic content = data['content'];
    if (content is String) {
      try {
        content = jsonDecode(content);
      } on FormatException {
        content = null;
      }
    }
    final flattenedBody = data['content_body'];
    if (content is Map &&
        content['body'] is String &&
        (content['body'] as String).trim().isNotEmpty) {
      body = content['body'] as String;
    } else if (flattenedBody is String && flattenedBody.trim().isNotEmpty) {
      // Sygnal flattens content fields for FCM HTTP v1.
      body = flattenedBody;
    }
  }
  await notifications.show(
    id: pushNotificationId(target),
    title: 'Matter',
    body: body,
    notificationDetails: NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        '聊天消息',
        channelDescription: 'Matrix 聊天消息推送',
        importance: Importance.high,
        priority: Priority.high,
        visibility: NotificationVisibility.private,
        groupKey: 'matrix:${target.userId}',
        // Android's active-notification query exposes tags, not payloads.
        tag: jsonEncode(target.toData()),
      ),
    ),
    payload: jsonEncode(target.toData()),
  );
}

class FcmPushRuntime {
  final notifications = FlutterLocalNotificationsPlugin();
  final _opened = StreamController<PushTarget>.broadcast();
  Stream<PushTarget> get opened => _opened.stream;
  PushTarget? initialTarget;
  String? initializationError;
  FirebaseClientConfig? configuration;
  bool configurationChanged = false;
  bool get isConfigured => configuration != null && !configurationChanged;
  Future<void>? _initialization;

  Future<void> initialize() => _initialization ??= _initialize();

  Future<void> _initialize() async {
    if (!fcmPushSupported) return;
    try {
      configuration = await FirebaseClientConfigStore().load();
      if (configuration == null) return;
      await Firebase.initializeApp(options: configuration!.options);
      FirebaseMessaging.onBackgroundMessage(handleFcmBackgroundMessage);
      await notifications.initialize(
        settings: _initializationSettings,
        onDidReceiveNotificationResponse: (response) =>
            _openPayload(response.payload),
      );
      final launch = await notifications.getNotificationAppLaunchDetails();
      if (launch?.didNotificationLaunchApp ?? false) {
        initialTarget = _parsePayload(launch?.notificationResponse?.payload);
      }
      FirebaseMessaging.onMessage.listen((message) {
        unawaited(
          showMatrixPush(
            notifications,
            message.data,
            isFocused: () =>
                WidgetsBinding.instance.lifecycleState ==
                AppLifecycleState.resumed,
          ).catchError((Object error) {
            debugPrint(
              'Failed to display Matrix notification: ${error.runtimeType}',
            );
          }),
        );
      });
      // Also handle a gateway supplying an FCM notification payload.
      FirebaseMessaging.onMessageOpenedApp.listen((message) {
        final target = PushTarget.fromData(message.data);
        if (target != null) _opened.add(target);
      });
      final initialMessage = await FirebaseMessaging.instance
          .getInitialMessage();
      initialTarget ??= initialMessage == null
          ? null
          : PushTarget.fromData(initialMessage.data);
    } catch (error) {
      initializationError = 'FCM 初始化失败，请检查导入的 Firebase 配置和 Google Play 服务';
      debugPrint('FCM initialization failed: ${error.runtimeType}');
    }
  }

  PushTarget? _parsePayload(String? payload) {
    if (payload == null || payload.isEmpty) return null;
    try {
      final data = jsonDecode(payload);
      return data is Map<String, dynamic> ? PushTarget.fromData(data) : null;
    } on FormatException {
      return null;
    }
  }

  void _openPayload(String? payload) {
    final target = _parsePayload(payload);
    if (target != null) _opened.add(target);
  }

  Future<List<String>> roomNotificationEvents(
    String userId,
    String roomId,
  ) async {
    final active = await notifications.getActiveNotifications();
    return [
      for (final notification in active)
        if (_parsePayload(notification.tag ?? notification.payload)
            case final target?
            when target.userId == userId && target.roomId == roomId)
          target.eventId,
    ];
  }

  Future<void> cancelRoomNotifications(
    String userId,
    String roomId,
    List<String> eventIds,
  ) async {
    final readEvents = eventIds.toSet();
    for (final notification in await notifications.getActiveNotifications()) {
      final target = _parsePayload(notification.tag ?? notification.payload);
      if (target != null &&
          target.userId == userId &&
          target.roomId == roomId &&
          readEvents.contains(target.eventId) &&
          notification.id != null) {
        await notifications.cancel(id: notification.id!, tag: notification.tag);
      }
    }
  }

  Future<void> retireToken() async {
    if (configuration != null && initializationError == null) {
      await FirebaseMessaging.instance.deleteToken();
    }
  }

  void _checkConfiguration() {
    if (configurationChanged) {
      throw StateError('Firebase 配置已更换，请在系统设置中强行停止 Matter 后重新打开');
    }
    if (configuration == null) {
      throw StateError('请先导入 Android google-services.json');
    }
  }

  Future<void> requestPermission() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance.requestPermission();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
  }

  Future<String> getToken() async {
    await initialize();
    _checkConfiguration();
    if (initializationError != null) throw StateError(initializationError!);
    final permission = await FirebaseMessaging.instance
        .getNotificationSettings();
    if (permission.authorizationStatus != AuthorizationStatus.authorized) {
      throw StateError('通知权限未授予，请在系统设置中允许 Matter 通知');
    }
    final token = await FirebaseMessaging.instance.getToken();
    if (token == null || token.isEmpty) {
      throw StateError('无法获取 FCM 令牌，请检查 Google Play 服务和网络');
    }
    return token;
  }
}

final fcmPushRuntime = FcmPushRuntime();
