import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:convert';
import '../src/rust/api/matrix.dart' as rust;

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
}

final isLoggedInProvider = StateProvider<bool>((ref) => false);

/// Whether the Rust session has been fully restored and is ready for API calls.
final sessionReadyProvider = StateProvider<bool>((ref) => false);

final currentUserProvider = StateProvider<CurrentUser?>((ref) => null);

/// Provider for the homeserver URL
final homeserverProvider = StateProvider<String>(
  (ref) => 'http://10.0.2.2:8008',
);

/// Auth error message provider
final authErrorProvider = StateProvider<String?>((ref) => null);

// ── Multi-account session persistence ─────────────────────────────────

const _kSessions = 'multi_sessions'; // JSON list of StoredSession
const _kSessionDisplayNames =
    'session_display_names'; // JSON map: user_id -> display_name
const _kActiveUserId = 'active_user_id';

/// All saved sessions (for multi-account).
final sessionsProvider = StateProvider<List<rust.StoredSession>>((ref) => []);

/// The currently active user ID (for quick switching).
final activeUserIdProvider = StateProvider<String?>((ref) => null);

/// Save a new session (add to the list, set as active).
Future<void> addSession({
  required String homeserver,
  required String accessToken,
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
    userId: userId,
    deviceId: deviceId,
  );
  sessions.add(newSession);

  // Save
  await prefs.setString(
    _kSessions,
    jsonEncode(
      sessions
          .map(
            (s) => {
              'homeserver_url': s.homeserverUrl,
              'access_token': s.accessToken,
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
  final raw = prefs.getString(_kSessions);
  if (raw == null) return [];

  try {
    final List<dynamic> list = jsonDecode(raw);
    return list
        .map(
          (e) => rust.StoredSession(
            homeserverUrl: e['homeserver_url'] as String,
            accessToken: e['access_token'] as String,
            userId: e['user_id'] as String,
            deviceId: e['device_id'] as String,
          ),
        )
        .toList();
  } catch (_) {
    return [];
  }
}

/// Get the active user ID (the last used account).
Future<String?> loadActiveUserId() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kActiveUserId);
}

/// Get the display name for a user.
Future<String> loadDisplayName(String userId) async {
  final namesMap = await _loadDisplayNames();
  return namesMap[userId] ?? userId.split(':').first.replaceFirst('@', '');
}

/// Remove a session for a specific user_id.
Future<void> removeSession(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  final sessions = await loadAllSessions();
  sessions.removeWhere((s) => s.userId == userId);
  await prefs.setString(
    _kSessions,
    jsonEncode(
      sessions
          .map(
            (s) => {
              'homeserver_url': s.homeserverUrl,
              'access_token': s.accessToken,
              'user_id': s.userId,
              'device_id': s.deviceId,
            },
          )
          .toList(),
    ),
  );

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
  required String userId,
  required String deviceId,
  required String displayName,
}) async {
  await addSession(
    homeserver: homeserver,
    accessToken: accessToken,
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
