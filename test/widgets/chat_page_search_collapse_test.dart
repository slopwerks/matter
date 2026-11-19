import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/mobile_tab_view.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/src/rust/api/matrix.dart';

import '../helpers/neu_test_theme.dart';

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

  for (final material in [false, true]) {
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

  testWidgets(
    'Material keeps an icon-only new chat FAB below the fading header',
    (tester) async {
      final container = ProviderContainer(
        overrides: [
          inboxRoomsProvider.overrideWith((ref) => const AsyncData([])),
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
      final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
      expect(
        scaffold.appBar == null || scaffold.extendBodyBehindAppBar,
        isTrue,
      );
      expect(find.byType(TopFadeBlur), findsOneWidget);
      final fade = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(TopFadeBlur),
          matching: find.byWidgetPredicate(
            (widget) =>
                widget is DecoratedBox &&
                widget.decoration is BoxDecoration &&
                (widget.decoration as BoxDecoration).gradient is LinearGradient,
          ),
        ),
      );
      final gradient =
          (fade.decoration as BoxDecoration).gradient! as LinearGradient;
      expect(
        gradient.colors.first.withValues(alpha: 1),
        tester.element(appBar).neu.base,
      );
      expect(gradient.colors.first.a, greaterThan(0));
      expect(gradient.colors.first.a, lessThan(1));
      expect(gradient.colors.last.a, 0);
    },
  );
}
