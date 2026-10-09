import 'dart:async';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../src/rust/api/matrix/push.dart' as push;
import 'fcm_push_runtime.dart';
import 'firebase_client_config.dart';
import 'push_runtime.dart';
import 'push_registration_manager.dart';
import 'push_settings.dart';

final firebaseClientConfigProvider = FutureProvider<FirebaseClientConfig?>(
  (ref) => FirebaseClientConfigStore().load(),
);

final pushSettingsProvider = FutureProvider.family<PushSettings, String>(
  (ref, userId) => PushSettingsStore().load(userId),
);

final pushRegistrationManagerProvider = Provider<PushRegistrationManager>(
  (ref) => PushRegistrationManager(
    store: PushSettingsStore(),
    getToken: getPushToken,
    updateDeliveryState: updatePushDeliveryState,
    register: (userId, settings, token) async => push.registerHttpPusher(
      accountUserId: userId,
      pushkey: token,
      appId: settings.appId,
      gatewayUrl: settings.gatewayUrl,
      registrationId: settings.registrationId,
      webSubscription: await webSubscription(settings),
    ),
    unregister: (userId, registration) => push.unregisterHttpPusher(
      accountUserId: userId,
      pushkey: registration.token,
      appId: registration.appId,
    ),
  ),
);

final pushRegistrationErrorProvider =
    NotifierProvider<PushRegistrationErrors, Map<String, String>>(
      PushRegistrationErrors.new,
    );

class PushRegistrationErrors extends Notifier<Map<String, String>> {
  @override
  Map<String, String> build() => {};
  void setError(String userId, String? error) {
    state = {...state}..remove(userId);
    if (error != null) state = {...state, userId: error};
  }
}

/// Kept alive at the app root, including the login page and account switches.
final pushLifecycleProvider = Provider<void>((ref) {
  if (!pushSupported) return;
  final manager = ref.read(pushRegistrationManagerProvider);
  var disposed = false;
  Future<void> refresh() async {
    if (!ref.read(sessionReadyProvider)) return;
    try {
      final accounts = await rust.listAccounts();
      for (final account in accounts) {
        try {
          await manager.refresh([account.userId]);
          if (!disposed) {
            ref
                .read(pushRegistrationErrorProvider.notifier)
                .setError(account.userId, null);
          }
        } catch (error) {
          if (!disposed) {
            ref
                .read(pushRegistrationErrorProvider.notifier)
                .setError(account.userId, '$error');
          }
        }
      }
    } catch (error) {
      debugPrint('Push registration refresh failed: ${error.runtimeType}');
    }
  }

  ref.listen(sessionReadyProvider, (_, ready) {
    if (ready) unawaited(refresh());
  });
  ref.listen(sessionsProvider, (_, _) => unawaited(refresh()));
  final tokens =
      fcmPushSupported &&
          fcmPushRuntime.isConfigured &&
          fcmPushRuntime.initializationError == null
      ? FirebaseMessaging.instance.onTokenRefresh.listen(
          (_) => unawaited(refresh()),
        )
      : null;
  ref.onDispose(() {
    disposed = true;
    unawaited(tokens?.cancel());
  });
  unawaited(refresh());
});
