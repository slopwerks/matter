import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

import 'helpers/neu_test_theme.dart';

rust.MessageSearchResult _hit(int i) => rust.MessageSearchResult(
  roomId: '!loading:example.org',
  roomName: 'Loading',
  eventId: '\$hit-$i',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  body: 'needle $i',
  timestamp: '${10000 - i}',
  isDm: false,
  isEdited: false,
);

void main() {
  testWidgets(
    'ordinary next page after history completion does not requery the loaded prefix',
    (tester) async {
      var complete = false;
      final requests = <MessageSearchRequest>[];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith((ref, request) async {
              requests.add(request);
              final results = List.generate(
                65,
                _hit,
              ).skip(request.offset).take(request.limit).toList();
              return rust.MessageSearchPage(
                results: results,
                hasMore: request.offset + results.length < 65,
                terms: const ['needle'],
                historyComplete: complete,
              );
            }),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              scope,
            ) async {
              complete = true;
              return const rust.MessageSearchBackfill(
                loadedEvents: 1,
                reachedStart: true,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const ChatSearchPage(roomId: '!loading:example.org'),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      final before = requests.length;
      await tester.scrollUntilVisible(
        find.text('needle 64', findRichText: true),
        500,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(requests.skip(before).map((request) => request.offset), [60]);
      expect(find.text('needle 64', findRichText: true), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  for (final total in [65, 125]) {
    testWidgets(
      'final history refresh rebuilds loaded prefix without gaps or stale hits total=$total',
      (tester) async {
        final gate = Completer<rust.MessageSearchBackfill>();
        final container = ProviderContainer(
          overrides: [
            messageSearchProvider.overrideWith((ref, request) async {
              final all = gate.isCompleted
                  ? [_hit(-1), ...List.generate(total - 1, (i) => _hit(i + 1))]
                  : List.generate(total, _hit);
              final page = all
                  .skip(request.offset)
                  .take(request.limit)
                  .toList();
              return rust.MessageSearchPage(
                results: page,
                hasMore: request.offset + page.length < all.length,
                terms: const ['needle'],
                historyComplete: gate.isCompleted,
              );
            }),
            messageSearchHistoryBackfillProvider.overrideWithValue(
              (scope) => gate.future,
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(),
              home: const ChatSearchPage(roomId: '!loading:example.org'),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('chat-search-field')),
          'needle',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        await tester.scrollUntilVisible(
          find.text('needle ${total - 1}', findRichText: true),
          500,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
          maxScrolls: 50,
        );
        await tester.pump();
        gate.complete(
          const rust.MessageSearchBackfill(loadedEvents: 1, reachedStart: true),
        );
        await tester.pumpAndSettle();
        final list = tester.widget<ListView>(find.byType(ListView));
        expect(list.childrenDelegate.estimatedChildCount, total);
        final context = tester.element(find.byType(ListView));
        final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
        final ids = <String>[];
        for (var i = 0; i < total; i++) {
          final tile = delegate.builder(context, i)!;
          final result = (tile as dynamic).result as rust.MessageSearchResult;
          ids.add(result.eventId);
        }
        expect(ids.toSet().length, total);
        expect(ids, [
          r'$hit--1',
          ...List.generate(total - 1, (i) => '\$hit-${i + 1}'),
        ]);
        expect(ids, isNot(contains(r'$hit-0')));
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
  testWidgets('search first batch has 60 hits without requiring more history', (
    tester,
  ) async {
    MessageSearchRequest? request;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, value) async {
            request = value;
            return rust.MessageSearchPage(
              results: List.generate(value.limit, _hit),
              hasMore: true,
              terms: const ['needle'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatSearchPage(roomId: '!loading:example.org'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    expect(request!.offset, 0);
    expect(request!.limit, 60);
    expect(find.text('needle 0', findRichText: true), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets('search scrolling near the end appends exactly one next page', (
    tester,
  ) async {
    final requests = <MessageSearchRequest>[];
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          messageSearchProvider.overrideWith((ref, request) async {
            requests.add(request);
            return rust.MessageSearchPage(
              results: List.generate(
                request.offset == 0 ? request.limit : 5,
                (i) => _hit(request.offset + i),
              ),
              hasMore: request.offset == 0,
              terms: const ['needle'],
              historyComplete: true,
            );
          }),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const ChatSearchPage(roomId: '!loading:example.org'),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('chat-search-field')),
      'needle',
    );
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpAndSettle();
    final firstSize = requests.single.limit;
    await tester.scrollUntilVisible(
      find.text('needle ${firstSize - 1}', findRichText: true),
      400,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 40,
    );
    await tester.pumpAndSettle();
    expect(requests.map((request) => request.offset), [0, firstSize]);
    await tester.scrollUntilVisible(
      find.text('needle ${firstSize + 4}', findRichText: true),
      300,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
      maxScrolls: 10,
    );
    await tester.pumpAndSettle();
    expect(
      find.text('needle ${firstSize + 4}', findRichText: true),
      findsOneWidget,
    );
    expect(find.text('加载更多'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
