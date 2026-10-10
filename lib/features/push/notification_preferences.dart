import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../src/rust/api/matrix/notifications.dart' as rust;

/// Account IDs are passed through every call, including after an account switch.
class NotificationPreferencesApi {
  const NotificationPreferencesApi();

  Future<rust.NotificationPreferences> load(String userId) =>
      rust.getNotificationRules(accountUserId: userId);

  Future<void> setRule(
    String userId,
    rust.NotificationRule rule,
    bool enabled,
  ) => rust.setNotificationRule(
    accountUserId: userId,
    rule: rule,
    enabled: enabled,
  );

  Future<void> setKeyword(String userId, String keyword, bool enabled) =>
      rust.setNotificationKeyword(
        accountUserId: userId,
        keyword: keyword,
        enabled: enabled,
      );
}

final notificationPreferencesApiProvider = Provider<NotificationPreferencesApi>(
  (ref) => const NotificationPreferencesApi(),
);

final notificationPreferencesProvider = FutureProvider.autoDispose
    .family<rust.NotificationPreferences, String>(
      (ref, userId) =>
          ref.watch(notificationPreferencesApiProvider).load(userId),
    );
