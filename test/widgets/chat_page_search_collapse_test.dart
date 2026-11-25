import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/widgets/mobile_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/neu_test_theme.dart';

class _FilterMemoryFakeApi implements RustLibApi {
  final sync = StreamController<SyncEvent>.broadcast();

  @override
  Future<List<AccountInfo>> crateApiMatrixListAccounts() async => [];
  @override
  Stream<SyncEvent> crateApiMatrixWatchSyncEvents() => sync.stream;
  @override
  Stream<TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      const Stream.empty();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected: ${invocation.memberName}');
}

void main() {
  ChatRoom room(String id, String name) => ChatRoom(
    id: id,
    name: name,
    lastMessage: '',
    lastMessageTime: '0',
    lastEventId: '',
    unreadCount: 0,
    isMarkedUnread: false,
    roomType: 'group',
    isEncrypted: false,
    isMuted: false,
    roomState: 'joined',
  );

  for (final material in [false]) {
    testWidgets(
      '${material ? 'Material' : 'Neu'} scrolling collapses the search entry into a header icon',
      (tester) async {
        final container = ProviderContainer(
          overrides: [
            chatRoomsProvider.overrideWith(
              (ref) async => [
                for (var i = 0; i < 20; i++)
                  room('!room$i:example.org', 'Room $i'),
              ],
            ),
          ],
        );
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(material: material),
              home: const ChatPage(),
            ),
          ),
        );
        await tester.pump();

        // 静止时:搜索栏完整可见,头部搜索图标尚未出现。
        final searchEntry = find.byKey(const ValueKey('open-chat-search'));
        final headerIcon = find.byKey(const ValueKey('header-search-entry'));
        expect(searchEntry, findsOneWidget);
        expect(tester.getSize(searchEntry).height, greaterThan(0));
        expect(headerIcon, findsNothing);

        // 向上滚动一段距离:搜索栏随之渐隐,头部图标尚未出现。
        await tester.drag(find.byType(ListView), const Offset(0, -28));
        await tester.pump();

        expect(headerIcon, findsNothing);
        final entryOpacity = tester.widget<Opacity>(
          find.ancestor(of: searchEntry, matching: find.byType(Opacity)).first,
        );
        expect(entryOpacity.opacity, greaterThan(0));
        expect(entryOpacity.opacity, lessThan(1));

        // 继续滚动超过搜索栏高度:搜索栏完全滚出,头部搜索图标经时间动画显现。
        await tester.drag(find.byType(ListView), const Offset(0, -172));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(headerIcon, findsOneWidget);

        // 滚回顶部后恢复初始状态。
        await tester.drag(find.byType(ListView), const Offset(0, 400));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(headerIcon, findsNothing);
        final restoredOpacity = tester.widget<Opacity>(
          find.ancestor(of: searchEntry, matching: find.byType(Opacity)).first,
        );
        expect(restoredOpacity.opacity, 1);
      },
    );

    testWidgets(
      '${material ? 'Material' : 'Neu'} restores search after the list is replaced while away',
      (tester) async {
        var rooms = [
          for (var i = 0; i < 20; i++) room('!room$i:example.org', 'Room $i'),
        ];
        final container = ProviderContainer(
          overrides: [
            inboxRoomsProvider.overrideWith((ref) => AsyncData(rooms)),
          ],
        );
        addTearDown(container.dispose);
        final tab = ValueNotifier(0);
        final position = ValueNotifier(0.0);
        addTearDown(tab.dispose);
        addTearDown(position.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(material: material),
              home: ValueListenableBuilder<int>(
                valueListenable: tab,
                builder: (context, index, _) => MobileTabView(
                  index: index,
                  position: position,
                  onChanged: (value) => tab.value = value,
                  children: const [ChatPage(), SizedBox.expand()],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.drag(find.byType(ListView), const Offset(0, -200));
        await tester.pumpAndSettle();
        tab.value = 1;
        await tester.pumpAndSettle();
        rooms = [];
        container.invalidate(inboxRoomsProvider);
        await tester.pumpAndSettle();
        rooms = [room('!new:example.org', 'New room')];
        container.invalidate(inboxRoomsProvider);
        await tester.pumpAndSettle();
        tab.value = 0;
        await tester.pumpAndSettle();

        final searchEntry = find.byKey(const ValueKey('open-chat-search'));
        final scroll = tester.state<ScrollableState>(
          find.byType(Scrollable).first,
        );
        expect(scroll.position.pixels, 0);
        expect(
          tester
              .widget<Opacity>(
                find
                    .ancestor(of: searchEntry, matching: find.byType(Opacity))
                    .first,
              )
              .opacity,
          1,
        );
        expect(find.byKey(const ValueKey('header-search-entry')), findsNothing);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final compact in [true, false]) {
    testWidgets(
      'Material chat header adapts search on scroll (compact: $compact)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(compact ? 390 : 840, 740);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer(
          overrides: [
            inboxRoomsProvider.overrideWith(
              (ref) => AsyncData([
                for (var i = 0; i < 20; i++)
                  room('!room$i:example.org', 'Room $i'),
              ]),
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(material: true),
              home: const ChatPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final appBar = find.byType(AppBar);
        final fab = find.byType(FloatingActionButton);
        expect(fab, findsOneWidget);
        expect(
          find.descendant(of: fab, matching: find.byTooltip('新聊天')),
          findsOneWidget,
        );
        final fabSize = tester.getSize(fab);
        expect(fabSize.width, fabSize.height);
        expect(
          find.descendant(of: fab, matching: find.byType(Text)),
          findsNothing,
        );
        expect(
          tester.getTopLeft(fab).dy,
          greaterThan(tester.getBottomLeft(appBar).dy),
        );
        expect(find.byTooltip('搜索'), findsNothing);
        expect(find.byType(TopFadeBlur), findsNothing);
        final scheme = Theme.of(tester.element(appBar)).colorScheme;
        expect(
          tester.widget<AppBar>(appBar).backgroundColor,
          compact ? scheme.primaryContainer : scheme.surface,
        );
        final expandedHeight = tester.getSize(appBar).height;
        Future<void> expectTransitionFrame() async {
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 120));
          for (final key in ['open-chat-search', 'header-search-entry']) {
            final fade = find
                .ancestor(
                  of: find.byKey(ValueKey(key)),
                  matching: find.byType(Opacity),
                )
                .first;
            expect(
              tester.widget<Opacity>(fade).opacity,
              inExclusiveRange(0, 1),
            );
          }
          expect(tester.getSize(appBar).height, lessThan(expandedHeight));
        }

        await tester.drag(find.byType(ListView), const Offset(0, -400));
        if (compact) await expectTransitionFrame();
        await tester.pumpAndSettle();
        if (compact) {
          final icon = find.byKey(const ValueKey('header-search-entry'));
          expect(tester.getSize(appBar).height, lessThan(expandedHeight));
          expect(find.byKey(const ValueKey('open-chat-search')), findsNothing);
          await tester.tap(icon);
          await tester.pumpAndSettle();
          expect(find.byType(ChatSearchPage), findsOneWidget);
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(icon.hitTestable(), findsOneWidget);
          await tester.drag(find.byType(ListView), const Offset(0, 800));
          await expectTransitionFrame();
          await tester.pumpAndSettle();
        }
        expect(tester.getSize(appBar).height, expandedHeight);
        expect(
          find.byKey(const ValueKey('open-chat-search')).hitTestable(),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('header-search-entry')), findsNothing);
      },
    );
  }

  testWidgets(
    'Material filter switches preserve collapsed header and scroll memory',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final api = _FilterMemoryFakeApi();
      RustLib.initMock(api: api);
      addTearDown(() async {
        await api.sync.close();
        RustLib.dispose();
      });

      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 800);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);

      final rooms = [
        for (var i = 0; i < 20; i++)
          ChatRoom(
            id: '!room$i:example.org',
            name: 'Room $i',
            lastMessage: 'msg',
            lastMessageTime: '${1000 - i}',
            lastEventId: '\$e$i',
            unreadCount: i == 0 ? 1 : 0,
            isMarkedUnread: false,
            roomType: i.isEven ? 'dm' : 'group',
            isEncrypted: false,
            isMuted: false,
            roomState: 'joined',
          ),
      ];
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => rooms),
          spacesProvider.overrideWith((ref) async => const []),
          ungroupedRoomsProvider.overrideWith((ref) async => rooms),
          contactsProvider.overrideWith((ref) async => const []),
          ignoredUserIdsProvider.overrideWith((ref) async => <String>{}),
        ],
      );
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(material: true),
            home: const MatterApp(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Scroll down on 全部 to collapse the search bar.
      await tester.drag(find.byType(ListView), const Offset(0, -320));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('header-search-entry')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('open-chat-search')), findsNothing);
      final roomScrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      final scrolledOffset = tester
          .state<ScrollableState>(roomScrollable)
          .position
          .pixels;
      expect(scrolledOffset, greaterThan(0));

      // Switch to 未读 (only 1 room, unscrollable): forehead stays collapsed.
      await tester.tap(find.text('未读'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('header-search-entry')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('open-chat-search')), findsNothing);

      // Switch to 私聊: forehead still stays collapsed.
      await tester.tap(find.text('私聊'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('header-search-entry')).hitTestable(),
        findsOneWidget,
      );

      // Switch back to 全部: restores previous scroll offset and collapsed state.
      await tester.tap(find.text('全部'));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(roomScrollable).position.pixels,
        closeTo(scrolledOffset, 1.0),
      );
      expect(
        find.byKey(const ValueKey('header-search-entry')).hitTestable(),
        findsOneWidget,
      );

      // Pulling back to the top expands the search bar again.
      await tester.drag(find.byType(ListView), const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('open-chat-search')).hitTestable(),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('header-search-entry')), findsNothing);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );
}
