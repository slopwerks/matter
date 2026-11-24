import 'dart:async';
import 'dart:convert';

import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../src/rust/api/matrix.dart' as rust;
import '../../src/rust/api/matrix/push.dart' as push;
import 'fcm_push_runtime.dart';
import 'firebase_client_config.dart';
import 'push_avatar.dart';
import 'push_room_directory.dart';
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

/// Clear notifications when a synced read on another device empties a room.
final pushReadStateProvider = Provider<void>((ref) {
  if (!pushSupported || !ref.watch(sessionReadyProvider)) return;
  final userId = ref.watch(activeUserIdProvider);
  if (userId == null) return;
  var previous = <String, (int, String)>{};
  ref.listen(allChatRoomsProvider, (_, next) {
    if (next.isLoading || next.hasError) return;
    final rooms = next.asData?.value;
    if (rooms == null) return;
    final current = {
      for (final room in rooms) room.id: (room.unreadCount, room.lastEventId),
    };
    for (final room in rooms) {
      // A room can already be read on the first snapshot, or a new last event
      // can be read before sync ever reports a positive unread count.
      if (room.unreadCount == 0 && previous[room.id] != current[room.id]) {
        unawaited(
          dismissReadRoomPushes(
            userId,
            room.id,
            throughEventId: room.lastEventId,
          ),
        );
      }
    }
    previous = current;
  }, fireImmediately: true);
});

/// Keep the room snapshot the background notification path reads in sync.
///
/// The push payload carries no direct/group flag and may omit a room name, so
/// the payload alone cannot title a notification correctly. Persisting the
/// joined-room list here lets the FCM background isolate read it without any
/// access to the running Rust client.
final pushRoomDirectoryProvider = Provider<void>((ref) {
  if (!pushSupported || !ref.watch(sessionReadyProvider)) return;
  final userId = ref.watch(activeUserIdProvider);
  if (userId == null) return;
  ref.listen(allChatRoomsProvider, (_, next) {
    if (next.isLoading || next.hasError) return;
    final rooms = next.asData?.value;
    if (rooms == null) return;
    final snapshot = [
      for (final room in rooms)
        if (room.roomType != 'space')
          (
            id: room.id,
            name: room.name,
            roomType: room.roomType,
            avatarMxc: room.avatarUrl ?? '',
            isEncrypted: room.isEncrypted,
          ),
    ];
    unawaited(savePushRoomDirectory(userId, snapshot));
    if (kIsWeb) {
      // The browser push worker cannot read local storage, so mirror the
      // direct/group flag it needs to title a notification.
      unawaited(
        updateWebPushRoomDirectory(
          userId,
          jsonEncode({
            for (final room in snapshot)
              room.id: {'name': room.name, 'is_direct': room.roomType == 'dm'},
          }),
        ),
      );
    }
  }, fireImmediately: true);
});

/// Downloads notification avatars using the Rust client's authenticated
/// session, which already holds valid credentials.
final pushAvatarCacheProvider = Provider<PushAvatarCache>(
  (ref) =>
      PushAvatarCache(download: (mxc) => rust.downloadMediaBytes(mxcUrl: mxc)),
);

/// Download the avatars notifications need so the notification path can read
/// them from disk.
///
/// Fetching them in the FCM background isolate silently produced no avatars at
/// all, because that isolate could not read the account's access token. Doing
/// it here also reuses the session the Rust client already holds. Every
/// download is cache-first, so a steady state only stats local files.
final pushAvatarPrefetchProvider = Provider<void>((ref) {
  if (!pushSupported || !ref.watch(sessionReadyProvider)) return;
  final userId = ref.watch(activeUserIdProvider);
  if (userId == null) return;
  // Nothing here is observable unless a notification can be shown, and the
  // contact scan below is expensive (it walks every joined room's member
  // list), so an account with push off must not pay for any of it.
  final settings = ref.watch(pushSettingsProvider(userId)).asData?.value;
  if (settings == null || !settings.enabled) return;
  final cache = ref.read(pushAvatarCacheProvider);

  Future<void> prefetch(Iterable<String?> mxcs) async {
    for (final mxc in mxcs) {
      if (mxc != null && mxc.startsWith('mxc://')) {
        await cache.ensure(userId, mxc);
      }
    }
  }

  // Every joined room's avatar. A direct chat usually has no room avatar of
  // its own, so its sender avatar comes from the contact list below.
  ref.listen(allChatRoomsProvider, (_, next) {
    final rooms = next.asData?.value;
    if (rooms == null) return;
    unawaited(prefetch(rooms.map((room) => room.avatarUrl)));
  }, fireImmediately: true);

  // Sender avatars, recorded account-wide. The contact list spans every joined
  // room, so a room the user never opened still has its senders' avatars
  // available, which a per-room snapshot could not provide.
  ref.listen(contactsProvider, (_, next) {
    final contacts = next.asData?.value;
    if (contacts == null) return;
    unawaited(() async {
      await savePushSenderAvatars(userId, {
        for (final contact in contacts)
          if (contact.avatarUrl case final mxc? when mxc.startsWith('mxc://'))
            contact.id: mxc,
      });
      await prefetch(contacts.map((contact) => contact.avatarUrl));
    }());
  }, fireImmediately: true);
});

/// Kept alive at the app root, including the login page and account switches.
final pushLifecycleProvider = Provider<void>((ref) {
  ref.watch(pushRoomDirectoryProvider);
  ref.watch(pushAvatarPrefetchProvider);
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
      // Keep token refreshes paired with the FCM token registered at the gateway.
      // ignore: deprecated_member_use
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
