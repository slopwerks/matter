import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/providers/auth_provider.dart';
import 'package:matter/features/markdown/markdown_source_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getTemporaryDirectory':
            case 'getApplicationSupportDirectory':
              return '/tmp/matter_auth_provider_test';
          }
          return null;
        });
  });

  group('active user id persistence', () {
    test('saveActiveUserId writes the active user key', () async {
      await saveActiveUserId('@alice:example.org');
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_user_id'), '@alice:example.org');
    });

    test('loadActiveUserId reads the persisted value', () async {
      SharedPreferences.setMockInitialValues({
        'active_user_id': '@bob:example.org',
      });
      expect(await loadActiveUserId(), '@bob:example.org');
    });

    test('loadActiveUserId returns null when unset', () async {
      expect(await loadActiveUserId(), isNull);
    });
  });

  group('display name persistence', () {
    test('loadDisplayName returns the stored name', () async {
      SharedPreferences.setMockInitialValues({
        'session_display_names': jsonEncode({'@alice:example.org': 'Alice'}),
      });
      expect(await loadDisplayName('@alice:example.org'), 'Alice');
    });

    test('loadDisplayName falls back to localpart', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await loadDisplayName('@bob:example.org'), 'bob');
    });
  });

  group('session persistence', () {
    test('addSession stores metadata and secure token', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        refreshToken: 'refresh-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      final prefs = await SharedPreferences.getInstance();
      final sessionsRaw = prefs.getString('multi_sessions');
      expect(sessionsRaw, isNotNull);

      final sessions = jsonDecode(sessionsRaw!) as List;
      expect(sessions.length, 1);
      expect(sessions.first['user_id'], '@alice:example.org');
      expect(sessions.first['homeserver_url'], 'https://example.org');
      expect(sessions.first['device_id'], 'DEVICE_A');
      expect(sessions.first.containsKey('access_token'), isFalse);

      expect(prefs.getString('active_user_id'), '@alice:example.org');
      final names = jsonDecode(prefs.getString('session_display_names')!);
      expect(names['@alice:example.org'], 'Alice');

      final secure = FlutterSecureStorage();
      final token = await secure.read(
        key:
            'matrix_access_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(token, 'token-a');
      final refreshToken = await secure.read(
        key:
            'matrix_refresh_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(refreshToken, 'refresh-a');
    });

    test(
      'loadAllSessions restores sessions from metadata and secure storage',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );
        await addSession(
          homeserver: 'https://matrix.org',
          accessToken: 'token-b',
          userId: '@bob:matrix.org',
          deviceId: 'DEVICE_B',
          displayName: 'Bob',
        );

        final sessions = await loadAllSessions();
        expect(sessions.map((s) => s.userId), [
          '@alice:example.org',
          '@bob:matrix.org',
        ]);
        expect(sessions.map((s) => s.accessToken), ['token-a', 'token-b']);
      },
    );

    test(
      'loadAllSessions restores refresh tokens from secure storage',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          refreshToken: 'refresh-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );

        final sessions = await loadAllSessions();
        expect(sessions.single.refreshToken, 'refresh-a');
      },
    );

    test('persistSessionTokens replaces rotated tokens', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        refreshToken: 'refresh-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      await persistSessionTokens(
        userId: '@alice:example.org',
        accessToken: 'token-b',
        refreshToken: 'refresh-b',
      );

      final sessions = await loadAllSessions();
      expect(sessions.single.accessToken, 'token-b');
      expect(sessions.single.refreshToken, 'refresh-b');
    });

    test('loadAllSessions skips sessions with missing tokens', () async {
      SharedPreferences.setMockInitialValues({
        'multi_sessions': jsonEncode([
          {
            'homeserver_url': 'https://example.org',
            'user_id': '@alice:example.org',
            'device_id': 'DEVICE_A',
          },
        ]),
      });

      final sessions = await loadAllSessions();
      expect(sessions, isEmpty);
    });

    test(
      'loadAllSessions keeps valid sessions after a malformed entry',
      () async {
        await addSession(
          homeserver: 'https://example.org',
          accessToken: 'token-a',
          userId: '@alice:example.org',
          deviceId: 'DEVICE_A',
          displayName: 'Alice',
        );
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(
          'multi_sessions',
          jsonEncode([
            {'user_id': 42},
            {
              'homeserver_url': 'https://example.org',
              'user_id': '@alice:example.org',
              'device_id': 'DEVICE_A',
            },
          ]),
        );

        final sessions = await loadAllSessions();
        expect(sessions.single.userId, '@alice:example.org');
      },
    );

    test('removeSession deletes metadata, token and display name', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );

      await removeSession('@alice:example.org');

      final sessions = await loadAllSessions();
      expect(sessions, isEmpty);

      final prefs = await SharedPreferences.getInstance();
      final names = jsonDecode(prefs.getString('session_display_names')!);
      expect(names.containsKey('@alice:example.org'), isFalse);

      final secure = FlutterSecureStorage();
      final token = await secure.read(
        key:
            'matrix_access_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(token, isNull);
      final refreshToken = await secure.read(
        key:
            'matrix_refresh_token_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      );
      expect(refreshToken, isNull);
    });

    test('removeSession switches active user when another exists', () async {
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await addSession(
        homeserver: 'https://matrix.org',
        accessToken: 'token-b',
        userId: '@bob:matrix.org',
        deviceId: 'DEVICE_B',
        displayName: 'Bob',
      );

      await removeSession('@alice:example.org');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_user_id'), '@bob:matrix.org');
    });

    test('removeSession clears that account markdown source cache', () async {
      const store = MarkdownSourceStore();
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await addSession(
        homeserver: 'https://matrix.org',
        accessToken: 'token-b',
        userId: '@bob:matrix.org',
        deviceId: 'DEVICE_B',
        displayName: 'Bob',
      );
      for (final userId in ['@alice:example.org', '@bob:matrix.org']) {
        await store.save(
          userId: userId,
          roomId: '!room:example.org',
          eventId: r'$event',
          source: '**$userId**',
          body: userId,
          formattedBody: null,
          persist: true,
        );
      }

      await removeSession('@alice:example.org');

      expect(
        await store.load(
          userId: '@alice:example.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: '@alice:example.org',
          formattedBody: null,
          allowPersistence: true,
        ),
        isNull,
      );
      expect(
        await store.load(
          userId: '@bob:matrix.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: '@bob:matrix.org',
          formattedBody: null,
          allowPersistence: true,
        ),
        '**@bob:matrix.org**',
      );
    });

    test('clearAllSessions wipes everything', () async {
      const store = MarkdownSourceStore();
      await addSession(
        homeserver: 'https://example.org',
        accessToken: 'token-a',
        userId: '@alice:example.org',
        deviceId: 'DEVICE_A',
        displayName: 'Alice',
      );
      await store.save(
        userId: '@alice:example.org',
        roomId: '!room:example.org',
        eventId: r'$event',
        source: '**hello**',
        body: 'hello',
        formattedBody: null,
        persist: true,
      );

      await clearAllSessions();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('multi_sessions'), isNull);
      expect(prefs.getString('session_display_names'), isNull);
      expect(prefs.getString('active_user_id'), isNull);

      final secure = FlutterSecureStorage();
      final all = await secure.readAll();
      expect(all, isEmpty);
      expect(
        await store.load(
          userId: '@alice:example.org',
          roomId: '!room:example.org',
          eventId: r'$event',
          body: 'hello',
          formattedBody: null,
          allowPersistence: true,
        ),
        isNull,
      );
    });

    test('migrateLegacySession converts old keys to multi-session', () async {
      SharedPreferences.setMockInitialValues({
        'session_homeserver': 'https://legacy.org',
        'session_access_token': 'legacy-token',
        'session_user_id': '@legacy:example.org',
        'session_device_id': 'LEGACY',
        'session_display_name': 'Legacy User',
      });

      final migrated = await migrateLegacySession();
      expect(migrated, isTrue);

      final sessions = await loadAllSessions();
      expect(sessions.single.userId, '@legacy:example.org');
      expect(sessions.single.accessToken, 'legacy-token');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('session_homeserver'), isNull);
      expect(prefs.getString('session_access_token'), isNull);
    });

    test('migrateLegacySession returns false when keys are missing', () async {
      SharedPreferences.setMockInitialValues({});
      final migrated = await migrateLegacySession();
      expect(migrated, isFalse);
    });
  });
}
