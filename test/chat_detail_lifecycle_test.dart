import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/unread_messages_banner.dart';
import 'package:matter/pages/chat/emoji_picker_panel.dart';
import 'package:matter/pages/chat/image_message_bubble.dart';
import 'package:matter/pages/chat/image_message_collection.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_insert_animation.dart';
import 'package:matter/pages/chat/pinned_messages_page.dart';
import 'package:matter/pages/chat/room_metadata_patch.dart';
import 'package:matter/pages/chat/room_management_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/pages/chat/send_flight.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/hidden_rooms_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/api/matrix/unread.dart' as unread;
import 'package:matter/src/rust/api/matrix/history.dart' as history;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:media_kit/media_kit.dart' as media;
import 'package:matter/features/audio/audio_playback_session.dart';
import 'package:matter/features/audio/audio_track.dart';
import 'package:matter/features/audio/audio_playback_provider.dart';
import 'package:matter/pages/chat/media_playback.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';

import 'support/video_test_player.dart';
import 'helpers/neu_test_theme.dart';

class _AudioJumpPlayer extends VideoTestPlayer {
  @override
  Future<void> open(media.Playable playable, {bool play = true}) async {
    state = state.copyWith(playing: false, position: Duration.zero);
  }
}

class _FakeRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  int subscribeTypingCalls = 0;
  int unsubscribeTypingCalls = 0;
  int subscribeRoomCalls = 0;
  int unsubscribeRoomCalls = 0;
  int markRoomAsReadCalls = 0;
  bool? lastMarkReadExplicit;
  unread.RoomUnreadState entryUnread = const unread.RoomUnreadState(
    unreadCount: 0,
  );
  Completer<unread.RoomUnreadState>? pendingUnreadState;
  List<rust.ChatMessage> unreadContext = const [];
  Object? unreadContextError;
  final unreadReadEventIds = <String?>[];
  final readLifecycle = <String>[];
  final unreadPageCalls = <(String, String, String?)>[];
  final unreadPages = <String?, unread.UnreadPage>{};
  final pendingUnreadPages = <String?, Completer<unread.UnreadPage>>{};

  @override
  Future<unread.UnreadPage> crateApiMatrixUnreadGetUnreadPage({
    required String accountUserId,
    required String roomId,
    required String readEventId,
    required String throughEventId,
    String? nextBatch,
    required List<String> ignoredUserIds,
  }) async {
    unreadPageCalls.add((readEventId, throughEventId, nextBatch));
    if (pendingUnreadPages[nextBatch] case final pending?) {
      return pending.future;
    }
    if (unreadPages[nextBatch] case final page?) return page;
    throw StateError('Unexpected unread page $nextBatch');
  }

  @override
  Future<unread.RoomUnreadState> crateApiMatrixUnreadGetRoomUnreadState({
    required String accountUserId,
    required String roomId,
  }) {
    readLifecycle.add('capture');
    return pendingUnreadState?.future ?? Future.value(entryUnread);
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixUnreadGetUnreadContext({
    required String accountUserId,
    required String roomId,
    String? readEventId,
    required List<String> ignoredUserIds,
  }) async {
    unreadReadEventIds.add(readEventId);
    if (unreadContextError case final error?) throw error;
    return unreadContext;
  }

  int getMessagesBeforeCalls = 0;
  final typingSubscriptionAccounts = <String?>[];
  final roomSubscriptionAccounts = <String?>[];
  final messagesBeforeEventIds = <String>[];
  List<rust.ChatMessage> messagesBefore = const [];
  Object? messagesBeforeError;
  final messagesAfterEventIds = <String>[];
  final messagesAfterPages = <String, List<rust.ChatMessage>>{};
  final pendingMessagesAfter = <String, Completer<history.HistoryPage>>{};
  final messagesAfterOverrides = <String, history.HistoryPage>{};
  Object? messagesAfterError;

  @override
  Future<history.HistoryPage> crateApiMatrixGetMessagesAfter({
    required String roomId,
    required String fromEventId,
    required int limit,
  }) async {
    messagesAfterEventIds.add(fromEventId);
    if (messagesAfterError case final error?) throw error;
    final pending = pendingMessagesAfter[fromEventId];
    if (pending != null) return pending.future;
    if (messagesAfterOverrides[fromEventId] case final page?) return page;
    final messages =
        messagesAfterPages[fromEventId] ?? const <rust.ChatMessage>[];
    return history.HistoryPage(
      messages: messages,
      nextEventId: messages.lastOrNull?.id,
      hasMore: messages.isNotEmpty,
    );
  }

  int getMessagesAroundCalls = 0;
  final messagesAroundRooms = <String>[];
  List<rust.ChatMessage> messagesAround = const [];
  Object? messagesAroundError;
  final pendingMessagesAround = <String, Completer<List<rust.ChatMessage>>>{};
  Completer<String>? pendingSend;
  Completer<bool>? pendingRoomEncryption;
  List<rust.ChatRoom> chatRooms = const [];
  final sentMessages = <rust.FormattedMessageInput>[];
  @override
  Future<List<String>> crateApiMatrixGetPinnedEventIds({
    required String accountUserId,
    required String roomId,
  }) async => const [];

  rust.ChatMessage? reactionResult;
  final reactionCalls = <String>[];

  @override
  Future<rust.ChatMessage> crateApiMatrixToggleReaction({
    required String accountUserId,
    required String roomId,
    required String eventId,
    required String key,
  }) async {
    reactionCalls.add('$accountUserId/$roomId/$eventId/$key');
    return reactionResult!;
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    return chatRooms;
  }

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    pendingSend = Completer<String>();
    sentMessages.add(message);
    return pendingSend!.future;
  }

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}
  String? activeTypingRoom;
  String? activeTypingSubscription;
  final activeReceiptRooms = <String>{};
  Completer<void>? typingSubscribeBarrier;
  Completer<void>? typingUnsubscribeBarrier;
  Completer<void>? roomSubscribeBarrier;
  Completer<void>? roomUnsubscribeBarrier;

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) =>
      pendingRoomEncryption?.future ?? Future.value(false);

  @override
  Future<String> crateApiMatrixSubscribeTypingForRoom({
    required String roomId,
    String? accountUserId,
  }) async {
    subscribeTypingCalls++;
    typingSubscriptionAccounts.add(accountUserId);
    final barrier = typingSubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeTypingRoom = roomId;
    activeTypingSubscription = 'typing-subscription-$subscribeTypingCalls';
    return activeTypingSubscription!;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeTyping({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {
    unsubscribeTypingCalls++;
    final barrier = typingUnsubscribeBarrier;
    if (barrier != null) await barrier.future;
    if (activeTypingRoom == roomId &&
        activeTypingSubscription == subscriptionId) {
      activeTypingRoom = null;
      activeTypingSubscription = null;
    }
  }

  @override
  Future<String> crateApiMatrixSubscribeRoomForReceipts({
    required String roomId,
    String? accountUserId,
  }) async {
    subscribeRoomCalls++;
    roomSubscriptionAccounts.add(accountUserId);
    final barrier = roomSubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeReceiptRooms.add(roomId);
    return 'subscription-$subscribeRoomCalls';
  }

  @override
  Future<bool> crateApiMatrixMarkRoomAsRead({
    required String accountUserId,
    required String roomId,
    required bool explicit,
  }) async {
    markRoomAsReadCalls++;
    readLifecycle.add('mark');
    entryUnread = const unread.RoomUnreadState(unreadCount: 0);
    lastMarkReadExplicit = explicit;
    return true;
  }

  @override
  Stream<rust.TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      const Stream.empty();

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesBefore({
    required String roomId,
    required String fromEventId,
    required int limit,
  }) async {
    getMessagesBeforeCalls++;
    messagesBeforeEventIds.add(fromEventId);
    if (messagesBeforeError case final error?) throw error;
    return messagesBefore;
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessagesAround({
    required String roomId,
    required String eventId,
    required int limit,
  }) async {
    getMessagesAroundCalls++;
    if (messagesAroundError case final error?) throw error;
    messagesAroundRooms.add(roomId);
    final pending = pendingMessagesAround[eventId];
    if (pending != null) return pending.future;
    return messagesAround;
  }

  @override
  Future<void> crateApiMatrixUnsubscribeRoomForReceipts({
    required String roomId,
    required String subscriptionId,
    String? accountUserId,
  }) async {
    unsubscribeRoomCalls++;
    final barrier = roomUnsubscribeBarrier;
    if (barrier != null) await barrier.future;
    activeReceiptRooms.remove(roomId);
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  int pinnedMessagesCalls = 0;
  List<rust.ChatMessage> pinnedMessages = const [];

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetPinnedMessages({
    required String roomId,
  }) async {
    pinnedMessagesCalls++;
    return pinnedMessages;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

rust.ChatMessage _message(
  String id, {
  String timestamp = '1',
  String? inReplyTo,
  String content = 'hello',
  List<rust.Reaction> reactions = const [],
}) {
  return rust.ChatMessage(
    id: id,
    senderId: '@alice:example.org',
    senderName: 'Alice',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: false,
    msgType: rust.MessageType.text,
    inReplyTo: inReplyTo,
    isEdited: false,
    editHistory: const [],
    reactions: reactions,
    readers: const [],
    totalMembers: 2,
  );
}

rust.ChatMessage _ownMessage(
  String id, {
  required String content,
  required String timestamp,
  rust.MessageType msgType = rust.MessageType.text,
  String? imageUrl,
  int? imageWidth,
  int? imageHeight,
  rust.ImageMessageMetadata? imageMetadata,
}) {
  return rust.ChatMessage(
    id: id,
    senderId: '',
    senderName: '我',
    content: content,
    mentionedUserIds: const [],
    mentionsRoom: false,
    timestamp: timestamp,
    isMe: true,
    msgType: msgType,
    imageUrl: imageUrl,
    imageWidth: imageWidth,
    imageHeight: imageHeight,
    imageMetadata: imageMetadata,
    isEdited: false,
    editHistory: const [],
    reactions: const [],
    readers: const [],
    totalMembers: 2,
  );
}

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    rustApi.subscribeTypingCalls = 0;
    rustApi.unsubscribeTypingCalls = 0;
    rustApi.subscribeRoomCalls = 0;
    rustApi.unsubscribeRoomCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
    rustApi.lastMarkReadExplicit = null;
    rustApi.entryUnread = const unread.RoomUnreadState(unreadCount: 0);
    rustApi.pendingUnreadState = null;
    rustApi.unreadContext = const [];
    rustApi.unreadContextError = null;
    rustApi.unreadReadEventIds.clear();
    rustApi.readLifecycle.clear();
    rustApi.unreadPageCalls.clear();
    rustApi.unreadPages.clear();
    rustApi.pendingUnreadPages.clear();
    rustApi.getMessagesBeforeCalls = 0;
    rustApi.typingSubscriptionAccounts.clear();
    rustApi.roomSubscriptionAccounts.clear();
    rustApi.messagesBeforeEventIds.clear();
    rustApi.messagesBefore = const [];
    rustApi.messagesBeforeError = null;
    rustApi.messagesAfterEventIds.clear();
    rustApi.messagesAfterPages.clear();
    rustApi.pendingMessagesAfter.clear();
    rustApi.messagesAfterOverrides.clear();
    rustApi.messagesAfterError = null;
    rustApi.getMessagesAroundCalls = 0;
    rustApi.messagesAroundRooms.clear();
    rustApi.messagesAround = const [];
    rustApi.messagesAroundError = null;
    rustApi.pendingMessagesAround.clear();
    rustApi.pendingSend = null;
    rustApi.sentMessages.clear();
    rustApi.reactionResult = null;
    rustApi.reactionCalls.clear();
    rustApi.pendingRoomEncryption = null;
    rustApi.chatRooms = const [];
    rustApi.pinnedMessagesCalls = 0;
    rustApi.pinnedMessages = const [];
    rustApi.activeTypingRoom = null;
    rustApi.activeReceiptRooms.clear();
    rustApi.typingSubscribeBarrier = null;
    rustApi.typingUnsubscribeBarrier = null;
    rustApi.roomSubscribeBarrier = null;
    rustApi.roomUnsubscribeBarrier = null;
    SharedPreferences.setMockInitialValues({});
  });

  for (final crossRoom in [false, true]) {
    for (final material in [false, true]) {
      testWidgets(
        'audio header below pins locates source crossRoom=$crossRoom material=$material',
        (tester) async {
          const roomId = '!audio-view:example.org';
          final sourceRoom = crossRoom ? '!audio-source:example.org' : roomId;
          const userId = '@alice:example.org';
          final target = _message(r'$audio-source-target', timestamp: '1');
          final latest = _message(r'$audio-latest', timestamp: '100');
          rustApi.messagesAround = [target];
          rustApi.pinnedMessages = [_message(r'$audio-pin')];
          final session = (await tester.runAsync(() async {
            final value =
                AudioPlaybackSession(
                  createPlayer: () => MediaPlayback(
                    player: media.Player(platformPlayer: _AudioJumpPlayer()),
                  ),
                  load: (_, account, preparation) async => PreparedMediaSource(
                    media: media.Media('file:///audio.ogg'),
                    cleanup: () async {},
                  ),
                  waveformLoader: (_, preparation) async => const [],
                )..setAccount(
                  const AudioAccount(userId, 'https://example.org', null),
                );
            await value.playTrack(
              AudioTrack(
                id: 'audio-source',
                filename: 'source.ogg',
                url: null,
                mediaSourceJson: null,
                roomId: sourceRoom,
                messageId: target.id,
              ),
            );
            return value;
          }))!;
          addTearDown(session.close);
          final container = ProviderContainer(
            overrides: [
              audioPlaybackSessionProvider.overrideWithValue(session),
              ignoredUserIdsProvider.overrideWith(
                (ref) async => const <String>{},
              ),
              roomMembersProvider(roomId).overrideWith((ref) async => const []),
              if (crossRoom)
                roomMembersProvider(sourceRoom)
                    .overrideWith((ref) async => const []),
            ],
          );
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = userId;
          for (final id in {roomId, sourceRoom}) {
            container.read(messageCacheOwnerProvider(id).notifier).value =
                userId;
            container.read(messageCachePrimedProvider(id).notifier).value =
                true;
          }
          container.read(messageCacheProvider(roomId).notifier).value = [
            latest,
          ];
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: neuTestTheme(material: material),
                navigatorObservers: [chatRouteObserver],
                home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final audioBar = find.byKey(const ValueKey('audio-message-bar'));
          final pins = find.byKey(const ValueKey('pinned-messages-stack'));
          expect(audioBar, findsOneWidget);
          expect(pins, findsOneWidget);
          expect(
            tester.getTopLeft(audioBar).dy,
            greaterThanOrEqualTo(tester.getBottomLeft(pins).dy - 0.5),
          );
          expect(
            tester.getBottomLeft(audioBar).dy,
            lessThan(tester.getSize(find.byType(Scaffold).first).height / 2),
          );
          await tester.tap(find.byTooltip('回到音频消息'));
          await tester.pumpAndSettle();
          expect(rustApi.messagesAroundRooms, contains(sourceRoom));
          expect(
            find.byKey(const ValueKey(r'text-bubble:$audio-source-target')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  for (final memberName in ['小明', '  小明  ', '   ', null]) {
    testWidgets('typing indicator resolves room nickname ($memberName)', (
      tester,
    ) async {
      const roomId = '!typing-name:example.org';
      const userId = '@me:example.org';
      const typingUserId = '@alice:example.org';
      final members = Completer<List<rust.Contact>>();
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) => members.future),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = userId;
      container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      container
          .read(typingUsersStateProvider('$userId:$roomId').notifier)
          .value = {
        userId,
        typingUserId,
      };
      await tester.pump();
      expect(find.text('alice 正在输入…'), findsOneWidget);
      members.complete([
        if (memberName != null)
          rust.Contact(
            id: typingUserId,
            name: memberName,
            status: typingUserId,
          ),
      ]);
      await tester.pump();
      await tester.pump();
      final expectedName = memberName?.trim();
      expect(
        find.text(
          '${expectedName == null || expectedName.isEmpty ? 'alice' : expectedName} 正在输入…',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('me 正在输入'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  for (final focused in [false, true]) {
    for (final entry in ['chip', 'quick', 'picker']) {
      testWidgets(
        'reaction counts update with the same emoji ($entry, focused=$focused)',
        (tester) async {
          const roomId = '!reaction-count:example.org';
          const userId = '@me:example.org';
          const eventId = r'$react';
          rust.ChatMessage message(List<String> senders) => _message(
            eventId,
            reactions: [rust.Reaction(key: '👍', senders: senders)],
          );
          final original = message(['@bob:example.org']);
          rustApi.messagesAround = [original];
          final container = ProviderContainer(
            overrides: [
              ignoredUserIdsProvider.overrideWith(
                (ref) async => const <String>{},
              ),
              roomMembersProvider(roomId).overrideWith((ref) async => const []),
            ],
          );
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = userId;
          await container.read(roomMembersProvider(roomId).future);
          container.read(messageCacheOwnerProvider(roomId).notifier).value =
              userId;
          container.read(messageCachePrimedProvider(roomId).notifier).value =
              true;
          container.read(messageCacheProvider(roomId).notifier).value = [
            original,
          ];
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: neuTestTheme(),
                home: ChatDetailPage(
                  roomId: roomId,
                  roomName: 'Room',
                  initialMessageId: focused ? eventId : null,
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final chip = find.byKey(const ValueKey('$eventId:👍'));
          expect(
            find.descendant(of: chip, matching: find.text('1')),
            findsOneWidget,
          );
          Future<void> clickReaction() async {
            if (entry == 'chip') {
              await tester.tap(chip);
              return;
            }
            final bubble = tester.getRect(
              find.byKey(const ValueKey('text-bubble:$eventId')),
            );
            await tester.longPressAt(Offset(bubble.right - 6, bubble.top + 6));
            await tester.pumpAndSettle();
            if (entry == 'quick') {
              await tester.tap(find.text('👍').last);
            } else {
              await tester.tap(find.byIcon(Icons.add_rounded).last);
              await tester.pumpAndSettle();
              await tester.tap(
                find.descendant(
                  of: find.byType(EmojiPickerPanel),
                  matching: find.text('👍'),
                ),
              );
            }
          }

          rustApi.reactionResult = message(['@bob:example.org', userId]);
          await clickReaction();
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: chip, matching: find.text('2')),
            findsOneWidget,
          );
          // There is still no reaction event ID. This click must use the shared
          // toggle API, rather than sending again or redacting the parent message.
          rustApi.reactionResult = original;
          await clickReaction();
          await tester.pumpAndSettle();
          expect(
            find.descendant(of: chip, matching: find.text('1')),
            findsOneWidget,
          );
          expect(
            rustApi.reactionCalls,
            List.filled(2, '$userId/$roomId/$eventId/👍'),
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('room subscriptions are bound to the active account', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(rustApi.typingSubscriptionAccounts, ['@alice:example.org']);
    expect(rustApi.roomSubscriptionAccounts, ['@alice:example.org']);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'the timeline runs under the pinned stack instead of beneath it',
    (tester) async {
      const roomId = '!pinned-underlay:example.org';
      const userId = '@me:example.org';
      rustApi.pinnedMessages = [_message(r'$pinned')];
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = userId;
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [
        _ownMessage(r'$own', content: 'hi', timestamp: '10'),
      ];
      container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const ValueKey(r'pinned-message:$pinned')),
        findsOneWidget,
      );

      // The pinned stack is a floating glass layer: the timeline viewport must
      // start above its bottom edge so messages scroll under it. Clipping the
      // viewport exactly at that edge is what cut the background off at a hard
      // line below the stack.
      final viewport = tester.getRect(
        find.byKey(const ValueKey('pinned-messages-stack')),
      );
      final timeline = tester.getRect(find.byType(CustomScrollView));
      expect(timeline.top, lessThan(viewport.bottom));
      expect(timeline.top, lessThanOrEqualTo(viewport.top));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('switching away and back restores live room view ownership', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(roomViewOwnerProvider(roomId)), '@alice:example.org');
    final readCallsBeforeSwitch = rustApi.markRoomAsReadCalls;

    container.invalidate(roomViewOwnerProvider);
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    await tester.pump();
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(roomViewOwnerProvider(roomId)), '@alice:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsBeforeSwitch));
    expect(rustApi.typingSubscriptionAccounts.last, '@alice:example.org');
    expect(rustApi.roomSubscriptionAccounts.last, '@alice:example.org');
  });

  testWidgets('the chat header opens the pinned messages page', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    rustApi.pinnedMessagesCalls = 0;
    rustApi.pinnedMessages = const [];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('置顶消息'));
    await tester.pumpAndSettle();

    expect(find.byType(PinnedMessagesPage), findsOneWidget);
    // One load feeds the chat's stacked pin strip; the pushed page performs
    // its own authoritative load.
    expect(rustApi.pinnedMessagesCalls, 2);
    expect(find.text('暂无置顶消息'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('repeated search taps open only one search route', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final searchButton = tester.widget<NeuIconButton>(
      find.widgetWithIcon(NeuIconButton, Icons.search_rounded),
    );
    searchButton.onPressed!();
    searchButton.onPressed!();
    await tester.pumpAndSettle();

    expect(find.byType(ChatSearchPage), findsOneWidget);
  });

  testWidgets('an initial search result opens around the target message', (
    tester,
  ) async {
    const roomId = '!search-jump:example.org';
    final target = _message(r'$search-target');
    final latest = _message(r'$latest-message');
    final pendingContext = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessagesAround[r'$search-target'] = pendingContext;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$search-target',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsWidgets);

    pendingContext.complete([target]);
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$search-target')),
      findsOneWidget,
    );
  });

  testWidgets('a recall removes a message from detached history browsing', (
    tester,
  ) async {
    const roomId = '!recalled-history:example.org';
    const userId = '@alice:example.org';
    rustApi.messagesAround = [_message(r'$old-target')];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = userId;
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$latest'),
    ];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$old-target',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$old-target')),
      findsOneWidget,
    );
    await tester.runAsync(
      () => recordMessageRedaction(container.read, (
        roomId: roomId,
        userId: userId,
      ), r'$old-target'),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$old-target')),
      findsNothing,
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a connected initial search result keeps the live timeline', (
    tester,
  ) async {
    const roomId = '!connected-search-jump:example.org';
    final target = _message(r'$connected-target', timestamp: '1');
    final latest = _message(r'$connected-latest', timestamp: '100');
    rustApi.messagesAround = [target, latest];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$connected-target',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$connected-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$connected-latest')),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LatestMessageControl>(find.byType(LatestMessageControl))
          .visible,
      isFalse,
    );
    expect(find.textContaining('正在浏览历史消息'), findsNothing);
  });

  testWidgets('a missing initial search result restores the live timeline', (
    tester,
  ) async {
    const roomId = '!missing-search-jump:example.org';
    final latest = _message(r'$latest-message');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [latest];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: roomId,
            roomName: 'Room',
            initialMessageId: r'$missing-message',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$latest-message')),
      findsOneWidget,
    );
  });

  testWidgets('long-pressing a message avatar inserts a Matrix mention', (
    tester,
  ) async {
    const roomId = '!mention:example.org';
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith(
          (ref) async => const [
            rust.Contact(
              id: '@alice:example.org',
              name: 'Alice',
              status: '@alice:example.org',
            ),
          ],
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$mention-source'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.longPress(find.byKey(const ValueKey('message-sender-avatar')));
    await tester.pump();

    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      '@alice:example.org ',
    );
  });

  testWidgets('reply preview loads and jumps to an unloaded target', (
    tester,
  ) async {
    const roomId = '!reply-jump:example.org';
    final target = _message(r'$reply-target', timestamp: '1');
    final reply = _message(r'$reply', timestamp: '100', inReplyTo: target.id);
    rustApi.messagesAround = [target, reply];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [reply];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$reply-target')),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 1);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$reply-target')),
      findsOneWidget,
    );
  });

  testWidgets('a stale jump response cannot replace the latest target', (
    tester,
  ) async {
    const roomId = '!jump-generation:example.org';
    final firstTarget = _message(r'$first-target', timestamp: '1');
    final secondTarget = _message(r'$second-target', timestamp: '2');
    final firstReply = _message(
      r'$first-reply',
      timestamp: '100',
      inReplyTo: firstTarget.id,
    );
    final secondReply = _message(
      r'$second-reply',
      timestamp: '101',
      inReplyTo: secondTarget.id,
    );
    final firstLoad = Completer<List<rust.ChatMessage>>();
    final secondLoad = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessagesAround[firstTarget.id] = firstLoad;
    rustApi.pendingMessagesAround[secondTarget.id] = secondLoad;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      firstReply,
      secondReply,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$first-target')),
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$second-target')),
    );
    await tester.pump();

    secondLoad.complete([secondTarget]);
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
      findsOneWidget,
    );

    firstLoad.complete([firstTarget]);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$first-target')),
      findsNothing,
    );
  });

  Future<ProviderContainer> openHistoryPin(
    WidgetTester tester, {
    int pinnedIndex = 0,
    bool reply = false,
    bool material = false,
    bool dark = true,
    bool images = false,
  }) async {
    const roomId = '!newer-pagination:example.org';
    const account = '@alice:example.org';
    final live = List.generate(
      120,
      (i) => _message('\$event-${i + 401}', timestamp: '${i + 401}'),
    );
    rustApi.messagesAround = List.generate(
      60,
      (i) => _message(
        '\$event-${i + 1}',
        timestamp: '${i + 1}',
        content:
            'history ${i + 1}: ${List.filled(i % 5 + 1, 'context').join(' ')}',
      ),
    );
    if (images) {
      for (final id in [58, 60]) {
        rustApi.messagesAround[id - 1] = _ownMessage(
          '\$event-$id',
          content: 'image $id',
          timestamp: '$id',
          msgType: rust.MessageType.image,
          imageUrl: 'https://example.org/$id.jpg',
          imageWidth: 400,
          imageHeight: 300,
          imageMetadata: rust.ImageMessageMetadata(
            albumRoot: id == 58 ? null : r'$event-58',
            blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
            spoiler: false,
          ),
        );
      }
    }
    final target = rustApi.messagesAround[pinnedIndex];
    rustApi.pinnedMessages = [target];
    if (reply) {
      live[live.length - 1] = _message(
        r'$event-520',
        timestamp: '520',
        inReplyTo: target.id,
      );
    }
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
        messagesProvider(roomId).overrideWith((ref) async => live),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = account;
    container.read(messageCacheOwnerProvider(roomId).notifier).value = account;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(material: material, dark: dark),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(
        ValueKey('${reply ? 'reply-preview' : 'pinned-message'}:${target.id}'),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> dragToNewerEdge(WidgetTester tester) async {
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
    await tester.pumpAndSettle();
  }

  for (final reply in [false, true]) {
    for (final material in [false, true]) {
      for (final dark in [false, true]) {
        testWidgets(
          'newer page keeps the visible anchor and waits for another drag reply=$reply material=$material dark=$dark',
          (tester) async {
            await tester.binding.setSurfaceSize(const Size(400, 720));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            await openHistoryPin(
              tester,
              pinnedIndex: 29,
              reply: reply,
              material: material,
              dark: dark,
            );
            expect(rustApi.messagesAfterEventIds, isEmpty);
            final target = find.byKey(const ValueKey(r'text-bubble:$event-30'));
            expect(target, findsOneWidget);
            final targetY = tester.getTopLeft(target).dy;
            await tester.pump(const Duration(seconds: 1));
            expect(tester.getTopLeft(target).dy, closeTo(targetY, 1));

            final pending = Completer<history.HistoryPage>();
            rustApi.pendingMessagesAfter[r'$event-60'] = pending;
            rustApi.messagesAfterPages[r'$event-160'] = [
              _message(r'$event-161', timestamp: '161'),
            ];
            final controller = tester
                .widget<CustomScrollView>(find.byType(CustomScrollView))
                .controller!;
            controller.jumpTo(controller.position.minScrollExtent);
            await tester.pumpAndSettle();
            expect(rustApi.messagesAfterEventIds, isEmpty);
            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, -100),
            );
            await tester.pump();
            await tester.pump(const Duration(seconds: 1));
            await tester.pump();
            expect(controller.position.isScrollingNotifier.value, isFalse);
            expect(rustApi.messagesAfterEventIds, [r'$event-60']);
            String? anchorId;
            double? anchorY;
            for (var i = 60; i >= 1; i--) {
              final finder = find.byKey(ValueKey('text-bubble:\$event-$i'));
              if (finder.evaluate().length != 1) continue;
              final rect = tester.getRect(finder);
              if (rect.top > 160 && rect.bottom < 620) {
                anchorId = '\$event-$i';
                anchorY = rect.top;
                break;
              }
            }
            expect(anchorId, isNotNull);
            pending.complete(
              history.HistoryPage(
                messages: List.generate(
                  100,
                  (i) => _message('\$event-${i + 61}', timestamp: '${i + 61}'),
                ),
                nextEventId: r'$event-160',
                hasMore: true,
              ),
            );
            await tester.pumpAndSettle();
            final anchor = find.byKey(ValueKey('text-bubble:$anchorId'));
            expect(anchor, findsOneWidget);
            expect(tester.getTopLeft(anchor).dy, closeTo(anchorY!, 1));
            expect(
              controller.offset - controller.position.minScrollExtent,
              greaterThan(100),
            );
            await tester.pump(const Duration(seconds: 1));
            expect(rustApi.messagesAfterEventIds, [r'$event-60']);

            controller.jumpTo(controller.position.minScrollExtent);
            await tester.pumpAndSettle();
            expect(rustApi.messagesAfterEventIds, [r'$event-60']);
            await tester.drag(
              find.byType(CustomScrollView),
              const Offset(0, -100),
            );
            await tester.pumpAndSettle();
            expect(rustApi.messagesAfterEventIds, [
              r'$event-60',
              r'$event-160',
            ]);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
          },
        );
      }
    }
  }

  for (final material in [false, true]) {
    testWidgets(
      'paging preserves the anchored interleaved album material=$material',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(400, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await openHistoryPin(
          tester,
          pinnedIndex: 57,
          images: true,
          material: material,
        );
        expect(rustApi.messagesAfterEventIds, isEmpty);
        final collection = find.byWidgetPredicate(
          (widget) =>
              widget is ImageMessageCollection &&
              widget.messages.any((message) => message.id == r'$event-58'),
        );
        final pending = Completer<history.HistoryPage>();
        rustApi.pendingMessagesAfter[r'$event-60'] = pending;
        await tester.drag(find.byType(CustomScrollView), const Offset(0, -40));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        await tester.pump();
        expect(rustApi.messagesAfterEventIds, [r'$event-60']);
        expect(collection, findsOneWidget);
        final before = tester.getRect(collection);
        pending.complete(
          history.HistoryPage(
            messages: [
              _ownMessage(
                r'$event-61',
                content: 'late album member',
                timestamp: '59',
                msgType: rust.MessageType.image,
                imageUrl: 'https://example.org/61.jpg',
                imageWidth: 400,
                imageHeight: 300,
                imageMetadata: const rust.ImageMessageMetadata(
                  albumRoot: r'$event-58',
                  blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
                  spoiler: false,
                ),
              ),
              _message(r'$event-62', timestamp: '62'),
            ],
            nextEventId: r'$event-62',
            hasMore: true,
          ),
        );
        await tester.pumpAndSettle();
        expect(collection, findsOneWidget);
        final widget = tester.widget<ImageMessageCollection>(collection);
        expect(widget.messages.map((message) => message.id), [
          r'$event-58',
          r'$event-60',
        ]);
        expect(widget.album, isTrue);
        expect(tester.getRect(collection).top, closeTo(before.top, 1));
        expect(tester.getRect(collection).size, before.size);
        expect(rustApi.messagesAfterEventIds, [r'$event-60']);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets('one held drag loads one page even after its request completes', (
    tester,
  ) async {
    rustApi.messagesAfterPages[r'$event-60'] = [
      _message(r'$event-61', timestamp: '61'),
    ];
    rustApi.messagesAfterPages[r'$event-61'] = [
      _message(r'$event-62', timestamp: '62'),
    ];
    await openHistoryPin(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(CustomScrollView)),
    );
    // The first move wins the drag recognizer; the next produces scrolling.
    await gesture.moveBy(const Offset(0, -30));
    await tester.pump();
    await gesture.moveBy(const Offset(0, -100));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(rustApi.messagesAfterEventIds, [r'$event-60']);
    await gesture.moveBy(const Offset(0, -300));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(rustApi.messagesAfterEventIds, [r'$event-60']);
    await gesture.up();
    await tester.pumpAndSettle();
    await dragToNewerEdge(tester);
    expect(rustApi.messagesAfterEventIds, [r'$event-60', r'$event-61']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'joining live preserves the reading anchor then latest clears it',
    (tester) async {
      await openHistoryPin(tester);
      final pending = Completer<history.HistoryPage>();
      rustApi.pendingMessagesAfter[r'$event-60'] = pending;
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      controller.jumpTo(controller.position.minScrollExtent);
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -100));
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await tester.pump();
      expect(controller.position.isScrollingNotifier.value, isFalse);
      final anchor = find.byKey(const ValueKey(r'text-bubble:$event-60'));
      expect(anchor, findsOneWidget);
      final before = tester.getTopLeft(anchor).dy;
      pending.complete(
        history.HistoryPage(
          messages: List.generate(
            342,
            (i) => _message('\$event-${i + 61}', timestamp: '${i + 61}'),
          ),
          nextEventId: r'$event-402',
          hasMore: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(anchor).dy, closeTo(before, 1));
      expect(rustApi.messagesAfterEventIds, [r'$event-60']);
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LatestMessageControl));
      await tester.pumpAndSettle();
      expect(controller.position.minScrollExtent, 0);
      expect(controller.offset, closeTo(0, 1));
      expect(
        find.byKey(const ValueKey(r'text-bubble:$event-520')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('detached history loads newer pages and reconnects to live', (
    tester,
  ) async {
    for (final anchor in [60, 160, 260, 360]) {
      rustApi.messagesAfterPages['\$event-$anchor'] = List.generate(
        100,
        (i) => _message(
          '\$event-${anchor + i + 1}',
          timestamp: '${anchor + i + 1}',
        ),
      );
    }
    final container = await openHistoryPin(tester);
    for (var i = 0; i < 8; i++) {
      await dragToNewerEdge(tester);
    }
    expect(
      rustApi.messagesAfterEventIds,
      containsAll([r'$event-60', r'$event-160', r'$event-260', r'$event-360']),
    );
    final cached = container.read(
      messageCacheProvider('!newer-pagination:example.org'),
    );
    expect(
      cached.map((m) => m.id),
      containsAll([r'$event-1', r'$event-361', r'$event-520']),
    );
    expect(cached.map((m) => m.id).toSet().length, cached.length);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$event-520')),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey(r'text-bubble:$event-1')),
      1200,
      scrollable: find
          .descendant(
            of: find.byType(CustomScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 50,
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey(r'text-bubble:$event-1')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('newer history error remains retryable', (tester) async {
    rustApi.messagesAfterError = StateError('offline');
    await openHistoryPin(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    await dragToNewerEdge(tester);
    expect(find.byKey(const ValueKey('newer-history-retry')), findsOneWidget);
    expect(find.text('重试加载更新消息'), findsOneWidget);
    rustApi.messagesAfterError = null;
    rustApi.messagesAfterPages[r'$event-60'] = [
      _message(r'$event-61', timestamp: '61'),
    ];
    await tester.tap(find.byKey(const ValueKey('newer-history-retry')));
    await tester.pumpAndSettle();
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(
      rustApi.messagesAfterEventIds.where((id) => id == r'$event-60').length,
      greaterThan(1),
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$event-61')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('empty filtered newer page advances its raw event cursor', (
    tester,
  ) async {
    rustApi.messagesAfterOverrides[r'$event-60'] = const history.HistoryPage(
      messages: [],
      nextEventId: r'$hidden-boundary',
      hasMore: true,
    );
    rustApi.messagesAfterPages[r'$hidden-boundary'] = [
      _message(r'$event-61', timestamp: '61'),
    ];
    final container = await openHistoryPin(tester);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    await dragToNewerEdge(tester);
    expect(rustApi.messagesAfterEventIds, [r'$event-60']);
    await tester.tap(find.byKey(const ValueKey('newer-history-retry')));
    await tester.pumpAndSettle();
    controller.jumpTo(controller.position.minScrollExtent);
    await tester.pumpAndSettle();
    expect(rustApi.messagesAfterEventIds, contains(r'$hidden-boundary'));
    expect(
      find.byKey(const ValueKey(r'text-bubble:$event-61')),
      findsOneWidget,
    );
    // Until a real overlap, the detached window must not leak into live cache.
    expect(
      container
          .read(messageCacheProvider('!newer-pagination:example.org'))
          .any((m) => m.id == r'$event-1'),
      isFalse,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('returning to latest cancels a pending pin jump', (tester) async {
    final pending = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessagesAround[r'$event-1'] = pending;
    await openHistoryPin(tester);
    expect(rustApi.getMessagesAroundCalls, 1);
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    await tester.tap(find.byType(LatestMessageControl));
    await tester.pumpAndSettle();
    pending.complete(rustApi.messagesAround);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$event-520')),
      findsOneWidget,
    );
    expect(find.byKey(const ValueKey(r'text-bubble:$event-1')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final switchAccount in [false, true]) {
    testWidgets(
      'late newer page is discarded after leaving history account=$switchAccount',
      (tester) async {
        rustApi.messagesAfterError = StateError('offline');
        final container = await openHistoryPin(tester);
        final controller = tester
            .widget<CustomScrollView>(find.byType(CustomScrollView))
            .controller!;
        controller.jumpTo(controller.position.minScrollExtent);
        await tester.pumpAndSettle();
        rustApi.messagesAfterError = null;
        final pending = Completer<history.HistoryPage>();
        rustApi.pendingMessagesAfter[r'$event-60'] = pending;
        await tester.tap(find.byKey(const ValueKey('newer-history-retry')));
        await tester.pump();
        await tester.pump(const Duration(seconds: 5));
        await tester.pump(const Duration(milliseconds: 300));
        if (switchAccount) {
          container.read(activeUserIdProvider.notifier).value =
              '@bob:example.org';
        } else {
          await tester.tap(find.byType(LatestMessageControl));
        }
        await tester.pumpAndSettle();
        pending.complete(
          history.HistoryPage(
            messages: [_message(r'$late-newer', timestamp: '999')],
            nextEventId: r'$late-newer',
            hasMore: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(
          container
              .read(messageCacheProvider('!newer-pagination:example.org'))
              .any((m) => m.id == r'$late-newer'),
          isFalse,
        );
        expect(
          find.byKey(const ValueKey(r'text-bubble:$late-newer')),
          findsNothing,
        );
        if (switchAccount) {
          expect(find.text('账号已切换'), findsOneWidget);
        } else {
          expect(
            find.byKey(const ValueKey(r'text-bubble:$event-520')),
            findsOneWidget,
          );
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  testWidgets(
    'jumping to a detached message hides the live window until the latest control is tapped',
    (tester) async {
      const roomId = '!focused-jump:example.org';
      final target = _message(r'$far-target', timestamp: '1');
      // The slice around the far target does not touch the live window.
      rustApi.messagesAround = [
        target,
        _message(r'$far-neighbor', timestamp: '2'),
      ];
      final reply = _message(
        r'$live-reply',
        timestamp: '100',
        inReplyTo: target.id,
      );
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [reply];
      container.read(messageCacheOwnerProvider(roomId).notifier).value =
          'anonymous';
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      await tester.tap(
        find.byKey(const ValueKey(r'reply-preview:$far-target')),
      );
      await tester.pumpAndSettle();

      // Focused browsing: the detached slice renders, the live window hides.
      expect(
        find.byKey(const ValueKey(r'text-bubble:$far-target')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(r'text-bubble:$live-reply')),
        findsNothing,
      );

      // Let the hint snackbar clear the bottom-right control, then leave the
      // focused view through it.
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(LatestMessageControl));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey(r'text-bubble:$live-reply')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey(r'text-bubble:$far-target')),
        findsNothing,
      );
    },
  );

  testWidgets('account switching clears a detached history slice', (
    tester,
  ) async {
    const roomId = '!focused-account:example.org';
    const alice = '@alice:example.org';
    final target = _message(r'$account-target', timestamp: '1');
    final reply = _message(
      r'$account-live-reply',
      timestamp: '100',
      inReplyTo: target.id,
    );
    rustApi.messagesAround = [target];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = alice;
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [reply];
    container.read(messageCacheOwnerProvider(roomId).notifier).value = alice;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$account-target')),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-target')),
      findsOneWidget,
    );

    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pump();
    expect(find.text('账号已切换'), findsOneWidget);

    container.read(activeUserIdProvider.notifier).value = alice;
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-live-reply')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$account-target')),
      findsNothing,
    );
  });

  testWidgets('reply preview jumps to an offscreen loaded target', (
    tester,
  ) async {
    const roomId = '!reply-scroll:example.org';
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final target = _message(r'$loaded-target', timestamp: '0');
    final reply = _message(
      r'$loaded-reply',
      timestamp: '101',
      inReplyTo: target.id,
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      target,
      ...List.generate(
        100,
        (index) => _message('\$middle-$index', timestamp: '${index + 1}'),
      ),
      reply,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$loaded-target')),
      findsNothing,
    );

    await tester.tap(
      find.byKey(const ValueKey(r'reply-preview:$loaded-target')),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesAroundCalls, 0);
    expect(
      find.byKey(const ValueKey(r'text-bubble:$loaded-target')),
      findsOneWidget,
    );
  });

  testWidgets('leaving a chat clears its active room without using ref', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(theme: neuTestTheme(), home: SizedBox.shrink()),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
  });

  testWidgets('dispose waits for pending room subscriptions', (tester) async {
    final subscribeBarrier = Completer<void>();
    rustApi.typingSubscribeBarrier = subscribeBarrier;
    rustApi.roomSubscribeBarrier = subscribeBarrier;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    subscribeBarrier.complete();
    await tester.pump();
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);
    expect(rustApi.activeTypingRoom, isNull);
    expect(rustApi.activeReceiptRooms, isEmpty);
  });

  testWidgets('disposing an old chat does not clear its replacement room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    Widget buildChat(String roomId) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            key: ValueKey(roomId),
            roomId: roomId,
            roomName: 'Room',
          ),
        ),
      );
    }

    await tester.pumpWidget(buildChat('!old:example.org'));
    await tester.pump();
    expect(
      rustApi.subscribeRoomCalls,
      1,
      reason: 'entering old room subscribes',
    );

    await tester.pumpWidget(buildChat('!new:example.org'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(container.read(currentRoomIdProvider), '!new:example.org');
    // old room disposed (unsubscribes), new room initialized (subscribes).
    expect(
      rustApi.subscribeRoomCalls,
      2,
      reason: 'entering new room subscribes',
    );
    expect(
      rustApi.unsubscribeRoomCalls,
      1,
      reason: 'old room unsubscribe on dispose',
    );

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const SizedBox.shrink(),
      ),
    );
    await tester.pump();
    expect(
      rustApi.unsubscribeRoomCalls,
      2,
      reason: 'new room unsubscribe on dispose',
    );
  });

  testWidgets('returning to a chat restores its room subscriptions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(roomId: '!a:example.org', roomName: 'A'),
        ),
      ),
    );
    await tester.pump();

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const ChatDetailPage(roomId: '!b:example.org', roomName: 'B'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!b:example.org');

    final unsubscribeBarrier = Completer<void>();
    rustApi.typingUnsubscribeBarrier = unsubscribeBarrier;
    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!a:example.org');
    expect(rustApi.subscribeTypingCalls, 3);
    expect(rustApi.subscribeRoomCalls, 3);

    unsubscribeBarrier.complete();
    await tester.pump();
    expect(rustApi.activeTypingRoom, '!a:example.org');
  });

  testWidgets('a covered chat stops being the active room until uncovered', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // While covered, the chat must not be treated as the visible room:
    // incoming messages would otherwise be silently marked as read.
    expect(container.read(currentRoomIdProvider), isNull);
    final readCallsWhileCovered = rustApi.markRoomAsReadCalls;

    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsWhileCovered));
  });

  testWidgets('a popup suspends reads without rebuilding room subscriptions', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final typingSubscriptions = rustApi.subscribeTypingCalls;
    final receiptSubscriptions = rustApi.subscribeRoomCalls;

    final context = tester.element(find.byType(ChatDetailPage));
    unawaited(
      showDialog<void>(
        context: context,
        builder: (_) => const AlertDialog(content: Text('popup')),
      ),
    );
    await tester.pumpAndSettle();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(container.read(roomViewOwnerProvider('!room:example.org')), isNull);
    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    Navigator.of(tester.element(find.text('popup'))).pop();
    await tester.pumpAndSettle();

    expect(
      container.read(roomViewOwnerProvider('!room:example.org')),
      '@alice:example.org',
    );
    expect(rustApi.subscribeTypingCalls, typingSubscriptions);
    expect(rustApi.subscribeRoomCalls, receiptSubscriptions);
  });

  testWidgets('returning to a chat preserves pending unread suppression', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('management')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    final readCallsWhileCovered = rustApi.markRoomAsReadCalls;

    navigator.pop();
    await tester.pumpAndSettle();

    expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
    expect(rustApi.markRoomAsReadCalls, readCallsWhileCovered);
  });

  testWidgets('manual unread suppresses auto-read delayed by cache priming', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final encryptionCheck = Completer<bool>();
    rustApi.pendingRoomEncryption = encryptionCheck;
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(rustApi.markRoomAsReadCalls, 0);

    // The room-list action sets suppression before its unread request starts.
    // Finish cache priming only after that explicit action has won the race.
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    encryptionCheck.complete(false);
    await tester.pump();
    await tester.pump();

    expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
    expect(rustApi.markRoomAsReadCalls, 0);
  });

  testWidgets('backgrounding deactivates the room until the app resumes', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    final readCallsBeforeBackground = rustApi.markRoomAsReadCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();
    // In the background the room is no longer "being viewed", so background
    // sync must not auto-mark incoming messages as read.
    expect(container.read(currentRoomIdProvider), isNull);
    expect(rustApi.unsubscribeTypingCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(rustApi.markRoomAsReadCalls, greaterThan(readCallsBeforeBackground));
  });

  testWidgets('transient inactive state keeps room subscriptions alive', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final typingSubscriptions = rustApi.subscribeTypingCalls;
    final receiptSubscriptions = rustApi.subscribeRoomCalls;

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();

    expect(container.read(currentRoomIdProvider), '!room:example.org');
    expect(container.read(roomViewOwnerProvider('!room:example.org')), isNull);
    expect(rustApi.unsubscribeTypingCalls, 0);
    expect(rustApi.unsubscribeRoomCalls, 0);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(
      container.read(roomViewOwnerProvider('!room:example.org')),
      '@alice:example.org',
    );
    expect(rustApi.subscribeTypingCalls, typingSubscriptions);
    expect(rustApi.subscribeRoomCalls, receiptSubscriptions);
  });

  testWidgets('resume waits for pending room unsubscriptions', (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final unsubscribeBarrier = Completer<void>();
    rustApi.typingUnsubscribeBarrier = unsubscribeBarrier;
    rustApi.roomUnsubscribeBarrier = unsubscribeBarrier;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    expect(rustApi.unsubscribeTypingCalls, 1);
    expect(rustApi.unsubscribeRoomCalls, 1);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 1);
    expect(rustApi.subscribeRoomCalls, 1);

    unsubscribeBarrier.complete();
    await tester.pump();
    await tester.pump();

    expect(rustApi.subscribeTypingCalls, 2);
    expect(rustApi.subscribeRoomCalls, 2);
    expect(rustApi.activeTypingRoom, '!room:example.org');
    expect(rustApi.activeReceiptRooms, contains('!room:example.org'));
  });

  testWidgets('popping a cover while paused does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pause the app, then pop the cover while still paused: the route
    // callback must not reactivate the room in the background.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump();

    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Returning to the foreground reactivates it.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('popping a cover while inactive does not reactivate the room', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Room',
          ),
        ),
      ),
    );
    await tester.pump();
    expect(container.read(currentRoomIdProvider), '!room:example.org');

    final navigator = Navigator.of(tester.element(find.byType(ChatDetailPage)));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('cover')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    // Pop the cover during a transient inactive window (e.g. notification
    // shade): the route callback must not reactivate the room.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    navigator.pop();
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), isNull);

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(container.read(currentRoomIdProvider), '!room:example.org');
  });

  testWidgets('does not reactivate a chat route that is also being popped', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          navigatorObservers: [chatRouteObserver],
          home: const Scaffold(body: SizedBox(key: ValueKey('root-route'))),
        ),
      ),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const ChatDetailPage(
            roomId: '!leaving:example.org',
            roomName: 'Leaving',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final initialReadCalls = rustApi.markRoomAsReadCalls;

    unawaited(
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: SizedBox.shrink()),
        ),
      ),
    );
    await tester.pumpAndSettle();
    navigator.pop();
    navigator.pop();
    await tester.pumpAndSettle();

    expect(find.byType(ChatDetailPage), findsNothing);
    expect(find.byKey(const ValueKey('root-route')), findsOneWidget);
    expect(rustApi.markRoomAsReadCalls, initialReadCalls);
  });

  testWidgets('waits for initial members before rendering cached messages', (
    tester,
  ) async {
    const roomId = '!members:example.org';
    final members = Completer<List<rust.Contact>>();
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) => members.future),
      ],
    );
    addTearDown(container.dispose);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$members'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsNothing);

    members.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey('text-bubble:\$members')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('hides cached messages while the ignore list is unknown', (
    tester,
  ) async {
    const roomId = '!ignored-loading:example.org';
    final ignoredUsers = Completer<Set<String>>();
    final ownMessage = _ownMessage(r'$own', content: 'mine', timestamp: '2');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) => ignoredUsers.future),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
      ownMessage,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    // While the ignore list is unknown, no messages are exposed unfiltered.
    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsNothing);

    ignoredUsers.complete(const {'@alice:example.org'});
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.byKey(const ValueKey(r'text-bubble:$own')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('keeps messages hidden when the ignore list fails to load', (
    tester,
  ) async {
    const roomId = '!ignored-failure:example.org';
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) => Future<Set<String>>.error(StateError('offline')),
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(find.byKey(const ValueKey(r'text-bubble:$ignored')), findsNothing);
    expect(find.text('无法加载忽略列表，消息已隐藏'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('loads older history when ignored messages empty the window', (
    tester,
  ) async {
    const roomId = '!ignored-window:example.org';
    final older = _ownMessage(
      r'$older-visible',
      content: 'older',
      timestamp: '0',
    );
    rustApi.messagesBefore = [older];
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));
    expect(rustApi.messagesBeforeEventIds.first, r'$ignored-anchor');
    expect(
      find.byKey(const ValueKey(r'text-bubble:$older-visible')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('a jump invalidates pagination during the encryption check', (
    tester,
  ) async {
    const roomId = '!pagination-jump-race:example.org';
    const userId = '@me:example.org';
    final stalePage = _ownMessage(
      r'$stale-page',
      content: 'stale page',
      timestamp: '0',
    );
    final jumpTarget = _ownMessage(
      r'$pagination-jump-target',
      content: 'jump target',
      timestamp: '50',
    );
    rustApi.messagesBefore = [stalePage];
    rustApi.messagesAround = [jumpTarget];
    rustApi.pinnedMessages = [jumpTarget];
    final encryptionCheck = Completer<bool>();
    rustApi.pendingRoomEncryption = encryptionCheck;
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith(
          (ref) async => const {'@alice:example.org'},
        ),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = userId;
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$ignored-pagination-anchor'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value = userId;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));

    await tester.tap(
      find.byKey(const ValueKey(r'pinned-message:$pagination-jump-target')),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$pagination-jump-target')),
      findsOneWidget,
    );

    encryptionCheck.complete(false);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$pagination-jump-target')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey(r'text-bubble:$stale-page')),
      findsNothing,
    );
  });

  testWidgets(
    'stops automatic back-pagination when every older page is ignored',
    (tester) async {
      const roomId = '!ignored-dead-end:example.org';
      // Every historical page is from an ignored sender: auto-pagination must
      // stop after one page instead of pulling the whole history.
      rustApi.messagesBefore = [
        _message(r'$ignored-1'),
        _message(r'$ignored-2'),
        _message(r'$ignored-3'),
      ];
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith(
            (ref) async => const {'@alice:example.org'},
          ),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      await container.read(roomMembersProvider(roomId).future);
      container.read(messageCacheProvider(roomId).notifier).value = [
        _message(r'$ignored-anchor'),
      ];
      container.read(messageCacheOwnerProvider(roomId).notifier).value =
          'anonymous';
      container.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(1));
      // No visible message came back, so the timeline shows the manual retry
      // affordance and no further automatic pages are fetched.
      await tester.pump(const Duration(seconds: 1));
      final callsAfterIdle = rustApi.getMessagesBeforeCalls;
      await tester.pump(const Duration(seconds: 1));
      expect(rustApi.getMessagesBeforeCalls, callsAfterIdle);
      expect(
        find.byKey(const ValueKey(r'text-bubble:$ignored-1')),
        findsNothing,
      );
      expect(find.text('重试加载更早消息'), findsOneWidget);

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('removes newly ignored user messages from an open timeline', (
    tester,
  ) async {
    const roomId = '!ignored-live:example.org';
    var ignoredUsers = <String>{};
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => ignoredUsers),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$live-ignored'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsOneWidget,
    );

    ignoredUsers = {'@alice:example.org'};
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();
    await tester.pump();

    expect(
      find.byKey(const ValueKey(r'text-bubble:$live-ignored')),
      findsNothing,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('backfills offline gaps before paging beyond cached history', (
    tester,
  ) async {
    const roomId = '!offline-gap:example.org';
    final latest = List.generate(
      100,
      (i) => _message('\$event-${i + 301}', timestamp: '${i + 301}'),
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
        messagesProvider(roomId).overrideWith((ref) async => latest),
      ],
    );
    addTearDown(container.dispose);
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$event-1'),
    ];
    rustApi.messagesBefore = [_message(r'$event-300', timestamp: '300')];
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final controller = tester
        .widget<CustomScrollView>(find.byType(CustomScrollView))
        .controller!;
    controller.jumpTo(controller.position.maxScrollExtent);
    await tester.pumpAndSettle();
    expect(rustApi.messagesBeforeEventIds.first, r'$event-301');
    expect(
      container.read(messageCacheProvider(roomId)).map((m) => m.id),
      contains(r'$event-300'),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('re-arms older-message loading after leaving a failed edge', (
    tester,
  ) async {
    const roomId = '!older-failure:example.org';
    await tester.binding.setSurfaceSize(const Size(800, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    rustApi.messagesBeforeError = StateError('offline');
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = List.generate(
      120,
      (index) => _ownMessage(
        '\$cached-$index',
        content: 'cached $index',
        timestamp: '$index',
      ),
    );
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump();
    }

    final scrollView = tester.widget<CustomScrollView>(
      find.byType(CustomScrollView),
    );
    final scrollController = scrollView.controller!;
    scrollController.jumpTo(scrollController.position.maxScrollExtent);
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesBeforeCalls, 1);
    expect(find.textContaining('加载更早消息失败'), findsOneWidget);

    await tester.pump(const Duration(seconds: 1));
    expect(rustApi.getMessagesBeforeCalls, 1);

    rustApi.messagesBeforeError = null;
    rustApi.messagesBefore = [
      _ownMessage(r'$automatic-retry', content: 'recovered', timestamp: '0'),
    ];
    scrollController.jumpTo(scrollController.position.minScrollExtent);
    await tester.pump();
    unawaited(
      scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 100),
        curve: Curves.linear,
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.getMessagesBeforeCalls, greaterThanOrEqualTo(2));
    expect(
      find.byKey(const ValueKey(r'text-bubble:$automatic-retry')),
      findsOneWidget,
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'a failed send offers retry and delete from its long-press menu',
    (tester) async {
      const roomId = '!failed-send:example.org';
      await tester.binding.setSurfaceSize(const Size(900, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'doomed message');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send_rounded));
      await tester.pump();
      expect(rustApi.pendingSend, isNotNull);

      // Fail the send: the bubble becomes a failed local message with an
      // error icon, and long-pressing must offer retry/delete instead of
      // being a dead end.
      rustApi.pendingSend!.completeError(StateError('offline'));
      await tester.pump();
      await tester.pump();
      expect(find.byIcon(Icons.error_rounded), findsOneWidget);

      final failedBubble = find.byKey(
        const ValueKey(r'text-bubble:$failed-message'),
      );
      expect(failedBubble, findsNothing);
      // Locate the failed bubble: it renders under the failed prefix id.
      final failedId = find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'text-bubble:$localOutgoingFailedPrefix',
            ),
      );
      expect(failedId, findsOneWidget);

      // Delete from the long-press menu removes the failed message.
      await tester.scrollUntilVisible(
        failedId,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.longPress(failedId, warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('删除消息'), findsOneWidget);
      await tester.tap(find.text('删除消息'));
      await tester.pumpAndSettle();
      expect(failedId, findsNothing);
      expect(tester.takeException(), isNull);

      // Let the send-flight expiry timer run out before the test ends.
      await tester.pump(const Duration(seconds: 3));

      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('retrying a failed send re-sends and marks the message sent', (
    tester,
  ) async {
    const roomId = '!failed-retry:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry me');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    expect(rustApi.sentMessages, hasLength(1));
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);

    // Retry: the send is attempted again and the message returns to a
    // normal (sent) state instead of staying failed.
    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();
    expect(rustApi.sentMessages, hasLength(2));

    // Complete the retry successfully; the failed bubble disappears.
    rustApi.pendingSend!.complete(r'$retried');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the retry polling loop run to completion (~8s budget) so it
    // leaves no pending timers behind.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('retry polling reconciles the sent bubble via the timeline', (
    tester,
  ) async {
    // Regression: the retry path used to pass the *pending* id to the
    // polling loop after renaming the message to its `sent:` id, so the
    // first still-local check always failed and no timeline refresh ever
    // ran — the sent bubble then lingered until the next sync cycle.
    const roomId = '!retry-poll:example.org';
    // Count timeline fetches through a provider override: the polling loop
    // refreshes via messagesProvider, and without the override it would
    // short-circuit on the unset session instead of reaching the bridge.
    var getMessagesCalls = 0;
    final container = ProviderContainer(
      overrides: [
        messagesProvider(roomId).overrideWith((ref) async {
          getMessagesCalls++;
          return const <rust.ChatMessage>[];
        }),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry poll');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);

    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();

    // The retry succeeds: the message flips to the sent state. The polling
    // loop must then poll the timeline (getMessages) instead of bailing out
    // on the first id mismatch.
    final readsBeforePoll = getMessagesCalls;
    rustApi.pendingSend!.complete(r'$retried-poll');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the polling loop run; it must have refreshed the timeline at
    // least once.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    expect(getMessagesCalls, greaterThan(readsBeforePoll));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('retrying a failed send re-stamps the message timestamp', (
    tester,
  ) async {
    const roomId = '!failed-retry-stamp:example.org';
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final key = (roomId: roomId, userId: '@alice:example.org');

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    await tester.enterText(find.byType(TextField), 'retry stamp');
    await tester.pump();
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    rustApi.pendingSend!.completeError(StateError('offline'));
    await tester.pump();
    await tester.pump();

    final failedId = find.byWidgetPredicate(
      (widget) =>
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith(
            'text-bubble:$localOutgoingFailedPrefix',
          ),
    );
    expect(failedId, findsOneWidget);
    final failedMessages = container.read(localOutgoingMessagesProvider(key));
    final failedTimestamp =
        int.tryParse(failedMessages.first.message.timestamp) ?? 0;

    // Retry through the long-press menu (same UI path as production).
    await tester.scrollUntilVisible(
      failedId,
      100,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.longPress(failedId, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重试发送'));
    await tester.pump();
    await tester.pump();

    // The resent local message must carry a NEW timestamp: keeping the old
    // one would never match the server echo within the matcher's window and
    // leave a permanent duplicate bubble.
    final retriedMessages = container.read(localOutgoingMessagesProvider(key));
    final retried = retriedMessages
        .where(
          (message) =>
              message.message.id.startsWith(localOutgoingPendingPrefix),
        )
        .toList();
    expect(retried, hasLength(1));
    final retriedTimestamp = int.tryParse(retried.first.message.timestamp) ?? 0;
    expect(retriedTimestamp, greaterThan(failedTimestamp));

    rustApi.pendingSend!.complete(r'$retried-stamp');
    await tester.pump();
    await tester.pump();
    expect(failedId, findsNothing);

    // Let the retry polling loop run to completion (~8s budget) so it
    // leaves no pending timers behind.
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('cached messages keep their first-frame vertical position', (
    tester,
  ) async {
    const roomId = '!cached:example.org';
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      _message(r'$cached'),
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );

    final bubble = find.byKey(const ValueKey('text-bubble:\$cached'));
    expect(bubble, findsNothing);

    await tester.pump();

    expect(bubble, findsOneWidget);
    final firstTop = tester.getTopLeft(bubble).dy;

    await tester.pump(const Duration(milliseconds: 180));

    expect(tester.getTopLeft(bubble).dy, closeTo(firstTop, 0.1));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('appending a sticker keeps the previous sticker image state', (
    tester,
  ) async {
    const roomId = '!sticker-append:example.org';
    final firstSticker = _ownMessage(
      r'$first-sticker',
      content: 'first',
      timestamp: '100',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/first.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final secondSticker = _ownMessage(
      r'$second-sticker',
      content: 'second',
      timestamp: '101',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/second.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
    ];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final firstBubble = find.byKey(
      const ValueKey(r'image-bubble:$first-sticker'),
    );
    expect(firstBubble, findsOneWidget);
    final firstState = tester.state(firstBubble);

    container.read(messageCacheProvider(roomId).notifier).value = [
      firstSticker,
      secondSticker,
    ];
    await tester.pump();

    expect(tester.state(firstBubble), same(firstState));
    expect(find.byType(ImageMessageBubble), findsNWidgets(2));

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('sticker state survives local-to-remote reconciliation in chat', (
    tester,
  ) async {
    const roomId = '!sticker-reconcile:example.org';
    const flightId = 'sticker-anchor';
    const sourceImageUrl = 'https://example.org/remote-sticker.png';
    final localSticker = _ownMessage(
      '$localOutgoingSentPrefix$flightId',
      content: 'sticker',
      timestamp: '100',
      msgType: rust.MessageType.sticker,
      imageUrl: 'https://example.org/local-sticker.png',
      imageWidth: 512,
      imageHeight: 512,
    );
    final remoteSticker = _ownMessage(
      r'$remote-sticker-anchor',
      content: 'sticker',
      timestamp: '101',
      msgType: rust.MessageType.sticker,
      imageUrl: sourceImageUrl,
      imageWidth: 512,
      imageHeight: 512,
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = const [];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    container
        .read(
          localOutgoingMessagesProvider((roomId: roomId, userId: 'anonymous'))
              .notifier,
        )
        .value = [
      LocalOutgoingMessage(
        message: localSticker,
        sourceImageUrl: sourceImageUrl,
      ),
    ];

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    final localState = tester.state(find.byType(ImageMessageBubble));

    container.read(messageCacheProvider(roomId).notifier).value = [
      remoteSticker,
    ];
    await tester.pump();

    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
    await tester.pump();
    expect(tester.state(find.byType(ImageMessageBubble)), same(localState));
  });

  testWidgets('a rapid bottom send cancels flight and inserts smoothly', (
    tester,
  ) async {
    const roomId = '!animated-send:example.org';
    final oldMessage = _ownMessage(
      r'$old-message',
      content: 'old',
      timestamp: DateTime.now().millisecondsSinceEpoch.toString(),
    );
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
      ],
    );
    addTearDown(container.dispose);
    await container.read(roomMembersProvider(roomId).future);
    container.read(messageCacheProvider(roomId).notifier).value = [oldMessage];
    container.read(messageCacheOwnerProvider(roomId).notifier).value =
        'anonymous';
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pump();

    final oldBubble = find.byKey(const ValueKey(r'text-bubble:$old-message'));
    await tester.enterText(find.byType(TextField), 'new');
    await tester.pump(const Duration(milliseconds: 220));
    final initialTop = tester.getTopLeft(oldBubble).dy;
    final canceledFlight = registerSendFlight(
      '${localOutgoingPendingPrefix}already-flying',
      const SendFlightSpec(
        sourceRect: Rect.fromLTWH(20, 500, 80, 80),
        kind: SendFlightKind.sticker,
        child: SizedBox(),
      ),
    );
    expect(hasOngoingSendFlight, isTrue);

    final sendButton = tester.widget<NeuIconButton>(
      find.descendant(
        of: find.byKey(const ValueKey('send_only')),
        matching: find.byType(NeuIconButton),
      ),
    );
    sendButton.onPressed!();
    await tester.pump();

    expect(hasOngoingSendFlight, isFalse);
    await expectLater(canceledFlight, completes);
    expect(find.byType(MessageInsertAnimation), findsOneWidget);
    final lateralSlide = tester.widget<SlideTransition>(
      find.descendant(
        of: find.byType(MessageInsertAnimation),
        matching: find.byType(SlideTransition),
      ),
    );
    expect(lateralSlide.position.value.dx, greaterThan(0));
    expect(tester.getTopLeft(oldBubble).dy, closeTo(initialTop, 0.1));

    await tester.pump(const Duration(milliseconds: 120));
    final middleTop = tester.getTopLeft(oldBubble).dy;
    expect(middleTop, lessThan(initialTop));

    await tester.pump(const Duration(milliseconds: 160));
    expect(tester.getTopLeft(oldBubble).dy, lessThan(middleTop));

    await tester.pump(const Duration(seconds: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  Future<ProviderContainer> openGeometryUnread(
    WidgetTester tester,
    List<rust.ChatMessage> messages, {
    unread.RoomUnreadState? snapshot,
    Size size = const Size(400, 720),
    Set<String> ignored = const {},
    bool material = false,
  }) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const roomId = '!geometry-unread:example.org';
    const account = '@reader:example.org';
    rustApi.entryUnread =
        snapshot ??
        unread.RoomUnreadState(
          unreadCount: 999,
          readEventId: r'$read',
          throughEventId: messages.last.id,
          boundaryResolved: true,
          unreadEventIds: messages
              .where((message) => message.id != r'$read')
              .map((message) => message.id)
              .toList(),
        );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => ignored),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
        messagesProvider(roomId).overrideWith((ref) async => messages),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = account;
    container.read(messageCacheOwnerProvider(roomId).notifier).value = account;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(material: material),
          navigatorObservers: [chatRouteObserver],
          home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets(
    'unread end to end unresolved body is not a clickable target and becomes navigable only when decoded',
    (tester) async {
      final live = List.generate(
        90,
        (i) => _message('\$utd-live-$i', timestamp: '${i + 2}'),
      );
      final container = await openGeometryUnread(
        tester,
        [
          _message(
            r'$utd-target',
            timestamp: '1',
            content: unableToDecryptMessageContent,
          ),
          ...live,
        ],
        snapshot: const unread.RoomUnreadState(
          unreadCount: 1,
          readEventId: r'$read',
          throughEventId: r'$utd-live-89',
          boundaryResolved: true,
          unreadEventIds: [r'$utd-target'],
          unresolvedEventIds: [r'$utd-target'],
        ),
      );
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      container
          .read(messageCacheProvider('!geometry-unread:example.org').notifier)
          .value = [
        _message(r'$utd-target', timestamp: '1', content: 'decoded body'),
        ...live,
      ];
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<UnreadMessagesBanner>(find.byType(UnreadMessagesBanner))
            .count,
        1,
      );
      await tester.tap(find.byType(UnreadMessagesBanner));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(r'text-bubble:$utd-target')),
        findsOneWidget,
      );
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      expect(rustApi.unreadReadEventIds, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final material in [false, true]) {
    for (final lines in [1, 20, 23, 24, 26]) {
      testWidgets(
        'unread single jump fully exposes a fitting target material=$material lines=$lines',
        (tester) async {
          final target = _message(
            r'$single-target',
            timestamp: '100',
            content: List.generate(lines, (i) => 'line $i').join('\n'),
          );
          rustApi.messagesAround = [
            ...List.generate(
              20,
              (i) => _message('\$before-$i', timestamp: '${i + 1}'),
            ),
            target,
            ...List.generate(
              40,
              (i) => _message('\$after-$i', timestamp: '${i + 101}'),
            ),
          ];
          await openGeometryUnread(
            tester,
            List.generate(
              90,
              (i) => _message('\$live-single-$i', timestamp: '${i + 500}'),
            ),
            material: material,
            snapshot: const unread.RoomUnreadState(
              unreadCount: 1,
              readEventId: r'$read',
              boundaryResolved: true,
              unreadEventIds: [r'$single-target'],
            ),
          );
          await tester.tap(find.byType(UnreadMessagesBanner));
          await tester.pumpAndSettle();
          final bubble = tester.getRect(
            find.byKey(const ValueKey(r'text-bubble:$single-target')),
          );
          final input = tester.getRect(
            find.byKey(const ValueKey('message-input-surface')),
          );
          // This text fits in a screen, so one click must expose all of it.
          if (lines <= 23) {
            expect(bubble.top, greaterThanOrEqualTo(material ? 56 : 82));
            expect(bubble.bottom, lessThanOrEqualTo(input.top + 1));
            expect(find.byType(UnreadMessagesBanner), findsNothing);
          } else {
            // Just above the real readable height: clicks must advance, not
            // repeatedly center the same partially covered message.
            for (
              var i = 0;
              i < 5 && find.byType(UnreadMessagesBanner).evaluate().isNotEmpty;
              i++
            ) {
              final before = tester
                  .getTopLeft(
                    find.byKey(const ValueKey(r'text-bubble:$single-target')),
                  )
                  .dy;
              await tester.tap(find.byType(UnreadMessagesBanner));
              await tester.pumpAndSettle();
              if (find.byType(UnreadMessagesBanner).evaluate().isNotEmpty) {
                expect(
                  tester
                      .getTopLeft(
                        find.byKey(
                          const ValueKey(r'text-bubble:$single-target'),
                        ),
                      )
                      .dy,
                  isNot(closeTo(before, 1)),
                );
              }
            }
            expect(find.byType(UnreadMessagesBanner), findsNothing);
          }
          expect(rustApi.unreadReadEventIds, isEmpty);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  testWidgets('unread single jump advances to a different remaining target', (
    tester,
  ) async {
    rustApi.messagesAround = [
      _message(r'$first-target', timestamp: '1'),
      ...List.generate(
        50,
        (i) => _message('\$between-$i', timestamp: '${i + 2}'),
      ),
      _message(r'$second-target', timestamp: '100'),
    ];
    await openGeometryUnread(
      tester,
      List.generate(
        90,
        (i) => _message('\$different-live-$i', timestamp: '${i + 500}'),
      ),
      snapshot: const unread.RoomUnreadState(
        unreadCount: 2,
        readEventId: r'$read',
        boundaryResolved: true,
        unreadEventIds: [r'$first-target', r'$second-target'],
      ),
    );
    await tester.tap(find.byType(UnreadMessagesBanner));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<UnreadMessagesBanner>(find.byType(UnreadMessagesBanner))
          .count,
      1,
    );
    await tester.tap(find.byType(UnreadMessagesBanner));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
      findsOneWidget,
    );
    final second = tester.getRect(
      find.byKey(const ValueKey(r'text-bubble:$second-target')),
    );
    expect(second.top, greaterThanOrEqualTo(82));
    expect(
      second.bottom,
      lessThanOrEqualTo(
        tester
                .getTopLeft(find.byKey(const ValueKey('message-input-surface')))
                .dy +
            1,
      ),
    );
    expect(find.byType(UnreadMessagesBanner), findsNothing);
    expect(rustApi.getMessagesAroundCalls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'unread end to end unknown boundary cannot become an endless earlier-message jump',
    (tester) async {
      await openGeometryUnread(
        tester,
        [_message(r'$already-visible', timestamp: '2')],
        snapshot: const unread.RoomUnreadState(
          unreadCount: 1,
          readEventId: r'$read',
          throughEventId: r'$already-visible',
          boundaryResolved: false,
          unreadEventIds: [r'$already-visible'],
        ),
      );
      expect(find.text('查看较早消息'), findsNothing);
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      expect(rustApi.unreadReadEventIds, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'unread end to end incomplete interval cannot repeat an already seen first target',
    (tester) async {
      final pending = Completer<unread.UnreadPage>();
      rustApi.pendingUnreadPages['next'] = pending;
      rustApi.unreadPages[null] = const unread.UnreadPage(
        eventIds: [r'$jump-target'],
        unresolvedEventIds: [],
        nextBatch: 'next',
        reachedEnd: false,
      );
      rustApi.unreadContext = [_message(r'$jump-target', timestamp: '2')];
      rustApi.messagesAround = [_message(r'$jump-target', timestamp: '2')];
      await openGeometryUnread(
        tester,
        List.generate(
          90,
          (i) => _message('\$unread-live-$i', timestamp: '${500 + i}'),
        ),
        snapshot: const unread.RoomUnreadState(
          unreadCount: 1,
          readEventId: r'$read',
          throughEventId: r'$entry-tail',
          boundaryResolved: false,
        ),
      );
      expect(find.byType(UnreadMessagesBanner), findsOneWidget);
      await tester.tap(find.byType(UnreadMessagesBanner));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey(r'text-bubble:$jump-target')),
        findsOneWidget,
      );
      expect(find.text('查看较早消息'), findsNothing);
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      expect(rustApi.getMessagesAroundCalls, 1);
      expect(rustApi.unreadReadEventIds, isEmpty);
      pending.complete(
        const unread.UnreadPage(
          eventIds: [],
          unresolvedEventIds: [],
          reachedEnd: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final jump in [false, true]) {
    for (final material in [false, true]) {
      testWidgets(
        'unread end to end keyboard keeps ${jump ? 'jumped context' : 'live'} latest bubble above composer material=$material',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          addTearDown(tester.view.resetViewInsets);
          final live = List.generate(
            90,
            (i) => _message('\$keyboard-live-$i', timestamp: '${500 + i}'),
          );
          rustApi.messagesAround = List.generate(
            60,
            (i) => _message('\$keyboard-history-$i', timestamp: '${i + 1}'),
          );
          final container = await openGeometryUnread(
            tester,
            live,
            material: material,
            snapshot: unread.RoomUnreadState(
              unreadCount: 2,
              readEventId: r'$read',
              boundaryResolved: true,
              unreadEventIds: [
                jump ? r'$keyboard-history-0' : r'$not-loaded',
                r'$other-unread',
              ],
            ),
          );
          if (jump) {
            await tester.tap(find.byType(UnreadMessagesBanner));
            await tester.pumpAndSettle();
          }
          final controller = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .controller!;
          controller.jumpTo(controller.position.minScrollExtent);
          await tester.pumpAndSettle();
          final id = jump ? r'$keyboard-history-59' : r'$keyboard-live-89';
          final bubble = find.byKey(ValueKey('text-bubble:$id'));
          expect(bubble, findsOneWidget);
          const draftKey = (
            roomId: '!geometry-unread:example.org',
            userId: '@reader:example.org',
          );
          container.read(replyingToProvider(draftKey).notifier).value =
              live.last;
          await tester.pumpAndSettle();
          await tester.enterText(find.byType(TextField), 'keep my draft');
          await tester.pumpAndSettle();
          final before = tester.getRect(bubble);
          expect(find.byType(UnreadMessagesBanner), findsOneWidget);
          final forwardBefore = List.of(rustApi.messagesAfterEventIds);
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          final after = tester.getRect(bubble);
          final input = tester.getRect(
            find.byKey(const ValueKey('message-input-surface')),
          );
          expect(after.bottom, lessThanOrEqualTo(input.top + 1));
          expect(after.top, closeTo(before.top - 300, 2));
          expect(find.byType(UnreadMessagesBanner), findsOneWidget);
          expect(rustApi.messagesAfterEventIds, forwardBefore);
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'keep my draft',
          );
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(tester.getRect(bubble).top, closeTo(before.top, 2));
          await tester.tap(find.byIcon(Icons.sentiment_satisfied_alt_rounded));
          await tester.pumpAndSettle();
          expect(
            tester.getRect(bubble).bottom,
            lessThanOrEqualTo(
              tester
                      .getTopLeft(
                        find.byKey(const ValueKey('message-input-surface')),
                      )
                      .dy +
                  1,
            ),
          );
          expect(find.byType(UnreadMessagesBanner), findsOneWidget);
          await tester.tap(find.byIcon(Icons.keyboard_rounded));
          tester.view.viewInsets = const FakeViewPadding(bottom: 300);
          await tester.pumpAndSettle();
          expect(tester.getRect(bubble).top, closeTo(before.top - 300, 2));
          tester.view.resetViewInsets();
          await tester.pumpAndSettle();
          expect(tester.getRect(bubble).top, closeTo(before.top, 2));
          expect(
            container.read(replyingToProvider(draftKey))?.id,
            live.last.id,
          );
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'keep my draft',
          );
          expect(rustApi.messagesAfterEventIds, forwardBefore);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  testWidgets(
    'unread navigation follows viewport after scrolling and does not reappear',
    (tester) async {
      final messages = [
        _ownMessage(r'$read', content: 'read', timestamp: '1'),
        ...List.generate(
          24,
          (i) => _message(
            '\$geometry-$i',
            timestamp: '${i + 2}',
            content: 'unread line $i',
          ),
        ),
      ];
      await openGeometryUnread(tester, messages);
      expect(find.byType(UnreadMessagesBanner), findsOneWidget);
      final before = tester
          .widget<UnreadMessagesBanner>(find.byType(UnreadMessagesBanner))
          .count!;
      expect(before, greaterThan(0));
      expect(before, lessThan(24));
      for (
        var i = 0;
        i < 20 && find.byType(UnreadMessagesBanner).evaluate().isNotEmpty;
        i++
      ) {
        await tester.drag(find.byType(CustomScrollView), const Offset(0, 240));
        await tester.pumpAndSettle();
      }
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      final controller = tester
          .widget<CustomScrollView>(find.byType(CustomScrollView))
          .controller!;
      controller.jumpTo(controller.position.minScrollExtent);
      await tester.pumpAndSettle();
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('unread navigation follows viewport when the window grows', (
    tester,
  ) async {
    final messages = [
      _ownMessage(r'$read', content: 'read', timestamp: '1'),
      ...List.generate(
        6,
        (i) => _message(
          '\$geometry-$i',
          timestamp: '${i + 2}',
          content: 'unread line $i',
        ),
      ),
    ];
    await openGeometryUnread(tester, messages, size: const Size(400, 360));
    expect(find.byType(UnreadMessagesBanner), findsOneWidget);
    await tester.binding.setSurfaceSize(const Size(400, 1200));
    await tester.pumpAndSettle();
    expect(find.byType(UnreadMessagesBanner), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'unread navigation follows viewport but excludes own and ignored messages',
    (tester) async {
      await openGeometryUnread(
        tester,
        [
          _ownMessage(r'$read', content: 'read', timestamp: '1'),
          _ownMessage(r'$own', content: 'own', timestamp: '2'),
          _message(r'$ignored', timestamp: '3'),
        ],
        ignored: const {'@alice:example.org'},
      );
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'unread navigation follows viewport with frozen async pages and unknown counts',
    (tester) async {
      final pending = Completer<unread.UnreadPage>();
      rustApi.pendingUnreadPages[null] = pending;
      final messages = [
        _ownMessage(r'$read', content: 'read', timestamp: '1'),
        _message(r'$async-unread', timestamp: '2'),
      ];
      await openGeometryUnread(
        tester,
        messages,
        snapshot: const unread.RoomUnreadState(
          unreadCount: 999,
          readEventId: r'$read',
          throughEventId: r'$async-unread',
          boundaryResolved: true,
        ),
      );
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      expect(rustApi.unreadPageCalls, [(r'$read', r'$async-unread', null)]);
      expect(rustApi.markRoomAsReadCalls, greaterThan(0));
      pending.complete(
        const unread.UnreadPage(
          eventIds: [r'$async-unread'],
          unresolvedEventIds: [],
          reachedEnd: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets(
    'unread navigation follows viewport and discards a late page after account switch',
    (tester) async {
      final pending = Completer<unread.UnreadPage>();
      rustApi.pendingUnreadPages[null] = pending;
      final container = await openGeometryUnread(
        tester,
        [_message(r'$async-unread', timestamp: '2')],
        snapshot: const unread.RoomUnreadState(
          unreadCount: 1,
          readEventId: r'$read',
          throughEventId: r'$async-unread',
          boundaryResolved: true,
        ),
      );
      expect(rustApi.unreadPageCalls.length, 1);
      container.read(activeUserIdProvider.notifier).value =
          '@other:example.org';
      await tester.pumpAndSettle();
      pending.complete(
        const unread.UnreadPage(
          eventIds: [r'$late-unread'],
          unresolvedEventIds: [],
          reachedEnd: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(UnreadMessagesBanner), findsNothing);
      expect(find.text('账号已切换'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final album in [false, true]) {
    testWidgets(
      'unread navigation follows viewport for ${album ? 'mosaic' : 'covered stack'} images',
      (tester) async {
        rust.ChatMessage image(String id, String timestamp, {String? root}) =>
            rust.ChatMessage(
              id: id,
              senderId: '@alice:example.org',
              senderName: 'Alice',
              content: 'image',
              mentionedUserIds: const [],
              mentionsRoom: false,
              timestamp: timestamp,
              isMe: false,
              msgType: rust.MessageType.image,
              imageUrl: 'https://example.org/$id.jpg',
              imageWidth: 400,
              imageHeight: 300,
              imageMetadata: rust.ImageMessageMetadata(
                albumRoot: root,
                blurhash: 'LEHV6nWB2yk8pyo0adR*.7kCMdnj',
                spoiler: false,
              ),
              isEdited: false,
              editHistory: const [],
              reactions: const [],
              readers: const [],
              totalMembers: 2,
            );
        await openGeometryUnread(tester, [
          _ownMessage(r'$read', content: 'read', timestamp: '1'),
          image(r'$image-first', '2'),
          image(r'$image-last', '3', root: album ? r'$image-first' : null),
        ]);
        if (album) {
          expect(find.byType(UnreadMessagesBanner), findsNothing);
        } else {
          expect(
            tester
                .widget<UnreadMessagesBanner>(find.byType(UnreadMessagesBanner))
                .count,
            1,
          );
          await tester.tap(find.byType(UnreadMessagesBanner));
          await tester.pumpAndSettle();
          expect(find.byType(UnreadMessagesBanner), findsNothing);
        }
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }

  for (final material in [false, true]) {
    for (final count in [1, 3]) {
      testWidgets(
        'unread navigation follows viewport for $count visible messages material=$material',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(400, 720));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          const roomId = '!visible-unread:example.org';
          const account = '@alice:example.org';
          final messages = [
            _ownMessage(r'$read', content: 'already read', timestamp: '1'),
            ...List.generate(
              count,
              (i) => _message(
                '\$unread-$i',
                timestamp: '${i + 2}',
                content: 'visible unread $i',
              ),
            ),
          ];
          rustApi.entryUnread = unread.RoomUnreadState(
            unreadCount: count,
            readEventId: r'$read',
            throughEventId: messages.last.id,
            boundaryResolved: true,
            unreadEventIds: messages
                .skip(1)
                .map((message) => message.id)
                .toList(),
            unresolvedEventIds: const [],
          );
          final container = ProviderContainer(
            overrides: [
              ignoredUserIdsProvider.overrideWith(
                (ref) async => const <String>{},
              ),
              roomMembersProvider(roomId).overrideWith((ref) async => const []),
              messagesProvider(roomId).overrideWith((ref) async => messages),
            ],
          );
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = account;
          container.read(messageCacheOwnerProvider(roomId).notifier).value =
              account;
          container.read(messageCachePrimedProvider(roomId).notifier).value =
              true;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: neuTestTheme(material: material),
                home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (var i = 0; i < count; i++) {
            final bubble = find.byKey(ValueKey('text-bubble:\$unread-$i'));
            expect(bubble, findsOneWidget);
            final rect = tester.getRect(bubble);
            expect(rect.top, greaterThan(100));
            expect(rect.bottom, lessThan(660));
          }
          expect(find.byType(UnreadMessagesBanner), findsNothing);
          expect(rustApi.readLifecycle.first, 'capture');
          expect(rustApi.markRoomAsReadCalls, greaterThan(0));
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  testWidgets('unread navigation follows viewport for one oversized message', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    const roomId = '!long-unread:example.org';
    const account = '@alice:example.org';
    final messages = [
      _ownMessage(r'$read', content: 'already read', timestamp: '1'),
      _message(
        r'$long-unread',
        timestamp: '2',
        content: List.generate(80, (i) => 'unread line $i').join('\n'),
      ),
    ];
    rustApi.entryUnread = const unread.RoomUnreadState(
      unreadCount: 1,
      readEventId: r'$read',
      throughEventId: r'$long-unread',
      boundaryResolved: true,
      unreadEventIds: [r'$long-unread'],
      unresolvedEventIds: [],
    );
    final container = ProviderContainer(
      overrides: [
        ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
        roomMembersProvider(roomId).overrideWith((ref) async => const []),
        messagesProvider(roomId).overrideWith((ref) async => messages),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = account;
    container.read(messageCacheOwnerProvider(roomId).notifier).value = account;
    container.read(messageCachePrimedProvider(roomId).notifier).value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .getSize(find.byKey(const ValueKey(r'text-bubble:$long-unread')))
          .height,
      greaterThan(720),
    );
    expect(find.byType(UnreadMessagesBanner), findsOneWidget);
    for (
      var i = 0;
      i < 8 && find.byType(UnreadMessagesBanner).evaluate().isNotEmpty;
      i++
    ) {
      final bubble = find.byKey(const ValueKey(r'text-bubble:$long-unread'));
      final before = tester.getTopLeft(bubble).dy;
      await tester.tap(find.byType(UnreadMessagesBanner));
      await tester.pumpAndSettle();
      if (find.byType(UnreadMessagesBanner).evaluate().isNotEmpty) {
        expect(tester.getTopLeft(bubble).dy, isNot(closeTo(before, 1)));
      }
    }
    expect(find.byType(UnreadMessagesBanner), findsNothing);
    expect(rustApi.unreadReadEventIds, isEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  for (final material in [false, true]) {
    for (final hasMarker in [false, true]) {
      testWidgets(
        'entry unread survives auto-read and jumps to history material=$material marker=$hasMarker',
        (tester) async {
          const roomId = '!unread-entry:example.org';
          const account = '@alice:example.org';
          final target = _message(r'$first-unread', timestamp: '201');
          final entryLabel = hasMarker ? '123 条未读 · 跳到最早未读' : '查看较早消息';
          rustApi.entryUnread = unread.RoomUnreadState(
            unreadCount: 123,
            readEventId: hasMarker ? r'$read-boundary' : null,
            boundaryResolved: hasMarker,
            unreadEventIds: hasMarker
                ? [target.id, ...List.generate(122, (i) => '\$other-unread-$i')]
                : null,
          );
          rustApi.unreadContext = [target];
          rustApi.messagesAround = [target];
          final container = ProviderContainer(
            overrides: [
              ignoredUserIdsProvider.overrideWith(
                (ref) async => const <String>{},
              ),
              roomMembersProvider(roomId).overrideWith((ref) async => const []),
              messagesProvider(roomId).overrideWith(
                (ref) async => List.generate(
                  100,
                  (i) => _message('\$latest-$i', timestamp: '${i + 500}'),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value = account;
          container.read(messageCacheOwnerProvider(roomId).notifier).value =
              account;
          container.read(messageCachePrimedProvider(roomId).notifier).value =
              true;
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: neuTestTheme(material: material),
                home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(rustApi.readLifecycle.first, 'capture');
          expect(rustApi.markRoomAsReadCalls, greaterThan(0));
          if (!hasMarker) {
            expect(find.byType(UnreadMessagesBanner), findsNothing);
            expect(find.text('查看较早消息'), findsNothing);
            expect(rustApi.unreadReadEventIds, isEmpty);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump();
            return;
          }
          expect(find.text(entryLabel), findsOneWidget);
          final controller = tester
              .widget<CustomScrollView>(find.byType(CustomScrollView))
              .controller!;
          expect(controller.offset, controller.position.minScrollExtent);
          // A failed context request must keep the entry available for retry.
          if (hasMarker) {
            rustApi.messagesAroundError = StateError('offline');
          } else {
            rustApi.unreadContextError = StateError('offline');
          }
          await tester.tap(find.text(entryLabel));
          await tester.pumpAndSettle();
          expect(find.text(entryLabel), findsOneWidget);
          rustApi.unreadContextError = null;
          rustApi.messagesAroundError = null;
          await tester.tap(find.text(entryLabel));
          await tester.pumpAndSettle();
          if (hasMarker) {
            expect(rustApi.getMessagesAroundCalls, greaterThan(1));
            expect(find.text('122 条未读 · 跳到最早未读'), findsOneWidget);
          } else {
            expect(rustApi.unreadReadEventIds.last, isNull);
          }
          expect(
            find.byKey(const ValueKey(r'text-bubble:$first-unread')),
            findsOneWidget,
          );
          expect(find.text(entryLabel), findsNothing);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }

  testWidgets(
    'room auto-reads wait until the entry read position is captured',
    (tester) async {
      const roomId = '!unread-capture:example.org';
      const account = '@alice:example.org';
      rustApi.pendingUnreadState = Completer<unread.RoomUnreadState>();
      final container = ProviderContainer(
        overrides: [
          ignoredUserIdsProvider.overrideWith((ref) async => const <String>{}),
          roomMembersProvider(roomId).overrideWith((ref) async => const []),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = account;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const ChatDetailPage(roomId: roomId, roomName: 'Room'),
          ),
        ),
      );
      await tester.pump();
      expect(container.read(roomViewOwnerProvider(roomId)), isNull);
      expect(rustApi.markRoomAsReadCalls, 0);
      rustApi.pendingUnreadState!.complete(
        const unread.RoomUnreadState(unreadCount: 123, readEventId: r'$read'),
      );
      await tester.pumpAndSettle();
      expect(container.read(roomViewOwnerProvider(roomId)), account);
      expect(rustApi.markRoomAsReadCalls, greaterThan(0));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('opening a chat reads the room without the explicit clear', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(roomId: '!room:example.org', roomName: 'Room'),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(rustApi.markRoomAsReadCalls, greaterThan(0));
    // Opening a room relies on the store-checked inner clear (explicit:false);
    // the unconditional explicit write is reserved for the explicit
    // "标记为已读" actions.
    expect(rustApi.lastMarkReadExplicit, isFalse);
  });

  testWidgets('an open chat follows server-side room renames', (tester) async {
    rust.ChatRoom room(String name) => rust.ChatRoom(
      id: '!room:example.org',
      name: name,
      lastMessage: '',
      lastMessageTime: '',
      lastEventId: '',
      unreadCount: 0,
      isMarkedUnread: false,
      roomType: 'group',
      isEncrypted: false,
      isMuted: false,
      roomState: 'joined',
    );
    rustApi.chatRooms = [room('Old name')];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Old name',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.pump();
    expect(find.text('Old name'), findsWidgets);

    // Another client renamed the room; the next room-list snapshot carries it.
    rustApi.chatRooms = [room('New name')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();

    expect(find.text('Old name'), findsNothing);
    expect(find.text('New name'), findsWidgets);

    // Hiding the currently open room must not stop metadata updates.
    await container.read(hiddenRoomsProvider.notifier).hideRooms([
      '!room:example.org',
    ]);
    await tester.pump();
    rustApi.chatRooms = [room('Hidden room name')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();

    expect(find.text('Hidden room name'), findsWidgets);
  });

  testWidgets('repeated local room names wait for the matching event echo', (
    tester,
  ) async {
    rust.ChatRoom room(String name, String nameEventId) => rust.ChatRoom(
      id: '!room:example.org',
      name: name,
      nameEventId: nameEventId,
      lastMessage: '',
      lastMessageTime: '',
      lastEventId: '',
      unreadCount: 0,
      isMarkedUnread: false,
      roomType: 'group',
      isEncrypted: false,
      isMuted: false,
      roomState: 'joined',
    );
    rustApi.chatRooms = [room('Name A', r'$name-a0')];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatDetailPage(
            roomId: '!room:example.org',
            roomName: 'Name A',
            nameEventId: r'$name-a0',
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.byIcon(Icons.more_vert_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('房间管理'));
    await tester.pumpAndSettle();

    final management = tester.widget<RoomManagementPage>(
      find.byType(RoomManagementPage),
    );
    management.onRoomDetailsChanged!(
      const RoomNamePatch(
        roomId: '!room:example.org',
        name: 'Name B',
        nameEventId: r'$name-b',
      ),
    );
    management.onRoomDetailsChanged!(
      const RoomNamePatch(
        roomId: '!room:example.org',
        name: 'Name A',
        nameEventId: r'$name-a2',
      ),
    );
    await tester.pump();
    Navigator.of(tester.element(find.byType(RoomManagementPage))).pop();
    await tester.pumpAndSettle();

    // Re-deliver the cached original A event. Its equal display value must not
    // confirm the final A edit.
    rustApi.chatRooms = [room('Name A', r'$name-a0')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name A'), findsWidgets);

    // B is the real echo of the superseded first edit. Keep the final A.
    rustApi.chatRooms = [room('Name B', r'$name-b')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name B'), findsNothing);
    expect(find.text('Name A'), findsWidgets);

    // Only the distinct event ID of the final A confirms the latest edit.
    rustApi.chatRooms = [room('Name A', r'$name-a2')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name A'), findsWidgets);

    // A real remote edit may reuse B's value, but has its own event ID.
    rustApi.chatRooms = [room('Name B', r'$name-b-remote')];
    container.invalidate(allChatRoomsProvider);
    await tester.pump();
    await tester.pump();
    expect(find.text('Name B'), findsWidgets);
  });
}
