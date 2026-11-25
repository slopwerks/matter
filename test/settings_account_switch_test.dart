import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/pages/settings/settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRustApi implements RustLibApi {
  String activeUserId = '@alice:example.org';
  final switchCalls = <String>[];
  final removedAccounts = <String>[];
  final startSyncAccounts = <String>[];
  Completer<void>? switchBarrier;
  Completer<void>? switchStarted;
  Completer<void>? removeBarrier;
  Completer<void>? removeStarted;
  Completer<void>? logoutBarrier;
  Completer<void>? logoutStarted;
  bool failNextBobAccessToken = false;
  bool failNextBobStartSync = false;
  bool failNextAliceSwitch = false;
  bool failLogout = false;
  String? cleanupError;
  bool remoteLogoutPending = false;
  Object? listAccountsError;

  @override
  Future<bool> crateApiMatrixSwitchAccount({required String userId}) async {
    switchCalls.add(userId);
    if (switchStarted case final started? when !started.isCompleted) {
      started.complete();
    }
    await switchBarrier?.future;
    if (userId == '@alice:example.org' && failNextAliceSwitch) {
      failNextAliceSwitch = false;
      return false;
    }
    activeUserId = userId;
    return true;
  }

  @override
  Future<String?> crateApiMatrixGetAccessToken() async {
    if (activeUserId == '@bob:example.org' && failNextBobAccessToken) {
      failNextBobAccessToken = false;
      throw StateError('target token unavailable');
    }
    return 'token-$activeUserId';
  }

  @override
  Future<rust.SessionTokenUpdate?> crateApiMatrixGetSessionTokens({
    required String accountUserId,
  }) async => rust.SessionTokenUpdate(
    userId: accountUserId,
    accessToken: 'token-$accountUserId',
  );

  @override
  Future<String?> crateApiMatrixGetRefreshToken() async => null;

  @override
  Future<void> crateApiMatrixSyncOnce() async {}

  @override
  Future<void> crateApiMatrixStartSync() async {
    startSyncAccounts.add(activeUserId);
    if (activeUserId == '@bob:example.org' && failNextBobStartSync) {
      failNextBobStartSync = false;
      throw StateError('target sync unavailable');
    }
  }

  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async {
    if (listAccountsError case final error?) throw error;
    return [
      if (!removedAccounts.contains('@alice:example.org'))
        const rust.AccountInfo(
          userId: '@alice:example.org',
          deviceId: 'ALICE',
          homeserverUrl: 'https://alice.example.org',
        ),
      if (!removedAccounts.contains('@bob:example.org'))
        const rust.AccountInfo(
          userId: '@bob:example.org',
          deviceId: 'BOB',
          homeserverUrl: 'https://bob.example.org',
        ),
    ];
  }

  @override
  Future<rust.AccountRemovalResult> crateApiMatrixRemoveAccount({
    required String userId,
  }) async {
    removeStarted?.complete();
    await removeBarrier?.future;
    removedAccounts.add(userId);
    return rust.AccountRemovalResult(
      cleanupError: cleanupError,
      remoteLogoutPending: remoteLogoutPending,
    );
  }

  @override
  Future<rust.AccountRemovalResult> crateApiMatrixLogout() async {
    logoutStarted?.complete();
    await logoutBarrier?.future;
    if (failLogout) throw StateError('logout failed after sync stopped');
    removedAccounts.add(activeUserId);
    return rust.AccountRemovalResult(
      cleanupError: cleanupError,
      remoteLogoutPending: remoteLogoutPending,
    );
  }

  @override
  Future<rust.UserProfile> crateApiMatrixGetProfile() async =>
      rust.UserProfile(userId: activeUserId, displayName: activeUserId);

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const pathProviderChannel = MethodChannel('plugins.flutter.io/path_provider');
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathProviderChannel, (call) async {
          switch (call.method) {
            case 'getTemporaryDirectory':
            case 'getApplicationSupportDirectory':
              return '/tmp/matter_settings_account_switch_test';
          }
          return null;
        });
    rustApi.activeUserId = '@alice:example.org';
    rustApi.switchCalls.clear();
    rustApi.removedAccounts.clear();
    rustApi.startSyncAccounts.clear();
    rustApi.switchBarrier = null;
    rustApi.switchStarted = null;
    rustApi.removeBarrier = null;
    rustApi.removeStarted = null;
    rustApi.logoutBarrier = null;
    rustApi.logoutStarted = null;
    rustApi.failNextBobAccessToken = false;
    rustApi.failNextBobStartSync = false;
    rustApi.failNextAliceSwitch = false;
    rustApi.failLogout = false;
    rustApi.cleanupError = null;
    rustApi.remoteLogoutPending = false;
    rustApi.listAccountsError = null;

    await addSession(
      homeserver: 'https://alice.example.org',
      accessToken: 'alice-token',
      userId: '@alice:example.org',
      deviceId: 'ALICE',
      displayName: 'Alice',
    );
    await addSession(
      homeserver: 'https://bob.example.org',
      accessToken: 'bob-token',
      userId: '@bob:example.org',
      deviceId: 'BOB',
      displayName: 'Bob',
    );
    await saveActiveUserId('@alice:example.org');
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer();
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(sessionReadyProvider.notifier).value = true;
    return container;
  }

  test(
    'a failed target activation rolls back and restarts the old sync',
    () async {
      final container = createContainer();
      addTearDown(container.dispose);
      rustApi.failNextBobAccessToken = true;

      await expectLater(
        container
            .read(accountSwitchControllerProvider)
            .switchTo('@bob:example.org'),
        throwsA(isA<StateError>()),
      );

      expect(rustApi.switchCalls, ['@bob:example.org', '@alice:example.org']);
      expect(container.read(activeUserIdProvider), '@alice:example.org');
      expect(container.read(sessionReadyProvider), isTrue);
      expect(rustApi.startSyncAccounts, ['@alice:example.org']);
      expect(await loadActiveUserId(), '@alice:example.org');
    },
  );

  test('concurrent account switches run in request order', () async {
    await addSession(
      homeserver: 'https://carol.example.org',
      accessToken: 'carol-token',
      userId: '@carol:example.org',
      deviceId: 'CAROL',
      displayName: 'Carol',
    );
    final container = createContainer();
    addTearDown(container.dispose);
    final controller = container.read(accountSwitchControllerProvider);
    rustApi.switchBarrier = Completer<void>();
    rustApi.switchStarted = Completer<void>();

    final first = controller.switchTo('@bob:example.org');
    await rustApi.switchStarted!.future;
    final second = controller.switchTo('@carol:example.org');
    await Future<void>.delayed(Duration.zero);

    expect(rustApi.switchCalls, ['@bob:example.org']);
    rustApi.switchBarrier!.complete();
    await Future.wait([first, second]);

    expect(rustApi.switchCalls, ['@bob:example.org', '@carol:example.org']);
    expect(container.read(activeUserIdProvider), '@carol:example.org');
    expect(rustApi.activeUserId, '@carol:example.org');
  });

  test('a replacement sync failure keeps the old account', () async {
    final container = createContainer();
    addTearDown(container.dispose);
    rustApi.failNextBobStartSync = true;

    await expectLater(
      container
          .read(accountSwitchControllerProvider)
          .removeAccount('@alice:example.org'),
      throwsA(isA<StateError>()),
    );

    expect(rustApi.removedAccounts, isEmpty);
    expect(rustApi.switchCalls, ['@bob:example.org', '@alice:example.org']);
    expect(rustApi.startSyncAccounts, [
      '@bob:example.org',
      '@alice:example.org',
    ]);
    expect(container.read(activeUserIdProvider), '@alice:example.org');
    expect((await loadAllSessions()).map((session) => session.userId), [
      '@alice:example.org',
      '@bob:example.org',
    ]);
  });

  test('a failed rollback clears the mismatched active session', () async {
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(isLoggedInProvider.notifier).value = true;
    container.read(currentUserProvider.notifier).value = const CurrentUser(
      id: '@alice:example.org',
      displayName: 'Alice',
      homeserver: 'https://alice.example.org',
    );
    container.read(currentAccessTokenProvider.notifier).value = 'alice-token';
    rustApi.failNextBobAccessToken = true;
    rustApi.failNextAliceSwitch = true;

    await expectLater(
      container
          .read(accountSwitchControllerProvider)
          .switchTo('@bob:example.org'),
      throwsA(isA<StateError>()),
    );

    expect(rustApi.activeUserId, '@bob:example.org');
    expect(container.read(activeUserIdProvider), isNull);
    expect(container.read(currentUserProvider), isNull);
    expect(container.read(currentAccessTokenProvider), isNull);
    expect(container.read(isLoggedInProvider), isFalse);
    expect(container.read(sessionReadyProvider), isTrue);
    expect(await loadActiveUserId(), '@alice:example.org');
  });

  test('last-account removal clears session state through the controller', () async {
    await removeSession('@bob:example.org');
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(isLoggedInProvider.notifier).value = true;
    container.read(currentUserProvider.notifier).value = const CurrentUser(
      id: '@alice:example.org',
      displayName: 'Alice',
      homeserver: 'https://alice.example.org',
    );
    rustApi.logoutBarrier = Completer<void>();
    rustApi.logoutStarted = Completer<void>();

    final removalFuture = container
        .read(accountSwitchControllerProvider)
        .removeAccount('@alice:example.org');
    await rustApi.logoutStarted!.future;
    expect(container.read(sessionReadyProvider), isFalse);
    rustApi.logoutBarrier!.complete();
    await removalFuture;

    expect(container.read(isLoggedInProvider), isFalse);
    expect(container.read(currentUserProvider), isNull);
    expect(container.read(activeUserIdProvider), isNull);
    expect(container.read(sessionReadyProvider), isTrue);
    expect(await loadAllSessions(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey(
        'matrix_session_removed_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      ),
      isFalse,
    );
  });

  test('store cleanup warning still commits last-account removal', () async {
    await removeSession('@bob:example.org');
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(isLoggedInProvider.notifier).value = true;
    rustApi.cleanupError = 'store is still busy';

    final warning = await container
        .read(accountSwitchControllerProvider)
        .removeAccount('@alice:example.org');

    expect(warning, 'store is still busy');
    expect(rustApi.startSyncAccounts, isEmpty);
    expect(container.read(activeUserIdProvider), isNull);
    expect(container.read(isLoggedInProvider), isFalse);
    expect(await loadAllSessions(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey(
        'matrix_session_removed_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      ),
      isTrue,
    );
  });

  test('remote logout warning still commits local account removal', () async {
    await removeSession('@bob:example.org');
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(isLoggedInProvider.notifier).value = true;
    rustApi.remoteLogoutPending = true;

    final warning = await container
        .read(accountSwitchControllerProvider)
        .removeAccount('@alice:example.org');

    expect(warning, contains('服务器上的登录设备可能仍然有效'));
    expect(await loadAllSessions(), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.containsKey(
        'matrix_session_removed_${base64Url.encode(utf8.encode('@alice:example.org'))}',
      ),
      isFalse,
    );
  });

  test(
    'local cleanup failure still removes an invalid account from state',
    () async {
      final container = ProviderContainer(
        overrides: [
          accountSessionRemoverProvider.overrideWithValue(
            (_) async => throw StateError('secure storage unavailable'),
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(sessionsProvider.notifier).value = await loadAllSessions();

      final warning = await container
          .read(accountSwitchControllerProvider)
          .removeAccount('@bob:example.org');

      expect(rustApi.removedAccounts, ['@bob:example.org']);
      expect(warning, contains('本地会话清理失败'));
      expect(
        container.read(sessionsProvider).map((session) => session.userId),
        ['@alice:example.org'],
      );
      expect((await loadAllSessions()).map((session) => session.userId), [
        '@alice:example.org',
      ]);
      final prefs = await SharedPreferences.getInstance();
      expect(
        (jsonDecode(prefs.getString('multi_sessions')!) as List).map(
          (session) => session['user_id'],
        ),
        ['@alice:example.org', '@bob:example.org'],
      );
    },
  );

  test('account removal clears only that account composer state', () async {
    const aliceKey = (
      roomId: '!shared:example.org',
      userId: '@alice:example.org',
    );
    const bobKey = (roomId: '!shared:example.org', userId: '@bob:example.org');
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(messageDraftProvider(aliceKey).notifier).value =
        'alice draft';
    container.read(editingDraftProvider(aliceKey).notifier).value = (
      editingId: r'$alice-edit',
      text: 'alice edit',
    );
    container.read(messageDraftProvider(bobKey).notifier).value = 'bob draft';
    container.read(editingDraftProvider(bobKey).notifier).value = (
      editingId: r'$bob-edit',
      text: 'bob edit',
    );
    container.read(editingSendInFlightProvider(bobKey).notifier).value =
        r'$bob-edit';

    await container
        .read(accountSwitchControllerProvider)
        .removeAccount('@bob:example.org');

    expect(container.read(messageDraftProvider(bobKey)), '');
    expect(container.read(editingDraftProvider(bobKey)), isNull);
    expect(container.read(editingSendInFlightProvider(bobKey)), isNull);
    expect(container.read(messageDraftProvider(aliceKey)), 'alice draft');
    expect(container.read(editingDraftProvider(aliceKey))?.text, 'alice edit');
  });

  test('ordinary account switches preserve composer state', () async {
    const aliceKey = (
      roomId: '!shared:example.org',
      userId: '@alice:example.org',
    );
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(messageDraftProvider(aliceKey).notifier).value =
        'alice draft';
    container.read(editingDraftProvider(aliceKey).notifier).value = (
      editingId: r'$alice-edit',
      text: 'alice edit',
    );

    await container
        .read(accountSwitchControllerProvider)
        .switchTo('@bob:example.org');

    expect(container.read(messageDraftProvider(aliceKey)), 'alice draft');
    expect(container.read(editingDraftProvider(aliceKey))?.text, 'alice edit');
  });

  test('a failed last-account logout restarts the old sync', () async {
    await removeSession('@bob:example.org');
    final container = createContainer();
    addTearDown(container.dispose);
    container.read(isLoggedInProvider.notifier).value = true;
    rustApi.failLogout = true;

    await expectLater(
      container
          .read(accountSwitchControllerProvider)
          .removeAccount('@alice:example.org'),
      throwsA(isA<StateError>()),
    );

    expect(rustApi.startSyncAccounts, ['@alice:example.org']);
    expect(container.read(activeUserIdProvider), '@alice:example.org');
    expect(container.read(isLoggedInProvider), isTrue);
    expect(container.read(sessionReadyProvider), isTrue);
    expect((await loadAllSessions()).map((session) => session.userId), [
      '@alice:example.org',
    ]);
  });
}
