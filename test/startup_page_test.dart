import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/pages/settings/startup_page_settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/providers/startup_page_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

const _alice = '@alice:test';
const _bob = '@bob:test';

ProviderContainer _container({Future<List<rust.Space>>? spaces}) =>
    ProviderContainer(
      overrides: [
        allChatRoomsProvider.overrideWith((ref) async => const []),
        spacesProvider.overrideWith((ref) => spaces ?? Future.value(const [])),
      ],
    );

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(theme: neuTestTheme(), home: const MatterApp()),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await tester.pump();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'remember is default and missing history opens all conversations',
    () async {
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.allChats,
      );
    },
  );
  test('navigation history is isolated by account', () async {
    await rememberNavigationPage(
      _alice,
      const StartupLocation(
        NavigationDestinationPage.space,
        spaceId: '!space:test',
      ),
    );
    expect((await loadStartupLocation(_alice)).spaceId, '!space:test');
    expect(
      (await loadStartupLocation(_bob)).page,
      NavigationDestinationPage.allChats,
    );
  });
  test('explicit startup choice overrides remembered history and restores across containers', () async {
    await rememberNavigationPage(
      _alice,
      const StartupLocation(NavigationDestinationPage.directMessages),
    );
    for (final page in StartupPage.values.where(
      (page) => page != StartupPage.remember,
    )) {
      final container = ProviderContainer();
      await container.read(startupPageProvider.notifier).setPage(page);
      container.dispose();
      expect((await loadStartupLocation(_alice)).page.name, page.name);
      final restored = ProviderContainer();
      restored.read(startupPageProvider);
      await Future<void>.delayed(Duration.zero);
      expect(restored.read(startupPageProvider), page);
      restored.dispose();
    }
  });
  test('invalid remembered values fall back to all conversations', () async {
    final key = 'last_page_${base64Url.encode(utf8.encode(_alice))}';
    for (final value in [
      'bad-json',
      '[]',
      '{}',
      '{"page":"space"}',
      '{"page":"unknown"}',
    ]) {
      SharedPreferences.setMockInitialValues({key: value});
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.allChats,
      );
    }
  });
  test('restore cannot overwrite an early startup setting edit', () async {
    SharedPreferences.setMockInitialValues({'startup_page': 'settings'});
    final container = ProviderContainer();
    await container
        .read(startupPageProvider.notifier)
        .setPage(StartupPage.allChats);
    expect(container.read(startupPageProvider), StartupPage.allChats);
    container.dispose();
  });
  for (final material in [false, true]) {
    testWidgets('startup settings expose every option ($material)', (
      tester,
    ) async {
      final container = ProviderContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(material: material),
            home: const StartupPageSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final page in StartupPage.values) {
        final item = find.byKey(ValueKey('startup-page-${page.name}'));
        await tester.ensureVisible(item);
        await tester.tap(item);
        await tester.pumpAndSettle();
        expect(container.read(startupPageProvider), page);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
  }
  for (final width in [390.0, 1200.0]) {
    testWidgets('startup choice is applied without restoring a room ($width)', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await rememberNavigationPage(
        _alice,
        const StartupLocation(NavigationDestinationPage.directMessages),
      );
      final container = _container();
      container.read(activeUserIdProvider.notifier).value = _alice;
      await _pump(tester, container);
      expect(
        tester.widget<ChatPage>(find.byType(ChatPage).first).directMessagesOnly,
        isTrue,
      );
      expect(container.read(currentRoomIdProvider), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
  }
  testWidgets(
    'fresh desktop offers all conversations and remembers explicit changes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = _container();
      container.read(activeUserIdProvider.notifier).value = _alice;
      await _pump(tester, container);
      expect(find.byKey(const ValueKey('desktop-all-chats')), findsOneWidget);
      final direct = find.byTooltip('私聊');
      await tester.tap(
        direct.evaluate().isNotEmpty
            ? direct
            : find.byIcon(Icons.person_outline),
      );
      await tester.pumpAndSettle();
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.directMessages,
      );
      final allChats = find.byTooltip('全部会话');
      await tester.tap(
        allChats.evaluate().isNotEmpty
            ? allChats
            : find.byIcon(Icons.chat_bubble_outline).first,
      );
      await tester.pumpAndSettle();
      expect(
        (await loadStartupLocation(_alice)).page,
        NavigationDestinationPage.allChats,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
  testWidgets(
    'invalid space falls back and a late space load never overrides navigation',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await rememberNavigationPage(
        _alice,
        const StartupLocation(
          NavigationDestinationPage.space,
          spaceId: '!old:test',
        ),
      );
      final pending = Completer<List<rust.Space>>();
      final container = _container(spaces: pending.future);
      container.read(activeUserIdProvider.notifier).value = _alice;
      await _pump(tester, container);
      final direct = find.byTooltip('私聊');
      await tester.tap(
        direct.evaluate().isNotEmpty
            ? direct
            : find.byIcon(Icons.person_outline),
      );
      await tester.pump();
      pending.complete(const []);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('desktop-direct-messages')),
        findsOneWidget,
      );
      expect(container.read(navigationIndexProvider), 0);
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );
  testWidgets(
    'all-conversations startup lists rooms without opening the first one',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const room = rust.ChatRoom(
        id: '!unread:test',
        name: '未读群聊',
        lastMessage: '新消息',
        lastMessageTime: '1',
        lastEventId: r'$new',
        unreadCount: 1,
        isMarkedUnread: false,
        roomType: 'group',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      );
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => const [room]),
          spacesProvider.overrideWith((ref) async => const []),
        ],
      );
      container.read(activeUserIdProvider.notifier).value = _alice;
      await _pump(tester, container);
      expect(find.text('未读群聊'), findsOneWidget);
      expect(container.read(currentRoomIdProvider), isNull);
      expect(
        tester
            .widget<ChatPage>(find.byKey(const ValueKey('desktop-all-chats')))
            .autoSelectFirstRoom,
        isFalse,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    },
  );

  testWidgets('missing saved space returns to all conversations', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await rememberNavigationPage(
      _alice,
      const StartupLocation(
        NavigationDestinationPage.space,
        spaceId: '!missing:test',
      ),
    );
    final container = _container();
    container.read(activeUserIdProvider.notifier).value = _alice;
    await _pump(tester, container);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-all-chats')), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
  });
}
