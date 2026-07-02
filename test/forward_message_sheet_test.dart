import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/forward_message_sheet.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/theme/app_theme.dart';

rust.ChatRoom _room(
  String id,
  String name, {
  String type = 'group',
  String state = 'joined',
}) => rust.ChatRoom(
  id: id,
  name: name,
  lastMessage: '',
  lastMessageTime: '0',
  unreadCount: 0,
  roomType: type,
  isEncrypted: false,
  roomState: state,
);

final _message = rust.ChatMessage(
  id: r'$event:example.org',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: '你好',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '0',
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

void main() {
  test(
    'forwardableRooms includes only joined conversations and searches names',
    () {
      final rooms = [
        _room('!alpha:example.org', 'Alpha'),
        _room('!beta:example.org', 'Beta'),
        _room('!space:example.org', 'Alpha Space', type: 'space'),
        _room('!invite:example.org', 'Alpha Invite', state: 'invited'),
      ];

      expect(forwardableRooms(rooms, 'ALP').map((room) => room.id), [
        '!alpha:example.org',
      ]);
    },
  );

  testWidgets('selecting a room sends the message and closes the sheet', (
    tester,
  ) async {
    String? forwardedTargetRoomId;
    await _pumpLauncher(
      tester,
      rooms: [_room('!target:example.org', '目标会话')],
      sender:
          ({
            required sourceRoomId,
            required targetRoomId,
            required message,
          }) async {
            expect(sourceRoomId, '!source:example.org');
            expect(message, _message);
            forwardedTargetRoomId = targetRoomId;
          },
    );

    await tester.tap(find.text('打开转发'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('forward-room-!target:example.org')),
    );
    await tester.pumpAndSettle();

    expect(forwardedTargetRoomId, '!target:example.org');
    expect(find.text('转发到'), findsNothing);
  });

  testWidgets(
    'an empty room list shows the empty-state message and no tappable rooms',
    (tester) async {
      await _pumpLauncher(tester, rooms: const [], sender: _noopSender);

      await tester.tap(find.text('打开转发'));
      await tester.pumpAndSettle();

      expect(find.text('暂无可转发的会话'), findsOneWidget);
      expect(find.byType(ListTile), findsNothing);
    },
  );

  testWidgets('a search with no matches shows the no-match message', (
    tester,
  ) async {
    await _pumpLauncher(
      tester,
      rooms: [_room('!target:example.org', '目标会话')],
      sender: _noopSender,
    );

    await tester.tap(find.text('打开转发'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const ValueKey('forward-room-search')),
      '不存在的会话',
    );
    await tester.pumpAndSettle();

    expect(find.text('未找到会话'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });

  testWidgets('a send failure leaves the sheet open and shows the error', (
    tester,
  ) async {
    await _pumpLauncher(
      tester,
      rooms: [_room('!target:example.org', '目标会话')],
      sender:
          ({
            required sourceRoomId,
            required targetRoomId,
            required message,
          }) async {
            throw Exception('网络不可用');
          },
    );

    await tester.tap(find.text('打开转发'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const ValueKey('forward-room-!target:example.org')),
    );
    await tester.pump();

    expect(find.text('转发到'), findsOneWidget);
    expect(find.textContaining('转发失败'), findsOneWidget);
    expect(find.textContaining('网络不可用'), findsOneWidget);
  });

  testWidgets('success notice clears the input and centers its content', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var tapped = false;

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              const Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 80,
                child: SizedBox(key: ValueKey('message-input')),
              ),
              ForwardSuccessNoticeOverlay(
                bottomInset: 80,
                roomName: '目标会话',
                onRoomTap: () => tapped = true,
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('成功转发到'), findsOneWidget);
    expect(find.text('目标会话'), findsOneWidget);
    final inputRect = tester.getRect(
      find.byKey(const ValueKey('message-input')),
    );
    final noticeRect = tester.getRect(
      find.byKey(const ValueKey('forward-success-notice-surface')),
    );
    final noticeMaterial = tester.widget<Material>(
      find.byKey(const ValueKey('forward-success-notice-surface')),
    );
    final textRect = tester
        .getRect(find.text('成功转发到'))
        .expandToInclude(tester.getRect(find.text('目标会话')));
    expect(noticeRect.bottom, lessThanOrEqualTo(inputRect.top - 12));
    expect(noticeRect.center.dx, closeTo(200, 0.5));
    expect(textRect.center.dx, closeTo(200, 0.5));
    expect(noticeMaterial.borderRadius, BorderRadius.circular(AppRadii.button));

    await tester.tap(find.byKey(const ValueKey('forward-success-room-link')));
    await tester.pump();
    expect(tapped, isTrue);
  });
}

Future<void> _pumpLauncher(
  WidgetTester tester, {
  required List<rust.ChatRoom> rooms,
  required ForwardMessageSender sender,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [chatRoomsProvider.overrideWith((ref) async => rooms)],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showModalBottomSheet<rust.ChatRoom>(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (_) => ForwardMessageSheet(
                  sourceRoomId: '!source:example.org',
                  message: _message,
                  sender: sender,
                ),
              ),
              child: const Text('打开转发'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _noopSender({
  required String sourceRoomId,
  required String targetRoomId,
  required rust.ChatMessage message,
}) async {}
