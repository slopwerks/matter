import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Media fixtures run on Wi-Fi unless a test explicitly exercises network rules.
Future<void> installStorageWifi() async {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const connectivity = MethodChannel('dev.fluttercommunity.plus/connectivity');
  const events = MethodChannel('dev.fluttercommunity.plus/connectivity_status');
  messenger.setMockMethodCallHandler(connectivity, (_) async => ['wifi']);
  messenger.setMockMethodCallHandler(events, (_) async => null);
  addTearDown(() {
    messenger.setMockMethodCallHandler(connectivity, null);
    messenger.setMockMethodCallHandler(events, null);
  });
  await SharedPreferences.getInstance();
}
