import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/pages/login/login_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

const _user = '@alice:example.org';
const _indexKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=';
final _storageKey =
    'matrix_search_index_key_${base64Url.encode(utf8.encode(_user))}';

class _FakeRustApi implements RustLibApi {
  final resumeRequests =
      <({String user, String key, bool reset, bool memory})>[];
  int createCalls = 0;
  bool rejectPassword = false;
  static const session = rust.StoredSession(
    userId: _user,
    deviceId: 'EXISTING_DEVICE',
    homeserverUrl: 'https://example.org',
    accessToken: 'new-access',
    refreshToken: 'new-refresh',
  );

  @override
  Future<rust.AuthResult> crateApiMatrixResumeSessionWithPassword({
    required String accountUserId,
    required String password,
    required String searchIndexKey,
    required bool resetSearchIndex,
    required bool useInMemorySearchIndex,
  }) async {
    resumeRequests.add((
      user: accountUserId,
      key: searchIndexKey,
      reset: resetSearchIndex,
      memory: useInMemorySearchIndex,
    ));
    return rust.AuthResult(
      success: !rejectPassword,
      needsUiaa: false,
      userId: _user,
      error: rejectPassword ? 'Invalid password' : null,
    );
  }

  @override
  Future<void> crateApiMatrixCreateClient({
    required String homeserverUrl,
    required String dataDir,
    required String searchIndexKey,
    required bool useInMemorySearchIndex,
  }) async {
    createCalls++;
    throw StateError('stop before fresh login');
  }

  @override
  Future<rust.StoredSession?> crateApiMatrixGetSession() async => session;
  @override
  Future<String?> crateApiMatrixGetAccessToken() async => session.accessToken;
  @override
  Future<rust.SessionTokenUpdate?> crateApiMatrixGetSessionTokens({
    required String accountUserId,
  }) async => rust.SessionTokenUpdate(
    userId: _user,
    accessToken: session.accessToken,
    refreshToken: session.refreshToken,
  );
  @override
  Future<rust.UserProfile> crateApiMatrixGetProfile() async =>
      const rust.UserProfile(userId: _user, displayName: 'Alice');
  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() =>
      rust.ConnectionStatus.connected;
  @override
  Future<void> crateApiMatrixSyncOnce() async {}
  @override
  Future<void> crateApiMatrixStartSync() async {}
  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late _FakeRustApi api;
  const channel = MethodChannel('plugins.flutter.io/path_provider');
  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({_storageKey: _indexKey});
    api.resumeRequests.clear();
    api.createCalls = 0;
    api.rejectPassword = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          channel,
          (_) async => '/tmp/matter-login-recovery',
        );
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool resume = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: LoginPage(
            initialHomeserver: 'https://example.org',
            initialUserId: _user,
            resumeSession: resume,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'password');
    return container;
  }

  Future<void> submit(WidgetTester tester) async {
    await tester.tap(find.byType(TextField).last);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets(
    'soft relogin retains search key and persists original device with renewed tokens',
    (tester) async {
      final container = await mount(tester);
      await submit(tester);
      expect(api.resumeRequests, [
        (user: _user, key: _indexKey, reset: false, memory: false),
      ]);
      expect(api.createCalls, 0);
      expect(container.read(isLoggedInProvider), isTrue);
      final sessions = await loadAllSessions();
      expect(sessions.single.deviceId, 'EXISTING_DEVICE');
      expect(sessions.single.accessToken, 'new-access');
      expect(sessions.single.refreshToken, 'new-refresh');
      expect(
        await const FlutterSecureStorage().read(key: _storageKey),
        _indexKey,
      );
    },
  );

  testWidgets(
    'wrong password permits retry without creating a device or replacing search key',
    (tester) async {
      final container = await mount(tester);
      api.rejectPassword = true;
      await submit(tester);
      expect(container.read(isLoggedInProvider), isFalse);
      expect(find.text('认证失败，请检查账号、密码或 Token'), findsOneWidget);
      expect(
        await const FlutterSecureStorage().read(key: _storageKey),
        _indexKey,
      );
      api.rejectPassword = false;
      await submit(tester);
      expect(api.resumeRequests.length, 2);
      expect(api.createCalls, 0);
      expect(container.read(isLoggedInProvider), isTrue);
    },
  );

  testWidgets('editing the account does not reuse another account device', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField).at(1), 'bob');
    await tester.tap(find.byType(TextField).last);
    await submit(tester);
    expect(api.resumeRequests, isEmpty);
    expect(api.createCalls, 1);
  });

  testWidgets('hard logout uses fresh authentication', (tester) async {
    await mount(tester, resume: false);
    await submit(tester);
    expect(api.resumeRequests, isEmpty);
    expect(api.createCalls, 1);
  });
}
