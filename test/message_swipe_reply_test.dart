import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_group.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  int togglePinnedCalls = 0;
  String? lastToggleRoomId;
  String? lastToggleEventId;
  bool toggleResult = false;
  Object? toggleError;
  Completer<bool>? pendingToggle;
  int pinnedIdsCalls = 0;
  List<String> pinnedIds = const [];
  Object? pinnedIdsError;
  Completer<List<String>>? pendingPinnedIds;

  @override
  Future<List<String>> crateApiMatrixGetPinnedEventIds({
    required String accountUserId,
    required String roomId,
  }) async {
    pinnedIdsCalls++;
    if (pinnedIdsError case final error?) throw error;
    if (pendingPinnedIds case final pending?) return pending.future;
    return pinnedIds;
  }

  @override
  Future<bool> crateApiMatrixSetPinnedMessage({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required bool pinned,
  }) async {
    togglePinnedCalls++;
    lastToggleRoomId = roomId;
    lastToggleEventId = eventId;
    if (toggleError case final error?) throw error;
    if (pendingToggle case final pending?) return pending.future;
    return toggleResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

const _roomId = '!room:example.org';
const _roomAccountKey = (roomId: _roomId, userId: 'anonymous');

ChatMessage _message({
  required String id,
  required bool isMe,
  String? inReplyTo,
}) => ChatMessage(
  id: id,
  senderId: isMe ? '@me:example.org' : '@alice:example.org',
  senderName: isMe ? '我' : 'Alice',
  content: '测试消息',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '100',
  isMe: isMe,
  msgType: MessageType.text,
  inReplyTo: inReplyTo,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Widget _buildSubject({
  required ProviderContainer container,
  required ChatMessage message,
  VoidCallback? onReplyRequested,
  ValueChanged<String>? onMentionRequested,
  ValueChanged<String>? onMessageJumpRequested,
  bool showAvatar = false,
}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: neuTestTheme(),
      home: Scaffold(
        body: MessageGroupWidget(
          group: MessageGroup(
            senderId: message.senderId,
            senderName: message.senderName,
            isMe: message.isMe,
            messages: [message],
          ),
          roomId: _roomId,
          messageIndex: {message.id: message},
          showAvatar: showAvatar,
          onReplyRequested: onReplyRequested,
          onMentionRequested: onMentionRequested,
          onMessageJumpRequested: onMessageJumpRequested,
        ),
      ),
    ),
  );
}

void main() {
  late _FakeRustApi api;

  setUpAll(() {
    api = _FakeRustApi();
    RustLib.initMock(api: api);
  });

  tearDownAll(RustLib.dispose);

  testWidgets('message menu only shows pin for an unpinned message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-toggle', isMe: false);
    api.pinnedIds = const [];

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-toggle')),
    );
    await tester.pumpAndSettle();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('取消置顶'), findsNothing);
  });

  testWidgets('message menu stays usable while pin state is loading', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-loading', isMe: false);
    api.pendingPinnedIds = Completer<List<String>>();
    addTearDown(() => api.pendingPinnedIds = null);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-loading')),
    );
    await tester.pump();

    expect(find.text('回复'), findsOneWidget);
    expect(find.text('置顶'), findsNothing);
    expect(find.text('取消置顶'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    api.pendingPinnedIds!.complete(const []);
    await tester.pumpAndSettle();

    expect(find.text('置顶'), findsOneWidget);
    expect(find.text('取消置顶'), findsNothing);
  });

  testWidgets('pinning from the message menu calls the toggle', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-action', isMe: false);
    api.togglePinnedCalls = 0;
    api.toggleError = null;
    api.toggleResult = true;
    api.pinnedIds = const [];

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-action')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();

    expect(api.togglePinnedCalls, 1);
    expect(api.lastToggleRoomId, _roomId);
    expect(api.lastToggleEventId, r'$pin-action');
    // The menu reports the post-write server state.
    expect(find.text('消息已置顶'), findsOneWidget);
  });

  testWidgets('the message menu unpins an already-pinned message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-action', isMe: false);
    api.togglePinnedCalls = 0;
    api.toggleError = null;
    api.toggleResult = false;
    api.pinnedIds = [r'$pin-action'];

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-action')),
    );
    await tester.pumpAndSettle();

    expect(find.text('置顶'), findsNothing);
    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();

    // The server state decides the target: pinned -> unpin, reported as such.
    expect(api.togglePinnedCalls, 1);
    expect(api.lastToggleEventId, r'$pin-action');
    expect(find.text('已取消置顶'), findsOneWidget);
    expect(find.text('消息已置顶'), findsNothing);
  });

  testWidgets('a failed authoritative pin read does not write stale intent', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-read-fail', isMe: false);
    api.togglePinnedCalls = 0;
    api.pinnedIdsError = StateError('authoritative read failed');
    addTearDown(() => api.pinnedIdsError = null);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-read-fail')),
    );
    await tester.pumpAndSettle();

    expect(api.togglePinnedCalls, 0);
    expect(find.text('置顶'), findsNothing);
    expect(find.text('取消置顶'), findsNothing);
  });

  testWidgets('a failed pin action surfaces the error', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-fail', isMe: false);
    api.togglePinnedCalls = 0;
    api.toggleError = StateError('offline');
    api.pinnedIds = const [];

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-fail')),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('置顶'));
    await tester.pumpAndSettle();

    expect(api.togglePinnedCalls, 1);
    // Non-timeout failures go through the shared actionFailureMessage
    // wording.
    expect(find.textContaining('操作失败:'), findsOneWidget);
  });

  testWidgets('pin completion does not use a disposed message ref', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$pin-after-dispose', isMe: false);
    api.toggleError = null;
    api.toggleResult = true;
    api.pinnedIds = const [];
    api.pendingToggle = Completer<bool>();
    addTearDown(() => api.pendingToggle = null);
    var showMessage = true;
    late StateSetter updateHost;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                updateHost = setState;
                if (!showMessage) return const SizedBox.shrink();
                return MessageGroupWidget(
                  group: MessageGroup(
                    senderId: message.senderId,
                    senderName: message.senderName,
                    isMe: false,
                    messages: [message],
                  ),
                  roomId: _roomId,
                  messageIndex: {message.id: message},
                  showAvatar: false,
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.longPress(
      find.byKey(const ValueKey(r'text-bubble:$pin-after-dispose')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('置顶'));
    await tester.pump();

    updateHost(() => showMessage = false);
    await tester.pump();
    api.pendingToggle!.complete(true);
    await tester.pumpAndSettle();

    expect(find.textContaining('操作失败:'), findsNothing);
    expect(find.text('消息已置顶'), findsOneWidget);
  });

  testWidgets('long-pressing a sender avatar requests a mention', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$avatar-mention', isMe: false);
    String? mentionedUserId;

    await tester.pumpWidget(
      _buildSubject(
        container: container,
        message: message,
        showAvatar: true,
        onMentionRequested: (userId) => mentionedUserId = userId,
      ),
    );

    await tester.longPress(find.byKey(const ValueKey('message-sender-avatar')));

    expect(mentionedUserId, '@alice:example.org');
  });

  testWidgets('tapping a reply preview requests its original message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final original = _message(id: r'$original', isMe: false);
    final reply = _message(
      id: r'$reply-preview',
      isMe: false,
      inReplyTo: original.id,
    );
    String? targetMessageId;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: MessageGroupWidget(
              group: MessageGroup(
                senderId: reply.senderId,
                senderName: reply.senderName,
                isMe: false,
                messages: [reply],
              ),
              roomId: _roomId,
              messageIndex: {original.id: original, reply.id: reply},
              showAvatar: false,
              onMessageJumpRequested: (messageId) =>
                  targetMessageId = messageId,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey(r'reply-preview:$original')));

    expect(targetMessageId, original.id);
  });

  testWidgets('left swipe past threshold starts a reply to another user', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$incoming', isMe: false);
    var replyRequests = 0;

    await tester.pumpWidget(
      _buildSubject(
        container: container,
        message: message,
        onReplyRequested: () => replyRequests++,
      ),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$incoming')),
      const Offset(-70, 0),
    );
    await tester.pump();

    expect(container.read(replyingToProvider(_roomAccountKey)), message);
    expect(replyRequests, 1);
  });

  testWidgets('left swipe below threshold does not start a reply', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$short', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$short')),
      const Offset(-30, 0),
    );
    await tester.pumpAndSettle();

    expect(container.read(replyingToProvider(_roomAccountKey)), isNull);
  });

  testWidgets('left swipe can start from empty space in the message row', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$full-row', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    final swipeTarget = find.byKey(const ValueKey(r'swipe-reply:$full-row'));
    final targetRect = tester.getRect(swipeTarget);
    final bubbleRect = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$full-row')),
    );
    final emptySpaceStart = Offset(targetRect.right - 48, targetRect.center.dy);

    expect(targetRect.width, greaterThan(bubbleRect.width + 100));
    expect(emptySpaceStart.dx, greaterThan(bubbleRect.right));

    final gesture = await tester.startGesture(emptySpaceStart);
    await gesture.moveBy(const Offset(-70, 0));
    await gesture.up();
    await tester.pump();

    expect(container.read(replyingToProvider(_roomAccountKey)), message);
  });

  testWidgets('left swipe cannot start from the rightmost 40dp', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$right-edge', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    final swipeTarget = find.byKey(const ValueKey(r'swipe-reply:$right-edge'));
    final targetRect = tester.getRect(swipeTarget);
    final gesture = await tester.startGesture(
      Offset(targetRect.right - 20, targetRect.center.dy),
    );
    await gesture.moveBy(const Offset(-70, 0));
    await gesture.up();
    await tester.pump();

    expect(container.read(replyingToProvider(_roomAccountKey)), isNull);
    final contentTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')),
    );
    expect(contentTransform.transform.storage[12], 0);
  });

  testWidgets('own synced messages can also be swiped to reply', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$mine', isMe: true);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    await tester.drag(
      find.byKey(const ValueKey(r'swipe-reply:$mine')),
      const Offset(-70, 0),
    );
    await tester.pump();

    expect(container.read(replyingToProvider(_roomAccountKey)), message);
  });

  testWidgets('reply icon animates in on the right while swiping', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$animated', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message),
    );

    final swipeTarget = find.byKey(const ValueKey(r'swipe-reply:$animated'));
    final gesture = await tester.startGesture(tester.getCenter(swipeTarget));
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final icon = find.descendant(
      of: swipeTarget,
      matching: find.byIcon(Icons.reply_rounded),
    );
    final opacity = tester.widget<Opacity>(
      find.ancestor(of: icon, matching: find.byType(Opacity)),
    );
    final scale = tester.widget<Transform>(
      find.ancestor(of: icon, matching: find.byType(Transform)).first,
    );
    final contentTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')),
    );

    expect(icon, findsOneWidget);
    expect(opacity.opacity, greaterThan(0));
    expect(scale.transform.storage[0], greaterThan(0.72));
    expect(contentTransform.transform.storage[12], lessThan(0));

    await gesture.up();
    await tester.pumpAndSettle();

    final settledTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')),
    );
    expect(settledTransform.transform.storage[12], 0);
  });

  testWidgets('avatar at its default position moves with the message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final message = _message(id: r'$avatar-default', isMe: false);

    await tester.pumpWidget(
      _buildSubject(container: container, message: message, showAvatar: true),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(
        find.byKey(const ValueKey(r'swipe-reply:$avatar-default')),
      ),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final dynamic avatarRender = tester.renderObject(
      find.byKey(const ValueKey('sticky-group-avatar-slot')),
    );
    expect(avatarRender.debugIsSticky, isFalse);
    expect(avatarRender.debugHorizontalPaintOffset, closeTo(-40, 0.1));

    await gesture.up();
    await tester.pumpAndSettle();
  });

  testWidgets('sticky avatar stays fixed below the swiped message', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final scrollController = ScrollController();
    addTearDown(scrollController.dispose);
    final viewportKey = GlobalKey();
    final first = _message(id: r'$sticky-first', isMe: false);
    final last = _message(id: r'$sticky-last', isMe: false);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: SizedBox(
              height: 120,
              child: SingleChildScrollView(
                key: viewportKey,
                controller: scrollController,
                child: MessageGroupWidget(
                  group: MessageGroup(
                    senderId: first.senderId,
                    senderName: first.senderName,
                    isMe: false,
                    messages: [first, last],
                  ),
                  roomId: _roomId,
                  messageIndex: {first.id: first, last.id: last},
                  showAvatar: true,
                  scrollController: scrollController,
                  scrollViewportKey: viewportKey,
                  stickyBottomInset: 100,
                ),
              ),
            ),
          ),
        ),
      ),
    );

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey(r'swipe-reply:$sticky-last'))),
    );
    await gesture.moveBy(const Offset(-40, 0));
    await tester.pump();

    final dynamic avatarRender = tester.renderObject(
      find.byKey(const ValueKey('sticky-group-avatar-slot')),
    );
    final contentTransform = tester.widget<Transform>(
      find.byKey(const ValueKey('swipe-reply-content')).last,
    );
    expect(avatarRender.debugIsSticky, isTrue);
    expect(avatarRender.debugHorizontalPaintOffset, 0);
    expect(contentTransform.transform.storage[12], lessThan(0));

    final stack = tester.widget<Stack>(
      find
          .ancestor(
            of: find.byKey(const ValueKey('sticky-group-avatar-slot')),
            matching: find.byType(Stack),
          )
          .first,
    );
    expect(
      (stack.children.last as Padding).key,
      const ValueKey('sticky-group-messages-layer'),
    );

    await gesture.up();
    await tester.pumpAndSettle();
  });
}
