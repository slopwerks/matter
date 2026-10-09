import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/push_registration_manager.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> googleServices({String packageName = 'moe.aks.matter'}) =>
    {
      'project_info': {'project_number': '12345', 'project_id': 'user-project'},
      'client': [
        {
          'client_info': {
            'mobilesdk_app_id': '1:12345:android:abcdef',
            'android_client_info': {'package_name': packageName},
          },
          'api_key': [
            {'current_key': 'public-client-key'},
          ],
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'imports matching Android client from a multi-client google-services file',
    () {
      final source = googleServices();
      (source['client'] as List).insert(
        0,
        (googleServices(packageName: 'another.package')['client'] as List)
            .single,
      );
      final config = FirebaseClientConfig.fromGoogleServices(
        jsonEncode(source),
      );
      expect(config.projectId, 'user-project');
      expect(config.senderId, '12345');
      expect(config.appId, '1:12345:android:abcdef');
      expect(config.apiKey, 'public-client-key');
    },
  );

  test(
    'rejects wrong package, server credentials, missing keys and mismatched sender',
    () {
      final missingKey = googleServices();
      missingKey['client'][0]['api_key'] = [];
      final wrongSender = googleServices();
      wrongSender['project_info']['project_number'] = '99999';
      for (final source in [
        googleServices(packageName: 'wrong.package'),
        missingKey,
        wrongSender,
        {
          'type': 'service_account',
          'project_id': 'project',
          'private_key': 'never-store-this',
        },
        {},
      ]) {
        expect(
          () => FirebaseClientConfig.fromGoogleServices(jsonEncode(source)),
          throwsFormatException,
        );
      }
      expect(
        () => FirebaseClientConfig.fromGoogleServices('not JSON'),
        throwsFormatException,
      );
    },
  );

  test(
    'unconfigured APK can persist a user project without any build options',
    () async {
      final store = FirebaseClientConfigStore();
      expect(await store.load(), isNull);
      final config = FirebaseClientConfig.fromGoogleServices(
        jsonEncode(googleServices()),
      );
      await store.save(config);
      final restored = await FirebaseClientConfigStore().load();
      expect(restored!.matches(config), isTrue);
      final prefs = await SharedPreferences.getInstance();
      expect(
        jsonDecode(prefs.getString(firebaseClientConfigKey)!),
        config.toJson(),
      );
      expect(restored.options.projectId, 'user-project');
    },
  );

  test(
    'project change disables all FCM accounts and keeps cleanup journal on failure',
    () async {
      final settingsStore = PushSettingsStore();
      for (final userId in ['@alice:example.org', '@bob:example.org']) {
        await settingsStore.save(
          userId,
          const PushSettings(
            enabled: true,
            registrationId: 'old',
            registrations: [
              PushRegistration(token: 'old-token', appId: 'old.app'),
            ],
          ),
        );
      }
      await settingsStore.save(
        '@web:example.org',
        const PushSettings(enabled: true, backend: PushBackend.web),
      );
      var offline = true;
      var saved = false;
      final deleted = <String>[];
      final manager = PushRegistrationManager(
        store: settingsStore,
        getToken: (_) async => throw StateError('must not request tokens'),
        register: (_, _, _) async => throw StateError('must not register'),
        unregister: (userId, _) async {
          if (offline) throw StateError('offline');
          deleted.add(userId);
        },
      );
      await expectLater(
        manager.changeFcmConfiguration(() async {
          saved = true;
        }),
        throwsStateError,
      );
      expect(saved, isFalse);
      for (final userId in ['@alice:example.org', '@bob:example.org']) {
        final settings = await settingsStore.load(userId);
        expect(settings.enabled, isFalse);
        expect(settings.registrationId, isNot('old'));
        expect(settings.registrations, hasLength(1));
      }
      expect((await settingsStore.load('@web:example.org')).enabled, isTrue);
      offline = false;
      await manager.changeFcmConfiguration(() async {
        expect(
          deleted,
          containsAll(['@alice:example.org', '@bob:example.org']),
        );
        saved = true;
      });
      expect(saved, isTrue);
      expect(
        (await settingsStore.load('@alice:example.org')).registrations,
        isEmpty,
      );
      expect(
        (await settingsStore.load('@bob:example.org')).registrations,
        isEmpty,
      );
    },
  );
}
