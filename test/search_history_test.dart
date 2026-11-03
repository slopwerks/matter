import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

import 'helpers/neu_test_theme.dart';

rust.MessageSearchResult _result(int index) => rust.MessageSearchResult(
  roomId: '!history:example.org',
  roomName: 'History',
  eventId: '\$old-$index',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  body: '旧消息匹配 $index',
  timestamp: '${1000000 - index}',
  isDm: false,
  isEdited: false,
);

void main() {
  for (final roomId in [null, '!history:example.org']) {
    testWidgets('old search continues after an empty page room=$roomId', (
      tester,
    ) async {
      var calls = 0;
      var complete = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith(
              (ref, request) async => rust.MessageSearchPage(
                results: complete ? [_result(100)] : [],
                hasMore: false,
                terms: const ['匹配'],
                historyComplete: complete,
              ),
            ),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              scope,
            ) async {
              expect(scope, roomId);
              calls++;
              complete = calls == 2;
              return rust.MessageSearchBackfill(
                loadedEvents: complete ? 1 : 0,
                reachedStart: complete,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatSearchPage(roomId: roomId),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        '匹配',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(calls, 2);
      expect(find.text('旧消息匹配 100', findRichText: true), findsOneWidget);
      expect(find.text('搜索较早消息失败，请重试'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  }

  testWidgets('empty history is bounded and remains retryable', (tester) async {
    var calls = 0;
    var recover = false;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith(
            (ref, request) async => rust.MessageSearchPage(
              results: recover ? [_result(100)] : [],
              hasMore: false,
              terms: const ['匹配'],
              historyComplete: recover,
            ),
          ),
          messageSearchHistoryBackfillProvider.overrideWithValue((scope) async {
            calls++;
            return rust.MessageSearchBackfill(
              loadedEvents: recover ? 1 : 0,
              reachedStart: recover,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatSearchPage(roomId: '!history:example.org'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '匹配',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(calls, 8);
    expect(find.text('搜索较早消息失败，请重试'), findsOneWidget);
    expect(find.text('没有找到匹配的消息'), findsNothing);
    recover = true;
    await tester.tap(find.byTooltip('重试'));
    await tester.pumpAndSettle();
    expect(calls, 9);
    expect(find.text('旧消息匹配 100', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('existing results can paginate while old history is loading', (
    tester,
  ) async {
    final gate = Completer<rust.MessageSearchBackfill>();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith(
            (ref, request) async => rust.MessageSearchPage(
              results: [_result(request.offset)],
              hasMore: request.offset == 0,
              terms: const ['匹配'],
              historyComplete: gate.isCompleted,
            ),
          ),
          messageSearchHistoryBackfillProvider.overrideWithValue(
            (scope) => gate.future,
          ),
        ],
        child: MaterialApp(theme: neuTestTheme(), home: const ChatSearchPage()),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '匹配',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.text('正在搜索较早消息…'), findsOneWidget);
    expect(find.text('加载更多'), findsOneWidget);
    await tester.tap(find.text('加载更多'));
    await tester.pump();
    await tester.pump();
    expect(find.text('旧消息匹配 0', findRichText: true), findsOneWidget);
    expect(find.text('旧消息匹配 30', findRichText: true), findsOneWidget);
    gate.complete(
      const rust.MessageSearchBackfill(loadedEvents: 1, reachedStart: true),
    );
    await tester.pumpAndSettle();
    expect(find.text('旧消息匹配 0', findRichText: true), findsOneWidget);
    expect(find.text('旧消息匹配 30', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'switching account discards progressive search and late history',
    (tester) async {
      final gate = Completer<rust.MessageSearchBackfill>();
      var calls = 0;
      final container = ProviderContainer(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            final alice =
                ref.watch(activeUserIdProvider) == '@alice:example.org';
            return rust.MessageSearchPage(
              results: [_result(alice ? 1 : 2)],
              hasMore: false,
              terms: const ['匹配'],
              historyComplete: !alice,
            );
          }),
          messageSearchHistoryBackfillProvider.overrideWithValue((scope) {
            calls++;
            return gate.future;
          }),
        ],
      );
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value =
          '@alice:example.org';
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const ChatSearchPage(),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        '匹配',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.text('旧消息匹配 1', findRichText: true), findsOneWidget);
      container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
      await tester.pump();
      await tester.pump();
      gate.complete(
        const rust.MessageSearchBackfill(loadedEvents: 0, reachedStart: false),
      );
      await tester.pumpAndSettle();
      expect(find.text('旧消息匹配 1', findRichText: true), findsNothing);
      expect(find.text('旧消息匹配 2', findRichText: true), findsOneWidget);
      expect(calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('search can paginate beyond 500 matching results', (
    tester,
  ) async {
    final offsets = <int>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            offsets.add(request.offset);
            return rust.MessageSearchPage(
              results: [_result(request.offset)],
              hasMore: request.offset < 510,
              terms: const ['匹配'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatSearchPage(roomId: '!history:example.org'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      '匹配',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    for (var i = 0; i < 17; i++) {
      final more = find.text('加载更多');
      expect(more, findsOneWidget);
      await tester.ensureVisible(more);
      await tester.pumpAndSettle();
      await tester.tap(more);
      await tester.pumpAndSettle();
    }
    expect(offsets.last, 510);
    expect(find.text('旧消息匹配 510', findRichText: true), findsOneWidget);
    expect(find.text('加载更多'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
