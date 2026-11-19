import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/space_page.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/pages/settings/settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/widgets/mobile_tab_view.dart';
import 'package:matter/widgets/neu_action.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

Future<ProviderContainer> _pumpMobileApp(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        chatRoomsProvider.overrideWith((ref) async => const []),
        spacesProvider.overrideWith((ref) async => const []),
        contactsProvider.overrideWith((ref) async => const []),
      ],
      child: MaterialApp(theme: neuTestTheme(), home: const MatterApp()),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  return ProviderScope.containerOf(tester.element(find.byType(MatterApp)));
}

Finder _dockItems() => find.descendant(
  of: find.byKey(const ValueKey('mobile-dock')),
  matching: find.byType(NeuAction),
);

Finder _dockHighlight() => find.descendant(
  of: find.byKey(const ValueKey('mobile-dock')),
  matching: find.byWidgetPredicate(
    (widget) => widget is NeuSurface && widget.accent,
  ),
);

void main() {
  setUpAll(() => RustLib.initMock(api: _FakeRustApi()));
  tearDownAll(RustLib.dispose);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('mobile tabs retain their state across return visits', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          chatRoomsProvider.overrideWith((ref) async => const []),
          spacesProvider.overrideWith((ref) async => const []),
          contactsProvider.overrideWith((ref) async => const []),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: const MatterApp()),
      ),
    );
    await tester.pumpAndSettle();
    final initialState = tester.state(find.byType(ChatPage));
    await tester.tap(_dockItems().at(2));
    await tester.pumpAndSettle();
    expect(initialState.mounted, isTrue);
    expect(
      TickerMode.valuesOf(
        tester.element(find.byType(ChatPage, skipOffstage: false)),
      ).enabled,
      isFalse,
    );
    expect(find.byType(SettingsPage, skipOffstage: false), findsNothing);
    await tester.tap(_dockItems().at(0));
    await tester.pumpAndSettle();
    expect(tester.state(find.byType(ChatPage)), same(initialState));
    final container = ProviderScope.containerOf(
      tester.element(find.byType(MatterApp)),
    );
    container.read(activeUserIdProvider.notifier).value = '@other:example.org';
    await tester.pumpAndSettle();
    expect(initialState.mounted, isFalse);
    expect(tester.state(find.byType(ChatPage)), isNot(same(initialState)));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'dock jumps transition directly without mounting intermediate tabs',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpMobileApp(tester);
      await tester.tap(_dockItems().at(3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      expect(find.byType(ChatPage), findsOneWidget);
      expect(find.byType(SettingsPage), findsOneWidget);
      final incomingOpacity = tester
          .widget<Opacity>(
            find
                .ancestor(
                  of: find.byType(SettingsPage),
                  matching: find.byType(Opacity),
                )
                .first,
          )
          .opacity;
      final incomingOffset = tester
          .widget<FractionalTranslation>(
            find
                .ancestor(
                  of: find.byType(SettingsPage),
                  matching: find.byType(FractionalTranslation),
                )
                .first,
          )
          .translation
          .dx;
      expect(incomingOpacity, inExclusiveRange(0, 1));
      expect(incomingOffset, inExclusiveRange(0, .12));
      expect(find.byType(SpacePage, skipOffstage: false), findsNothing);
      expect(find.byType(ContactsPage, skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
      expect(find.byType(ChatPage), findsNothing);
      expect(find.byType(SettingsPage), findsOneWidget);
    },
  );

  testWidgets('dock taps keep the destination selected throughout the slide', (
    tester,
  ) async {
    final container = await _pumpMobileApp(tester);
    final position = tester
        .widget<MobileTabView>(find.byType(MobileTabView))
        .position;
    final selections = <int>[];
    final subscription = container.listen(
      navigationIndexProvider,
      (_, next) => selections.add(next),
    );
    addTearDown(subscription.close);
    final dock = _dockItems();
    await tester.tap(dock.at(3));
    await tester.pump();
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    expect(selections, [3]);
    expect(position.value, 3);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
    'dock highlight moves with the page and snaps to its destination',
    (tester) async {
      await _pumpMobileApp(tester);
      final dock = _dockItems();
      final highlight = _dockHighlight();
      final start = tester.getCenter(highlight).dx;
      final destination = tester.getCenter(dock.at(3)).dx;
      await tester.tap(dock.at(3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      final during = tester.getCenter(highlight).dx;
      expect(during, greaterThan(start));
      expect(during, lessThan(destination));
      final position = tester
          .widget<MobileTabView>(find.byType(MobileTabView))
          .position;
      final step = tester.getCenter(dock.at(1)).dx - start;
      expect(during, closeTo(start + position.value * step, 0.1));
      await tester.pumpAndSettle();
      expect(tester.getCenter(highlight).dx, closeTo(destination, 0.1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('rapid dock taps settle on the last destination', (tester) async {
    final container = await _pumpMobileApp(tester);
    final selections = <int>[];
    final subscription = container.listen(
      navigationIndexProvider,
      (_, next) => selections.add(next),
    );
    addTearDown(subscription.close);
    await tester.tap(_dockItems().at(3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    final before = tester.getTopLeft(find.byType(SettingsPage));
    final highlightBefore = tester.getCenter(_dockHighlight());
    await tester.tap(_dockItems().at(0));
    await tester.pump();
    expect(tester.getTopLeft(find.byType(SettingsPage)), before);
    expect(tester.getCenter(_dockHighlight()), highlightBefore);
    for (var frame = 0; frame < 20; frame++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
    await tester.pumpAndSettle();
    final position = tester
        .widget<MobileTabView>(find.byType(MobileTabView))
        .position;
    expect(selections, [3, 0]);
    expect(position.value, 0);
    expect(
      tester.getCenter(_dockHighlight()).dx,
      closeTo(tester.getCenter(_dockItems().at(0)).dx, 0.1),
    );
    await tester.drag(find.byType(MobileTabView), const Offset(-600, 0));
    await tester.pumpAndSettle();
    expect(container.read(navigationIndexProvider), 1);
    expect(position.value, 1);
  });

  testWidgets('dock follows a partial swipe and snaps back on release', (
    tester,
  ) async {
    final container = await _pumpMobileApp(tester);
    final start = tester.getCenter(_dockHighlight()).dx;
    final step = tester.getCenter(_dockItems().at(1)).dx - start;
    final position = tester
        .widget<MobileTabView>(find.byType(MobileTabView))
        .position;
    final gesture = await tester.startGesture(const Offset(700, 200));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    expect(position.value, greaterThan(0));
    expect(position.value, lessThan(0.5));
    expect(container.read(navigationIndexProvider), 0);
    expect(
      tester.getCenter(_dockHighlight()).dx,
      closeTo(start + position.value * step, 0.1),
    );
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(position.value, 0);
    expect(tester.getCenter(_dockHighlight()).dx, closeTo(start, 0.1));
  });

  testWidgets('a swipe can take over an unfinished dock transition', (
    tester,
  ) async {
    final container = await _pumpMobileApp(tester);
    await tester.tap(_dockItems().at(3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    final position = tester
        .widget<MobileTabView>(find.byType(MobileTabView))
        .position;
    final gesture = await tester.startGesture(const Offset(100, 200));
    await gesture.moveBy(const Offset(600, 0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await gesture.up();
    await tester.pumpAndSettle();
    // Settings is already the most visible page; a right swipe goes to Contacts.
    expect(position.value, 2);
    expect(container.read(navigationIndexProvider), 2);
    expect(
      tester.getCenter(_dockHighlight()).dx,
      closeTo(tester.getCenter(_dockItems().at(2)).dx, 0.1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings retains its scroll position across dock visits', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpMobileApp(tester);
    await tester.tap(_dockItems().at(3));
    await tester.pumpAndSettle();
    final scrollable = find
        .descendant(
          of: find.byType(SettingsPage),
          matching: find.byType(Scrollable),
        )
        .first;
    await tester.scrollUntilVisible(
      find.text('导出日志'),
      400,
      scrollable: scrollable,
    );
    await tester.pumpAndSettle();
    final state = tester.state<ScrollableState>(scrollable);
    final offset = state.position.pixels;
    expect(offset, greaterThan(0));
    await tester.tap(_dockItems().at(0));
    await tester.pumpAndSettle();
    await tester.tap(_dockItems().at(3));
    await tester.pumpAndSettle();
    expect(tester.state<ScrollableState>(scrollable), same(state));
    expect(state.position.pixels, offset);
  });

  testWidgets('dock navigation can take over an active drag', (tester) async {
    final container = await _pumpMobileApp(tester);
    final gesture = await tester.startGesture(const Offset(700, 200));
    await gesture.moveBy(const Offset(-100, 0));
    await tester.pump();
    await tester.tap(_dockItems().at(3));
    await tester.pump();
    await gesture.moveBy(const Offset(-100, 0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(container.read(navigationIndexProvider), 3);
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('layout changes during a transition retain the selected tab', (
    tester,
  ) async {
    await _pumpMobileApp(tester);
    await tester.tap(_dockItems().at(3));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(400, 700));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(
      tester.getCenter(_dockHighlight()).dx,
      closeTo(tester.getCenter(_dockItems().at(3)).dx, .1),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'space page builds only nearby rooms and can reach the last room',
    (tester) async {
      final rooms = List.generate(
        200,
        (index) => rust.ChatRoom(
          id: '!room$index:example.org',
          name: 'Room $index',
          lastMessage: '',
          lastMessageTime: '0',
          lastEventId: '',
          unreadCount: 0,
          isMarkedUnread: false,
          roomType: 'group',
          isEncrypted: false,
          isMuted: false,
          roomState: 'joined',
        ),
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            spacesProvider.overrideWith((ref) async => const []),
            ungroupedRoomsProvider.overrideWith((ref) async => rooms),
          ],
          child: MaterialApp(theme: neuTestTheme(), home: const SpacePage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatListItem).evaluate().length, lessThan(20));
      await tester.scrollUntilVisible(
        find.text('Room 199'),
        500,
        maxScrolls: 100,
      );
      await tester.pumpAndSettle();
      expect(find.text('Room 199'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'settings lays out lower sections only as they approach the viewport',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(theme: neuTestTheme(), home: const SettingsPage()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('主题'), findsOneWidget);
      expect(find.text('导出日志'), findsNothing);
      await tester.scrollUntilVisible(find.text('导出日志'), 400);
      await tester.pumpAndSettle();
      expect(find.text('导出日志'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Android route transitions animate between routes', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        theme: neuTestTheme().copyWith(platform: TargetPlatform.android),
        home: const Scaffold(body: Text('Rooms')),
      ),
    );
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Chat')),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    // 标准预测性返回构建器沿用 Zoom 过渡:转场期间两个路由都在树中。
    expect(find.text('Rooms'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    await tester.pumpAndSettle();
    expect(find.text('Rooms'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(find.text('Rooms'), findsOneWidget);
  });
}
