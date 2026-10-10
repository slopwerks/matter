import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'push_settings.dart';

@JS('matterPush.initialize')
external JSPromise<JSAny?> _initialize();
@JS('matterPush.requestPermission')
external JSPromise<JSAny?> _requestPermission();
@JS('matterPush.subscribe')
external JSPromise<JSString> _subscribe(JSString key);
@JS('matterPush.subscription')
external JSPromise<JSString> _subscription();
@JS('matterPush.updateAccount')
external JSPromise<JSAny?> _updateAccount(
  JSString userId,
  JSString registrationId,
  JSBoolean enabled,
);
@JS('matterPush.roomNotificationEvents')
external JSPromise<JSString> _roomNotificationEvents(
  JSString userId,
  JSString roomId,
);
@JS('matterPush.cancelRoomNotifications')
external JSPromise<JSAny?> _cancelRoomNotifications(
  JSString userId,
  JSString roomId,
  JSArray<JSString> eventIds,
);
@JS('matterPush.addOpenListener')
external void _addOpenListener(JSFunction listener);
@JS('matterPush.takeInitialTarget')
external JSString? _takeInitialTarget();

bool get webPushSupported => true;
final _opened = StreamController<PushTarget>.broadcast();
Stream<PushTarget> get opened => _opened.stream;

PushTarget? _parse(String value) {
  try {
    final data = jsonDecode(value);
    return data is Map<String, dynamic> ? PushTarget.fromData(data) : null;
  } on FormatException {
    return null;
  }
}

Future<void> initialize() async {
  _addOpenListener(
    ((JSString value) {
      final target = _parse(value.toDart);
      if (target != null) _opened.add(target);
    }).toJS,
  );
  // Subscription and permission are deferred until the user enables push.
}

PushTarget? takeInitialTarget() {
  final value = _takeInitialTarget();
  return value == null ? null : _parse(value.toDart);
}

Future<void> requestPermission() async => await _requestPermission().toDart;

Future<String> getToken(PushSettings settings) async {
  await _initialize().toDart;
  final raw = (await _subscribe(settings.vapidPublicKey.toJS).toDart).toDart;
  final subscription = jsonDecode(raw) as Map<String, dynamic>;
  return (subscription['keys'] as Map<String, dynamic>)['p256dh'] as String;
}

Future<String> subscriptionJson() async =>
    (await _subscription().toDart).toDart;

Future<void> updateAccount(String userId, PushSettings settings) async {
  await _updateAccount(
    userId.toJS,
    settings.registrationId.toJS,
    (settings.enabled && settings.backend == PushBackend.web).toJS,
  ).toDart;
}

Future<List<String>> roomNotificationEvents(
  String userId,
  String roomId,
) async =>
    (jsonDecode(
              (await _roomNotificationEvents(
                userId.toJS,
                roomId.toJS,
              ).toDart).toDart,
            )
            as List)
        .cast<String>();

Future<void> cancelRoomNotifications(
  String userId,
  String roomId,
  List<String> eventIds,
) async => await _cancelRoomNotifications(
  userId.toJS,
  roomId.toJS,
  eventIds.map((id) => id.toJS).toList().toJS,
).toDart;

Future<void> blockAccount(String userId) async {
  await _updateAccount(userId.toJS, ''.toJS, false.toJS).toDart;
}
