import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/material_unread_pill.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/api/matrix/unread.dart' as unread;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeUnreadRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  final typingEvents = StreamController<rust.TypingNotification>.broadcast();

  List<rust.ChatMessage> messages = const [];
  List<rust.ChatRoom> rooms = const [];
  List<String> ignoredUsers = const [];
  unread.RoomUnreadState unreadState = const unread.RoomUnreadState(
    unreadCount: 0,
  );
  Completer<List<rust.ChatMessage>>? pendingGetMessages;
  Completer<unread.UnreadPage>? pendingUnreadPage;
  Future<unread.UnreadPage> Function(String? nextBatch)? unreadPageHandler;
  unread.UnreadPage unreadPageResult = const unread.UnreadPage(
    eventIds: [],
    unresolvedEventIds: [],
    reachedEnd: true,
    resetBefore: false,
  );
  int getUnreadStateCalls = 0;
  int markRoomAsReadCalls = 0;

  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() =>
      rust.ConnectionStatus.connected;

  @override
  Future<rust.UserProfile> crateApiMatrixGetProfile() async =>
      const rust.UserProfile(
        userId: '@alice:example.org',
        displayName: 'Alice',
      );

  @override
  Future<rust.IgnoredUsers> crateApiMatrixGetIgnoredUsers() async =>
      rust.IgnoredUsers(userIds: ignoredUsers, fromServer: true);

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async => rooms;

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetUngroupedRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async => const [];

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetSpaceChildren({
    required String spaceId,
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async => const [];

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) => pendingGetMessages?.future ?? Future.value(messages);

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesBefore({
    required String roomId,
    required String fromEventId,
    required int limit,
  }) async => const [];

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    markRoomAsReadCalls++;
    return true;
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async => const [];

  @override
  Future<List<String>> crateApiMatrixGetPinnedEventIds({
    required String accountUserId,
    required String roomId,
  }) async => const [];

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) async => const [];

  @override
  Future<List<rust.StickerPack>> crateApiMatrixGetStickerPacks({
    required String accountUserId,
    required String roomId,
  }) async => const [];

  @override
  Future<String> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
    String? accountUserId,
  }) async => 'typing-1';

  @override
  Future<void> crateApiMatrixUnsubscribeTyping({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {}

  @override
  Future<String> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
    String? accountUserId,
  }) async => 'receipts-1';

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {}

  @override
  Future<unread.RoomUnreadState> crateApiMatrixUnreadGetRoomUnreadState({
    required String accountUserId,
    required String roomId,
  }) async {
    getUnreadStateCalls++;
    return unreadState;
  }

  @override
  Future<unread.UnreadPage> crateApiMatrixUnreadGetUnreadPage({
    required String accountUserId,
    required String roomId,
    required String readEventId,
    required String throughEventId,
    String? nextBatch,
    required List<String> ignoredUserIds,
  }) =>
      unreadPageHandler?.call(nextBatch) ??
      pendingUnreadPage?.future ??
      Future.value(unreadPageResult);

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  @override
  Stream<rust.TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      typingEvents.stream;

  @override
  Future<rust.SessionTokenUpdate?> crateApiMatrixGetSessionTokens({
    required String accountUserId,
  }) async => null;

  @override
  Future<String?> crateApiMatrixGetAccessToken() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _msg(
  String id,
  int ts, {
  String senderId = '@bob:example.org',
  bool isMe = false,
  String? content,
}) => rust.ChatMessage(
  id: id,
  senderId: senderId,
  senderName: isMe ? 'Alice' : 'Bob',
  content: content ?? 'Message $id',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '$ts',
  isMe: isMe,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

rust.ChatRoom _room(String id, {int unreadCount = 0}) => rust.ChatRoom(
  id: id,
  name: 'Test Room',
  lastMessage: 'hi',
  lastMessageTime: '1000',
  lastEventId: r'$last',
  unreadCount: unreadCount,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: false,
  isMuted: false,
  roomState: 'joined',
);

Future<ProviderContainer> _pumpDetailPage(
  WidgetTester tester,
  _FakeUnreadRustApi rustApi, {
  required String roomId,
  Size size = const Size(420, 820),
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  final container = ProviderContainer();
  container.read(isLoggedInProvider.notifier).value = true;
  container.read(sessionReadyProvider.notifier).value = true;
  container.read(currentUserProvider.notifier).value = const CurrentUser(
    id: '@alice:example.org',
    displayName: 'Alice',
    homeserver: 'https://example.org',
  );
  container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
  addTearDown(() {
    container.dispose();
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });

  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildMaterialTheme(Brightness.dark),
        home: ChatDetailPage(
          roomId: roomId,
          roomName: 'Test Room',
          subtitle: '在线',
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pumpAndSettle();
  return container;
}

Future<void> _simulateAppBackgroundAndResume(WidgetTester tester) async {
  for (final state in const [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    await tester.pump();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeUnreadRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeUnreadRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    await rustApi.typingEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    resetIgnoredListAccountState('@alice:example.org');
    rustApi.messages = const [];
    rustApi.rooms = const [];
    rustApi.ignoredUsers = const [];
    rustApi.unreadState = const unread.RoomUnreadState(unreadCount: 0);
    rustApi.pendingGetMessages = null;
    rustApi.pendingUnreadPage = null;
    rustApi.unreadPageHandler = null;
    rustApi.unreadPageResult = const unread.UnreadPage(
      eventIds: [],
      unresolvedEventIds: [],
      reachedEnd: true,
      resetBefore: false,
    );
    rustApi.getUnreadStateCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
  });

  testWidgets(
    'LatestMessageControl clips ink to the capsule height while keeping a 48dp hit target',
    (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.dark)
              .copyWith(platform: TargetPlatform.android),
          home: Scaffold(
            body: Center(
              child: LatestMessageControl(
                visible: true,
                showSentNotice: false,
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final control = find.byType(LatestMessageControl);
      final ink = find.descendant(of: control, matching: find.byType(Ink));
      final inkWell = find.descendant(
        of: control,
        matching: find.byType(InkWell),
      );
      final controlRect = tester.getRect(control);
      final inkRect = tester.getRect(ink);
      final inkWellRect = tester.getRect(inkWell);

      expect(controlRect.height, greaterThanOrEqualTo(48));
      expect(inkWellRect, equals(inkRect));
      expect(inkRect.height, lessThan(48));

      // Tapping the outer 48dp padded band still triggers the capsule.
      await tester.tapAt(Offset(controlRect.center.dx, controlRect.top + 2));
      await tester.pump();
      expect(taps, 1);
    },
  );

  testWidgets(
    'visible unread messages at bottom do not trigger pill on open or after app resume',
    (tester) async {
      const roomId = '!visible:example.org';
      rustApi.rooms = [_room(roomId, unreadCount: 2)];
      rustApi.messages = [
        _msg(r'$1', 1000),
        _msg(r'$2', 2000),
        _msg(r'$3', 3000),
      ];
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 2,
        readEventId: r'$1',
        throughEventId: r'$3',
        boundaryResolved: true,
        unreadEventIds: [r'$2', r'$3'],
        unresolvedEventIds: [],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);

      // Messages $2 and $3 are already visible in the viewport: no pill!
      expect(find.byType(MaterialUnreadPill), findsNothing);
      expect(find.textContaining(RegExp(r'^0\s*条')), findsNothing);

      // Pause and resume app with auto-read cleared (unreadCount == 0) and a
      // new event $4 arriving in the tail. Must NOT resurrect as "0 条新消息".
      rustApi.messages = [
        _msg(r'$1', 1000),
        _msg(r'$2', 2000),
        _msg(r'$3', 3000),
        _msg(r'$4', 4000, isMe: true, senderId: '@alice:example.org'),
      ];
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 0,
        readEventId: r'$3',
        throughEventId: r'$4',
        boundaryResolved: true,
        unreadEventIds: [],
        unresolvedEventIds: [],
      );
      await _simulateAppBackgroundAndResume(tester);
      await tester.pumpAndSettle();

      expect(find.byType(MaterialUnreadPill), findsNothing);
      expect(find.textContaining(RegExp(r'^0\s*条')), findsNothing);
    },
  );

  testWidgets(
    'scrolling up after viewing bottom unread messages never resurrects the pill',
    (tester) async {
      const roomId = '!scroll-after-view:example.org';
      final msgs = List.generate(25, (i) => _msg('\$${i + 1}', (i + 1) * 1000));
      rustApi.rooms = [_room(roomId, unreadCount: 1)];
      rustApi.messages = msgs;
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 1,
        readEventId: r'$24',
        throughEventId: r'$25',
        boundaryResolved: true,
        unreadEventIds: [r'$25'],
        unresolvedEventIds: [],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);
      expect(find.byType(MaterialUnreadPill), findsNothing);

      // Scroll up far enough that $25 goes above the top of the viewport.
      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();

      expect(find.byType(MaterialUnreadPill), findsNothing);
    },
  );

  testWidgets(
    'room with only ignored unread candidates never shows pill or 暂无可定位的未读',
    (tester) async {
      const roomId = '!ignored:example.org';
      rustApi.rooms = [_room(roomId, unreadCount: 1)];
      rustApi.ignoredUsers = const ['@spammer:example.org'];
      rustApi.messages = [
        _msg(r'$1', 1000),
        _msg(r'$spam', 2000, senderId: '@spammer:example.org'),
      ];
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 1,
        readEventId: r'$1',
        throughEventId: r'$spam',
        boundaryResolved: true,
        unreadEventIds: [r'$spam'],
        unresolvedEventIds: [],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);

      expect(find.byType(MaterialUnreadPill), findsNothing);
      expect(find.textContaining('暂无可定位'), findsNothing);
      expect(find.textContaining(RegExp(r'^0\s*条')), findsNothing);
    },
  );

  testWidgets(
    'off-screen unread messages show pill with real count and never drop to 0 条新消息 on resume',
    (tester) async {
      const roomId = '!offscreen:example.org';
      // 30 messages so $2 (earliest unread) is well above the 820px viewport.
      final msgs = List.generate(30, (i) => _msg('\$${i + 1}', (i + 1) * 1000));
      rustApi.rooms = [_room(roomId, unreadCount: 29)];
      rustApi.messages = msgs;
      rustApi.unreadState = unread.RoomUnreadState(
        unreadCount: 29,
        readEventId: r'$1',
        throughEventId: r'$30',
        boundaryResolved: true,
        unreadEventIds: [for (var i = 2; i <= 30; i++) '\$$i'],
        unresolvedEventIds: const [],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);

      expect(find.byType(MaterialUnreadPill), findsOneWidget);
      expect(find.text('29 条新消息'), findsOneWidget);

      // Simulate app background -> foreground where auto-read zeroed unreadCount
      // and a new message arrived, while getUnreadPage is still loading.
      final pageCompleter = Completer<unread.UnreadPage>();
      rustApi.pendingUnreadPage = pageCompleter;
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 0,
        readEventId: r'$30',
        throughEventId: r'$31',
        boundaryResolved: true,
      );
      rustApi.messages = [...msgs, _msg(r'$31', 31000)];

      await _simulateAppBackgroundAndResume(tester);
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.textContaining(RegExp(r'^0\s*条')), findsNothing);
      expect(find.byType(MaterialUnreadPill), findsOneWidget);
      expect(find.text('29 条新消息'), findsOneWidget);

      // Complete the extension page with $31.
      pageCompleter.complete(
        unread.UnreadPage(
          eventIds: [for (var i = 2; i <= 31; i++) '\$$i'],
          unresolvedEventIds: const [],
          reachedEnd: true,
          resetBefore: false,
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('30 条新消息'), findsOneWidget);
      expect(find.textContaining(RegExp(r'^0\s*条')), findsNothing);
    },
  );

  testWidgets(
    'unresolved event after visible bottom unread target still clears and does not resurrect on scroll',
    (tester) async {
      const roomId = '!utd-after:example.org';
      final msgs = List.generate(
        25,
        (i) => _msg(
          '\$${i + 1}',
          (i + 1) * 1000,
          content: i == 24 ? unableToDecryptMessageContent : null,
        ),
      );
      rustApi.rooms = [_room(roomId, unreadCount: 2)];
      rustApi.messages = msgs;
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 2,
        readEventId: r'$23',
        throughEventId: r'$25',
        boundaryResolved: true,
        unreadEventIds: [r'$24', r'$25'],
        unresolvedEventIds: [r'$25'],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);
      expect(find.byType(MaterialUnreadPill), findsNothing);

      await tester.drag(find.byType(CustomScrollView), const Offset(0, 600));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialUnreadPill), findsNothing);
    },
  );

  testWidgets(
    'tapping 30 unread pill in a 120-message room jumps to exact first unread message',
    (tester) async {
      const roomId = '!jump-exact:example.org';
      final msgs = List.generate(
        120,
        (i) => _msg(
          '\$${i + 1}',
          (i + 1) * 1000,
          senderId: i.isEven ? '@bob:example.org' : '@carol:example.org',
        ),
      );
      rustApi.rooms = [_room(roomId, unreadCount: 30)];
      rustApi.messages = msgs;
      rustApi.unreadState = unread.RoomUnreadState(
        unreadCount: 30,
        readEventId: r'$90',
        throughEventId: r'$120',
        boundaryResolved: true,
        unreadEventIds: [for (var i = 91; i <= 120; i++) '\$$i'],
        unresolvedEventIds: const [],
      );

      await _pumpDetailPage(tester, rustApi, roomId: roomId);

      expect(find.byType(MaterialUnreadPill), findsOneWidget);
      expect(find.text('30 条新消息'), findsOneWidget);

      await tester.tap(find.text('30 条新消息'));
      await tester.pumpAndSettle();

      // Landed on $91 (30th from bottom), NOT $21 (100th from bottom).
      expect(find.text(r'Message $91'), findsOneWidget);
      expect(find.text(r'Message $21'), findsNothing);
      expect(find.byType(MaterialUnreadPill), findsNothing);
    },
  );

  testWidgets(
    'multi-page unread scan resets stale earlier page when own-message boundary appears on page 2',
    (tester) async {
      const roomId = '!reset-page2:example.org';
      final msgs = List.generate(
        120,
        (i) => _msg(
          '\$${i + 1}',
          (i + 1) * 1000,
          senderId: i == 89 ? '@alice:example.org' : '@bob:example.org',
          isMe: i == 89,
        ),
      );
      rustApi.rooms = [_room(roomId, unreadCount: 30)];
      rustApi.messages = msgs;
      rustApi.unreadState = const unread.RoomUnreadState(
        unreadCount: 30,
        readEventId: r'$20',
        throughEventId: r'$120',
        boundaryResolved: false,
      );
      rustApi.unreadPageHandler = (nextBatch) async {
        if (nextBatch == null) {
          return unread.UnreadPage(
            eventIds: [for (var i = 21; i <= 70; i++) '\$$i'],
            unresolvedEventIds: const [],
            nextBatch: 'page-2',
            reachedEnd: false,
            resetBefore: false,
          );
        }
        return unread.UnreadPage(
          eventIds: [for (var i = 91; i <= 120; i++) '\$$i'],
          unresolvedEventIds: const [],
          nextBatch: null,
          reachedEnd: true,
          resetBefore: true,
          boundaryResolved: true,
        );
      };

      await _pumpDetailPage(tester, rustApi, roomId: roomId);

      expect(find.byType(MaterialUnreadPill), findsOneWidget);
      expect(find.text('30 条新消息'), findsOneWidget);

      await tester.tap(find.text('30 条新消息'));
      await tester.pumpAndSettle();

      expect(find.text(r'Message $91'), findsOneWidget);
      expect(find.text(r'Message $21'), findsNothing);
      expect(find.byType(MaterialUnreadPill), findsNothing);
    },
  );
}
