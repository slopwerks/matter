import 'dart:async';
import 'push_settings.dart';

bool get webPushSupported => false;
Future<void> initialize() async {}
Future<void> requestPermission() async =>
    throw UnsupportedError('Web Push 仅支持浏览器');
Future<String> getToken(PushSettings settings) async =>
    throw UnsupportedError('Web Push 仅支持浏览器');
Future<String> subscriptionJson() async =>
    throw UnsupportedError('Web Push 仅支持浏览器');
Future<void> updateAccount(String userId, PushSettings settings) async {}
Future<List<String>> roomNotificationEvents(
  String userId,
  String roomId,
) async => [];
Future<void> cancelRoomNotifications(
  String userId,
  String roomId,
  List<String> eventIds,
) async {}
Future<void> blockAccount(String userId) async {}
Stream<PushTarget> get opened => const Stream.empty();
PushTarget? takeInitialTarget() => null;
