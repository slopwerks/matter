import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/chat_detail_page.dart';
import 'package:matter/pages/chat/search_bar.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart' show RustLib, RustLibApi;
import 'helpers/neu_test_theme.dart';

rust.ChatRoom _room({
  required String id,
  required String name,
  String roomState = 'joined',
  String roomType = 'group',
  String? avatarUrl,
  String? nameEventId,
  String? avatarEventId,
}) => rust.ChatRoom(
  id: id,
  name: name,
  avatarUrl: avatarUrl,
  nameEventId: nameEventId,
  avatarEventId: avatarEventId,
  lastMessage: '',
  lastMessageTime: '',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: roomType,
  isEncrypted: true,
  isMuted: false,
  roomState: roomState,
);

const _cjkResult = rust.MessageSearchResult(
  roomId: '!room:example.org',
  roomName: '产品讨论',
  eventId: r'$event',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  body: '今晚八点开会',
  timestamp: '1710000000000',
  isDm: false,
  isEdited: false,
);

const _olderCjkResult = rust.MessageSearchResult(
  roomId: '!room:example.org',
  roomName: '产品讨论',
  eventId: r'$older-event',
  senderId: '@bob:example.org',
  senderName: 'Bob',
  body: '上周八点开会',
  timestamp: '1700000000000',
  isDm: false,
  isEdited: false,
);

class _FakeRustApi implements RustLibApi {
  final List<String?> cancelMessageSearchCalls = [];

  @override
  Future<void> crateApiMatrixCancelMessageSearch({String? roomId}) async {
    cancelMessageSearchCalls.add(roomId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  testWidgets('chat search bar opens the global search page', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(body: ChatSearchBar()),
        ),
      ),
    );

    await tester.tap(find.byKey(const ValueKey('open-chat-search')));
    await tester.pumpAndSettle();

    expect(find.byType(ChatSearchPage), findsOneWidget);
    expect(find.text('消息'), findsOneWidget);
    expect(find.text('聊天'), findsOneWidget);
  });

  test('room filtering supports CJK names and excludes left rooms', () {
    final rooms = [
      _room(id: '!one:example.org', name: '产品讨论'),
      _room(id: '!two:example.org', name: 'General'),
      _room(id: '!left:example.org', name: '产品旧群', roomState: 'left'),
    ];

    expect(filterRoomsForSearch(rooms, '产品').map((room) => room.id), [
      '!one:example.org',
    ]);
    expect(filterRoomsForSearch(rooms, '!two').single.name, 'General');
    expect(filterRoomsForSearch(rooms, '!TWO').single.name, 'General');
  });

  testWidgets(
    'loading the next page starts history backfill for the new page',
    (tester) async {
      final backfillGate = Completer<void>();
      var historyCompleteForNextPage = false;
      var backfillCalls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith((ref, request) async {
              if (request.offset == 0) {
                return const rust.MessageSearchPage(
                  results: [_cjkResult],
                  hasMore: true,
                  terms: ['开会'],
                  historyComplete: true,
                );
              }
              return rust.MessageSearchPage(
                results: [
                  _olderCjkResult,
                  if (!historyCompleteForNextPage) _cjkResult,
                ],
                hasMore: false,
                terms: const ['开会'],
                historyComplete: historyCompleteForNextPage,
              );
            }),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              roomId,
            ) async {
              backfillCalls++;
              await backfillGate.future;
              historyCompleteForNextPage = true;
              return const rust.MessageSearchBackfill(
                loadedEvents: 100,
                reachedStart: true,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatSearchPage(roomId: '!room:example.org'),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        '开会',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();

      expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
      expect(find.text('加载更多'), findsOneWidget);
      expect(backfillCalls, 0);

      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.pump();

      expect(find.text('加载更多'), findsNothing);
      expect(backfillCalls, 1);

      backfillGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
      expect(find.text('上周八点开会', findRichText: true), findsOneWidget);
    },
  );

  testWidgets(
    'history backfill cancels the superseded Rust search before each refresh',
    (tester) async {
      final fakeRustApi = _FakeRustApi();
      RustLib.initMock(api: fakeRustApi);
      addTearDown(RustLib.dispose);

      var backfillCalls = 0;
      var historyComplete = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith(
              (ref, request) async => rust.MessageSearchPage(
                results: [_cjkResult],
                hasMore: false,
                terms: const ['开会'],
                historyComplete: historyComplete,
              ),
            ),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              roomId,
            ) async {
              backfillCalls++;
              if (backfillCalls >= 2) {
                historyComplete = true;
                return const rust.MessageSearchBackfill(
                  loadedEvents: 100,
                  reachedStart: true,
                );
              }
              return const rust.MessageSearchBackfill(
                loadedEvents: 100,
                reachedStart: false,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatSearchPage(roomId: '!room:example.org'),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        '开会',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();

      expect(backfillCalls, 2);
      expect(fakeRustApi.cancelMessageSearchCalls, [
        '!room:example.org',
        '!room:example.org',
      ]);
    },
  );

  testWidgets('room message search returns a CJK result event id', (
    tester,
  ) async {
    String? selectedEventId;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith(
            (ref, request) async => const rust.MessageSearchPage(
              results: [_cjkResult],
              hasMore: false,
              terms: ['八点'],
              historyComplete: true,
            ),
          ),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selectedEventId = await Navigator.of(context).push<String>(
                    MaterialPageRoute(
                      builder: (_) =>
                          const ChatSearchPage(roomId: '!room:example.org'),
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '八点',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
    await tester.tap(
      find.byKey(const ValueKey(r'message-search-result-$event')),
    );
    await tester.pumpAndSettle();

    expect(selectedEventId, r'$event');
  });

  testWidgets(
    'room search keeps local results visible while history backfills',
    (tester) async {
      final backfillGate = Completer<void>();
      var historyComplete = false;
      var backfillCalls = 0;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith((ref, request) async {
              return rust.MessageSearchPage(
                results: [_cjkResult, if (historyComplete) _olderCjkResult],
                hasMore: false,
                terms: const ['开会'],
                historyComplete: historyComplete,
              );
            }),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              roomId,
            ) async {
              backfillCalls++;
              await backfillGate.future;
              historyComplete = true;
              return const rust.MessageSearchBackfill(
                loadedEvents: 250,
                reachedStart: true,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatSearchPage(roomId: '!room:example.org'),
          ),
        ),
      );

      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        '开会',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      await tester.pump();

      expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
      expect(find.text('上周八点开会', findRichText: true), findsNothing);
      expect(backfillCalls, 1);

      backfillGate.complete();
      await tester.pumpAndSettle();

      expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
      expect(find.text('上周八点开会', findRichText: true), findsOneWidget);
    },
  );

  testWidgets('global search progressively indexes cached room history', (
    tester,
  ) async {
    var historyComplete = false;
    String? requestedRoomId = 'not-called';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            return rust.MessageSearchPage(
              results: [_cjkResult, if (historyComplete) _olderCjkResult],
              hasMore: false,
              terms: const ['开会'],
              historyComplete: historyComplete,
            );
          }),
          messageSearchHistoryBackfillProvider.overrideWithValue((
            roomId,
          ) async {
            requestedRoomId = roomId;
            historyComplete = true;
            return const rust.MessageSearchBackfill(
              loadedEvents: 1000,
              reachedStart: true,
            );
          }),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: ChatSearchPage()),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '开会',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();

    expect(requestedRoomId, isNull);
    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
    expect(find.text('上周八点开会', findRichText: true), findsOneWidget);
  });

  testWidgets('message search appends the next page without hiding results', (
    tester,
  ) async {
    final requests = <MessageSearchRequest>[];
    final nextPage = Completer<rust.MessageSearchPage>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            requests.add(request);
            if (request.offset == 0) {
              return const rust.MessageSearchPage(
                results: [_cjkResult],
                hasMore: true,
                terms: ['开会'],
                historyComplete: true,
              );
            }
            return nextPage.future;
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatSearchPage(roomId: '!room:example.org'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '开会',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(requests.single.offset, 0);
    expect(requests.single.limit, 30);
    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);

    await tester.tap(find.text('加载更多'));
    await tester.pump();
    expect(requests.last.offset, 30);
    expect(requests.last.limit, 30);
    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);

    nextPage.complete(
      const rust.MessageSearchPage(
        results: [_olderCjkResult],
        hasMore: false,
        terms: ['开会'],
        historyComplete: true,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('今晚八点开会', findRichText: true), findsOneWidget);
    expect(find.text('上周八点开会', findRichText: true), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
  });

  test('message highlighting follows backend AND terms', () {
    final ranges = messageHighlightRanges('明天我们在北京见', const ['明天', '北京']);

    expect(ranges, const [
      TextRange(start: 0, end: 2),
      TextRange(start: 5, end: 7),
    ]);
  });

  test('message highlighting preserves offsets when lowercase expands', () {
    final ranges = messageHighlightRanges('🙂İstanbul ẞ', const ['i', 'ß']);

    expect(ranges, const [
      TextRange(start: 2, end: 3),
      TextRange(start: 11, end: 12),
    ]);
  });

  testWidgets('global result waits for current room metadata before opening', (
    tester,
  ) async {
    final rooms = Completer<List<rust.ChatRoom>>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith(
            (ref, request) async => const rust.MessageSearchPage(
              results: [_cjkResult],
              hasMore: false,
              terms: ['八点'],
              historyComplete: true,
            ),
          ),
          chatRoomsProvider.overrideWith((ref) => rooms.future),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: ChatSearchPage()),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '八点',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    await tester.tap(
      find.byKey(const ValueKey(r'message-search-result-$event')),
    );
    await tester.pump();
    expect(find.byType(ChatDetailPage), findsNothing);

    rooms.complete([
      _room(
        id: '!room:example.org',
        name: '当前房间名',
        roomType: 'dm',
        avatarUrl: 'mxc://example.org/current',
        nameEventId: r'$name',
        avatarEventId: r'$avatar',
      ),
    ]);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    final detail = tester.widget<ChatDetailPage>(find.byType(ChatDetailPage));
    expect(detail.roomName, '当前房间名');
    expect(detail.avatarUrl, 'mxc://example.org/current');
    expect(detail.nameEventId, r'$name');
    expect(detail.avatarEventId, r'$avatar');
    expect(detail.isDm, isTrue);
  });

  testWidgets('chat tab does not start message index searches', (tester) async {
    var searchCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            searchCalls++;
            return const rust.MessageSearchPage(
              results: [],
              hasMore: false,
              terms: ['产品'],
              historyComplete: true,
            );
          }),
          chatRoomsProvider.overrideWith(
            (ref) async => [_room(id: '!room:example.org', name: '产品讨论')],
          ),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: ChatSearchPage()),
      ),
    );

    await tester.tap(find.text('聊天'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '产品',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(searchCalls, 0);
    expect(find.text('产品讨论'), findsOneWidget);

    await tester.tap(find.text('消息'));
    await tester.pumpAndSettle();
    expect(searchCalls, 1);
  });

  testWidgets('closing search cancels its pending debounce', (tester) async {
    var searchCalls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            searchCalls++;
            return const rust.MessageSearchPage(
              results: [],
              hasMore: false,
              terms: [],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Builder(
            builder: (context) => TextButton(
              onPressed: () => Navigator.of(
                context,
              ).push(MaterialPageRoute(builder: (_) => const ChatSearchPage())),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '尚未执行',
    );
    await tester.tap(find.byTooltip('返回'));
    await tester.pump(const Duration(milliseconds: 300));

    expect(searchCalls, 0);
  });

  testWidgets('keyboard search action submits without waiting for debounce', (
    tester,
  ) async {
    final requests = <MessageSearchRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            requests.add(request);
            return const rust.MessageSearchPage(
              results: [],
              hasMore: false,
              terms: ['立即搜索'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatSearchPage(roomId: '!room:example.org'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '立即搜索',
    );
    await tester.testTextInput.receiveAction(TextInputAction.search);
    await tester.pump();

    expect(requests.single.query, '立即搜索');
  });

  testWidgets('global message search uses all rooms and shows empty state', (
    tester,
  ) async {
    MessageSearchRequest? capturedRequest;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            capturedRequest = request;
            return const rust.MessageSearchPage(
              results: [],
              hasMore: false,
              terms: ['不存在'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: ChatSearchPage()),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '不存在',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    expect(capturedRequest?.roomId, isNull);
    expect(find.text('没有找到匹配的消息'), findsOneWidget);
  });

  testWidgets('message search error can be retried', (tester) async {
    var shouldFail = true;
    var calls = 0;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            calls++;
            if (shouldFail) throw StateError('index unavailable');
            return const rust.MessageSearchPage(
              results: [],
              hasMore: false,
              terms: ['重试'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: ChatSearchPage(roomId: '!room:example.org'),
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '重试',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('搜索暂时不可用，请重试'), findsOneWidget);

    shouldFail = false;
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();

    expect(calls, 2);
    expect(find.text('没有找到匹配的消息'), findsOneWidget);
  });
}
