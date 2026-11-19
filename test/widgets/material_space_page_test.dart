import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/chat_list_item.dart';
import 'package:matter/pages/chat/material_space_content.dart';
import 'package:matter/pages/chat/space_detail_page.dart';
import 'package:matter/pages/chat/space_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/providers/startup_page_provider.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../helpers/neu_test_theme.dart';

class _RustApi implements RustLibApi {
  List<rust.Space> spaces = [];
  final creations = <({String account, String name, String? topic})>[];
  final joins = <({String account, String identifier})>[];

  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  Future<String> crateApiMatrixCreateSpace({
    required String accountUserId,
    required String name,
    String? topic,
  }) async {
    creations.add((account: accountUserId, name: name, topic: topic));
    spaces = [...spaces, rust.Space(id: '!created:example.org', name: name)];
    return '!created:example.org';
  }

  @override
  Future<String> crateApiMatrixJoinRoom({
    required String accountUserId,
    required String identifier,
  }) async {
    joins.add((account: accountUserId, identifier: identifier));
    spaces = [
      ...spaces,
      const rust.Space(id: '!joined:example.org', name: '社区空间'),
    ];
    return '!joined:example.org';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

const _room = rust.ChatRoom(
  id: '!room:example.org',
  name: '讨论房间',
  lastMessage: '最近的讨论',
  lastMessageTime: '0',
  lastEventId: '',
  unreadCount: 3,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: false,
  isMuted: false,
  roomState: 'joined',
);

Future<void> _pumpPage(
  WidgetTester tester,
  _RustApi api, {
  double width = 320,
  bool dark = true,
  bool material = true,
  double textScale = 1,
  bool fullApp = false,
  GlobalKey? boundaryKey,
  TargetPlatform? platform,
  List<rust.ChatRoom> rooms = const [],
}) async {
  await tester.binding.setSurfaceSize(Size(width, 700));
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 700);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer(
    overrides: [
      spacesProvider.overrideWith((ref) async => api.spaces),
      allChatRoomsProvider.overrideWith((ref) async => []),
      syncStreamProvider.overrideWith((ref) => null),
      ungroupedRoomsProvider.overrideWith((ref) async => rooms),
      spaceDetailsProvider.overrideWith(
        (ref, id) async => rust.SpaceDetails(
          id: id,
          name: api.spaces.firstWhere((space) => space.id == id).name,
        ),
      ),
      spaceChildrenProvider.overrideWith((ref, id) async => []),
      allSpaceChildrenProvider.overrideWith((ref, id) async => []),
      roomMembersProvider.overrideWith((ref, id) async => []),
    ],
  );
  addTearDown(container.dispose);
  container.read(activeUserIdProvider.notifier).value = '@me:example.org';
  if (fullApp) {
    await container
        .read(startupPageProvider.notifier)
        .setPage(StartupPage.spaces);
    container.read(navigationIndexProvider.notifier).value = 1;
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: neuTestTheme(
          dark: dark,
          material: material,
        ).copyWith(platform: platform),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: RepaintBoundary(
          key: boundaryKey,
          child: fullApp ? const MatterApp() : const SpacePage(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  final api = _RustApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.spaces = [];
    api.creations.clear();
    api.joins.clear();
    SharedPreferences.setMockInitialValues({});
  });

  for (final dark in [false, true]) {
    for (final width in [320.0, 1000.0]) {
      testWidgets(
        'Material directory adapts cards and separates rooms at $width, dark=$dark',
        (tester) async {
          api.spaces = [
            for (var i = 0; i < 4; i++)
              rust.Space(id: '!space$i:example.org', name: '空间 $i'),
          ];
          await _pumpPage(
            tester,
            api,
            width: width,
            dark: dark,
            rooms: [_room],
          );
          final first = tester.getRect(
            find.byKey(const ValueKey('!space0:example.org')),
          );
          final second = tester.getRect(
            find.byKey(const ValueKey('!space1:example.org')),
          );
          expect(first.left, closeTo(width == 320 ? 16 : 20, .1));
          expect(first.top, greaterThanOrEqualTo(kToolbarHeight));
          if (width == 320) {
            expect(second.top, greaterThan(first.bottom));
            expect(second.left, first.left);
          } else {
            expect(second.top, first.top);
            expect(second.left, greaterThan(first.right));
          }
          expect(find.text('用于组织房间和成员，不直接作为聊天入口'), findsNothing);
          expect(find.text('查看房间、成员和空间设置'), findsNothing);
          expect(find.text('其他房间'), findsOneWidget);
          expect(find.text('最近的讨论'), findsOneWidget);
          expect(
            find.byKey(ValueKey('room-unread-badge:${_room.id}')),
            findsOneWidget,
          );
          expect(
            find.ancestor(
              of: find.byType(ChatListItem),
              matching: find.byType(Card),
            ),
            findsNothing,
          );
          expect(find.byTooltip('添加空间'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final width in [320.0, 1200.0]) {
    testWidgets(
      'Linux populated space directory clears the actual header at $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 700);
        tester.view.padding = const FakeViewPadding(top: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24);
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        api.spaces = [
          for (var i = 0; i < 8; i++)
            rust.Space(id: '!space$i:example.org', name: '空间 $i'),
        ];
        final boundaryKey = GlobalKey();
        await _pumpPage(
          tester,
          api,
          width: width,
          fullApp: true,
          boundaryKey: boundaryKey,
          platform: TargetPlatform.linux,
        );
        final header = tester.getRect(find.byType(AppBar));
        final first = tester.getRect(
          find.byKey(const ValueKey('!space0:example.org')),
        );
        expect(first.top, greaterThanOrEqualTo(header.bottom + 16));
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          try {
            return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          } finally {
            image.dispose();
          }
        });
        final x = (first.left + 24).toInt();
        final y = (header.bottom - 4).toInt();
        final offset = (y * width.toInt() + x) * 4;
        final actual = Color.fromARGB(
          pixels!.getUint8(offset + 3),
          pixels.getUint8(offset),
          pixels.getUint8(offset + 1),
          pixels.getUint8(offset + 2),
        );
        final colors = Theme.of(tester.element(find.byType(AppBar)))
            .extension<NeuColors>()!;
        // The toolbar is a fade, not a flat fill: it is near-opaque behind the
        // title and releases to zero at its bottom edge so rows do not get cut
        // off by a hard line. The pixel here is in that tail, so it is no
        // longer the full glassFill; what must hold is that the toolbar still
        // tints the page rather than showing the raw backdrop.
        final opaque = Color.alphaBlend(colors.glassFill, colors.base);
        final bare = colors.base;
        double distance(Color a, Color b) => (a.r - b.r).abs();
        expect(
          distance(actual, bare),
          lessThan(distance(opaque, bare)),
          reason: 'header should tint the page, fading towards its bottom',
        );

        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  for (final layout in [
    (width: 320.0, bottom: 0.0, fullApp: true),
    (width: 400.0, bottom: 34.0, fullApp: true),
    (width: 1200.0, bottom: 34.0, fullApp: true),
    (width: 320.0, bottom: 34.0, fullApp: false),
  ]) {
    testWidgets('space add menu remains reachable at $layout', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.padding = FakeViewPadding(bottom: layout.bottom);
      tester.view.viewPadding = FakeViewPadding(bottom: layout.bottom);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      api.spaces = [const rust.Space(id: '!space:example.org', name: '工作空间')];
      await _pumpPage(
        tester,
        api,
        width: layout.width,
        fullApp: layout.fullApp,
      );
      final fab = find.byType(FloatingActionButton);
      // The dock draws its own destinations, and Scaffold measures it as the
      // bottom navigation. The FAB sits above whatever the Scaffold reserved,
      // so ask the Scaffold for that rather than reading the bar's own top:
      // the bar is inset from that edge by the dock's safe-area padding.
      final navigation = find.byType(MaterialTabNavigationBar);
      // On a phone the dock floats, inset from the Scaffold's reserved edge by
      // its own safe-area padding, so the FAB clears the bar's top by the
      // floating margin plus that inset. A narrow desktop layout has no dock,
      // and the FAB clears the window edge instead.
      final hasDock = navigation.evaluate().isNotEmpty;
      final expected = hasDock
          ? tester.getTopLeft(navigation).dy - kFloatingActionButtonMargin - 8
          : 700 - layout.bottom - 16;
      expect(tester.getBottomLeft(fab).dy, closeTo(expected, .1));
      await tester.tap(fab);
      await tester.pumpAndSettle();
      expect(find.text('创建空间'), findsOneWidget);
      expect(find.text('加入空间'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('long space names fit a narrow directory with enlarged text', (
    tester,
  ) async {
    api.spaces = [
      const rust.Space(id: '!space:example.org', name: '这是一个名称很长的工作与社区讨论空间'),
    ];
    await _pumpPage(tester, api, textScale: 2);
    final name = tester.widget<Text>(find.text(api.spaces.single.name));
    expect(name.maxLines, 2);
    expect(name.overflow, TextOverflow.ellipsis);
    expect(find.byType(Card), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'empty create action and populated add menu refresh the directory',
    (tester) async {
      await _pumpPage(tester, api, fullApp: true, rooms: [_room]);
      expect(find.text('还没有加入空间'), findsOneWidget);
      expect(find.text('其他房间'), findsOneWidget);
      expect(find.byTooltip('添加空间'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, '创建空间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, '研发小组');
      await tester.enterText(find.byType(TextField).last, '研发讨论');
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(api.creations.single, (
        account: '@me:example.org',
        name: '研发小组',
        topic: '研发讨论',
      ));
      expect(
        find.byKey(const ValueKey('!created:example.org')),
        findsOneWidget,
      );
      expect(find.text('还没有加入空间'), findsNothing);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('加入空间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '#community:example.org');
      await tester.tap(find.text('加入'));
      await tester.pumpAndSettle();
      expect(api.joins.single, (
        account: '@me:example.org',
        identifier: '#community:example.org',
      ));
      expect(find.byKey(const ValueKey('!joined:example.org')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('empty join action opens the existing join flow', (tester) async {
    await _pumpPage(tester, api);
    expect(find.text('其他房间'), findsNothing);
    await tester.tap(find.widgetWithText(OutlinedButton, '加入空间'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '!community:example.org');
    await tester.tap(find.text('加入'));
    await tester.pumpAndSettle();
    expect(api.joins.single, (
      account: '@me:example.org',
      identifier: '!community:example.org',
    ));
    expect(find.byKey(const ValueKey('!joined:example.org')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a space card opens its details and room information is reachable',
    (tester) async {
      api.spaces = [const rust.Space(id: '!space:example.org', name: '工作空间')];
      await _pumpPage(tester, api, rooms: [_room]);
      await tester.tap(find.byTooltip('关于其他房间'));
      await tester.pumpAndSettle();
      expect(find.text('这些房间当前不属于任何已加入空间。'), findsOneWidget);
      await tester.tap(find.text('知道了'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('!space:example.org')));
      await tester.pumpAndSettle();
      expect(
        tester.widget<SpaceDetailPage>(find.byType(SpaceDetailPage)).space.id,
        '!space:example.org',
      );
      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialSpaceContent), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('Neu retains its grouped surfaces and original add action', (
    tester,
  ) async {
    api.spaces = [const rust.Space(id: '!space:example.org', name: '工作空间')];
    await _pumpPage(tester, api, material: false, rooms: [_room]);
    expect(find.byType(MaterialSpaceContent), findsNothing);
    expect(find.text('用于组织房间和成员，不直接作为聊天入口'), findsOneWidget);
    expect(find.text('查看房间、成员和空间设置'), findsOneWidget);
    expect(find.text('未归属群组'), findsOneWidget);
    expect(find.byTooltip('新建空间'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
