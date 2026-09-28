import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:matter/features/markdown/markdown_source_store.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/hidden_rooms_provider.dart';
import 'package:matter/providers/message_cache_persistence.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

/// A [SharedPreferencesStorePlatform] that serves reads from the wrapped
/// store but fails every write, simulating a snapshot update that never
/// reaches disk.
class _FailingWritePreferencesStore extends SharedPreferencesStorePlatform {
  _FailingWritePreferencesStore(this._inner);

  final SharedPreferencesStorePlatform _inner;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;

  @override
  Future<bool> remove(String key) => _inner.remove(key);

  @override
  Future<bool> clear() => _inner.clear();

  @override
  Future<Map<String, Object>> getAll() => _inner.getAll();
}

class _FakeRustApi implements RustLibApi {
  final syncEvents = StreamController<rust.SyncEvent>.broadcast();
  final typingEvents = StreamController<rust.TypingNotification>.broadcast();
  int ignoredUsersCalls = 0;
  List<String> ignoredUsers = const [];
  bool ignoredUsersFromServer = true;
  Object? ignoredUsersError;
  Completer<List<String>>? pendingIgnoredUsers;
  int getMessagesCalls = 0;
  int markRoomAsReadCalls = 0;
  bool? lastMarkReadExplicit;
  int chatRoomsCalls = 0;
  List<String>? chatRoomsIgnoredFilter;
  bool? chatRoomsAuthoritative;
  int ungroupedRoomsCalls = 0;
  int spaceChildrenCalls = 0;
  int knockRequestsCalls = 0;
  int membersCalls = 0;
  int contactsCalls = 0;
  Completer<List<rust.ChatMessage>>? pendingMessages;
  Completer<List<rust.ChatRoom>>? pendingChatRooms;
  List<rust.ChatRoom> chatRooms = const [];
  List<rust.Contact> contacts = const [];

  @override
  rust.ConnectionStatus crateApiMatrixGetConnectionStatus() {
    return rust.ConnectionStatus.connected;
  }

  @override
  Future<rust.IgnoredUsers> crateApiMatrixGetIgnoredUsers() async {
    ignoredUsersCalls++;
    if (ignoredUsersError case final error?) throw error;
    final pending = pendingIgnoredUsers;
    if (pending != null) {
      return rust.IgnoredUsers(
        userIds: await pending.future,
        fromServer: ignoredUsersFromServer,
      );
    }
    return rust.IgnoredUsers(
      userIds: ignoredUsers,
      fromServer: ignoredUsersFromServer,
    );
  }

  @override
  Future<List<rust.ChatMessage>> crateApiMatrixGetMessages({
    required String roomId,
  }) {
    getMessagesCalls++;
    return pendingMessages?.future ?? Future.value(const []);
  }

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
    lastMarkReadExplicit = explicit;
    return true;
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetChatRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) {
    chatRoomsCalls++;
    chatRoomsIgnoredFilter = ignoredUserIds;
    chatRoomsAuthoritative = authoritative;
    return pendingChatRooms?.future ?? Future.value(chatRooms);
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetUngroupedRooms({
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    ungroupedRoomsCalls++;
    return const [];
  }

  @override
  Future<List<rust.ChatRoom>> crateApiMatrixGetSpaceChildren({
    required String spaceId,
    List<String>? ignoredUserIds,
    required bool authoritative,
  }) async {
    spaceChildrenCalls++;
    return const [];
  }

  @override
  Future<List<rust.KnockRequest>> crateApiMatrixGetRoomKnockRequests({
    required String roomId,
  }) async {
    knockRequestsCalls++;
    return const [];
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetRoomMembers({
    required String roomId,
  }) async {
    membersCalls++;
    return const [];
  }

  @override
  Future<List<rust.Contact>> crateApiMatrixGetContacts() async {
    contactsCalls++;
    return contacts;
  }

  Completer<String>? pendingSend;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    final pending = pendingSend ??= Completer<String>();
    return pending.future;
  }

  @override
  Stream<rust.SyncEvent> crateApiMatrixWatchSyncEvents() => syncEvents.stream;

  @override
  Stream<rust.TypingNotification> crateApiMatrixWatchTypingNotifications() =>
      typingEvents.stream;

  @override
  Future<String?> crateApiMatrixGetAccessToken() async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

Future<WidgetRef> _captureRef(WidgetTester tester) async {
  WidgetRef? ref;
  await tester.pumpWidget(
    ProviderScope(
      child: Consumer(
        builder: (context, r, _) {
          ref = r;
          return Container();
        },
      ),
    ),
  );
  return ref!;
}

rust.ChatMessage _message(String id, String timestamp) => rust.ChatMessage(
  id: id,
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: id,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: timestamp,
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

rust.ChatRoom _room(
  String id, {
  String name = 'Room',
  bool isEncrypted = false,
}) => rust.ChatRoom(
  id: id,
  name: name,
  lastMessage: '',
  lastMessageTime: '0',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: 'group',
  isEncrypted: isEncrypted,
  isMuted: false,
  roomState: 'joined',
);

final _refreshMessagesRefProvider = FutureProvider.family<void, String>(
  (ref, roomId) => refreshMessagesRef(ref, roomId),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() async {
    await rustApi.syncEvents.close();
    await rustApi.typingEvents.close();
    RustLib.dispose();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    // The ignore-list globals are process-wide; drop leftovers from earlier
    // tests so a stale confirmed list cannot leak into the next account
    // snapshot read.
    resetIgnoredListAccountState('@alice:example.org');
    rustApi.ignoredUsersCalls = 0;
    rustApi.ignoredUsers = const [];
    rustApi.ignoredUsersFromServer = true;
    rustApi.ignoredUsersError = null;
    rustApi.pendingIgnoredUsers = null;
    rustApi.getMessagesCalls = 0;
    rustApi.markRoomAsReadCalls = 0;
    rustApi.lastMarkReadExplicit = null;
    rustApi.chatRooms = const [];
    rustApi.pendingChatRooms = null;
    rustApi.chatRoomsCalls = 0;
    rustApi.chatRoomsIgnoredFilter = null;
    rustApi.chatRoomsAuthoritative = null;
    rustApi.ungroupedRoomsCalls = 0;
    rustApi.spaceChildrenCalls = 0;
    rustApi.knockRequestsCalls = 0;
    rustApi.membersCalls = 0;
    rustApi.contactsCalls = 0;
    rustApi.contacts = const [];
    rustApi.pendingSend = null;
    rustApi.pendingMessages = null;
  });

  group('clearActiveSessionState', () {
    testWidgets('resets session-related providers', (tester) async {
      final ref = await _captureRef(tester);

      ref.read(isLoggedInProvider.notifier).value = true;
      ref.read(currentUserProvider.notifier).value = const CurrentUser(
        id: '@alice:example.org',
        displayName: 'Alice',
        homeserver: 'https://example.org',
      );
      ref.read(currentAccessTokenProvider.notifier).value = 'token';
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(connectionProvider.notifier).value =
          AppConnectionState.connected;

      clearActiveSessionState(ref);

      expect(ref.read(isLoggedInProvider), isFalse);
      expect(ref.read(currentUserProvider), isNull);
      expect(ref.read(currentAccessTokenProvider), isNull);
      expect(ref.read(activeUserIdProvider), isNull);
      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });

    testWidgets('can mark session ready when requested', (tester) async {
      final ref = await _captureRef(tester);

      clearActiveSessionState(ref, markSessionReady: true);

      expect(ref.read(sessionReadyProvider), isTrue);
    });

    testWidgets('drops ignore-list freshness of the outgoing account', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      ref.read(sessionReadyProvider.notifier).value = true;
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';

      // A completed server fetch marks the list confirmed.
      await ref.read(chatRoomsProvider.future);
      expect(rustApi.chatRoomsAuthoritative, isTrue);

      // Tearing the session down (logout, account switch) must drop that
      // freshness: the sync subscription is stopped while the session is
      // down, so the demoting event can be missed across a re-login.
      clearActiveSessionState(ref);

      ref.read(sessionReadyProvider.notifier).value = true;
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      await ref.read(chatRoomsProvider.future);
      await tester.pump();

      expect(rustApi.chatRoomsAuthoritative, isFalse);
    });

    testWidgets(
      're-establishing a session drops leftover ignore-list freshness',
      (tester) async {
        final ref = await _captureRef(tester);
        ref.read(sessionReadyProvider.notifier).value = true;
        ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';

        // A completed server fetch marks the list confirmed.
        await ref.read(chatRoomsProvider.future);
        expect(rustApi.chatRoomsAuthoritative, isTrue);

        // Account switch (and its rollback) funnels through
        // applyActiveSessionState. The confirmed list from the previous
        // session must not survive: cross-device changes that landed while
        // the session was down were never demoted. Hold the revalidation so
        // the post-switch state is observed deterministically.
        rustApi.pendingIgnoredUsers = Completer<List<String>>();
        ref.read(sessionReadyProvider.notifier).value = false;
        await applyActiveSessionState(
          ref,
          userId: '@alice:example.org',
          displayName: 'Alice',
          homeserver: 'https://example.org',
        );
        ref.read(sessionReadyProvider.notifier).value = true;
        await ref.read(chatRoomsProvider.future);
        await tester.pump();
        expect(rustApi.chatRoomsAuthoritative, isFalse);

        // Revalidation confirms the list again.
        rustApi.pendingIgnoredUsers!.complete(const []);
        await tester.pump();
        await ref.read(chatRoomsProvider.future);
        await tester.pump();
        expect(rustApi.chatRoomsAuthoritative, isTrue);
      },
    );
  });

  group('invalidateSessionCollections', () {
    testWidgets('resets room-local optimistic state', (tester) async {
      final ref = await _captureRef(tester);
      const roomId = '!room:example.org';
      ref
          .read(roomUnreadOverrideProvider(roomId).notifier)
          .value = const RoomUnreadOverride(
        unread: true,
        baselineUnreadCount: 0,
        baselineMarkedUnread: false,
        baselineLastEventId: '0',
      );
      ref.read(roomAutoReadSuppressedProvider(roomId).notifier).value = true;

      invalidateSessionCollections(ref);
      await tester.pump();

      expect(ref.read(roomUnreadOverrideProvider(roomId)), isNull);
      expect(ref.read(roomAutoReadSuppressedProvider(roomId)), isFalse);
    });
  });

  testWidgets('contacts exclude ignored users', (tester) async {
    rustApi.ignoredUsers = const ['@ignored:example.org'];
    rustApi.contacts = const [
      rust.Contact(
        id: '@ignored:example.org',
        name: 'Ignored',
        status: 'offline',
      ),
      rust.Contact(
        id: '@visible:example.org',
        name: 'Visible',
        status: 'online',
      ),
    ];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    final contacts = await container.read(contactsProvider.future);

    expect(contacts.map((contact) => contact.id), ['@visible:example.org']);
    expect(rustApi.contactsCalls, 1);
  });

  testWidgets('contacts restore unignored users', (tester) async {
    rustApi.ignoredUsers = const ['@ignored:example.org'];
    rustApi.contacts = const [
      rust.Contact(
        id: '@ignored:example.org',
        name: 'Ignored',
        status: 'offline',
      ),
      rust.Contact(
        id: '@visible:example.org',
        name: 'Visible',
        status: 'online',
      ),
    ];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    var contacts = await container.read(contactsProvider.future);
    expect(contacts.map((contact) => contact.id), ['@visible:example.org']);

    // Unignore via the confirmed write-through path the management page uses.
    await persistIgnoredUserList('@alice:example.org', const {});
    rustApi.ignoredUsers = const [];
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();

    contacts = await container.read(contactsProvider.future);
    expect(contacts.map((contact) => contact.id), [
      '@ignored:example.org',
      '@visible:example.org',
    ]);

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('contacts survive a failing ignore-list fetch', (tester) async {
    rustApi.ignoredUsersError = StateError('offline');
    rustApi.contacts = const [
      rust.Contact(
        id: '@ignored:example.org',
        name: 'Ignored',
        status: 'offline',
      ),
      rust.Contact(
        id: '@visible:example.org',
        name: 'Visible',
        status: 'online',
      ),
    ];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    // No persisted snapshot and a failing fetch: the contact list must not
    // go down with the ignore list (same degradation as _previewIgnoreFilter),
    // so the unfiltered contacts are served instead of an error.
    final contacts = await container.read(contactsProvider.future);

    expect(contacts.map((contact) => contact.id), [
      '@ignored:example.org',
      '@visible:example.org',
    ]);
    expect(rustApi.contactsCalls, 1);
  });

  testWidgets(
    'a retry completing after the page is disposed is not marked failed',
    (tester) async {
      // Regression: the old retry path wrapped the post-send local
      // bookkeeping (mark sent, timeline poll) in the same try as the send.
      // Leaving the page while the request was in flight made ref.read throw
      // there, so the catch restored the failed entry and rethrew — reporting
      // a message the server had already accepted as failed and inviting a
      // duplicate retry.
      final container = ProviderContainer();
      addTearDown(container.dispose);
      const key = (
        roomId: '!retry-disposed:example.org',
        userId: '@alice:example.org',
      );
      final failedId = '${localOutgoingFailedPrefix}1';
      container.read(localOutgoingMessagesProvider(key).notifier).value = [
        LocalOutgoingMessage(
          message: _message(failedId, '0'),
          sourceImageUrl: null,
        ),
      ];

      WidgetRef? ref;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final pendingSend = Completer<String>();
      rustApi.pendingSend = pendingSend;
      final retry = retryFailedLocalMessage(ref!, key, failedId);
      await tester.pump();

      // Leave the page while the retried send is still in flight.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();

      // The server accepts the message after the page is gone: the retry
      // must complete cleanly instead of restoring the failed entry and
      // rethrowing. The pending entry is dropped through the captured
      // notifier — the provider outlives the page, so a leftover entry
      // would resurface as a stuck "sending" bubble on the next visit,
      // while the echo renders as a normal message via sync.
      pendingSend.complete(r'$retried');
      await retry;
      expect(
        container
            .read(localOutgoingMessagesProvider(key))
            .map((message) => message.message.id),
        isEmpty,
      );
    },
  );

  testWidgets('a successful retry saves the original markdown source', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    const key = (
      roomId: '!retry-markdown:example.org',
      userId: '@alice:example.org',
    );
    const failedId = '${localOutgoingFailedPrefix}markdown';
    const eventId = r'$retried-markdown';
    const source = '| a | b |\n|---|---|\n| **one** | two |';
    const body = 'a | b\none | two';
    const formattedBody =
        '<table><tr><th>a</th><th>b</th></tr>'
        '<tr><td><strong>one</strong></td><td>two</td></tr></table>';
    container.read(activeUserIdProvider.notifier).value = key.userId;
    container.read(localOutgoingMessagesProvider(key).notifier).value = [
      LocalOutgoingMessage(
        message: rust.ChatMessage(
          id: failedId,
          senderId: key.userId,
          senderName: 'Alice',
          content: body,
          formattedBody: formattedBody,
          mentionedUserIds: const [],
          mentionsRoom: false,
          timestamp: '0',
          isMe: true,
          msgType: rust.MessageType.text,
          isEdited: false,
          editHistory: const [],
          reactions: const [],
          readers: const [],
          totalMembers: 2,
        ),
        markdownSource: source,
      ),
    ];

    WidgetRef? ref;
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, r, _) {
            ref = r;
            return const SizedBox.shrink();
          },
        ),
      ),
    );
    final pendingSend = Completer<String>();
    rustApi.pendingSend = pendingSend;
    final retry = retryFailedLocalMessage(ref!, key, failedId);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    pendingSend.complete(eventId);
    await retry;

    expect(
      await const MarkdownSourceStore().load(
        userId: key.userId,
        roomId: key.roomId,
        eventId: eventId,
        body: body,
        formattedBody: formattedBody,
        allowPersistence: true,
      ),
      source,
    );
  });

  testWidgets('refreshes ignored users only for their sync event', (
    tester,
  ) async {
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    final ignoredSubscription = container.listen(
      ignoredUserIdsProvider,
      (_, _) {},
      fireImmediately: true,
    );

    await container.read(ignoredUserIdsProvider.future);
    // The provider resolves with the persisted snapshot first; the network
    // refresh happens in the background.
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
    await tester.pump();
    await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 2);

    ignoredSubscription.close();
    syncSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('SyncCompleted retries an errored ignore-list provider', (
    tester,
  ) async {
    rustApi.ignoredUsersError = StateError('offline');
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    final ignoredSubscription = container.listen(
      ignoredUserIdsProvider,
      (_, _) {},
      fireImmediately: true,
    );

    // No persisted snapshot: the failed fetch leaves the provider in its
    // error state, which nothing else would recover (an empty ignore list
    // never emits IgnoredUsersChanged).
    await expectLater(
      container.read(ignoredUserIdsProvider.future),
      throwsStateError,
    );
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump();
    }
    expect(container.read(ignoredUserIdsProvider).hasError, isTrue);
    final callsBefore = rustApi.ignoredUsersCalls;

    // Connectivity returns: a completed sync cycle retries the fetch.
    rustApi.ignoredUsersError = null;
    rustApi.ignoredUsers = const ['@blocked:example.org'];
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    await tester.pump();
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@blocked:example.org',
    });
    expect(rustApi.ignoredUsersCalls, greaterThan(callsBefore));

    ignoredSubscription.close();
    syncSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('ignore-list recovery retries are throttled', (tester) async {
    rustApi.ignoredUsersError = StateError('offline');
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    // A distinct account: the throttle record is global per namespace, and
    // other tests may have attempted a recovery moments ago.
    container.read(activeUserIdProvider.notifier).value =
        '@throttle-test:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    final ignoredSubscription = container.listen(
      ignoredUserIdsProvider,
      (_, _) {},
      fireImmediately: true,
    );

    await expectLater(
      container.read(ignoredUserIdsProvider.future),
      throwsStateError,
    );
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump();
    }
    final callsBefore = rustApi.ignoredUsersCalls;

    // A sync cycle retries the failed fetch (the invalidation may rebuild
    // lazily, so poll until the fetch actually happened).
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    var retried = false;
    for (var attempt = 0; attempt < 10 && !retried; attempt++) {
      await tester.pump();
      retried = rustApi.ignoredUsersCalls > callsBefore;
    }
    expect(retried, isTrue);
    final callsAfterFirstRetry = rustApi.ignoredUsersCalls;

    // While the endpoint keeps failing, the throttled recovery must not
    // re-fire on every subsequent sync cycle.
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    for (var attempt = 0; attempt < 10; attempt++) {
      await tester.pump();
    }
    expect(rustApi.ignoredUsersCalls, callsAfterFirstRetry);

    // Once the throttle window elapses, the next sync cycle retries again.
    await tester.pump(const Duration(seconds: 31));
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    for (
      var attempt = 0;
      attempt < 10 && rustApi.ignoredUsersCalls == callsAfterFirstRetry;
      attempt++
    ) {
      await tester.pump();
    }
    expect(rustApi.ignoredUsersCalls, callsAfterFirstRetry + 1);

    ignoredSubscription.close();
    syncSubscription.close();
    // Leave no recovery-throttle record behind for this namespace: a later
    // test using the same account would be silently throttled.
    resetIgnoredListAccountState('@throttle-test:example.org');
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('typing state resets when the session changes', (tester) async {
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final typingSubscription = container.listen(
      typingStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    // Watch first: the raw auto-dispose state needs a listener for the
    // written value to survive the frame.
    final roomTyping = container.read(typingUsersProvider('!room:example.org'));
    expect(roomTyping, isEmpty);

    rustApi.typingEvents.add(
      rust.TypingNotification(
        roomId: '!room:example.org',
        userIds: const ['@bob:example.org'],
      ),
    );
    await tester.pump();
    expect(container.read(typingUsersProvider('!room:example.org')), {
      '@bob:example.org',
    });

    // Switch account: typing rows are keyed per account, so the previous
    // account's state must not leak into the new account's view (the 5s
    // auto-clear timer died with the old session).
    container.read(activeUserIdProvider.notifier).value = '@carol:example.org';
    await tester.pump();
    expect(container.read(typingUsersProvider('!room:example.org')), isEmpty);

    typingSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a sync event lets the store remove a cross-device un-ignore', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@blocked:example.org'],
    });
    rustApi.ignoredUsers = const ['@blocked:example.org'];

    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );
    final ignoredSubscription = container.listen(
      ignoredUserIdsProvider,
      (_, _) {},
      fireImmediately: true,
    );

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@blocked:example.org',
    });
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump();
    }
    final callsBeforeEvent = rustApi.ignoredUsersCalls;

    // The direct server read fails, but the account-data sync event means
    // the SDK store already contains the complete new list.
    rustApi.ignoredUsersFromServer = false;
    rustApi.ignoredUsers = const [];
    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());

    await tester.pump();
    await container.read(ignoredUserIdsProvider.future);
    for (var attempt = 0; attempt < 6; attempt++) {
      await tester.pump();
    }

    expect(rustApi.ignoredUsersCalls, greaterThan(callsBeforeEvent));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('ignored_users_v1_@alice:example.org'), isEmpty);
    expect(await container.read(ignoredUserIdsProvider.future), isEmpty);

    ignoredSubscription.close();
    syncSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'a full refresh lets the effective store remove a missed cross-device un-ignore',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'ignored_users_v1_@alice:example.org': const ['@blocked:example.org'],
      });
      rustApi.ignoredUsers = const ['@blocked:example.org'];

      final container = ProviderContainer();
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final syncSubscription = container.listen(
        syncStreamProvider,
        (_, _) {},
        fireImmediately: true,
      );
      final ignoredSubscription = container.listen(
        ignoredUserIdsProvider,
        (_, _) {},
        fireImmediately: true,
      );

      expect(await container.read(ignoredUserIdsProvider.future), {
        '@blocked:example.org',
      });
      for (var attempt = 0; attempt < 6; attempt++) {
        await tester.pump();
      }

      // Rust's fallback has already applied any pending local overrides. An
      // empty effective store therefore means the missed sync event really
      // did un-ignore the user and may shrink the Dart snapshot.
      rustApi.ignoredUsersFromServer = false;
      rustApi.ignoredUsers = const [];
      rustApi.syncEvents.add(const rust.SyncEvent.fullRefreshRequired());

      await tester.pump();
      await container.read(ignoredUserIdsProvider.future);
      for (var attempt = 0; attempt < 6; attempt++) {
        await tester.pump();
      }

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ignored_users_v1_@alice:example.org'),
        isEmpty,
      );
      expect(await container.read(ignoredUserIdsProvider.future), isEmpty);

      ignoredSubscription.close();
      syncSubscription.close();
      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'ignored users stay unknown without a snapshot when the fetch fails',
    (tester) async {
      rustApi.ignoredUsersError = StateError('offline');

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      // No persisted snapshot and a failing fetch: the provider must surface
      // an error (unknown) rather than silently resolving to an empty list.
      await expectLater(
        container.read(ignoredUserIdsProvider.future),
        throwsStateError,
      );
      expect(rustApi.ignoredUsersCalls, 1);

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a confirmed ignore change survives a failing refresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    rustApi.ignoredUsers = const ['@a:example.org'];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
    });
    await tester.pump();

    // The server-side ignore succeeded; the returned full list is written
    // through to the local snapshot so timelines filter the sender
    // immediately. The server now holds the change as well.
    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });
    rustApi.ignoredUsers = const ['@a:example.org', '@b:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });

    // A failing refresh afterwards must not restore the pre-change list.
    rustApi.ignoredUsersError = StateError('offline');
    container.invalidate(ignoredUserIdsProvider);
    await tester.pump();
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a stale GET after a confirmed PUT cannot roll it back', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    rustApi.ignoredUsers = const ['@a:example.org'];
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
    });
    await tester.pump();

    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });
    // The GET begins after the PUT, so it captures the same local version,
    // but the homeserver still returns its pre-PUT account-data snapshot.
    rustApi.ignoredUsers = const ['@a:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });
    await tester.pump(const Duration(seconds: 1));

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('ignored_users_v1_@alice:example.org'), [
      '@a:example.org',
      '@b:example.org',
    ]);
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a confirmed change survives a failed snapshot write', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    // Every snapshot write fails: the disk keeps the pre-change value, so
    // only the in-memory confirmed list can protect this session.
    SharedPreferencesStorePlatform.instance = _FailingWritePreferencesStore(
      SharedPreferencesStorePlatform.instance,
    );
    rustApi.ignoredUsers = const ['@a:example.org'];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
    });
    await tester.pump();

    // The server-side ignore succeeds, but writing its full post-write
    // list through to the snapshot fails on disk: the store still holds
    // the pre-change value.
    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });
    final stored = await SharedPreferencesStorePlatform.instance.getAll();
    expect(stored['flutter.ignored_users_v1_@alice:example.org'], [
      '@a:example.org',
    ]);

    // Simulate the in-process preference cache being lost over the stale
    // disk (the legacy SharedPreferences singleton caches writes even when
    // the store write failed). A rebuild must still serve the confirmed
    // in-memory list rather than the stale snapshot.
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    rustApi.ignoredUsersError = StateError('offline');
    container.invalidate(ignoredUserIdsProvider);
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });

    // Room previews filter on the same confirmed list.
    await container.read(chatRoomsProvider.future);
    expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'an in-flight refresh cannot overwrite a newer confirmed change',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
      });
      // The background refresh hangs until the test releases it.
      final refresh = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = refresh;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      // Resolves with the persisted snapshot; the refresh fetch is now in
      // flight and pending.
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@a:example.org',
      });

      // The server-side ignore succeeds and its full post-write list is
      // written through while the earlier refresh is still pending.
      await persistIgnoredUserList('@alice:example.org', const {
        '@a:example.org',
        '@b:example.org',
      });

      // The stale refresh now completes with the pre-change list; it must
      // not overwrite the newer write-through.
      rustApi.pendingIgnoredUsers = null;
      rustApi.ignoredUsers = const ['@a:example.org', '@b:example.org'];
      refresh.complete(const ['@a:example.org']);
      await tester.pump();

      container.invalidate(ignoredUserIdsProvider);
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@a:example.org',
        '@b:example.org',
      });

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a first load superseded by a change serves the newer snapshot', (
    tester,
  ) async {
    // No persisted snapshot: the provider waits on the authoritative
    // fetch, which hangs until the test releases it.
    final firstFetch = Completer<List<String>>();
    rustApi.pendingIgnoredUsers = firstFetch;

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    final future = container.read(ignoredUserIdsProvider.future);
    // Let the provider reach the pending fetch (version captured) before
    // the change lands.
    await tester.pump();

    // A confirmed ignore change (persisting the full post-write list)
    // lands while the first fetch is still in flight.
    await persistIgnoredUserList('@alice:example.org', const {
      '@a:example.org',
      '@b:example.org',
    });

    // The stale first response must not become the provider state.
    rustApi.pendingIgnoredUsers = null;
    firstFetch.complete(const ['@a:example.org']);
    expect(await future, {'@a:example.org', '@b:example.org'});

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a disposed hanging first load cannot block a rebuilt account', (
    tester,
  ) async {
    // The first session has no snapshot and its initial fetch never
    // completes, even after that provider is disposed.
    final firstFetch = Completer<List<String>>();
    rustApi.pendingIgnoredUsers = firstFetch;

    final firstContainer = ProviderContainer();
    firstContainer.read(sessionReadyProvider.notifier).value = true;
    firstContainer.read(activeUserIdProvider.notifier).value =
        '@alice:example.org';
    firstContainer.read(ignoredUserIdsProvider.future);
    await tester.pump();
    expect(rustApi.ignoredUsersCalls, 1);

    firstContainer.dispose();
    await tester.pump();

    // Re-entering the same account starts and completes a fresh build
    // while the disposed session's fetch remains unresolved.
    rustApi.pendingIgnoredUsers = null;
    final secondContainer = ProviderContainer();
    addTearDown(secondContainer.dispose);
    secondContainer.read(sessionReadyProvider.notifier).value = true;
    secondContainer.read(activeUserIdProvider.notifier).value =
        '@alice:example.org';

    expect(await secondContainer.read(ignoredUserIdsProvider.future), isEmpty);
    await secondContainer.read(chatRoomsProvider.future);
    expect(rustApi.chatRoomsIgnoredFilter, isEmpty);
    await tester.pump();

    // A confirmed write-through must revalidate both the list and room
    // previews without waiting for the abandoned first fetch.
    rustApi.ignoredUsers = const ['@b:example.org'];
    await persistIgnoredUserList('@alice:example.org', const {
      '@b:example.org',
    });
    await tester.pump();

    expect(await secondContainer.read(ignoredUserIdsProvider.future), {
      '@b:example.org',
    });
    await secondContainer.read(chatRoomsProvider.future);
    await tester.pump();
    expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));

    secondContainer.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'a first ignore load cannot persist the next account under the old namespace',
    (tester) async {
      final firstFetch = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = firstFetch;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final staleFuture = container.read(ignoredUserIdsProvider.future);
      staleFuture.ignore();
      await tester.pump();
      expect(rustApi.ignoredUsersCalls, 1);

      resetIgnoredListAccountState('@alice:example.org');
      container.read(sessionReadyProvider.notifier).value = false;
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      container.read(sessionReadyProvider.notifier).value = true;

      rustApi.pendingIgnoredUsers = null;
      rustApi.ignoredUsers = const ['@bob-blocked:example.org'];
      firstFetch.complete(const ['@bob-blocked:example.org']);
      await tester.pump();

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ignored_users_v1_@alice:example.org'),
        isNull,
      );
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@bob-blocked:example.org',
      });

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'a first load publishes the newer snapshot when a change lands mid-persist',
    (tester) async {
      // No persisted snapshot: the provider waits on the authoritative
      // fetch, which hangs until the test releases it.
      final firstFetch = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = firstFetch;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final future = container.read(ignoredUserIdsProvider.future);
      // Let the provider reach the pending fetch (version captured).
      await tester.pump();

      // Releasing the fetch lets the provider pass its first version check
      // and start persisting. The confirmed change is scheduled one
      // microtask later, landing while that persist is in flight — the
      // provider must still not publish the stale response.
      firstFetch.complete(const ['@a:example.org']);
      late Future<void> writeThrough;
      scheduleMicrotask(() {
        writeThrough = persistIgnoredUserList('@alice:example.org', const {
          '@a:example.org',
          '@b:example.org',
        });
      });
      expect(await future, {'@a:example.org', '@b:example.org'});
      await writeThrough;

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('room previews refilter against the write-through ignore list', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await container.read(chatRoomsProvider.future);
    expect(rustApi.chatRoomsCalls, 1);
    expect(rustApi.chatRoomsIgnoredFilter, isEmpty);
    // The first fetch completed against the server: the list is fresh and
    // may override the lagging store.
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    // A confirmed ignore change is written through; revalidating the ignore
    // provider (as the management page does) must cascade into the room
    // list so previews are re-filtered without waiting for the sync echo.
    await persistIgnoredUserList('@alice:example.org', const {
      '@b:example.org',
    });
    // The server now holds the change as well.
    rustApi.ignoredUsers = const ['@b:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    await container.read(chatRoomsProvider.future);
    await tester.pump();

    expect(rustApi.chatRoomsCalls, greaterThan(1));
    expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a write-through revalidates live providers without any page', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await container.read(chatRoomsProvider.future);
    expect(rustApi.chatRoomsIgnoredFilter, isEmpty);

    // The originating page is already gone: only the write-through runs and
    // nobody invalidates the provider. Live providers must still recompute —
    // otherwise an offline gap before the echo would leave the sender
    // visible (or hidden) indefinitely.
    await persistIgnoredUserList('@alice:example.org', const {
      '@b:example.org',
    });
    rustApi.ignoredUsers = const ['@b:example.org'];
    await tester.pump();
    await container.read(chatRoomsProvider.future);
    await tester.pump();

    expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('room previews pass no filter when the ignore list is unknown', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    // No persisted snapshot and the fetch fails: the ignore state is
    // unknown. It must not degrade into "nobody is ignored" — a null filter
    // lets Rust fall back to its store-side filter instead.
    rustApi.ignoredUsersError = StateError('offline');

    await container.read(chatRoomsProvider.future);

    expect(rustApi.chatRoomsCalls, 1);
    expect(rustApi.chatRoomsIgnoredFilter, isNull);
    expect(rustApi.chatRoomsAuthoritative, isFalse);
  });

  testWidgets(
    'a confirmed un-ignore makes the empty list authoritative again',
    (tester) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      rustApi.ignoredUsers = const ['@b:example.org'];

      await container.read(chatRoomsProvider.future);
      expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));
      expect(rustApi.chatRoomsAuthoritative, isTrue);

      // The un-ignore is confirmed and written through; the revalidated room
      // list must pass the (empty) list itself with the authoritative flag,
      // never null or a stale snapshot, so Rust lets it override the store
      // whose sync echo still lags — and cannot resurrect a stuck ignore
      // override for the preview.
      await persistIgnoredUserList('@alice:example.org', const {});
      rustApi.ignoredUsers = const [];
      container.invalidate(ignoredUserIdsProvider);
      await container.read(chatRoomsProvider.future);
      await tester.pump();

      expect(rustApi.chatRoomsIgnoredFilter, isNotNull);
      expect(rustApi.chatRoomsIgnoredFilter, isEmpty);
      expect(rustApi.chatRoomsAuthoritative, isTrue);

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('a confirmed un-ignore wins over a lagging store fallback', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    rustApi.ignoredUsers = const ['@b:example.org'];

    await container.read(chatRoomsProvider.future);

    // The un-ignore is confirmed and written through: the snapshot is now
    // empty and confirmed.
    await persistIgnoredUserList('@alice:example.org', const {});
    await tester.pump();

    // The sync echo never arrives and the network drops: the offline
    // refresh serves the store fallback, which still holds the old id.
    rustApi.ignoredUsersFromServer = false;
    rustApi.ignoredUsers = const ['@b:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    await container.read(chatRoomsProvider.future);
    await tester.pump();
    await tester.pump();

    // The confirmed state must win over the lagging store: the old id must
    // not be unioned back into the snapshot.
    expect(await container.read(ignoredUserIdsProvider.future), isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('ignored_users_v1_@alice:example.org'), isEmpty);
    expect(rustApi.chatRoomsIgnoredFilter, isNot(contains('@b:example.org')));
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('a persisted cache only merges until revalidated as fresh', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@cached:example.org'],
    });
    // Hold the background refresh: the provider serves the persisted
    // snapshot while its freshness is unconfirmed.
    rustApi.pendingIgnoredUsers = Completer<List<String>>();

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final syncSubscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    await container.read(chatRoomsProvider.future);
    // A merely persisted cache must be merged with the store, not treated
    // as authoritative.
    expect(rustApi.chatRoomsIgnoredFilter, contains('@cached:example.org'));
    expect(rustApi.chatRoomsAuthoritative, isFalse);

    // Once the refresh completes, the freshness upgrade must cascade into
    // the room list on its own (the list content is unchanged, so only a
    // freshness-aware revalidation rebuilds dependents).
    rustApi.pendingIgnoredUsers!.complete(const ['@cached:example.org']);
    await tester.pump();
    await container.read(chatRoomsProvider.future);
    await tester.pump();
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    // A cross-device change demotes the confirmed list: until the
    // revalidation completes, previews merge with the store again.
    rustApi.pendingIgnoredUsers = Completer<List<String>>();
    rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
    await tester.pump();
    await container.read(chatRoomsProvider.future);
    expect(rustApi.chatRoomsAuthoritative, isFalse);

    rustApi.pendingIgnoredUsers!.complete(const ['@cached:example.org']);
    await tester.pump();
    await container.read(chatRoomsProvider.future);
    await tester.pump();
    expect(rustApi.chatRoomsAuthoritative, isTrue);

    syncSubscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'an offline store fallback never overwrites the persisted snapshot',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'ignored_users_v1_@alice:example.org': const ['@ignored:example.org'],
      });
      // The network is down and the SDK store lags the confirmed state.
      rustApi.ignoredUsersFromServer = false;
      rustApi.ignoredUsers = const [];

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      await container.read(chatRoomsProvider.future);
      // Let the background refresh (store fallback) complete.
      await tester.pump();

      // The lagging store result must neither overwrite the persisted
      // snapshot nor become authoritative.
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@ignored:example.org',
      });
      expect(rustApi.chatRoomsIgnoredFilter, contains('@ignored:example.org'));
      expect(rustApi.chatRoomsAuthoritative, isFalse);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('ignored_users_v1_@alice:example.org'), [
        '@ignored:example.org',
      ]);

      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('an offline store fallback unions cross-device additions', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@a:example.org'],
    });
    // The network is down, but the SDK store already holds a cross-device
    // addition from the last sync: the persisted snapshot is a subset.
    rustApi.ignoredUsersFromServer = false;
    rustApi.ignoredUsers = const ['@a:example.org', '@b:example.org'];

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    await container.read(chatRoomsProvider.future);
    // Let the background refresh (store fallback) complete.
    await tester.pump();
    await tester.pump();

    // The superset must be unioned in — Dart timelines filter on this list
    // alone and would otherwise keep showing @b's messages. It is still not
    // authoritative: only a server result may shrink the list.
    expect(await container.read(ignoredUserIdsProvider.future), {
      '@a:example.org',
      '@b:example.org',
    });
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getStringList('ignored_users_v1_@alice:example.org'), [
      '@a:example.org',
      '@b:example.org',
    ]);
    await container.read(chatRoomsProvider.future);
    await tester.pump();
    expect(rustApi.chatRoomsIgnoredFilter, contains('@b:example.org'));
    expect(rustApi.chatRoomsAuthoritative, isFalse);

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'a sync event during the first build does not strand the future',
    (tester) async {
      // No persisted snapshot: the room list build waits on the ignore-list
      // fetch through the provider chain.
      final firstFetch = Completer<List<String>>();
      rustApi.pendingIgnoredUsers = firstFetch;

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final syncSubscription = container.listen(
        syncStreamProvider,
        (_, _) {},
        fireImmediately: true,
      );

      final future = container.read(chatRoomsProvider.future);
      // Let the build reach the pending fetch (mid-build).
      await tester.pump();

      // The event requests a revalidation while the build is in flight; it
      // must be deferred, or the room-list future waiting on it never
      // completes.
      rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
      await tester.pump();

      rustApi.pendingIgnoredUsers = null;
      rustApi.ignoredUsers = const ['@a:example.org'];
      firstFetch.complete(const ['@a:example.org']);

      await future;
      await tester.pump();
      await tester.pump();
      // The deferred revalidation did not strand the build; the next read
      // re-fetches and serves the revalidated list.
      expect(await container.read(ignoredUserIdsProvider.future), {
        '@a:example.org',
      });
      expect(rustApi.ignoredUsersCalls, greaterThanOrEqualTo(2));

      syncSubscription.close();
      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets(
    'a sync event drops an in-flight refresh instead of confirming it',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'ignored_users_v1_@alice:example.org': const <String>[],
      });
      // The first fetch hangs: it started before the cross-device change.
      rustApi.pendingIgnoredUsers = Completer<List<String>>();

      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final syncSubscription = container.listen(
        syncStreamProvider,
        (_, _) {},
        fireImmediately: true,
      );

      await container.read(chatRoomsProvider.future);
      expect(rustApi.chatRoomsAuthoritative, isFalse);

      // The cross-device change lands while the first fetch is in flight; a
      // revalidation starts behind it.
      rustApi.syncEvents.add(const rust.SyncEvent.ignoredUsersChanged());
      await tester.pump();
      final staleFetch = rustApi.pendingIgnoredUsers!;
      rustApi.pendingIgnoredUsers = Completer<List<String>>();
      await container.read(ignoredUserIdsProvider.future);

      // The late result of the pre-change fetch must be dropped: not
      // persisted, not confirmed, never authoritative.
      staleFetch.complete(const ['@stale:example.org']);
      await tester.pump();
      await tester.pump();
      expect(await container.read(ignoredUserIdsProvider.future), isEmpty);
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getStringList('ignored_users_v1_@alice:example.org'),
        isEmpty,
      );
      await container.read(chatRoomsProvider.future);
      await tester.pump();
      expect(
        rustApi.chatRoomsIgnoredFilter,
        isNot(contains('@stale:example.org')),
      );
      expect(rustApi.chatRoomsAuthoritative, isFalse);

      // The revalidation behind the event still lands and becomes fresh.
      rustApi.pendingIgnoredUsers!.complete(const ['@cross:example.org']);
      await tester.pump();
      await container.read(chatRoomsProvider.future);
      await tester.pump();
      expect(rustApi.chatRoomsIgnoredFilter, contains('@cross:example.org'));
      expect(rustApi.chatRoomsAuthoritative, isTrue);

      syncSubscription.close();
      container.dispose();
      await tester.pump(const Duration(seconds: 1));
    },
  );

  testWidgets('ignored users fall back to the persisted list on failure', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'ignored_users_v1_@alice:example.org': const ['@blocked:example.org'],
    });
    rustApi.ignoredUsersError = StateError('offline');

    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';

    final ids = await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    // A failed refresh must not degrade into "nobody is ignored".
    expect(ids, {'@blocked:example.org'});
    expect(rustApi.ignoredUsersCalls, 1);

    // Once the server is reachable again the fresh list wins and persists.
    rustApi.ignoredUsersError = null;
    rustApi.ignoredUsers = const ['@blocked:example.org', '@spam:example.org'];
    container.invalidate(ignoredUserIdsProvider);
    await container.read(ignoredUserIdsProvider.future);
    await tester.pump();
    await tester.pump();
    final refreshed = await container.read(ignoredUserIdsProvider.future);
    expect(refreshed, {'@blocked:example.org', '@spam:example.org'});

    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('room-list events refresh every room collection', (tester) async {
    rustApi.chatRooms = [
      _room('!project-one:example.org', name: 'Project one'),
    ];
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    final subscriptions = <ProviderSubscription<dynamic>>[
      container.listen(chatRoomsProvider, (_, _) {}, fireImmediately: true),
      container.listen(
        ungroupedRoomsProvider,
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        spaceChildrenProvider('!space:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        searchRoomsProvider('project'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        roomKnockRequestsProvider('!room:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(
        roomMembersProvider('!room:example.org'),
        (_, _) {},
        fireImmediately: true,
      ),
      container.listen(syncStreamProvider, (_, _) {}, fireImmediately: true),
    ];
    await tester.pump();
    expect(rustApi.chatRoomsCalls, 1);
    expect(rustApi.ungroupedRoomsCalls, 1);
    expect(rustApi.spaceChildrenCalls, 1);
    expect(
      (await container.read(searchRoomsProvider('project').future)).single.id,
      '!project-one:example.org',
    );
    expect(rustApi.knockRequestsCalls, 1);
    expect(rustApi.membersCalls, 1);

    rustApi.chatRooms = [
      _room('!project-two:example.org', name: 'Project two'),
    ];
    rustApi.syncEvents.add(const rust.SyncEvent.roomListChanged());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rustApi.chatRoomsCalls, 2);
    expect(rustApi.ungroupedRoomsCalls, 2);
    expect(rustApi.spaceChildrenCalls, 2);
    expect(
      (await container.read(searchRoomsProvider('project').future)).single.id,
      '!project-two:example.org',
    );
    // Member/knock lists are driven by member-state events, not generic
    // room-list activity: refetching them per sync burst would fire a
    // network /members request for every incoming message while the
    // management page is open.
    expect(rustApi.knockRequestsCalls, 1);
    expect(rustApi.membersCalls, 1);

    rustApi.syncEvents.add(const rust.SyncEvent.fullRefreshRequired());
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rustApi.knockRequestsCalls, 2);
    expect(rustApi.membersCalls, 2);

    rustApi.syncEvents.add(
      const rust.SyncEvent.roomMembersChanged(roomId: '!room:example.org'),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pump();

    expect(rustApi.knockRequestsCalls, 3);
    expect(rustApi.membersCalls, 3);

    for (final subscription in subscriptions) {
      subscription.close();
    }
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'manual hiding filters cached rooms and persists for the account',
    (tester) async {
      rustApi.chatRooms = [
        _room('!hidden:example.org'),
        _room('!shown:example.org'),
      ];
      final container = ProviderContainer();
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      final subscription = container.listen(chatRoomsProvider, (_, _) {});

      expect((await container.read(chatRoomsProvider.future)).length, 2);
      await tester.pump();
      await container.read(hiddenRoomsProvider.notifier).hideRooms([
        '!hidden:example.org',
      ]);
      await tester.pump();

      expect(
        (await container.read(chatRoomsProvider.future)).map((room) => room.id),
        ['!shown:example.org'],
      );
      expect((await container.read(allChatRoomsProvider.future)).length, 2);
      expect(rustApi.chatRoomsCalls, 1);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('hidden_room_ids_@alice:example.org'), [
        '!hidden:example.org',
      ]);

      await container.read(hiddenRoomsProvider.notifier).unhideRooms([
        '!hidden:example.org',
      ]);
      await tester.pump();
      expect((await container.read(chatRoomsProvider.future)).length, 2);

      subscription.close();
      container.dispose();
      await tester.pump();
    },
  );

  testWidgets('marks a newly refreshed current-room message as read', (
    tester,
  ) async {
    const roomId = '!current:example.org';
    rustApi.chatRooms = const [
      rust.ChatRoom(
        id: roomId,
        name: 'Current room',
        lastMessage: 'Old message',
        lastMessageTime: '0',
        lastEventId: r'$event-0',
        unreadCount: 0,
        isMarkedUnread: false,
        roomType: 'group',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      ),
    ];
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    // Mirror the chat page recording itself as the viewer of this room.
    container.read(roomViewOwnerProvider(roomId).notifier).value = container
        .read(activeUserIdProvider);
    await container.read(chatRoomsProvider.future);
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.chatRooms = const [
      rust.ChatRoom(
        id: roomId,
        name: 'Current room',
        lastMessage: 'New message',
        lastMessageTime: '1',
        lastEventId: r'$event-1',
        unreadCount: 2,
        isMarkedUnread: false,
        roomType: 'group',
        isEncrypted: false,
        isMuted: false,
        roomState: 'joined',
      ),
    ];
    rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();
    // The direct room-list fetch used by auto-read consumes the pending
    // debounced chat-list refresh rather than issuing the same request again.
    await tester.pump(const Duration(milliseconds: 500));

    expect(rustApi.getMessagesCalls, 1);
    expect(rustApi.markRoomAsReadCalls, 1);
    // The sync-driven auto-read passes explicit:false (it must not
    // unconditionally clear the server flag — the store-checked clear inside
    // the Rust side handles the "room being viewed" case).
    expect(rustApi.lastMarkReadExplicit, isFalse);
    expect(rustApi.chatRoomsCalls, 2);
    final unreadOverride = container.read(roomUnreadOverrideProvider(roomId));
    expect(unreadOverride?.unread, isFalse);
    expect(unreadOverride?.baselineUnreadCount, 2);
    expect(unreadOverride?.baselineLastEventId, r'$event-1');

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('keeps an explicitly unread current room unread on refresh', (
    tester,
  ) async {
    const roomId = '!unread:example.org';
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    // Mirror the chat page recording itself as the viewer of this room.
    container.read(roomViewOwnerProvider(roomId).notifier).value = container
        .read(activeUserIdProvider);
    container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
        true;
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    await tester.pump();

    expect(rustApi.getMessagesCalls, 1);
    expect(rustApi.markRoomAsReadCalls, 0);

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets('does not mark read after the refreshed room was closed', (
    tester,
  ) async {
    const roomId = '!closed:example.org';
    final messages = Completer<List<rust.ChatMessage>>();
    rustApi.pendingMessages = messages;
    final container = ProviderContainer();
    container.read(sessionReadyProvider.notifier).value = true;
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(currentRoomIdProvider.notifier).value = roomId;
    // Mirror the chat page recording itself as the viewer of this room.
    container.read(roomViewOwnerProvider(roomId).notifier).value = container
        .read(activeUserIdProvider);
    final subscription = container.listen(
      syncStreamProvider,
      (_, _) {},
      fireImmediately: true,
    );

    rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
    await tester.pump(const Duration(milliseconds: 150));
    expect(rustApi.getMessagesCalls, 1);

    container.read(currentRoomIdProvider.notifier).value = null;
    messages.complete(const []);
    await tester.pump();
    await tester.pump();

    expect(rustApi.markRoomAsReadCalls, 0);

    subscription.close();
    container.dispose();
    await tester.pump(const Duration(seconds: 1));
  });

  testWidgets(
    'drops a pending room refresh when the sync provider is disposed',
    (tester) async {
      const roomId = '!disposed:example.org';
      final pendingRooms = Completer<List<rust.ChatRoom>>();
      rustApi.pendingChatRooms = pendingRooms;
      final container = ProviderContainer();
      container.read(sessionReadyProvider.notifier).value = true;
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      container.read(currentRoomIdProvider.notifier).value = roomId;
      // Mirror the chat page recording itself as the viewer of this room.
      container.read(roomViewOwnerProvider(roomId).notifier).value = container
          .read(activeUserIdProvider);
      final subscription = container.listen(
        syncStreamProvider,
        (_, _) {},
        fireImmediately: true,
      );

      rustApi.syncEvents.add(const rust.SyncEvent.messageSent(roomId: roomId));
      await tester.pump(const Duration(milliseconds: 150));
      expect(rustApi.chatRoomsCalls, greaterThanOrEqualTo(1));
      expect(rustApi.markRoomAsReadCalls, 0);

      subscription.close();
      container.dispose();
      pendingRooms.complete(const []);
      await tester.pump();
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(rustApi.markRoomAsReadCalls, 0);
    },
  );

  group('bootstrapActiveSessionSync', () {
    testWidgets('retries until the third sync attempt succeeds', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      var syncAttempts = 0;
      var startSyncCalls = 0;
      final delays = <Duration>[];

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {
          syncAttempts++;
          if (syncAttempts < 3) throw StateError('transient failure');
        },
        startSync: () async {
          startSyncCalls++;
        },
        delay: (duration) async {
          delays.add(duration);
        },
      );

      expect(syncAttempts, 3);
      expect(delays, const [Duration(seconds: 2), Duration(seconds: 4)]);
      expect(startSyncCalls, 1);
      expect(ref.read(connectionProvider), AppConnectionState.connected);
    });

    testWidgets('reports disconnected after all initial sync attempts fail', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      var syncAttempts = 0;
      var startSyncCalls = 0;

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {
          syncAttempts++;
          throw StateError('offline');
        },
        startSync: () async {
          startSyncCalls++;
        },
        delay: (_) async {},
      );

      expect(syncAttempts, 3);
      expect(startSyncCalls, 1);
      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });

    testWidgets('reports disconnected when starting the sync loop fails', (
      tester,
    ) async {
      final ref = await _captureRef(tester);

      await bootstrapActiveSessionSyncForTest(
        ref,
        attemptLabel: 'test sync',
        startSyncLabel: 'test start sync',
        syncOnce: () async {},
        startSync: () async => throw StateError('start failed'),
        delay: (_) async {},
      );

      expect(ref.read(connectionProvider), AppConnectionState.disconnected);
    });
  });

  group('primeMessageCache', () {
    testWidgets('loads the persisted snapshot into the cache', (tester) async {
      const roomId = '!room:example.org';
      const namespace = '@alice:example.org';
      final message = _message(r'$cached', '100');
      final encoded = jsonEncode([chatMessageToMap(message)]);

      SharedPreferences.setMockInitialValues({
        'msg_cache_v2_$namespace::$roomId': encoded,
      });

      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            chatRoomsProvider.overrideWith((ref) async => [_room(roomId)]),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      await widgetRef.read(chatRoomsProvider.future);
      widgetRef.read(activeUserIdProvider.notifier).value = namespace;

      await primeMessageCache(widgetRef, roomId);

      expect(widgetRef.read(messageCacheProvider(roomId)).length, 1);
      expect(
        widgetRef.read(messageCacheProvider(roomId)).single.id,
        r'$cached',
      );
      expect(widgetRef.read(messageCachePrimedProvider(roomId)), isTrue);
    });

    testWidgets('clears stale cache when the namespace changes', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCacheProvider(roomId).notifier).value = [
        _message(r'$stale', '100'),
      ];
      ref.read(messageCacheOwnerProvider(roomId).notifier).value =
          '@bob:example.org';

      await primeMessageCache(ref, roomId);

      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
      expect(ref.read(messageCacheOwnerProvider(roomId)), '@alice:example.org');
    });

    testWidgets('only primes once per room', (tester) async {
      const roomId = '!room:example.org';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(messageCachePrimedProvider(roomId).notifier).value = true;

      await primeMessageCache(ref, roomId);

      // No persisted cache exists, but priming was skipped so the provider stays empty.
      expect(ref.read(messageCacheProvider(roomId)), isEmpty);
    });
  });

  group('message refresh', () {
    testWidgets('drops a network refresh after an account switch', (
      tester,
    ) async {
      const roomId = '!room:example.org';
      final pendingMessages = Completer<List<rust.ChatMessage>>();
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider(
              roomId,
            ).overrideWith((ref) => pendingMessages.future),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      widgetRef.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final refresh = refreshMessagesFromNetwork(widgetRef, roomId);
      widgetRef.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      pendingMessages.complete([_message(r'$alice', '100')]);
      await refresh;

      expect(widgetRef.read(messageCacheProvider(roomId)), isEmpty);
      expect(widgetRef.read(messageCacheOwnerProvider(roomId)), isNull);
    });

    testWidgets('drops a sync refresh after an account switch', (tester) async {
      const roomId = '!room:example.org';
      final pendingMessages = Completer<List<rust.ChatMessage>>();
      WidgetRef? ref;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messagesProvider(
              roomId,
            ).overrideWith((ref) => pendingMessages.future),
          ],
          child: Consumer(
            builder: (context, r, _) {
              ref = r;
              return Container();
            },
          ),
        ),
      );
      final widgetRef = ref!;
      widgetRef.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';

      final refresh = widgetRef.read(
        _refreshMessagesRefProvider(roomId).future,
      );
      widgetRef.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      pendingMessages.complete([_message(r'$alice', '100')]);
      await refresh;

      expect(widgetRef.read(messageCacheProvider(roomId)), isEmpty);
      expect(widgetRef.read(messageCacheOwnerProvider(roomId)), isNull);
    });
  });

  group('MXC URL cache', () {
    testWidgets('cachedResolvedMxcUrl reads from the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/image';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';
      ref.read(mxcUrlCacheProvider.notifier).value = {
        '@alice:example.org::mxc://example.org/image|96x96':
            'https://example.org/image.png',
      };

      final url = cachedResolvedMxcUrl(ref, mxc, width: 96, height: 96);
      expect(url, 'https://example.org/image.png');
    });

    testWidgets('cachedResolvedMxcUrl returns null for non-mxc URLs', (
      tester,
    ) async {
      final ref = await _captureRef(tester);
      expect(
        cachedResolvedMxcUrl(ref, 'https://example.org/image.png'),
        isNull,
      );
      expect(cachedResolvedMxcUrl(ref, null), isNull);
    });

    testWidgets('rememberResolvedMxcUrl updates the in-memory cache', (
      tester,
    ) async {
      const mxc = 'mxc://example.org/new';
      const httpUrl = 'https://example.org/new.png';
      final ref = await _captureRef(tester);
      ref.read(activeUserIdProvider.notifier).value = '@alice:example.org';

      rememberResolvedMxcUrl(ref, mxc, httpUrl);

      expect(ref.read(mxcUrlCacheProvider).values, contains(httpUrl));
    });
  });

  group('timed-out unread suppression convergence', () {
    testWidgets('a failed write is lifted, a landing write is kept', (
      tester,
    ) async {
      var fakeNow = DateTime(2026, 1, 1, 12);
      await withClock(Clock(() => fakeNow), () async {
        const roomId = '!room:example.org';
        final container = ProviderContainer();
        container.read(sessionReadyProvider.notifier).value = true;
        container.read(activeUserIdProvider.notifier).value =
            '@alice:example.org';
        final syncSubscription = container.listen(
          syncStreamProvider,
          (_, _) {},
          fireImmediately: true,
        );
        rustApi.chatRooms = [_room(roomId)];

        // Timed-out mark-unread write with the suppression armed.
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            true;

        // A refresh inside the 250s window keeps the suppression.
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);

        // Past the window with the write NOT landed (isMarkedUnread false,
        // room not being viewed): the suppression is lifted.
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isFalse);

        // A landing write (echo now shows the marker) keeps the suppression
        // while the room is NOT being viewed.
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            true;
        rustApi.chatRooms = [
          rust.ChatRoom(
            id: roomId,
            name: 'Room',
            lastMessage: '',
            lastMessageTime: '0',
            lastEventId: '',
            unreadCount: 0,
            isMarkedUnread: true,
            roomType: 'group',
            isEncrypted: false,
            isMuted: false,
            roomState: 'joined',
          ),
        ];
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);

        // A landing write keeps the suppression even while the user IS
        // viewing the room: the marker was explicitly requested and stays
        // until the room is opened again (same as the success path, which
        // closes the room instead).
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(currentRoomIdProvider.notifier).value = roomId;
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);

        // A viewed room whose write did not land: the suppression stays
        // armed (a late landing must not be revoked by the auto-read; the
        // success path behaves the same), and the entry is retained for
        // re-checks.
        rustApi.chatRooms = [_room(roomId)];
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            true;
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);

        // Once the user stops viewing, the retained entry's next due
        // evaluation drains it (still false).
        container.read(currentRoomIdProvider.notifier).value = null;
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isFalse);

        // A marker that lands while the suppression was lifted by an
        // explicit read action stays lifted: re-arming would block the
        // auto-read for a marker that the read action is about to remove.
        container.read(currentRoomIdProvider.notifier).value = roomId;
        rustApi.chatRooms = [
          rust.ChatRoom(
            id: roomId,
            name: 'Room',
            lastMessage: '',
            lastMessageTime: '0',
            lastEventId: '',
            unreadCount: 0,
            isMarkedUnread: true,
            roomType: 'group',
            isEncrypted: false,
            isMuted: false,
            roomState: 'joined',
          ),
        ];
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            false;
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isFalse);

        // A write that never lands is not protected forever: past the
        // bounded retention (~750s) the suppression is lifted even while
        // the user keeps viewing (a viewed room's receipts must not be
        // frozen indefinitely with no visible recovery).
        rustApi.chatRooms = [_room(roomId)];
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            true;
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);
        fakeNow = fakeNow.add(const Duration(seconds: 300));
        rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pump();
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isFalse);

        // A NEWER mark-unread write that re-armed the suppression is not
        // lifted by the OLD registration's expiry: the revision guard keeps
        // the newer write's protection until it lands or registers itself.
        rustApi.chatRooms = [_room(roomId)];
        noteTimedOutUnreadSuppression(
          roomId,
          revision: container.read(
            roomAutoReadSuppressionRevisionProvider(roomId),
          ),
        );
        container
            .read(roomAutoReadSuppressionRevisionProvider(roomId).notifier)
            .value++;
        container.read(roomAutoReadSuppressedProvider(roomId).notifier).value =
            true;
        for (var i = 0; i < 3; i++) {
          fakeNow = fakeNow.add(const Duration(seconds: 300));
          rustApi.syncEvents.add(const rust.SyncEvent.syncCompleted());
          await tester.pump(const Duration(milliseconds: 600));
          await tester.pump();
        }
        // Past the old entry's 750s bound, but the revision mismatch means
        // the expiry must not lift the newer write's suppression.
        expect(container.read(roomAutoReadSuppressedProvider(roomId)), isTrue);

        syncSubscription.close();
        container.dispose();
        await tester.pump(const Duration(seconds: 1));
      });
    });
  });
}
