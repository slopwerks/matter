import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/push_build_config.dart';
import 'package:matter/features/push/push_registration_manager.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

const alice = '@alice:example.org';
const bob = '@bob:example.org';
const gateway = 'https://push.example.org/_matrix/push/v1/notify';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late PushRegistrationManager manager;
  late PushSettingsStore store;
  late List<String> calls;
  late Map<String, bool> deliveryEnabled;
  late String token;
  bool failRegister = false;
  bool failUnregister = false;
  Completer<void>? registerBarrier;
  Completer<void>? registerStarted;
  var tokenRequests = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    store = PushSettingsStore();
    calls = [];
    deliveryEnabled = {};
    token = 'token-1';
    failRegister = false;
    failUnregister = false;
    registerBarrier = null;
    registerStarted = null;
    tokenRequests = 0;
    manager = PushRegistrationManager(
      store: store,
      updateDeliveryState: (userId, settings) async {
        deliveryEnabled[userId] = settings.enabled;
      },
      getToken: (_) async {
        tokenRequests++;
        return token;
      },
      register: (userId, settings, token) async {
        calls.add('register:$userId:${settings.appId}:$token');
        registerStarted?.complete();
        await registerBarrier?.future;
        if (failRegister) throw StateError('offline');
      },
      unregister: (userId, registration) async {
        calls.add('delete:$userId:${registration.appId}:${registration.token}');
        if (failUnregister) throw StateError('offline');
      },
    );
  });

  Future<void> enable(
    String userId, {
    String appId = 'moe.aks.matter',
    String url = gateway,
  }) => manager.configure(userId, enabled: true, gatewayUrl: url, appId: appId);
  Future<void> disable(String userId) => manager.configure(
    userId,
    enabled: false,
    gatewayUrl: gateway,
    appId: 'moe.aks.matter',
  );

  test(
    'web registration validates VAPID and uses account-specific subscription settings',
    () async {
      final vapid = base64Url.encode([4, ...List.filled(64, 1)]);
      await expectLater(
        manager.configure(
          alice,
          enabled: true,
          gatewayUrl: gateway,
          appId: 'matter.web',
          backend: PushBackend.web,
          vapidPublicKey: 'invalid',
        ),
        throwsArgumentError,
      );
      expect(tokenRequests, 0);
      await manager.configure(
        alice,
        enabled: true,
        gatewayUrl: gateway,
        appId: 'matter.web',
        backend: PushBackend.web,
        vapidPublicKey: vapid,
      );
      final settings = await store.load(alice);
      expect(settings.backend, PushBackend.web);
      expect(settings.vapidPublicKey, vapid);
      expect(calls.single, 'register:$alice:matter.web:token-1');
      final legacy = settings.toJson()
        ..remove('backend')
        ..remove('vapid_public_key');
      expect(PushSettings.fromJson(legacy).backend, PushBackend.android);
    },
  );

  test(
    'project change waits for in-flight registration before deleting its pusher',
    () async {
      registerStarted = Completer<void>();
      registerBarrier = Completer<void>();
      final enabling = enable(alice);
      await registerStarted!.future;
      var saved = false;
      final changing = manager.changeFcmConfiguration(() async {
        saved = true;
      });
      registerBarrier!.complete();
      await Future.wait([enabling, changing]);
      expect(calls, [
        'register:$alice:moe.aks.matter:token-1',
        'delete:$alice:moe.aks.matter:token-1',
      ]);
      expect(saved, isTrue);
      expect((await store.load(alice)).enabled, isFalse);
      expect((await store.load(alice)).registrations, isEmpty);
      expect(tokenRequests, 1);
    },
  );

  test('default is disabled and has no gateway or token acquisition', () async {
    final settings = await store.load(alice);
    expect(settings.enabled, isFalse);
    expect(settings.gatewayUrl, PushBuildConfig.gatewayUrl);
    await manager.refresh([alice, bob]);
    expect(calls, isEmpty);
    expect(tokenRequests, 0);
  });

  test(
    'a saved blank gateway does not permanently shadow the build prefill',
    () async {
      // Reproduces an install that persisted empty fields (for example by
      // importing google-services.json while the form was still blank) before
      // being rebuilt with prefill values.
      await store.save(
        alice,
        const PushSettings(enabled: false, registrationId: 'id'),
      );
      final settings = await store.load(alice);
      expect(settings.gatewayUrl, PushBuildConfig.gatewayUrl);
      expect(settings.appId, PushBuildConfig.androidAppId);
      expect(settings.vapidPublicKey, PushBuildConfig.vapidPublicKey);
      await expectLater(enable(alice), completes);
      expect((await store.load(alice)).gatewayUrl, gateway);
    },
  );

  test(
    'an explicitly saved gateway still wins over the build prefill',
    () async {
      await enable(
        alice,
        url: 'https://explicit.example.org/_matrix/push/v1/notify',
      );
      expect(
        (await store.load(alice)).gatewayUrl,
        'https://explicit.example.org/_matrix/push/v1/notify',
      );
    },
  );

  test(
    'rejects invalid configuration before requesting a token or saving',
    () async {
      await expectLater(
        enable(alice, url: 'http://push.example.org/_matrix/push/v1/notify'),
        throwsArgumentError,
      );
      await expectLater(enable(alice, appId: 'bad id'), throwsArgumentError);
      expect((await store.load(alice)).enabled, isFalse);
      expect(tokenRequests, 0);
      expect(calls, isEmpty);
    },
  );

  test(
    'registers both accounts with the same token and keeps separate settings',
    () async {
      await enable(alice);
      await enable(bob, appId: 'other.app');
      expect(calls, [
        'register:$alice:moe.aks.matter:token-1',
        'register:$bob:other.app:token-1',
      ]);
      expect((await store.load(alice)).appId, 'moe.aks.matter');
      expect((await store.load(bob)).appId, 'other.app');
      expect(
        (await store.load(alice)).registrationId,
        isNot((await store.load(bob)).registrationId),
      );
    },
  );

  test(
    'token rotation registers new token before deleting the old one',
    () async {
      await enable(alice);
      calls.clear();
      token = 'token-2';
      await manager.refresh([alice]);
      expect(calls, [
        'register:$alice:moe.aks.matter:token-2',
        'delete:$alice:moe.aks.matter:token-1',
      ]);
      expect((await store.load(alice)).registrations.single.token, 'token-2');
    },
  );

  test(
    'failed rotation keeps both possible registrations for offline disabling',
    () async {
      await enable(alice);
      token = 'token-2';
      failRegister = true;
      await expectLater(manager.refresh([alice]), throwsStateError);
      expect(
        (await store.load(alice)).registrations.map((value) => value.token),
        ['token-1', 'token-2'],
      );
      calls.clear();
      await disable(alice);
      expect(calls, [
        'delete:$alice:moe.aks.matter:token-1',
        'delete:$alice:moe.aks.matter:token-2',
      ]);
      expect((await store.load(alice)).registrations, isEmpty);
    },
  );

  test(
    'offline disabling rejects delivery immediately and retries deletion',
    () async {
      await enable(alice);
      final previous = await store.load(alice);
      failUnregister = true;
      await expectLater(disable(alice), throwsStateError);
      final settings = await store.load(alice);
      expect(settings.enabled, isFalse);
      expect(deliveryEnabled[alice], isFalse);
      expect(settings.registrations, hasLength(1));
      final target = PushTarget(
        userId: alice,
        roomId: '!room:example.org',
        eventId: r'$event',
        registrationId: previous.registrationId,
      );
      expect(target.acceptedBy(settings), isFalse);
      failUnregister = false;
      tokenRequests = 0;
      await manager.refresh([alice]);
      expect((await store.load(alice)).registrations, isEmpty);
      expect(tokenRequests, 0);
    },
  );

  test(
    'gateway update with same identifiers updates instead of deleting new registration',
    () async {
      await enable(alice);
      final previous = await store.load(alice);
      calls.clear();
      await enable(
        alice,
        url: 'https://new.example.org/_matrix/push/v1/notify',
      );
      expect(calls, ['register:$alice:moe.aks.matter:token-1']);
      final settings = await store.load(alice);
      expect(
        settings.gatewayUrl,
        'https://new.example.org/_matrix/push/v1/notify',
      );
      expect(settings.registrationId, isNot(previous.registrationId));
      expect(settings.registrations, hasLength(1));
    },
  );

  test(
    'changing application ID deletes the previous application registration',
    () async {
      await enable(alice);
      calls.clear();
      await enable(alice, appId: 'new.app');
      expect(calls, [
        'register:$alice:new.app:token-1',
        'delete:$alice:moe.aks.matter:token-1',
      ]);
      expect((await store.load(alice)).registrations.single.appId, 'new.app');
    },
  );

  test('disabling waits for an in-flight registration and wins', () async {
    registerStarted = Completer<void>();
    registerBarrier = Completer<void>();
    final enabling = enable(alice);
    await registerStarted!.future;
    final disabling = disable(alice);
    registerBarrier!.complete();
    await Future.wait([enabling, disabling]);
    expect(calls, [
      'register:$alice:moe.aks.matter:token-1',
      'delete:$alice:moe.aks.matter:token-1',
    ]);
    expect((await store.load(alice)).enabled, isFalse);
    expect((await store.load(alice)).registrations, isEmpty);
  });

  test(
    'removal drains registrations and prevents refresh from resurrecting them',
    () async {
      await enable(alice);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'matrix_session_removed_${base64Url.encode(utf8.encode(alice))}',
        '{}',
      );
      calls.clear();
      await manager.prepareAccountRemoval(alice);
      await manager.refresh([alice]);
      expect(calls, ['delete:$alice:moe.aks.matter:token-1']);
      expect((await store.load(alice)).enabled, isTrue);
      expect(deliveryEnabled[alice], isFalse);
      expect((await store.load(alice)).registrations, isEmpty);
      await expectLater(enable(alice), throwsStateError);
    },
  );

  test('an account failure does not prevent another account cleanup', () async {
    await enable(alice);
    await enable(bob);
    failUnregister = true;
    await expectLater(disable(bob), throwsStateError);
    failUnregister = false;
    calls.clear();
    token = 'token-2';
    failRegister = true;
    await expectLater(manager.refresh([alice, bob]), throwsStateError);
    expect(calls, [
      'register:$alice:moe.aks.matter:token-2',
      'delete:$bob:moe.aks.matter:token-1',
    ]);
    expect((await store.load(bob)).enabled, isFalse);
    expect((await store.load(bob)).registrations, isEmpty);
  });

  test(
    'notifications route by account and reject stale configurations and count-only pushes',
    () {
      final target = PushTarget.fromData({
        'user_id': alice,
        'room_id': '!room:example.org',
        'event_id': r'$event',
        'registration_id': 'current',
      })!;
      expect(target.userId, alice);
      expect(PushTarget.fromData(target.toData())?.eventId, r'$event');
      expect(
        target.acceptedBy(
          const PushSettings(enabled: true, registrationId: 'current'),
        ),
        isTrue,
      );
      expect(
        target.acceptedBy(
          const PushSettings(enabled: true, registrationId: 'old'),
        ),
        isFalse,
      );
      expect(PushTarget.fromData({'unread': '0'}), isNull);
      expect(
        PushTarget.fromData({...target.toData(), 'room_id': null}),
        isNull,
      );
      final otherAccount = PushTarget(
        userId: bob,
        roomId: target.roomId,
        eventId: target.eventId,
        registrationId: target.registrationId,
      );
      expect(pushNotificationId(target), pushNotificationId(target));
      expect(
        pushNotificationId(target),
        isNot(pushNotificationId(otherAccount)),
      );
    },
  );

  test(
    'background delivery checks saved membership and removal markers',
    () async {
      await enable(alice);
      final settings = await store.load(alice);
      final target = PushTarget(
        userId: alice,
        roomId: '!room:example.org',
        eventId: r'$event',
        registrationId: settings.registrationId,
      );
      expect(await acceptsPushTarget(target), isFalse);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'multi_sessions',
        jsonEncode([
          {'user_id': alice},
        ]),
      );
      expect(await acceptsPushTarget(target), isTrue);
      await prefs.setString(
        'matrix_session_removed_${base64Url.encode(utf8.encode(alice))}',
        '{}',
      );
      expect(await acceptsPushTarget(target), isFalse);
    },
  );
}
