import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/space_detail_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:matter/widgets/app_avatar.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  final linkedRooms = <(String, String)>[];
  @override
  Future<String> crateApiMatrixCreateGroupRoom({
    required String accountUserId,
    required String name,
    String? topic,
  }) async => '!new:example.org';
  @override
  Future<void> crateApiMatrixAddRoomToSpace({
    required String accountUserId,
    required String spaceId,
    required String roomId,
  }) async {
    linkedRooms.add((spaceId, roomId));
  }

  @override
  Future<void> crateApiMatrixUpdateSpaceDetails({
    required String accountUserId,
    required String spaceId,
    required String name,
    String? topic,
  }) async {
    throw StateError('空间名称已更新，但主题更新失败');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  const spaceId = '!space:example.org';
  var detailsName = '旧名称';
  var detailsCalls = 0;

  final api = _FakeRustApi();
  setUpAll(() {
    RustLib.initMock(api: api);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    detailsName = '旧名称';
    detailsCalls = 0;
  });

  testWidgets('partial detail update refreshes the visible space details', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        spaceDetailsProvider.overrideWith((ref, id) async {
          detailsCalls++;
          return rust.SpaceDetails(id: id, name: detailsName);
        }),
        spaceChildrenProvider.overrideWith((ref, id) async => const []),
        roomMembersProvider.overrideWith((ref, id) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(sessionReadyProvider.notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const SpaceDetailPage(
            space: rust.Space(id: spaceId, name: '旧名称'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(detailsCalls, 1);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑空间').last);
    await tester.pumpAndSettle();

    detailsName = '新名称';
    await tester.enterText(find.byType(TextField).first, detailsName);
    await tester.tap(find.widgetWithText(NeuButton, '保存'));
    await tester.pumpAndSettle();

    expect(detailsCalls, 2);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == detailsName,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('空间名称已更新'), findsOneWidget);
  });

  testWidgets(
    'Material space keeps room actions and readable member identities',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const room = rust.ChatRoom(
        id: '!room:example.org',
        name: '项目讨论房间',
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
      final container = ProviderContainer(
        overrides: [
          spaceDetailsProvider.overrideWith(
            (ref, id) async => rust.SpaceDetails(id: id, name: '项目空间'),
          ),
          spaceChildrenProvider.overrideWith((ref, id) async => const [room]),
          allSpaceChildrenProvider.overrideWith(
            (ref, id) async => const [room],
          ),
          roomMembersProvider.overrideWith(
            (ref, id) async => const [
              rust.Contact(
                id: '@long-member-id:example.org',
                roomRole: rust.MemberRole.administrator,
                name: '项目成员名称',
                status: 'online',
              ),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(sessionReadyProvider.notifier).value = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(material: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.4)),
              child: child!,
            ),
            home: const SpaceDetailPage(
              space: rust.Space(id: spaceId, name: '项目空间'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('项目讨论房间'), findsOneWidget);
      expect(
        find.byKey(
          const ValueKey('space-child-unread-badge:!room:example.org'),
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('新建房间'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, '房间名称'), '讨论');
      await tester.pump();
      await tester.tap(find.text('创建'));
      await tester.pumpAndSettle();
      expect(api.linkedRooms, [(spaceId, '!new:example.org')]);
      expect(find.text('未读 3'), findsOneWidget);
      expect(find.text('空间详情'), findsNothing);
      await tester.tap(find.byTooltip('房间操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('从空间移除'));
      await tester.pumpAndSettle();
      expect(find.text('移出空间'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('成员'));
      await tester.pumpAndSettle();
      expect(find.text('@long-member-id:example.org'), findsOneWidget);
      expect(find.text('管理员'), findsOneWidget);
      expect(
        tester
            .widget<AppAvatar>(
              find.byWidgetPredicate(
                (w) => w is AppAvatar && w.fallback == '项目成员名称',
              ),
            )
            .size,
        44,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
