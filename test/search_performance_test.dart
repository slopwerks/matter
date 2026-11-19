import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

import 'helpers/neu_test_theme.dart';

const _hit = rust.MessageSearchResult(
  roomId: '!perf:example.org',
  roomName: 'Search profile',
  eventId: r'$hit',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  body: 'needle match',
  timestamp: '1000',
  isDm: false,
  isEdited: false,
);

void main() {
  for (final scope in [null, '!perf:example.org']) {
    testWidgets('search UI work profile scope=$scope', (tester) async {
      var historySteps = 0;
      var queries = 0;
      var complete = false;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            messageSearchProvider.overrideWith((ref, request) async {
              queries++;
              return rust.MessageSearchPage(
                results: const [_hit],
                hasMore: false,
                terms: const ['needle'],
                historyComplete: complete,
              );
            }),
            messageSearchHistoryBackfillProvider.overrideWithValue((
              room,
            ) async {
              expect(room, scope);
              await Future<void>.delayed(const Duration(milliseconds: 20));
              historySteps++;
              complete = historySteps == 16;
              return rust.MessageSearchBackfill(
                loadedEvents: 250,
                reachedStart: complete,
              );
            }),
          ],
          child: MaterialApp(
            theme: neuTestTheme(),
            home: ChatSearchPage(roomId: scope),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('chat-search-field')),
        'needle',
      );
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(historySteps, 16);
      expect(complete, isTrue);
      expect(queries, lessThan(17));
      expect(find.text('needle match', findRichText: true), findsOneWidget);
      debugPrint(
        'SEARCH_UI_WORK ${jsonEncode({'scope': scope == null ? 'global' : 'room', 'history_steps': historySteps, 'query_requests': queries})}',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets(
      'history downloading does not wait for result refresh scope=$scope',
      (tester) async {
        final refreshGate = Completer<rust.MessageSearchPage>();
        addTearDown(() {
          if (!refreshGate.isCompleted) {
            refreshGate.complete(
              const rust.MessageSearchPage(
                results: [_hit],
                hasMore: false,
                terms: ['needle'],
                historyComplete: true,
              ),
            );
          }
        });
        var queries = 0;
        var historySteps = 0;
        var complete = false;
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              messageSearchProvider.overrideWith((ref, request) async {
                queries++;
                if (queries == 2) return refreshGate.future;
                return rust.MessageSearchPage(
                  results: const [_hit],
                  hasMore: false,
                  terms: const ['needle'],
                  historyComplete: complete,
                );
              }),
              messageSearchHistoryBackfillProvider.overrideWithValue((
                room,
              ) async {
                historySteps++;
                complete = historySteps == 8;
                return rust.MessageSearchBackfill(
                  loadedEvents: 250,
                  reachedStart: complete,
                );
              }),
            ],
            child: MaterialApp(
              theme: neuTestTheme(),
              home: ChatSearchPage(roomId: scope),
            ),
          ),
        );
        await tester.enterText(
          find.byKey(const ValueKey('chat-search-field')),
          'needle',
        );
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump();
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(queries, greaterThanOrEqualTo(2));
        expect(historySteps, 8);
        refreshGate.complete(
          const rust.MessageSearchPage(
            results: [_hit],
            hasMore: false,
            terms: ['needle'],
            historyComplete: false,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('needle match', findRichText: true), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
      },
    );
  }
}
