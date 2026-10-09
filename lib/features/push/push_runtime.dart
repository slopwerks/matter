import 'dart:async';
import 'package:flutter/foundation.dart';

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

Future<void> updatePushDeliveryState(String userId, PushSettings settings) =>
    web_push.updateAccount(userId, settings);
