import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/markdown/markdown_source_store.dart';
import '../features/push/push_settings.dart';
import '../src/rust/api/matrix.dart' as rust;
import 'authenticated_media_cache.dart';
import 'ignored_users_persistence.dart';
import 'message_cache_persistence.dart';
import 'mutable_state.dart';
import 'session_credential_store.dart';

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

final sessionCredentialStoreFailureProvider =
    NotifierProvider<MutableState<String?>, String?>(() => MutableState(null));

String? _startupSessionCredentialStoreFailure;

String? get startupSessionCredentialStoreFailure =>
    _startupSessionCredentialStoreFailure;

String? detectSessionCredentialStoreFailure(Object error) {
  if (defaultTargetPlatform != TargetPlatform.android ||
      (error is! SessionCredentialStoreException &&
          !isKeystoreFailure(error))) {
    return null;
  }
  return '$error';
}

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
    : defaultTargetPlatform == TargetPlatform.android
    ? const FlutterSecureStorage(aOptions: AndroidOptions(resetOnError: false))
    : const FlutterSecureStorage();
const _androidSecureStorageReset = FlutterSecureStorage(
  aOptions: AndroidOptions(resetOnError: true),
);

void _logSessionStorage(String level, String message) {
  debugPrint(message);
  try {
    rust.logAppMessage(level: level, tag: 'auth-storage', message: message);
  } catch (error) {
    // Provider unit tests use partial Rust API fakes. Runtime logging is
    // initialized before session discovery, so this fallback is test-only.
    debugPrint('Failed to persist auth-storage diagnostic: $error');
  }
}

String _sessionStorageErrorSummary(Object error) {
  if (error is FormatException) return 'malformed persisted session data';
  if (error is SessionCredentialStoreException) {
    return 'credential persistence verification failed';
  }
  if (isKeystoreFailure(error)) {
    return 'Android Keystore operation failed (${error.runtimeType})';
  }
  return error.runtimeType.toString();
}

String _tokenKey(String userId) =>
    'matrix_access_token_${base64Url.encode(utf8.encode(userId))}';

String _refreshTokenKey(String userId) =>
    'matrix_refresh_token_${base64Url.encode(utf8.encode(userId))}';

String _searchIndexKey(String userId) =>
    'matrix_search_index_key_${base64Url.encode(utf8.encode(userId))}';

String createSearchIndexKey() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes);
}

Future<void> persistSearchIndexKey(String userId, String key) async {
  if (key.isEmpty) throw StateError('搜索索引密钥为空');
  if (await isSessionCredentialCompatibilityModeEnabled()) {
    _logSessionStorage(
      'warn',
      'Search index key is session-only for $userId because secure storage '
          'compatibility mode is enabled',
    );
    return;
  }
  await _secureStorage.write(key: _searchIndexKey(userId), value: key);
  if (await _secureStorage.read(key: _searchIndexKey(userId)) != key) {
    throw StateError('搜索索引密钥写入校验失败');
  }
}

Future<({String key, bool created})> loadOrCreateSearchIndexKey(
  String userId,
) async {
  if (await isSessionCredentialCompatibilityModeEnabled()) {
    // Compatibility mode cannot persist the index key securely, so use an
    // in-memory index (empty key) and let the caller pass
    // useInMemorySearchIndex: true to Rust.
    return (key: '', created: false);
  }
  final stored = await _secureStorage.read(key: _searchIndexKey(userId));
  if (stored != null && stored.isNotEmpty) {
    return (key: stored, created: false);
  }
  final key = createSearchIndexKey();
  await persistSearchIndexKey(userId, key);
  return (key: key, created: true);
}

String _removedSessionKey(String userId) =>
    'matrix_session_removed_${base64Url.encode(utf8.encode(userId))}';

const _removedSessionKeyPrefix = 'matrix_session_removed_';

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
  String? searchIndexKey,
}) async {
  final prefs = await SharedPreferences.getInstance();

  // Load existing sessions
  final sessions = await loadAllSessions();

  // Remove any existing session for the same user_id (re-login)
  sessions.removeWhere((s) => s.userId == userId);
  _logSessionStorage(
    'info',
    'Persisting session for $userId: existingSessions=${sessions.length}, '
        'refreshTokenProvided=${refreshToken != null && refreshToken.isNotEmpty}',
  );

  // Add new session
  final newSession = rust.StoredSession(
    homeserverUrl: homeserver,
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: userId,
    deviceId: deviceId,
  );
  sessions.add(newSession);

  await persistSessionTokens(
    userId: userId,
    accessToken: accessToken,
    refreshToken: refreshToken,
  );
  if (searchIndexKey != null) {
    await persistSearchIndexKey(userId, searchIndexKey);
  }

  await unmarkSessionRemoved(userId);

  // Save
  final metadataSaved = await prefs.setString(
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
  final displayNameSaved = await prefs.setString(
    _kSessionDisplayNames,
    jsonEncode(namesMap),
  );

  // Set as active
  final activeUserSaved = await prefs.setString(_kActiveUserId, userId);
  _logSessionStorage(
    metadataSaved && displayNameSaved && activeUserSaved ? 'info' : 'error',
    'Session metadata write for $userId: metadataSaved=$metadataSaved, '
    'displayNameSaved=$displayNameSaved, '
    'activeUserSaved=$activeUserSaved, '
    'storedSessions=${sessions.length}',
  );
  if (!metadataSaved || !displayNameSaved || !activeUserSaved) {
    throw StateError('本地会话元数据写入失败');
  }
}

/// Load all saved sessions.
Future<List<rust.StoredSession>> loadAllSessions() async {
  _startupSessionCredentialStoreFailure = null;
  final prefs = await SharedPreferences.getInstance();
  await isSessionCredentialCompatibilityModeEnabled();
  await MarkdownSourceStore.clearLegacyEntries();
  final raw = prefs.getString(_kSessions);
  if (raw == null) {
    _logSessionStorage(
      'warn',
      'No session metadata found: '
          'activeUserPresent=${prefs.containsKey(_kActiveUserId)}, '
          'preferenceKeyCount=${prefs.getKeys().length}',
    );
    return [];
  }

  try {
    final List<dynamic> list = jsonDecode(raw);
    _logSessionStorage(
      'info',
      'Decoded session metadata: entries=${list.length}, '
          'activeUserPresent=${prefs.containsKey(_kActiveUserId)}',
    );
    final sessions = <rust.StoredSession>[];
    var migratedPlaintextTokens = false;
    for (var index = 0; index < list.length; index++) {
      final item = list[index];
      String? userId;
      try {
        final e = item as Map<String, dynamic>;
        userId = e['user_id'] as String;
        if (prefs.containsKey(_removedSessionKey(userId))) {
          _logSessionStorage(
            'info',
            'Skipping removed session metadata for $userId at index $index',
          );
          continue;
        }
        final credentials = await _readSessionCredentials(userId, index);
        var accessToken = credentials?.accessToken;
        var refreshToken = credentials?.refreshToken;

        // Migrate sessions written by older versions, then remove the token
        // from SharedPreferences when the sanitized metadata is saved below.
        final legacyToken = e['access_token'] as String?;
        if (legacyToken != null) {
          migratedPlaintextTokens = true;
          if (accessToken == null && legacyToken.isNotEmpty) {
            accessToken = legacyToken;
            await persistSessionTokens(
              userId: userId,
              accessToken: legacyToken,
              refreshToken: refreshToken,
            );
          }
        }
        final legacyRefreshToken = e['refresh_token'] as String?;
        if (legacyRefreshToken != null) {
          migratedPlaintextTokens = true;
          if ((refreshToken == null || refreshToken.isEmpty) &&
              legacyRefreshToken.isNotEmpty) {
            refreshToken = legacyRefreshToken;
            await persistSessionTokens(
              userId: userId,
              accessToken: accessToken ?? '',
              refreshToken: legacyRefreshToken,
            );
          }
        }
        if (accessToken == null || accessToken.isEmpty) {
          _logSessionStorage(
            'warn',
            'Skipping saved session for $userId: secure access token is missing',
          );
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
        _logSessionStorage(
          'info',
          'Loaded saved session for $userId: '
              'refreshTokenPresent=${refreshToken != null && refreshToken.isNotEmpty}',
        );
      } catch (error) {
        final credentialStoreFailure = detectSessionCredentialStoreFailure(
          error,
        );
        if (credentialStoreFailure != null) {
          _startupSessionCredentialStoreFailure = credentialStoreFailure;
        }
        _logSessionStorage(
          'error',
          'Failed to load saved session at index $index'
              '${userId == null ? '' : ' for $userId'}: '
              '${_sessionStorageErrorSummary(error)}',
        );
      }
    }

    if (migratedPlaintextTokens) {
      await _saveSessionMetadata(prefs, sessions);
    }
    _logSessionStorage(
      'info',
      'Session discovery completed: usableSessions=${sessions.length}, '
          'metadataEntries=${list.length}, '
          'migratedPlaintextTokens=$migratedPlaintextTokens',
    );
    return sessions;
  } catch (error) {
    _logSessionStorage(
      'error',
      'Failed to decode saved sessions: '
          '${_sessionStorageErrorSummary(error)}',
    );
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
  try {
    final compatibilityMode = await storeSessionCredentials(
      userId: userId,
      accessToken: accessToken,
      refreshToken: refreshToken,
      writeSecureCredentials: () async {
        await _secureStorage.write(key: _tokenKey(userId), value: accessToken);
        if (refreshToken != null && refreshToken.isNotEmpty) {
          await _secureStorage.write(
            key: _refreshTokenKey(userId),
            value: refreshToken,
          );
        } else {
          await _secureStorage.delete(key: _refreshTokenKey(userId));
        }
        final accessTokenReadback = await _secureStorage.read(
          key: _tokenKey(userId),
        );
        final refreshTokenReadback = await _secureStorage.read(
          key: _refreshTokenKey(userId),
        );
        final accessKeyPresent = await _secureStorage.containsKey(
          key: _tokenKey(userId),
        );
        final refreshKeyPresent = await _secureStorage.containsKey(
          key: _refreshTokenKey(userId),
        );
        final expectedRefreshToken =
            refreshToken != null && refreshToken.isNotEmpty
            ? refreshToken
            : null;
        final verified =
            accessKeyPresent &&
            accessTokenReadback == accessToken &&
            refreshTokenReadback == expectedRefreshToken &&
            refreshKeyPresent == (expectedRefreshToken != null);
        _logSessionStorage(
          verified ? 'info' : 'error',
          'Secure token write verification for $userId: '
          'accessKeyPresent=$accessKeyPresent, '
          'accessTokenMatches=${accessTokenReadback == accessToken}, '
          'refreshKeyPresent=$refreshKeyPresent, '
          'refreshTokenMatches=${refreshTokenReadback == expectedRefreshToken}',
        );
        if (!verified) {
          throw const SessionCredentialStoreException('系统密钥库未能持久化登录凭据');
        }
      },
    );
    if (compatibilityMode) {
      _logSessionStorage(
        'warn',
        'Session credentials persisted in compatibility mode for $userId',
      );
    }
  } catch (error) {
    _logSessionStorage(
      'error',
      'Session credential write failed for $userId: '
          '${_sessionStorageErrorSummary(error)}',
    );
    rethrow;
  }
}

Future<SessionCredentials?> _readSessionCredentials(
  String userId,
  int index,
) async {
  final result = await readSessionCredentials(
    userId: userId,
    readSecureCredentials: () async {
      final accessKeyPresent = await _secureStorage.containsKey(
        key: _tokenKey(userId),
      );
      final refreshKeyPresent = await _secureStorage.containsKey(
        key: _refreshTokenKey(userId),
      );
      _logSessionStorage(
        'info',
        'Reading secure tokens for $userId at index $index: '
            'accessKeyPresent=$accessKeyPresent, '
            'refreshKeyPresent=$refreshKeyPresent',
      );
      return SessionCredentials(
        accessToken: await _secureStorage.read(key: _tokenKey(userId)) ?? '',
        refreshToken: await _secureStorage.read(key: _refreshTokenKey(userId)),
      );
    },
  );
  final credentials = result.credentials;
  if (result.compatibilityMode) {
    _logSessionStorage(
      credentials == null ? 'warn' : 'info',
      'Reading compatibility credentials for $userId at index $index: '
      'credentialsPresent=${credentials != null}',
    );
  }
  return credentials;
}

Future<void> deletePersistedSessionCredentials(String userId) async {
  // This deletes the encrypted search index *key* from secure storage. The
  // index directory itself lives in the SDK data dir and is removed by Rust
  // during logout / remove_account (delete_account_sdk_store). If that cleanup
  // fails, the orphaned directory is reset on the next login because the key
  // is gone and restoreSession receives a fresh key with resetSearchIndex=true.
  // Interruption retries call cleanupRemovedAccountStore, which also deletes
  // the whole SDK dir.
  await removeSessionCredentials(
    userId: userId,
    deleteSecureCredentials: () async {
      await _secureStorage.delete(key: _tokenKey(userId));
      await _secureStorage.delete(key: _refreshTokenKey(userId));
      await _secureStorage.delete(key: _searchIndexKey(userId));
    },
  );
}

Future<({Set<String> userIds, bool complete})>
_loadSessionCredentialInventory() async {
  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getString(_kSessions);
  if (raw == null) return (userIds: <String>{}, complete: true);

  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) {
      return (userIds: <String>{}, complete: false);
    }
    final userIds = <String>{};
    var complete = true;
    for (final item in decoded) {
      if (item is! Map) {
        complete = false;
        continue;
      }
      final userId = item['user_id'];
      if (userId is! String) {
        complete = false;
        continue;
      }
      if (!prefs.containsKey(_removedSessionKey(userId))) {
        userIds.add(userId);
      }
    }
    return (userIds: userIds, complete: complete);
  } catch (error) {
    _logSessionStorage(
      'error',
      'Failed to inventory saved sessions before credential recovery: '
          '${_sessionStorageErrorSummary(error)}',
    );
    return (userIds: <String>{}, complete: false);
  }
}

Future<void> enableSessionCredentialCompatibilityModeAfterFailure() async {
  if (defaultTargetPlatform != TargetPlatform.android) {
    throw StateError('凭据兼容模式故障恢复仅适用于 Android');
  }
  final inventory = await _loadSessionCredentialInventory();
  final recoveredCredentials = <String, SessionCredentials>{};
  for (final session in await loadAllSessions()) {
    recoveredCredentials[session.userId] = SessionCredentials(
      accessToken: session.accessToken,
      refreshToken: session.refreshToken,
    );
  }
  final resetError = await recoverSessionCredentialStore(
    recoveredCredentials: recoveredCredentials,
    loadLatestCredentials: () async {
      final currentSession = await rust.getSession();
      if (currentSession == null) return const {};
      return {
        currentSession.userId: SessionCredentials(
          accessToken: currentSession.accessToken,
          refreshToken: currentSession.refreshToken,
        ),
      };
    },
    shouldResetSecureValues: (recoveredUserIds) {
      final complete =
          inventory.complete &&
          inventory.userIds.every(recoveredUserIds.contains);
      if (!complete) {
        _logSessionStorage(
          'warn',
          'Secure storage reset skipped because not every saved account '
              'credential could be copied',
        );
      }
      return complete;
    },
    resetSecureValues: _androidSecureStorageReset.deleteAll,
  );
  if (resetError != null) {
    _logSessionStorage(
      'warn',
      'Compatibility mode enabled, but secure storage reset failed: '
          '${_sessionStorageErrorSummary(resetError)}',
    );
  }
  _startupSessionCredentialStoreFailure = null;
  _logSessionStorage(
    'warn',
    'Session credential compatibility mode enabled after Keystore failure',
  );
}

Future<({bool rustSessionDiscarded, String? warning})>
discardUnpersistedLoginSession() async {
  final warnings = <String>[];
  String? userId;
  try {
    userId = (await rust.getSession())?.userId;
  } catch (error) {
    warnings.add('无法读取待撤销会话：$error');
  }

  if (userId != null) {
    try {
      await markSessionRemoved(userId);
    } catch (error) {
      warnings.add('无法记录本地清理状态：$error');
    }
  }

  var rustSessionDiscarded = false;
  try {
    final result = await rust.logout();
    rustSessionDiscarded = true;
    if (result.cleanupError case final cleanupError?) {
      warnings.add('SDK 数据清理失败：$cleanupError');
    }
    if (result.remoteLogoutPending) {
      warnings.add('远端会话撤销失败，服务器上的登录设备可能仍然有效，请从其他已登录客户端删除该设备');
    }
  } catch (error) {
    warnings.add('登录会话撤销失败：$error');
  }

  if (userId != null) {
    try {
      await removeSession(userId);
    } catch (error) {
      warnings.add('本地登录凭据清理失败：$error');
    }
  }

  return (
    rustSessionDiscarded: rustSessionDiscarded,
    warning: warnings.isEmpty ? null : warnings.join('；'),
  );
}

// Read and persist within one queue. Delayed rotation notifications must read
// the account's current pair rather than overwrite it with their older payload.
bool _sessionTokenPersistenceActive = false;
final _sessionTokenPersistenceWaiters = <Completer<void>>[];

Future<void> syncStoredSessionTokens(String userId) async {
  if (_sessionTokenPersistenceActive) {
    final turn = Completer<void>();
    _sessionTokenPersistenceWaiters.add(turn);
    await turn.future;
  } else {
    _sessionTokenPersistenceActive = true;
  }
  try {
    final tokens = await rust.getSessionTokens(accountUserId: userId);
    if (tokens == null || tokens.accessToken.isEmpty) return;
    await persistSessionTokens(
      userId: tokens.userId,
      accessToken: tokens.accessToken,
      refreshToken: tokens.refreshToken,
    );
  } finally {
    if (_sessionTokenPersistenceWaiters.isEmpty) {
      _sessionTokenPersistenceActive = false;
    } else {
      _sessionTokenPersistenceWaiters.removeAt(0).complete();
    }
  }
}

final sessionTokenPersistenceProvider =
    Provider<StreamSubscription<rust.SessionTokenUpdate>>((ref) {
      final subscription = rust.watchSessionTokenUpdates().listen((update) {
        unawaited(
          syncStoredSessionTokens(update.userId).catchError((Object error) {
            debugPrint(
              'Failed to persist refreshed session tokens for '
              '${update.userId}: $error',
            );
          }),
        );
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
  // Every caller persists the removed marker before invoking this (the
  // settings flow marks first, and the startup retry only runs for
  // already-marked accounts), so loadAllSessions hides the account no
  // matter what happens below. The removal must therefore never abort on
  // unreadable metadata JSON: a decode failure falls through with an empty
  // metadata list instead of throwing. Homeservers are collected here and
  // from the marker itself, and the marker is upgraded with the merged list
  // before the metadata is dropped, so a crash anywhere below can still
  // retry the media-cache cleanup once the metadata is gone.
  final removedHomeservers = <String>{..._removedHomeservers(prefs, userId)};
  final raw = prefs.getString(_kSessions);
  final remainingMetadata = <Map<String, dynamic>>[];
  if (raw != null) {
    var metadataDecoded = true;
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      for (final item in list) {
        final metadata = Map<String, dynamic>.from(item as Map);
        if (metadata['user_id'] == userId) {
          final homeserver = metadata['homeserver_url'];
          if (homeserver is String) removedHomeservers.add(homeserver);
        } else {
          remainingMetadata.add(metadata);
        }
      }
    } catch (error) {
      // Corrupt metadata JSON: aborting would strand the removal forever
      // (the marker is already persisted), so treat the metadata as
      // unreadable and keep going with the marker's recorded homeservers.
      metadataDecoded = false;
      debugPrint(
        'Failed to decode session metadata during removal of $userId: $error',
      );
    }
    // Upgrade the marker with the merged homeserver list before dropping
    // the metadata, so a crash (or a failed write) anywhere below still
    // leaves a retryable trail once the metadata is gone.
    await markSessionRemoved(userId, homeservers: removedHomeservers.toList());
    if (metadataDecoded) {
      // A failed write aborts with the metadata intact, so the next retry
      // can still collect homeservers from it; the marker upgrade above
      // has already landed either way.
      final saved = await prefs.setString(
        _kSessions,
        jsonEncode(remainingMetadata),
      );
      if (!saved) {
        throw StateError('本地会话元数据写入失败');
      }
    }
  } else {
    await markSessionRemoved(userId, homeservers: removedHomeservers.toList());
  }

  final activeId = prefs.getString(_kActiveUserId);
  if (activeId == userId) {
    String? nextUserId;
    for (final metadata in remainingMetadata) {
      final candidate = metadata['user_id'];
      if (candidate is String &&
          !prefs.containsKey(_removedSessionKey(candidate))) {
        // Skip accounts whose secure token is gone; loadAllSessions would
        // skip them too, and activating one would strand the app at the
        // login page after the next restart.
        final credentials = await _readSessionCredentials(candidate, -1);
        if (credentials == null || credentials.accessToken.isEmpty) continue;
        nextUserId = candidate;
        break;
      }
    }
    if (nextUserId != null) {
      await prefs.setString(_kActiveUserId, nextUserId);
    } else {
      await prefs.remove(_kActiveUserId);
    }
  }

  await deletePersistedSessionCredentials(userId);
  await clearCachedMessagesForNamespace(userId);
  await prefs.remove(ignoredUsersCacheKey(userId));
  await prefs.remove(pushSettingsKey(userId));
  await const MarkdownSourceStore().clearForUser(userId);
  for (final homeserver in removedHomeservers) {
    await clearAuthenticatedMediaCacheForSession(
      userId: userId,
      homeserver: homeserver,
    );
  }

  final namesMap = await _loadDisplayNames();
  namesMap.remove(userId);
  await prefs.setString(_kSessionDisplayNames, jsonEncode(namesMap));
}

/// Homeservers recorded in an account's removal marker, so media-cache
/// cleanup can be retried after a crash even once the account's metadata
/// is gone from [_kSessions]. Legacy markers (a bare `true` boolean) and
/// malformed markers yield an empty list.
List<String> _removedHomeservers(SharedPreferences prefs, String userId) {
  final value = prefs.get(_removedSessionKey(userId));
  if (value is! String) return const [];
  try {
    final decoded = jsonDecode(value);
    if (decoded is Map<String, dynamic>) {
      final homeservers = decoded['homeservers'];
      if (homeservers is List) {
        return homeservers.whereType<String>().toList();
      }
    }
  } catch (error) {
    debugPrint('Failed to decode removal marker for $userId: $error');
  }
  return const [];
}

/// Persist a tombstone for a session being removed.
///
/// The marker value is JSON so it also records the account's homeservers,
/// which scope the authenticated media cache; a retry reads them back via
/// [_removedHomeservers] once the metadata is gone.
Future<void> markSessionRemoved(
  String userId, {
  List<String> homeservers = const [],
}) async {
  final prefs = await SharedPreferences.getInstance();
  final persisted = await prefs.setString(
    _removedSessionKey(userId),
    jsonEncode({'homeservers': homeservers}),
  );
  if (!persisted) {
    throw StateError('无法持久化账号删除状态');
  }
  await PushSettingsStore().blockDelivery(userId);
}

Future<void> unmarkSessionRemoved(String userId) async {
  final prefs = await SharedPreferences.getInstance();
  final removed = await prefs.remove(_removedSessionKey(userId));
  if (!removed && prefs.containsKey(_removedSessionKey(userId))) {
    throw StateError('无法撤销账号删除状态');
  }
  await PushSettingsStore().resumeDelivery(userId);
}

/// Finish local cleanup for removals interrupted by a previous app exit.
///
/// Removal markers remain as tombstones until the account is explicitly
/// added again, so every startup can retry any cleanup step that failed.
Future<void> completePendingSessionRemovals({required String dataDir}) async {
  final prefs = await SharedPreferences.getInstance();
  final userIds = <String>[];
  for (final key in prefs.getKeys()) {
    if (!key.startsWith(_removedSessionKeyPrefix) || !prefs.containsKey(key)) {
      continue;
    }
    try {
      userIds.add(
        utf8.decode(
          base64Url.decode(key.substring(_removedSessionKeyPrefix.length)),
        ),
      );
    } catch (error) {
      debugPrint('Failed to decode account removal marker $key: $error');
    }
  }

  for (final userId in userIds) {
    var localCleanupSucceeded = false;
    var sdkCleanupSucceeded = false;
    try {
      await removeSession(userId);
      localCleanupSucceeded = true;
    } catch (error) {
      debugPrint('Failed to finish local session cleanup for $userId: $error');
    }
    try {
      await rust.cleanupRemovedAccountStore(userId: userId, dataDir: dataDir);
      sdkCleanupSucceeded = true;
    } catch (error) {
      debugPrint('Failed to finish SDK store cleanup for $userId: $error');
    }
    if (localCleanupSucceeded && sdkCleanupSucceeded) {
      try {
        await unmarkSessionRemoved(userId);
      } catch (error) {
        debugPrint(
          'Failed to finish account removal transaction for $userId: $error',
        );
      }
    }
  }
}

/// Clear all persisted sessions.
Future<void> clearAllSessions() async {
  final prefs = await SharedPreferences.getInstance();
  final sessions = await loadAllSessions();
  for (final session in sessions) {
    await deletePersistedSessionCredentials(session.userId);
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
  for (final key in prefs.getKeys().where(
    (key) => key.startsWith('${ignoredUsersCachePrefix}_'),
  )) {
    await prefs.remove(key);
  }
  // Accounts whose removal is still pending are skipped by loadAllSessions
  // above, so their credentials and caches would survive — and deleting the
  // markers would orphan them permanently (completePendingSessionRemovals
  // would never retry them). Clean them up first, then drop the markers.
  for (final key in prefs.getKeys().where(
    (key) => key.startsWith(_removedSessionKeyPrefix),
  )) {
    try {
      final userId = utf8.decode(
        base64Url.decode(key.substring(_removedSessionKeyPrefix.length)),
      );
      await deletePersistedSessionCredentials(userId);
      await clearCachedMessagesForNamespace(userId);
      await const MarkdownSourceStore().clearForUser(userId);
      for (final homeserver in _removedHomeservers(prefs, userId)) {
        await clearAuthenticatedMediaCacheForSession(
          userId: userId,
          homeserver: homeserver,
        );
      }
    } catch (error) {
      debugPrint('Failed to clean up pending-removed account for $key: $error');
    }
    await prefs.remove(key);
  }
  await clearAllCompatibilitySessionCredentials();
  for (final key in prefs.getKeys().where(
    (key) => key.startsWith('fcm_push_'),
  )) {
    final userId = utf8.decode(
      base64Url.decode(key.substring('fcm_push_'.length)),
    );
    await PushSettingsStore().blockDelivery(userId);
    await prefs.remove(key);
  }
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
  required String searchIndexKey,
}) async {
  await addSession(
    homeserver: homeserver,
    accessToken: accessToken,
    refreshToken: refreshToken,
    userId: userId,
    deviceId: deviceId,
    displayName: displayName,
    searchIndexKey: searchIndexKey,
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
