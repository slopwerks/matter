import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/pages/chat/message_input.dart' show messageDraftProvider;
import 'package:matter/pages/login/login_page.dart';
import 'package:matter/pages/settings/settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

const _alice = '@alice:example.org';
const _bob = '@bob:example.org';
const _aliceIndexKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';

class _FakeRustApi implements RustLibApi {
  final accounts = <String, rust.StoredSession>{};
  String activeUserId = _alice;
  String pendingHomeserver = '';
  bool rejectPassword = false;
  bool duplicateAccount = false;
  bool failNextBobAccessToken = false;
  Completer<void>? loginBarrier;
  void Function()? onLogout;
  Completer<void> syncStarted = Completer<void>();
  int createCalls = 0;
  int cancelCalls = 0;
  int passwordCalls = 0;
  final authMethods = <String>[];
  final logoutAccounts = <String>[];
  final switchAccounts = <String>[];
  final syncAccounts = <String>[];

  Future<rust.AuthResult> _authenticate(String method) async {
    authMethods.add(method);
    await loginBarrier?.future;
    if (duplicateAccount) {
      throw StateError('This account is already signed in.');
    }
    if (rejectPassword) {
      return const rust.AuthResult(
        success: false,
        needsUiaa: false,
        error: 'Invalid password',
      );
    }
    accounts[_bob] = rust.StoredSession(
      homeserverUrl: pendingHomeserver,
      accessToken: 'bob-token',
      refreshToken: 'bob-refresh',
      userId: _bob,
      deviceId: 'BOB_DEVICE',
    );
    activeUserId = _bob;
    return const rust.AuthResult(success: true, needsUiaa: false, userId: _bob);
  }

  @override
  Future<void> crateApiMatrixCreateClient({
    required String homeserverUrl,
    required String dataDir,
    required String searchIndexKey,
    required bool useInMemorySearchIndex,
  }) async {
    createCalls++;
    pendingHomeserver = homeserverUrl;
  }

  @override
  Future<void> crateApiMatrixCancelPendingLogin() async {
    cancelCalls++;
  }

  @override
  Future<rust.AuthResult> crateApiMatrixLoginWithPassword({
    required String username,
    required String password,
  }) {
    passwordCalls++;
    return _authenticate('password');
  }

  @override
  Future<rust.AuthResult> crateApiMatrixLoginWithToken({
    required String accessToken,
    required String userId,
    required String deviceId,
    String? refreshToken,
  }) => _authenticate('token');

  @override
  Future<rust.AuthResult> crateApiMatrixRegisterGetUiaaSession({
    required String username,
    required String password,
  }) => _authenticate('register');

  @override
  Future<rust.StoredSession?> crateApiMatrixGetSession() async =>
      accounts[activeUserId];

  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [
    for (final session in accounts.values)
      rust.AccountInfo(
        userId: session.userId,
        deviceId: session.deviceId,
        homeserverUrl: session.homeserverUrl,
      ),
  ];

  @override
  Future<String?> crateApiMatrixGetAccessToken() async {
    if (activeUserId == _bob && failNextBobAccessToken) {
      failNextBobAccessToken = false;
      throw StateError('new account activation failed');
    }
    return accounts[activeUserId]?.accessToken;
  }

  @override
  Future<rust.SessionTokenUpdate?> crateApiMatrixGetSessionTokens({
    required String accountUserId,
  }) async {
    final session = accounts[accountUserId];
    return session == null
        ? null
        : rust.SessionTokenUpdate(
            userId: session.userId,
            accessToken: session.accessToken,
            refreshToken: session.refreshToken,
          );
  }

  @override
  Future<rust.UserProfile> crateApiMatrixGetProfile() async => rust.UserProfile(
    userId: activeUserId,
    displayName: activeUserId == _alice ? 'Alice' : 'Bob',
  );

  @override
  Future<bool> crateApiMatrixSwitchAccount({required String userId}) async {
    switchAccounts.add(userId);
    if (!accounts.containsKey(userId)) return false;
    activeUserId = userId;
    return true;
  }

  @override
  Future<rust.AccountRemovalResult> crateApiMatrixLogout() async {
    logoutAccounts.add(activeUserId);
    onLogout?.call();
    accounts.remove(activeUserId);
    activeUserId = _alice;
    return const rust.AccountRemovalResult(remoteLogoutPending: false);
  }

  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() =>
      rust.ConnectionStatus.connected;

  @override
  Future<void> crateApiMatrixSyncOnce() async {}

  @override
  Future<void> crateApiMatrixStartSync() async {
    syncAccounts.add(activeUserId);
    if (!syncStarted.isCompleted) syncStarted.complete();
  }

  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

void main() {
  late _FakeRustApi api;
  late ProviderContainer container;
  const channel = MethodChannel('plugins.flutter.io/path_provider');

  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => '/tmp/matter-add-account-tests',
        );
    api.accounts.clear();
    api.accounts[_alice] = const rust.StoredSession(
      homeserverUrl: 'https://example.org',
      accessToken: 'alice-token',
      userId: _alice,
      deviceId: 'ALICE_DEVICE',
    );
    api.activeUserId = _alice;
    api.pendingHomeserver = '';
    api.rejectPassword = false;
    api.duplicateAccount = false;
    api.failNextBobAccessToken = false;
    api.loginBarrier = null;
    api.onLogout = null;
    api.syncStarted = Completer<void>();
    api.createCalls = 0;
    api.cancelCalls = 0;
    api.passwordCalls = 0;
    api.authMethods.clear();
    api.logoutAccounts.clear();
    api.switchAccounts.clear();
    api.syncAccounts.clear();
    await addSession(
      homeserver: 'https://example.org',
      accessToken: 'alice-token',
      userId: _alice,
      deviceId: 'ALICE_DEVICE',
      displayName: 'Alice',
      searchIndexKey: _aliceIndexKey,
    );
    container = ProviderContainer();
    container.read(activeUserIdProvider.notifier).value = _alice;
    container.read(currentUserProvider.notifier).value = const CurrentUser(
      id: _alice,
      displayName: 'Alice',
      homeserver: 'https://example.org',
    );
    container.read(isLoggedInProvider.notifier).value = true;
    container.read(sessionReadyProvider.notifier).value = true;
  });
  tearDown(() {
    container.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> openAddAccount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: neuTestTheme(), home: const SettingsPage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加账号'));
    await tester.pumpAndSettle();
    expect(find.byType(LoginPage), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).first,
      'https://other.example.org',
    );
  }

  Future<void> enterPassword(WidgetTester tester) async {
    await tester.enterText(find.byType(TextField).at(1), 'bob');
    await tester.enterText(find.byType(TextField).last, 'password');
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byType(TextField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('single-account settings can open and cancel adding an account', (
    tester,
  ) async {
    await openAddAccount(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(LoginPage), findsNothing);
    expect(api.cancelCalls, 1);
    expect(api.createCalls, 0);
    expect(api.logoutAccounts, isEmpty);
    expect(container.read(activeUserIdProvider), _alice);
    expect(container.read(sessionReadyProvider), isTrue);
  });

  for (final method in ['password', 'token', 'register']) {
    testWidgets(
      'adding an account with $method preserves both sessions and permits switching back',
      (tester) async {
        await openAddAccount(tester);
        if (method == 'token') {
          await tester.tap(find.text('Token'));
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField).at(1), _bob);
          await tester.enterText(find.byType(TextField).last, 'bob-token');
        } else {
          if (method == 'register') {
            await tester.tap(find.text('注册'));
            await tester.pumpAndSettle();
          }
          await enterPassword(tester);
        }
        await submit(tester);

        expect(api.authMethods, [method]);
        expect(find.byType(LoginPage), findsNothing);
        expect(container.read(activeUserIdProvider), _bob);
        expect(container.read(sessionReadyProvider), isTrue);
        final sessions = await loadAllSessions();
        expect(sessions.map((session) => session.userId), [_alice, _bob]);
        expect(sessions.first.deviceId, 'ALICE_DEVICE');
        expect(sessions.last.deviceId, 'BOB_DEVICE');
        expect(sessions.last.homeserverUrl, 'https://other.example.org');
        expect(api.logoutAccounts, isEmpty);
        expect(api.syncAccounts, [_bob]);
        await tester.tap(find.text('alice (example.org)'));
        await tester.pumpAndSettle();
        expect(container.read(activeUserIdProvider), _alice);
        expect(api.syncAccounts, [_bob, _alice]);
        expect(api.logoutAccounts, isEmpty);
      },
    );
  }

  testWidgets(
    'wrong password leaves the original account ready and allows retry',
    (tester) async {
      await openAddAccount(tester);
      await enterPassword(tester);
      api.rejectPassword = true;
      await submit(tester);

      expect(find.text('认证失败，请检查账号、密码或 Token'), findsOneWidget);
      expect(container.read(activeUserIdProvider), _alice);
      expect(container.read(sessionReadyProvider), isTrue);
      expect(api.accounts.keys, [_alice]);
      api.rejectPassword = false;
      await submit(tester);
      expect(container.read(activeUserIdProvider), _bob);
      expect(api.passwordCalls, 2);
    },
  );

  testWidgets(
    'an already-signed-in account is reported without replacing its session',
    (tester) async {
      await openAddAccount(tester);
      await enterPassword(tester);
      api.duplicateAccount = true;
      await submit(tester);

      expect(find.text('该账号已登录，请返回设置切换账号'), findsOneWidget);
      expect(container.read(activeUserIdProvider), _alice);
      expect(container.read(sessionReadyProvider), isTrue);
      expect((await loadAllSessions()).single.deviceId, 'ALICE_DEVICE');
      expect(api.logoutAccounts, isEmpty);
    },
  );

  testWidgets(
    'an in-flight login blocks back and duplicate keyboard submissions',
    (tester) async {
      await openAddAccount(tester);
      await enterPassword(tester);
      api.loginBarrier = Completer<void>();
      await tester.tap(find.byType(TextField).last);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(container.read(sessionReadyProvider), isFalse);
      await tester.pageBack();
      await tester.pump();
      expect(find.byType(LoginPage), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      expect(api.passwordCalls, 1);
      api.loginBarrier!.complete();
      await tester.pumpAndSettle();
      expect(find.byType(LoginPage), findsNothing);
      expect(container.read(activeUserIdProvider), _bob);
    },
  );

  testWidgets(
    'post-login persistence failure revokes only the new account and restores the original',
    (tester) async {
      const draftKey = (roomId: '!room:example.org', userId: _alice);
      container.read(messageDraftProvider(draftKey).notifier).value =
          'original draft';
      await openAddAccount(tester);
      await enterPassword(tester);
      api.failNextBobAccessToken = true;
      bool? readyDuringRollback;
      api.onLogout = () {
        readyDuringRollback = container.read(sessionReadyProvider);
      };
      // Failed-login cleanup removes real cache files, which needs real IO time.
      await tester.runAsync(() async {
        await tester.tap(find.byType(TextField).last);
        await tester.testTextInput.receiveAction(TextInputAction.done);
        await api.syncStarted.future.timeout(const Duration(seconds: 10));
        await Future<void>.delayed(Duration.zero);
      });
      await tester.pumpAndSettle();

      expect(readyDuringRollback, isFalse);
      expect(api.logoutAccounts, [_bob]);
      expect(api.switchAccounts, [_alice]);
      expect(container.read(activeUserIdProvider), _alice);
      expect(container.read(currentUserProvider)?.id, _alice);
      expect(container.read(sessionReadyProvider), isTrue);
      expect((await loadAllSessions()).single.deviceId, 'ALICE_DEVICE');
      expect((await loadOrCreateSearchIndexKey(_alice)).key, _aliceIndexKey);
      expect(container.read(messageDraftProvider(draftKey)), 'original draft');
      expect(api.syncAccounts, [_alice]);
    },
  );

  testWidgets(
    'a cleared session keeps the saved-account group and the add-account entry',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1200));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // The session can be torn down while the settings page is alive (an
      // expired token cleared from another route). The saved accounts are
      // still on disk and must remain reachable: without them there is no
      // way back into the account or into adding another one.
      container.read(isLoggedInProvider.notifier).value = false;
      container.read(currentUserProvider.notifier).value = null;
      container.read(activeUserIdProvider.notifier).value = null;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: neuTestTheme(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('添加账号'), findsOneWidget);
      expect(find.text('alice (example.org)'), findsOneWidget);
    },
  );
}
