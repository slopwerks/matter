import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/chat_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/hidden_rooms_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/material_adaptive_shell.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';
import 'package:matter/widgets/mobile_tab_view.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

rust.ChatRoom _room(int index, {String? preview}) => rust.ChatRoom(
  id: '!room$index:example.org',
  name: 'Room $index',
  lastMessage: preview ?? 'Preview $index',
  lastMessageTime: '0',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: false,
  isMuted: false,
  roomState: 'joined',
);

Future<ProviderContainer> _pumpApp(
  WidgetTester tester, {
  TextDirection direction = TextDirection.ltr,
}) async {
  final container = ProviderContainer(
    overrides: [
      allChatRoomsProvider.overrideWith((ref) async => []),
      spacesProvider.overrideWith((ref) async => []),
      contactsProvider.overrideWith((ref) async => []),
      ungroupedRoomsProvider.overrideWith((ref) async => []),
      syncStreamProvider.overrideWith((ref) => null),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        builder: (context, child) =>
            Directionality(textDirection: direction, child: child!),
        home: const MatterApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  return container;
}

// The dock draws its own destinations now, so address them by label: that is
// also what a user aims at, and it keeps the finder honest about which row of
// the bar is being touched.
const _destinationLabels = ['聊天', '空间', '通讯录', '设置'];

final _bar = find.byKey(const ValueKey('material-dock'));

Finder _destination(int index) => find.descendant(
  of: find.byKey(const ValueKey('material-dock')),
  matching: find.text(_destinationLabels[index]),
);

/// The lens tracks the page position. Assert what the reader can see — the
/// lens sits over the destination the pages are nearest to — instead of
/// restating the dock's geometry: width, padding and height all follow the
/// bar's measured size, so a formula copied into the test only agrees by
/// coincidence.
void _expectHighlight(WidgetTester tester, double page) {
  expect(_bar, findsOneWidget);
  final lens = find
      .descendant(of: _bar, matching: find.byType(CustomPaint))
      .first;
  final painted = _paintedLens(tester, lens);
  final scheme = Theme.of(tester.element(find.byType(MaterialTabNavigationBar)))
      .colorScheme;
  // Compare the encoded value: Color equality also weighs the float channels,
  // which differ in the last bits between a stored colour and a derived one.
  expect(
    painted.paint.color.toARGB32(),
    scheme.primary.withValues(alpha: .14).toARGB32(),
  );

  // The painter draws in the bar's own coordinates, so the expected centre is
  // the pitch the destinations are laid out on, with no origin correction.
  final count = _destinationLabels.length;
  final pitch = (tester.getSize(_bar).width - 8) / count;
  double centerOf(double index) {
    final direction = Directionality.of(tester.element(_bar));
    final visual = direction == TextDirection.ltr ? index : count - 1 - index;
    return 4 + (visual + .5) * pitch;
  }

  // The lens is a spring, so mid-flight it sits between two destinations
  // rather than on one. What must hold at every moment is that it is inside
  // the span its target implies -- never stuck at the previous destination.
  final x = painted.rrect.center.dx;
  final target = centerOf(page);
  expect(
    x,
    closeTo(target, pitch / 2),
    reason: 'lens should be heading for destination $page, not stuck',
  );
}

/// Reads back the single rounded rectangle the dock's painter draws.
({RRect rrect, Paint paint}) _paintedLens(WidgetTester tester, Finder lens) {
  final painter = tester.widget<CustomPaint>(lens).painter!;
  final canvas = _LensRecorder();
  painter.paint(canvas, tester.getSize(lens));
  expect(canvas.rrects, hasLength(1));
  return canvas.rrects.single;
}

class _LensRecorder implements Canvas {
  final rrects = <({RRect rrect, Paint paint})>[];

  @override
  void drawRRect(RRect rrect, Paint paint) =>
      rrects.add((rrect: rrect, paint: paint));

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RustApi()));
  tearDownAll(RustLib.dispose);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final page in [
    const ChatPage(),
    const ChatSearchPage(),
    const ContactsPage(),
  ]) {
    testWidgets('${page.runtimeType} uses an accessible Material search bar', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // Keep MediaQuery's breakpoint consistent with the layout constraints.
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 700);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => []),
          contactsProvider.overrideWith((ref) async => []),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.light),
            home: page,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final search = find.byType(SearchBar);
      expect(search, findsOneWidget);
      expect(tester.getSize(search).height, greaterThanOrEqualTo(56));
      final surface = tester.widget<Material>(
        find.descendant(of: search, matching: find.byType(Material)).first,
      );
      expect(surface.shape, isA<StadiumBorder>());
      await tester.tap(search);
      await tester.pumpAndSettle();
      expect(
        tester.widget<SearchBar>(find.byType(SearchBar)).focusNode!.hasFocus,
        isTrue,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets(
    'Material contact search filters names and status with enlarged text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            contactsProvider.overrideWith(
              (ref) async => const [
                rust.Contact(
                  id: '@rain:example.org',
                  name: 'Rain',
                  status: 'Coffee time',
                ),
                rust.Contact(
                  id: '@forest:example.org',
                  name: 'Forest',
                  status: 'On the road',
                ),
              ],
            ),
          ],
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.dark),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(2)),
              child: child!,
            ),
            home: const ContactsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'COFFEE');
      await tester.pumpAndSettle();
      expect(find.text('Rain'), findsOneWidget);
      expect(find.text('Forest'), findsNothing);
      await tester.enterText(find.byType(TextField), '');
      await tester.pumpAndSettle();
      expect(find.text('Rain'), findsOneWidget);
      expect(find.text('Forest'), findsOneWidget);
      expect(find.byTooltip('发消息'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('room refresh preserves visible rows and scroll position', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()
      ..complete(List.generate(30, _room));
    final container = ProviderContainer(
      overrides: [allChatRoomsProvider.overrideWith((ref) => response.future)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final scrollable = find.byType(Scrollable).first;
    final scroll = tester.state<ScrollableState>(scrollable);
    final offset = scroll.position.pixels;
    final row = find.byType(ChatListItem).first;
    final state = tester.state(row);
    final name = tester.widget<ChatListItem>(row).room.name;
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text(name), findsOneWidget);
    expect(state.mounted, isTrue);
    expect(tester.state<ScrollableState>(scrollable), same(scroll));
    expect(scroll.position.pixels, offset);
    response.complete(
      List.generate(30, (index) => _room(index, preview: 'Updated $index')),
    );
    await tester.pumpAndSettle();
    expect(find.text(name), findsOneWidget);
    expect(scroll.position.pixels, offset);
    expect(find.textContaining('Updated'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('returning home during a fetch keeps the existing list', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var response = Completer<List<rust.ChatRoom>>()
      ..complete(List.generate(30, _room));
    final container = ProviderContainer(
      overrides: [
        allChatRoomsProvider.overrideWith((ref) => response.future),
        contactsProvider.overrideWith((ref) async => []),
        syncStreamProvider.overrideWith((ref) => null),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const MatterApp(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final chatState = tester.state(find.byType(ChatPage));
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pumpAndSettle();
    final scroll = tester.state<ScrollableState>(find.byType(Scrollable).first);
    final offset = scroll.position.pixels;
    await tester.tap(_destination(2));
    await tester.pumpAndSettle();
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.tap(_destination(0));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.state(find.byType(ChatPage)), same(chatState));
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(ChatListItem), findsWidgets);
    expect(scroll.position.pixels, offset);
    response.complete(List.generate(30, _room));
    await tester.pumpAndSettle();
    expect(scroll.position.pixels, offset);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('cached rows do not auto-select a room during refresh', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()..complete([_room(0)]);
    final selected = <String>[];
    final container = ProviderContainer(
      overrides: [allChatRoomsProvider.overrideWith((ref) => response.future)],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            body: ChatPage(
              embedded: true,
              onRoomSelected: (room) => selected.add(room.id),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(selected, isNotEmpty);
    selected.clear();
    response = Completer<List<rust.ChatRoom>>();
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(find.text('Room 0'), findsOneWidget);
    expect(selected, isEmpty);
    response.complete([_room(1)]);
    await tester.pumpAndSettle();
    expect(selected, everyElement('!room1:example.org'));
    expect(selected, isNotEmpty);
  });

  testWidgets('hiding a room still removes it immediately', (tester) async {
    final container = ProviderContainer(
      overrides: [
        allChatRoomsProvider.overrideWith((ref) async => [_room(0)]),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Room 0'), findsOneWidget);
    await container.read(hiddenRoomsProvider.notifier).hideRooms([
      '!room0:example.org',
    ]);
    await tester.pump();
    expect(find.text('Room 0'), findsNothing);
    await tester.pumpAndSettle();
    expect(find.text('暂无聊天'), findsOneWidget);
  });

  testWidgets('account change does not keep the previous list during reload', (
    tester,
  ) async {
    var response = Completer<List<rust.ChatRoom>>()..complete([_room(0)]);
    final container = ProviderContainer(
      overrides: [
        activeUserIdProvider.overrideWith(
          () => MutableState('@alice:example.org'),
        ),
        allChatRoomsProvider.overrideWith((ref) {
          ref.watch(activeUserIdProvider);
          return response.future;
        }),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const ChatPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Room 0'), findsOneWidget);
    response = Completer<List<rust.ChatRoom>>();
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    expect(find.text('Room 0'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    response.complete([_room(1)]);
    await tester.pumpAndSettle();
    expect(find.text('Room 1'), findsOneWidget);
  });

  for (final direction in TextDirection.values) {
    testWidgets(
      'dock hold and slide switches visible pages before release in $direction',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = await _pumpApp(tester, direction: direction);
        final position = tester
            .widget<MobileTabView>(find.byType(MobileTabView))
            .position;
        final gesture = await tester.startGesture(
          tester.getCenter(_destination(0)),
        );
        await tester.pump(const Duration(milliseconds: 600));
        await gesture.moveTo(tester.getCenter(_destination(1)));
        await tester.pumpAndSettle();
        expect(container.read(navigationIndexProvider), 1);
        expect(position.value, 1);
        // The page, not just its selection state, must have changed.
        expect(find.text('还没有加入空间'), findsOneWidget);
        await gesture.moveTo(tester.getCenter(_destination(3)));
        await tester.pumpAndSettle();
        expect(container.read(navigationIndexProvider), 3);
        expect(position.value, 3);
        expect(find.text('外观与显示'), findsOneWidget);
        final lens = find
            .descendant(of: _bar, matching: find.byType(CustomPaint))
            .first;
        final previewX = _paintedLens(tester, lens).rrect.center.dx;
        await gesture.up();
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(
          _paintedLens(tester, lens).rrect.center.dx,
          closeTo(previewX, .5),
        );
        await tester.pumpAndSettle();
        expect(container.read(navigationIndexProvider), 3);
        expect(position.value, 3);
        _expectHighlight(tester, 3);
      },
    );

    testWidgets(
      'Material highlight follows taps, reversals and swipes in $direction',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await _pumpApp(tester, direction: direction);
        final position = tester
            .widget<MobileTabView>(find.byType(MobileTabView))
            .position;
        _expectHighlight(tester, 0);
        await tester.tap(_destination(3));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 64));
        expect(position.value, inExclusiveRange(0, 3));
        _expectHighlight(tester, position.value);
        final before = position.value;
        await tester.tap(_destination(0));
        await tester.pump();
        expect(position.value, before);
        _expectHighlight(tester, before);
        await tester.pumpAndSettle();
        _expectHighlight(tester, 0);
        final gesture = await tester.startGesture(const Offset(200, 200));
        await gesture.moveBy(
          Offset(direction == TextDirection.ltr ? -100 : 100, 0),
        );
        await tester.pump();
        expect(position.value, inExclusiveRange(0, .5));
        _expectHighlight(tester, position.value);
        await tester.pump(const Duration(milliseconds: 200));
        await gesture.up();
        await tester.pumpAndSettle();
        _expectHighlight(tester, 0);
      },
    );
  }

  testWidgets(
    'Material highlight stays aligned with large labels and a bottom safe area',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      tester.view.padding = const FakeViewPadding(bottom: 34);
      tester.view.viewPadding = const FakeViewPadding(bottom: 34);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpApp(tester);
      _expectHighlight(tester, 0);
      await tester.tap(_destination(3));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 64));
      final position = tester
          .widget<MobileTabView>(find.byType(MobileTabView))
          .position;
      _expectHighlight(tester, position.value);
      await tester.pumpAndSettle();
      _expectHighlight(tester, 3);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('connection title fades between labels', (tester) async {
    final container = await _pumpApp(tester);
    container.read(connectionProvider.notifier).value =
        AppConnectionState.connected;
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    expect(find.text('连接中…'), findsOneWidget);
    final title = find.descendant(
      of: find.byType(ChatPage),
      matching: find.text('聊天'),
    );
    expect(title, findsOneWidget);
    final opacity = find.ancestor(of: title, matching: find.byType(Opacity));
    expect(opacity, findsWidgets);
    expect(
      tester.widget<Opacity>(opacity.first).opacity,
      inExclusiveRange(0, 1),
    );
    await tester.pumpAndSettle();
    expect(find.text('连接中…'), findsNothing);
  });

  testWidgets(
    'conversation list keeps its width across the large window breakpoint',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1199, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpApp(tester);
      final list = find.byKey(const ValueKey('material-conversation-list'));
      expect(tester.getSize(list).width, 320);
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      await tester.pumpAndSettle();
      expect(tester.getSize(list).width, 320);
      await tester.drag(
        find.byKey(const ValueKey('conversation-list-divider')),
        const Offset(100, 0),
      );
      await tester.pumpAndSettle();
      final preferred = tester.getSize(list).width;
      expect(preferred, greaterThan(320));
      await tester.binding.setSurfaceSize(const Size(840, 800));
      await tester.pumpAndSettle();
      expect(tester.getSize(list).width, lessThan(preferred));
      await tester.binding.setSurfaceSize(const Size(1199, 800));
      await tester.pumpAndSettle();
      expect(tester.getSize(list).width, preferred);
      await tester.pumpWidget(const SizedBox());
      await _pumpApp(tester);
      expect(tester.getSize(list).width, preferred);
    },
  );

  testWidgets('desktop rail remembers a drag across resizing and reopening', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpApp(tester);
    final rail = find.byKey(const ValueKey('material-navigation-rail'));
    final divider = find.byKey(const ValueKey('material-rail-divider'));
    await tester.drag(divider, const Offset(-50, 0));
    await tester.pumpAndSettle();
    final width = tester.getSize(rail).width;
    expect(width, greaterThan(160));
    await tester.binding.setSurfaceSize(const Size(840, 800));
    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, lessThan(width));
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, width);
    await tester.pumpWidget(const SizedBox());
    await _pumpApp(tester);
    expect(tester.getSize(rail).width, width);
    await tester.tap(divider);
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(divider);
    await tester.pumpAndSettle();
    expect(tester.getSize(rail).width, 256);
  });

  testWidgets(
    'wide rail toggle can reverse mid-transition and respects reduced motion',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _pumpApp(tester);
      final rail = find.byKey(const ValueKey('material-navigation-rail'));
      final pane = find.byKey(const ValueKey('material-shell-content'));
      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));
      final width = tester.getSize(rail).width;
      expect(width, inExclusiveRange(80, 256));
      expect(tester.getTopLeft(pane).dx, width);
      await tester.tap(find.byTooltip('展开侧栏'));
      await tester.pump();
      expect(tester.getSize(rail).width, closeTo(width, 1));
      await tester.pumpAndSettle();
      expect(tester.getSize(rail).width, 256);
      tester.platformDispatcher.accessibilityFeaturesTestValue =
          const FakeAccessibilityFeatures(disableAnimations: true);
      addTearDown(
        tester.platformDispatcher.clearAccessibilityFeaturesTestValue,
      );
      await tester.pump();
      await tester.tap(find.byTooltip('收起侧栏'));
      await tester.pump();
      expect(tester.getSize(rail).width, 80);
      await tester.tap(find.byTooltip('空间'));
      await tester.pump();
      expect(
        tester.widget<MobileTabView>(find.byType(MobileTabView)).position.value,
        1,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('dragging wide content stays on the selected destination', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(600, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = await _pumpApp(tester);
    for (final width in [600.0, 1200.0]) {
      await tester.binding.setSurfaceSize(Size(width, 700));
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(Offset(width - 30, 350));
      await gesture.moveBy(Offset(-width * .65, 0));
      await tester.pump();
      expect(
        tester.widget<MobileTabView>(find.byType(MobileTabView)).position.value,
        0,
      );
      await gesture.up();
      await tester.pumpAndSettle();
      expect(container.read(navigationIndexProvider), 0);
    }
  });

  testWidgets(
    'collapsed rail keeps a full target and names keyboard destinations',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(840, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = await _pumpApp(tester);
      final rail = find.byKey(const ValueKey('material-navigation-rail'));
      await tester.drag(
        find.byKey(const ValueKey('material-rail-divider')),
        const Offset(-100, 0),
      );
      await tester.pumpAndSettle();
      final chat = find.byTooltip('聊天');
      expect(tester.getSize(rail).width, 64);
      expect(tester.getSize(chat), const Size.square(kMinInteractiveDimension));
      expect(tester.getCenter(chat).dx, tester.getCenter(rail).dx);
      Focus.of(
        tester.element(
          find.descendant(of: chat, matching: find.byIcon(Icons.chat_bubble)),
        ),
      ).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(find.text('空间'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(container.read(navigationIndexProvider), 1);
    },
  );

  testWidgets('expanded rail hover matches the selected space capsule', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpApp(tester);
    final rail = find.byKey(const ValueKey('material-navigation-rail'));
    final space = find.ancestor(
      of: find.descendant(
        of: rail,
        matching: find.byIcon(Icons.workspaces_outline),
      ),
      matching: find.byType(InkWell),
    );
    final point = tester.getCenter(space);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: point);
    await mouse.down(point);
    await mouse.up();
    await tester.pumpAndSettle();
    final selected = find.ancestor(
      of: find.descendant(of: rail, matching: find.byIcon(Icons.workspaces)),
      matching: find.byType(InkWell),
    );
    final indicator = find.byKey(const ValueKey('rail-indicator'));
    expect(tester.getRect(selected), tester.getRect(indicator));
    expect(tester.getSize(selected), const Size(232, 56));
    expect(
      tester.widget<InkWell>(selected).customBorder,
      const StadiumBorder(),
    );
    expect(tester.widget<InkWell>(selected).hoverColor, Colors.transparent);
    await mouse.removePointer();
  });

  testWidgets(
    'split room changes fade the latest detail at its final position',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final navigator = GlobalKey<NavigatorState>();
      final room = ValueNotifier('A');
      addTearDown(room.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: ValueListenableBuilder<String>(
            valueListenable: room,
            builder: (_, id, _) => MaterialConversationLayout(
              window: MaterialWindowClass.large,
              list: const Text('rooms'),
              detail: Text(id),
              roomId: id,
              navigator: navigator,
              routesOpen: false,
              active: true,
              onRoutesChanged: (_) {},
              onCloseSupporting: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final origin = tester.getTopLeft(find.text('A'));
      for (final id in ['B', 'C']) {
        room.value = id;
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        final detail = find.text(id);
        final fade = find
            .ancestor(of: detail, matching: find.byType(Opacity))
            .first;
        expect(tester.widget<Opacity>(fade).opacity, inExclusiveRange(0, 1));
        expect(tester.getTopLeft(detail), origin);
      }
      expect(find.text('B', skipOffstage: false), findsNothing);
      await tester.pumpAndSettle();
    },
  );

  testWidgets('desktop destination changes have a visible transition', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await _pumpApp(tester);
    final navigation = find.byKey(const ValueKey('material-navigation-rail'));
    expect(tester.getSize(navigation).width, 256);
    final indicator = find.byKey(const ValueKey('rail-indicator'));
    final startY = tester.getCenter(indicator).dy;
    final restingHeight = tester.getSize(indicator).height;
    await tester.tap(
      find.descendant(
        of: navigation,
        matching: find.byIcon(Icons.people_outline),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 64));
    final movingY = tester.getCenter(indicator).dy;
    expect(movingY, greaterThan(startY));
    expect(tester.getSize(indicator).height, greaterThan(restingHeight));
    final pane = find.byKey(const ValueKey('material-shell-content'));
    expect(
      tester.getTopLeft(find.byType(ContactsPage)).dx,
      tester.getTopLeft(pane).dx,
    );
    final fades = find.ancestor(
      of: find.byType(ContactsPage),
      matching: find.byType(Opacity),
    );
    expect(fades, findsWidgets);
    expect(tester.widget<Opacity>(fades.first).opacity, inExclusiveRange(0, 1));
    await tester.pumpAndSettle();
    expect(tester.getCenter(indicator).dy, greaterThan(movingY));
    expect(tester.getSize(indicator).height, restingHeight);
    expect(tester.widget<Opacity>(fades.first).opacity, 1);
  });
}
