import 'dart:async';

import 'push_settings.dart';

typedef RegisterPush =
    Future<void> Function(String userId, PushSettings settings, String token);
typedef UnregisterPush =
    Future<void> Function(String userId, PushRegistration registration);

/// Serializes user settings and token rotation so a late registration cannot
/// resurrect a pusher after the user disables it. The journal survives crashes.
class PushRegistrationManager {
  PushRegistrationManager({
    required this.store,
    required this.register,
    required this.unregister,
    required this.getToken,
    this.updateDeliveryState,
  });

  final PushSettingsStore store;
  final RegisterPush register;
  final UnregisterPush unregister;
  final Future<String> Function(PushSettings settings) getToken;
  final Future<void> Function(String userId, PushSettings settings)?
  updateDeliveryState;
  Future<void> _tail = Future.value();

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<void> configure(
    String userId, {
    required bool enabled,
    required String gatewayUrl,
    required String appId,
    PushBackend backend = PushBackend.android,
    String vapidPublicKey = '',
  }) => _serialize(() async {
    gatewayUrl = gatewayUrl.trim();
    appId = appId.trim();
    if (enabled) {
      final error = validatePushGateway(gatewayUrl) ?? validatePushAppId(appId);
      if (error != null) throw ArgumentError(error);
      if (backend == PushBackend.web) {
        final webError = validateVapidPublicKey(vapidPublicKey);
        if (webError != null) throw ArgumentError(webError);
      }
    }
    if (await store.isAccountRemoved(userId)) throw StateError('此账号正在移除');
    var settings = await store.load(userId);
    settings = settings.copyWith(
      enabled: enabled,
      gatewayUrl: gatewayUrl,
      appId: appId,
      backend: backend,
      vapidPublicKey: vapidPublicKey.trim(),
      registrationId: newPushRegistrationId(),
    );
    // Persist user intent before network work. Disabling works locally even
    // offline, and the journal retries remote deletion on the next refresh.
    await store.save(userId, settings);
    await updateDeliveryState?.call(userId, settings);
    await _reconcile(
      userId,
      settings,
      enabled ? await getToken(settings) : null,
    );
  });

  Future<void> refresh(List<String> userIds) => _serialize(() async {
    final tokens = <String, String>{};
    Object? firstError;
    StackTrace? firstStack;
    for (final userId in userIds) {
      try {
        if (await store.isAccountRemoved(userId)) continue;
        final settings = await store.load(userId);
        await updateDeliveryState?.call(userId, settings);
        String? token;
        if (settings.enabled) {
          final key = '${settings.backend.name}:${settings.vapidPublicKey}';
          token = tokens[key] ??= await getToken(settings);
        }
        await _reconcile(userId, settings, token);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
  });

  /// Run project replacement in the same queue as registration/token refresh.
  /// Persist the new project only after every old FCM pusher is removed.
  Future<void> changeFcmConfiguration(
    Future<void> Function() saveConfiguration,
  ) => _serialize(() async {
    Object? firstError;
    StackTrace? firstStack;
    for (final userId in await store.storedUserIds()) {
      try {
        var settings = await store.load(userId);
        if (settings.backend != PushBackend.android) continue;
        settings = settings.copyWith(
          enabled: false,
          registrationId: newPushRegistrationId(),
        );
        await store.save(userId, settings);
        await updateDeliveryState?.call(userId, settings);
        await _reconcile(userId, settings, null);
      } catch (error, stack) {
        firstError ??= error;
        firstStack ??= stack;
      }
    }
    if (firstError != null) Error.throwWithStackTrace(firstError, firstStack!);
    await saveConfiguration();
  });

  Future<void> prepareAccountRemoval(String userId) => _serialize(() async {
    var settings = await store.load(userId);
    await updateDeliveryState?.call(userId, settings.copyWith(enabled: false));
    // Keep the enabled preference in case logout itself fails. The removal
    // tombstone blocks refresh and delivery until the account action settles.
    for (final old in [...settings.registrations]) {
      await unregister(userId, old);
      settings = settings.copyWith(
        registrations: settings.registrations
            .where((entry) => !entry.matches(old))
            .toList(),
      );
      await store.save(userId, settings);
    }
  });

  Future<void> _reconcile(
    String userId,
    PushSettings settings,
    String? token,
  ) async {
    PushRegistration? desired;
    if (settings.enabled) {
      if (token == null || token.isEmpty) throw StateError('推送设备标识暂不可用，请重试');
      desired = PushRegistration(token: token, appId: settings.appId);
      if (!settings.registrations.any(desired.matches)) {
        settings = settings.copyWith(
          registrations: [...settings.registrations, desired],
        );
        await store.save(userId, settings);
      }
      await register(userId, settings, token);
    }
    for (final old in [...settings.registrations]) {
      if (desired != null && desired.matches(old)) continue;
      await unregister(userId, old);
      settings = settings.copyWith(
        registrations: settings.registrations
            .where((entry) => !entry.matches(old))
            .toList(),
      );
      await store.save(userId, settings);
    }
  }
}
