import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/features/auth/session_expiry_listener.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  final reloginAccounts = <String>[];
  Completer<void>? pendingRelogin;
  Object? reloginError;
  bool canResume = false;

  @override
  Future<bool> crateApiMatrixPrepareSessionRelogin({
    required String accountUserId,
  }) async {
    reloginAccounts.add(accountUserId);
    await pendingRelogin?.future;
    if (reloginError case final error?) throw error;
    return canResume;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late _FakeRustApi api;
  final resumeModes = <bool>[];
  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.reloginAccounts.clear();
    api.pendingRelogin = null;
    api.reloginError = null;
    api.canResume = false;
    resumeModes.clear();
  });

  Future<ProviderContainer> mount(
    WidgetTester tester, {
    bool expired = false,
  }) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(isLoggedInProvider.notifier).value = true;
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(connectionProvider.notifier).value = expired
        ? AppConnectionState.sessionExpired
        : AppConnectionState.connected;
    final navigatorKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          navigatorKey: navigatorKey,
          theme: neuTestTheme(),
          builder: (context, child) => Consumer(
            builder: (context, ref, _) => SessionExpiryListener(
              navigatorKey: navigatorKey,
              onRelogin: (canResume) {
                resumeModes.add(canResume);
                clearActiveSessionState(ref, markSessionReady: true);
                navigatorKey.currentState!.popUntil((route) => route.isFirst);
              },
              child: child!,
            ),
          ),
          home: Consumer(
            builder: (context, ref, _) => Scaffold(
              body: Text(ref.watch(isLoggedInProvider) ? '聊天页' : '登录页'),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('expired session opens a dialog above a settings route', (
    tester,
  ) async {
    final container = await mount(tester);
    final navigator = tester.state<NavigatorState>(
      find.byType(Navigator).first,
    );
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('设置页')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(connectionProvider.notifier).value =
        AppConnectionState.sessionExpired;
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('重新登录'), findsOneWidget);
    expect(find.text('设置页'), findsOneWidget);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(api.reloginAccounts, ['@alice:example.org']);
    expect(find.text('登录页'), findsOneWidget);
    expect(find.text('设置页'), findsNothing);
    expect(resumeModes, [false]);
  });

  testWidgets('soft logout passes original-device recovery mode to login', (
    tester,
  ) async {
    api.canResume = true;
    await mount(tester, expired: true);
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(resumeModes, [true]);
    expect(find.text('登录页'), findsOneWidget);
  });

  testWidgets(
    'already expired session prompts once and preserves session on later',
    (tester) async {
      final container = await mount(tester, expired: true);
      expect(find.text('登录已失效'), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();
      container.read(connectionProvider.notifier).value =
          AppConnectionState.sessionExpired;
      await tester.pumpAndSettle();
      expect(find.text('登录已失效'), findsNothing);
      expect(api.reloginAccounts, isEmpty);
      expect(container.read(isLoggedInProvider), isTrue);
      container.read(connectionProvider.notifier).value =
          AppConnectionState.connected;
      await tester.pumpAndSettle();
      container.read(connectionProvider.notifier).value =
          AppConnectionState.sessionExpired;
      await tester.pumpAndSettle();
      expect(find.text('登录已失效'), findsOneWidget);
    },
  );

  testWidgets('account switch closes an obsolete expiry dialog', (
    tester,
  ) async {
    final container = await mount(tester, expired: true);
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsNothing);
    expect(api.reloginAccounts, isEmpty);
  });

  testWidgets('relogin failure remains actionable in the dialog', (
    tester,
  ) async {
    final container = await mount(tester, expired: true);
    api.reloginError = StateError('temporary failure');
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsOneWidget);
    expect(find.text('无法打开登录页，请重试。'), findsOneWidget);
    expect(container.read(isLoggedInProvider), isTrue);
    api.reloginError = null;
    await tester.tap(find.text('重新登录'));
    await tester.pumpAndSettle();
    expect(find.text('登录页'), findsOneWidget);
  });

  testWidgets(
    'pending relogin blocks duplicate clicks and survives native status reset',
    (tester) async {
      final container = await mount(tester, expired: true);
      final pending = Completer<void>();
      api.pendingRelogin = pending;
      await tester.tap(find.text('重新登录'));
      await tester.pump();
      container.read(connectionProvider.notifier).value =
          AppConnectionState.disconnected;
      await tester.pump();
      expect(find.text('登录已失效'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('稍后'));
      await tester.pump();
      expect(find.text('登录已失效'), findsOneWidget);
      expect(api.reloginAccounts, ['@alice:example.org']);
      pending.complete();
      await tester.pumpAndSettle();
      expect(find.text('登录页'), findsOneWidget);
    },
  );

  testWidgets('late relogin completion cannot log out a different account', (
    tester,
  ) async {
    final container = await mount(tester, expired: true);
    final pending = Completer<void>();
    api.pendingRelogin = pending;
    await tester.tap(find.text('重新登录'));
    await tester.pump();
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pumpAndSettle();
    pending.complete();
    await tester.pumpAndSettle();
    expect(find.text('登录已失效'), findsNothing);
    expect(find.text('登录页'), findsNothing);
    expect(container.read(isLoggedInProvider), isTrue);
    expect(container.read(activeUserIdProvider), '@bob:example.org');
  });
}
