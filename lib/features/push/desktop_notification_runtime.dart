import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/matrix/desktop_notifications.dart' as rust;
import 'push_settings.dart';

bool get desktopNotificationsSupported =>
    !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

DesktopNotificationRuntime? _activeRuntime;

List<String> desktopRoomNotificationEvents(String userId, String roomId) =>
    _activeRuntime?.roomEvents(userId, roomId) ?? const [];
Future<void> cancelDesktopRoomNotifications(
  String userId,
  String roomId,
  List<String> eventIds,
) =>
    _activeRuntime?.cancelRoom(userId, roomId, eventIds: eventIds) ??
    Future.value();

final desktopNotificationRuntimeProvider = Provider<DesktopNotificationRuntime>(
  (ref) {
    final runtime = DesktopNotificationRuntime();
    _activeRuntime = runtime;
    ref.onDispose(() {
      if (identical(_activeRuntime, runtime)) _activeRuntime = null;
      runtime.dispose();
    });
    return runtime;
  },
);

class DesktopNotificationRuntime {
  DesktopNotificationRuntime({FlutterLocalNotificationsPlugin? plugin})
    : _plugin = plugin ?? FlutterLocalNotificationsPlugin();
  final FlutterLocalNotificationsPlugin _plugin;
  final _opened = StreamController<PushTarget>.broadcast();
  final _roomIds = <(String, String), int>{};
  final _targets = <int, PushTarget>{};
  final _seen = <(String, String, String)>{};
  Future<void>? _initialization;
  Future<void> _tail = Future.value();
  int _nextId = 1;
  bool _disposed = false;
  Stream<PushTarget> get opened => _opened.stream;

  Future<void> _serial(Future<void> Function() operation) {
    final next = _tail.then((_) => operation());
    _tail = next.then((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _initialize() async {
    try {
      final ready = await _plugin.initialize(
        settings: const InitializationSettings(
          linux: LinuxInitializationSettings(defaultActionName: '打开聊天'),
        ),
        onDidReceiveNotificationResponse: (response) {
          final target = _targets[response.id];
          if (!_disposed &&
              target != null &&
              response.payload == jsonEncode(target.toData())) {
            _opened.add(target);
          }
        },
      );
      if (ready == false) throw StateError('系统通知服务不可用');
    } catch (_) {
      _initialization = null;
      rethrow;
    }
  }

  Future<void> show(
    rust.DesktopNotification event, {
    required bool Function() isCurrent,
  }) => _serial(() async {
    final key = (event.userId, event.roomId, event.eventId);
    if (_disposed || _seen.contains(key) || !isCurrent()) return;
    await (_initialization ??= _initialize());
    if (_disposed || !isCurrent()) return;
    final id = _roomIds.putIfAbsent((
      event.userId,
      event.roomId,
    ), () => _nextId++);
    final target = PushTarget(
      userId: event.userId,
      roomId: event.roomId,
      eventId: event.eventId,
      registrationId: 'desktop',
    );
    await _plugin.show(
      id: id,
      title: event.roomName,
      body: const HtmlEscape(HtmlEscapeMode.element)
          .convert('${event.senderName}: ${event.body}'),
      notificationDetails: const NotificationDetails(
        linux: LinuxNotificationDetails(
          category: LinuxNotificationCategory.imReceived,
        ),
      ),
      payload: jsonEncode(target.toData()),
    );
    _targets[id] = target;
    _seen.add(key);
    if (_seen.length > 256) _seen.remove(_seen.first);
    if (!isCurrent()) {
      await _plugin.cancel(id: id);
      _targets.remove(id);
    }
  });

  List<String> roomEvents(String userId, String roomId) => [
    for (final target in _targets.values)
      if (target.userId == userId && target.roomId == roomId) target.eventId,
  ];

  Future<void> cancelRoom(
    String userId,
    String roomId, {
    List<String>? eventIds,
  }) => _serial(() async {
    final id = _roomIds[(userId, roomId)];
    final target = _targets[id];
    if (id == null ||
        target == null ||
        (eventIds != null && !eventIds.contains(target.eventId))) {
      return;
    }
    await _plugin.cancel(id: id);
    _targets.remove(id);
  });

  Future<void> cancelAccount(String userId) => _serial(() async {
    final ids = _targets.entries
        .where((entry) => entry.value.userId == userId)
        .map((entry) => entry.key)
        .toList();
    for (final id in ids) {
      await _plugin.cancel(id: id);
      _targets.remove(id);
    }
  });

  void dispose() {
    _disposed = true;
    unawaited(_opened.close());
  }
}
