import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
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

final currentUserProvider = StateProvider<CurrentUser?>((ref) => null);

/// Provider for the homeserver URL
final homeserverProvider = StateProvider<String>(
  (ref) => 'http://10.0.2.2:8008',
);

/// Auth error message provider
final authErrorProvider = StateProvider<String?>((ref) => null);

// ── Session persistence keys ─────────────────────────────────────────

const _kHomeserver = 'session_homeserver';
const _kAccessToken = 'session_access_token';
const _kUserId = 'session_user_id';
const _kDeviceId = 'session_device_id';
const _kDisplayName = 'session_display_name';

/// Save session data to SharedPreferences.
Future<void> persistSession({
  required String homeserver,
  required String accessToken,
  required String userId,
  required String deviceId,
  required String displayName,
}) async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(_kHomeserver, homeserver);
  await prefs.setString(_kAccessToken, accessToken);
  await prefs.setString(_kUserId, userId);
  await prefs.setString(_kDeviceId, deviceId);
  await prefs.setString(_kDisplayName, displayName);
}

/// Load saved session data. Returns null if no session saved.
Future<rust.StoredSession?> loadPersistedSession() async {
  final prefs = await SharedPreferences.getInstance();
  final homeserver = prefs.getString(_kHomeserver);
  final accessToken = prefs.getString(_kAccessToken);
  final userId = prefs.getString(_kUserId);
  final deviceId = prefs.getString(_kDeviceId);

  if (homeserver == null || accessToken == null || userId == null || deviceId == null) {
    return null;
  }

  return rust.StoredSession(
    homeserverUrl: homeserver,
    accessToken: accessToken,
    userId: userId,
    deviceId: deviceId,
  );
}

/// Clear persisted session data.
Future<void> clearPersistedSession() async {
  final prefs = await SharedPreferences.getInstance();
  await prefs.remove(_kHomeserver);
  await prefs.remove(_kAccessToken);
  await prefs.remove(_kUserId);
  await prefs.remove(_kDeviceId);
  await prefs.remove(_kDisplayName);
}

/// Get the persisted display name.
Future<String?> loadPersistedDisplayName() async {
  final prefs = await SharedPreferences.getInstance();
  return prefs.getString(_kDisplayName);
}
