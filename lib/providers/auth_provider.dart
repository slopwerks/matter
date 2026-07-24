import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/markdown/markdown_source_store.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'authenticated_media_cache.dart';
import 'message_cache_persistence.dart';
import 'mutable_state.dart';

class CurrentUser {
  final String id;
  final String displayName;
  final String? avatarUrl;
  final String homeserver;

  const CurrentUser({
    required this.id,
    required this.displayName,
    this.avatarUrl,
    required this.homeserver,
  });

  CurrentUser copyWith({String? displayName, String? avatarUrl}) {
    return CurrentUser(
      id: id,
      displayName: displayName ?? this.displayName,
      avatarUrl: avatarUrl ?? this.avatarUrl,
      homeserver: homeserver,
    );
  }
}

final isLoggedInProvider = NotifierProvider<MutableState<bool>, bool>(
  () => MutableState(false),
);

/// Whether the Rust session has been fully restored and is ready for API calls.
final sessionReadyProvider = NotifierProvider<MutableState<bool>, bool>(
  () => MutableState(false),
);

final currentUserProvider =
    NotifierProvider<MutableState<CurrentUser?>, CurrentUser?>(
      () => MutableState(null),
    );

final currentAccessTokenProvider =
    NotifierProvider<MutableState<String?>, String?>(() => MutableState(null));

/// Provider for the homeserver URL
final homeserverProvider = NotifierProvider<MutableState<String>, String>(
  () => MutableState(''),
);

/// Auth error message provider
final authErrorProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

// ── Multi-account session persistence ─────────────────────────────────

const _kSessions = 'multi_sessions'; // JSON list of StoredSession
const _kSessionDisplayNames =
    'session_display_names'; // JSON map: user_id -> display_name
const _kActiveUserId = 'active_user_id';
final _secureStorage = defaultTargetPlatform == TargetPlatform.macOS
    ? FlutterSecureStorage(
        mOptions: MacOsOptions(
          accessibility: KeychainAccessibility.first_unlock_this_device,
          usesDataProtectionKeychain: false,
        ),
      )
    : const FlutterSecureStorage();

String _tokenKey(String userId) =>
    'matrix_access_token_${base64Url.encode(utf8.encode(userId))}';

String _refreshTokenKey(String userId) =>
    'matrix_refresh_token_${base64Url.encode(utf8.encode(userId))}';

/// All saved sessions (for multi-account).
final sessionsProvider =
    NotifierProvider<
      MutableState<List<rust.StoredSession>>,
      List<rust.StoredSession>
    >(() => MutableState([]));

/// The currently active user ID (for quick switching).
final activeUserIdProvider = NotifierProvider<MutableState<String?>, String?>(
  () => MutableState(null),
);

/// Save a new session (add to the list, set as active).
Future<void> addSession({
  required String homeserver,
  required String accessToken,
  String? refreshToken,
  required String userId,
  required String deviceId,
  required String displayName,
}) async {
  final prefs = await SharedPreferences.getInstance();

  // Load existing sessions
  final sessions = await loadAllSessions();

  // Remove any existing session for the same user_id (re-login)
  sessions.removeWhere((s) => s.userId == userId);

  // Add new session
  final newSession = rust.StoredSession(
    homeserverUrl: homeserver,
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: userId,
    deviceId: deviceId,
  );
  sessions.add(newSession);

  await _secureStorage.write(key: _tokenKey(userId), value: accessToken);
  if (refreshToken != null && refreshToken.isNotEmpty) {
    await _secureStorage.write(
      key: _refreshTokenKey(userId),
      value: refreshToken,
    );
  } else {
    await _secureStorage.delete(key: _refreshTokenKey(userId));
  }

  // Save
  await prefs.setString(
    _kSessions,
    jsonEncode(
      sessions
          .map(
            (s) => {
              'homeserver_url': s.homeserverUrl,
              'user_id': s.userId,
              'device_id': s.deviceId,
            },
          )
          .toList(),
    ),
  );

  // Save display name
  final namesMap = await _loadDisplayNames();
  namesMap[userId] = displayName;
  await prefs.setString(_kSessionDisplayNames, jsonEncode(namesMap));

  // Set as active
  await prefs.setString(_kActiveUserId, userId);
}

/// Load all saved sessions.
Future<List<rust.StoredSession>> loadAllSessions() async {
  final prefs = await SharedPreferences.getInstance();
  await MarkdownSourceStore.clearLegacyEntries();
  final raw = prefs.getString(_kSessions);
  if (raw == null) return [];

  try {
    final List<dynamic> list = jsonDecode(raw);
    final sessions = <rust.StoredSession>[];
    var migratedPlaintextTokens = false;
    for (final item in list) {
      String? userId;
      try {
        final e = item as Map<String, dynamic>;
        userId = e['user_id'] as String;
        var accessToken = await _secureStorage.read(key: _tokenKey(userId));
        var refreshToken = await _secureStorage.read(
          key: _refreshTokenKey(userId),
        );

        // Migrate sessions written by older versions, then remove the token
        // from SharedPreferences when the sanitized metadata is saved below.
        final legacyToken = e['access_token'] as String?;
        if (legacyToken != null) {
          migratedPlaintextTokens = true;
          if (accessToken == null && legacyToken.isNotEmpty) {
            accessToken = legacyToken;
            await _secureStorage.write(
              key: _tokenKey(userId),
              value: legacyToken,
            );
          }
        }
        final legacyRefreshToken = e['refresh_token'] as String?;
        if (legacyRefreshToken != null) {
          migratedPlaintextTokens = true;
          if ((refreshToken == null || refreshToken.isEmpty) &&
              legacyRefreshToken.isNotEmpty) {
            refreshToken = legacyRefreshToken;
            await _secureStorage.write(
              key: _refreshTokenKey(userId),
              value: legacyRefreshToken,
            );
          }
        }
        if (accessToken == null || accessToken.isEmpty) {
          debugPrint('Saved session has no secure token for $userId');
          continue;
        }

        sessions.add(
          rust.StoredSession(
            homeserverUrl: e['homeserver_url'] as String,
            accessToken: accessToken,
            refreshToken: (refreshToken == null || refreshToken.isEmpty)
                ? null
                : refreshToken,
            userId: userId,
            deviceId: e['device_id'] as String,
          ),
        );
      } catch (error) {
        debugPrint(
          'Failed to load saved session${userId == null ? '' : ' for $userId'}: $error',
        );
      }
    }

    if (migratedPlaintextTokens) {
      await _saveSessionMetadata(prefs, sessions);
    }
    return sessions;
  } catch (error) {
    debugPrint('Failed to decode saved sessions: $error');
    return [];
  }
}

/// Get the active user ID (the last used account).
Future<String?> loadActiveUserId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kActiveUserId);
}

/// Persist the account that should be restored as active on the next launch.
Future<void> saveActiveUserId(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kActiveUserId, userId);
}

Future<void> persistSessionTokens({
  required String userId,
  required String accessToken,
  String? refreshToken,
}) async {
  await _secureStorage.write(key: _tokenKey(userId), value: accessToken);
  if (refreshToken != null && refreshToken.isNotEmpty) {
    await _secureStorage.write(
      key: _refreshTokenKey(userId),
      value: refreshToken,
    );
  } else {
    await _secureStorage.delete(key: _refreshTokenKey(userId));
  }
}

Future<void> syncStoredSessionTokens(String userId) async {
  final accessToken = await rust.getAccessToken();
  if (accessToken == null || accessToken.isEmpty) return;
  await persistSessionTokens(
    userId: userId,
    accessToken: accessToken,
    refreshToken: await rust.getRefreshToken(),
  );
}

final sessionTokenPersistenceProvider =
    Provider<StreamSubscription<rust.SessionTokenUpdate>>((ref) {
      var pendingWrite = Future<void>.value();
      final subscription = rust.watchSessionTokenUpdates().listen((update) {
        pendingWrite = pendingWrite.then((_) async {
          try {
            await persistSessionTokens(
              userId: update.userId,
              accessToken: update.accessToken,
              refreshToken: update.refreshToken,
            );
          } catch (error) {
            debugPrint(
              'Failed to persist refreshed session tokens for '
              '${update.userId}: $error',
            );
          }
        });
      });
      ref.onDispose(subscription.cancel);
      return subscription;
    });

/// Get the display name for a user.
Future<String> loadDisplayName(String userId) async {
  final namesMap = await _loadDisplayNames();
  return namesMap[userId] ?? userId.split(':').first.replaceFirst('@', '');
}

/// Remove a session for a specific user_id.
Future<void> removeSession(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  final sessions = await loadAllSessions();
  final removedSessions = sessions.where((s) => s.userId == userId).toList();
  sessions.removeWhere((s) => s.userId == userId);
  await _saveSessionMetadata(prefs, sessions);
  await _secureStorage.delete(key: _tokenKey(userId));
  await _secureStorage.delete(key: _refreshTokenKey(userId));
  await clearCachedMessagesForNamespace(userId);
  await const MarkdownSourceStore().clearForUser(userId);
  for (final session in removedSessions) {
    await clearAuthenticatedMediaCacheForSession(
      userId: session.userId,
      homeserver: session.homeserverUrl,
    );
  }

  final namesMap = await _loadDisplayNames();
  namesMap.remove(userId);
  await prefs.setString(_kSessionDisplayNames, jsonEncode(namesMap));

  // If this was the active user, switch to another or clear
  final activeId = prefs.getString(_kActiveUserId);
  if (activeId == userId) {
    if (sessions.isNotEmpty) {
      await prefs.setString(_kActiveUserId, sessions.first.userId);
    } else {
      await prefs.remove(_kActiveUserId);
    }
  }
}

/// Clear all persisted sessions.
Future<void> clearAllSessions() async {
  final prefs = await SharedPreferences.getInstance();
  final sessions = await loadAllSessions();
  for (final session in sessions) {
    await _secureStorage.delete(key: _tokenKey(session.userId));
    await _secureStorage.delete(key: _refreshTokenKey(session.userId));
    await clearCachedMessagesForNamespace(session.userId);
    await const MarkdownSourceStore().clearForUser(session.userId);
    await clearAuthenticatedMediaCacheForSession(
      userId: session.userId,
      homeserver: session.homeserverUrl,
    );
  }
  await const MarkdownSourceStore().clearAll();
  await prefs.remove(_kSessions);
  await prefs.remove(_kSessionDisplayNames);
  await prefs.remove(_kActiveUserId);
}

// ── Legacy single-session compat (migration) ───────────────────────────

const _kHomeserver = 'session_homeserver';
const _kAccessToken = 'session_access_token';
const _kUserId = 'session_user_id';
const _kDeviceId = 'session_device_id';
const _kDisplayName = 'session_display_name';

/// Migrate legacy single-session data to multi-session format.
/// Returns true if migration happened.
Future<bool> migrateLegacySession() async {
  final prefs = await SharedPreferences.getInstance();
  final homeserver = prefs.getString(_kHomeserver);
  final accessToken = prefs.getString(_kAccessToken);
  final userId = prefs.getString(_kUserId);
  final deviceId = prefs.getString(_kDeviceId);
  final displayName = prefs.getString(_kDisplayName);

  if (homeserver == null ||
      accessToken == null ||
      userId == null ||
      deviceId == null) {
    return false;
  }

  // Add to multi-session format
  await addSession(
    homeserver: homeserver,
    accessToken: accessToken,
    refreshToken: null,
    userId: userId,
    deviceId: deviceId,
    displayName: displayName ?? userId.split(':').first.replaceFirst('@', ''),
  );

  // Remove legacy keys
  await prefs.remove(_kHomeserver);
  await prefs.remove(_kAccessToken);
  await prefs.remove(_kUserId);
  await prefs.remove(_kDeviceId);
  await prefs.remove(_kDisplayName);

  return true;
}

// ── Internal helpers ──────────────────────────────────────────────────

Future<Map<String, String>> _loadDisplayNames() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kSessionDisplayNames);
  if (raw == null) return {};
  try {
    final Map<String, dynamic> map = jsonDecode(raw);
    return map.map((k, v) => MapEntry(k, v as String));
  } catch (_) {
    return {};
  }
}

Future<void> _saveSessionMetadata(
  SharedPreferences prefs,
  List<rust.StoredSession> sessions,
) async {
  await prefs.setString(
    _kSessions,
    jsonEncode(
      sessions
          .map(
            (s) => {
              'homeserver_url': s.homeserverUrl,
              'user_id': s.userId,
              'device_id': s.deviceId,
            },
          )
          .toList(),
    ),
  );
}

// ── Legacy compat functions (still used in settings page logout) ───────

/// Get the current session if logged in, for persisting.
/// Delegates to the Rust side.
Future<rust.StoredSession?> getStoredSession() async {
  return await rust.getSession();
}

/// Clear persisted session data (removes active session only).
Future<void> clearPersistedSession() async {
  final userId = await rust.getActiveUserId();
  if (userId != null) {
    await removeSession(userId);
  }
}

/// @deprecated Use addSession instead for multi-account.
Future<void> persistSession({
  required String homeserver,
  required String accessToken,
  String? refreshToken,
  required String userId,
  required String deviceId,
  required String displayName,
}) async {
  await addSession(
    homeserver: homeserver,
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: userId,
    deviceId: deviceId,
    displayName: displayName,
  );
}

/// @deprecated Use loadAllSessions instead for multi-account.
Future<rust.StoredSession?> loadPersistedSession() async {
  final sessions = await loadAllSessions();
  final activeId = await loadActiveUserId();
  if (activeId != null) {
    return sessions.cast<rust.StoredSession?>().firstWhere(
      (s) => s?.userId == activeId,
      orElse: () => sessions.isNotEmpty ? sessions.first : null,
    );
  }
  return sessions.isNotEmpty ? sessions.first : null;
}

/// @deprecated Use removeSession instead for multi-account.
Future<void> clearPersistedSessionLegacy() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kHomeserver);
  await prefs.remove(_kAccessToken);
  await prefs.remove(_kUserId);
  await prefs.remove(_kDeviceId);
  await prefs.remove(_kDisplayName);
}
