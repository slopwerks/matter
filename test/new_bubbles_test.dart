import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_message_bubble.dart';
import 'package:matter/pages/chat/location_message_bubble.dart';
import 'package:matter/pages/chat/poll_message_bubble.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/theme/app_theme.dart';

const _metadata = Positioned(right: 0, bottom: 0, child: SizedBox.shrink());

void main() {
  test('attachment filenames are reduced to portable basenames', () {
    expect(sanitizeAttachmentFilename('../../secret.pdf'), 'secret.pdf');
    expect(sanitizeAttachmentFilename(r'C:\temp\CON.txt'), '_CON.txt');
    expect(sanitizeAttachmentFilename('..'), 'attachment.bin');
    expect(sanitizeAttachmentFilename('bad:name?.zip'), 'bad_name_.zip');
    expect(
      sanitizeAttachmentFilename('invoice\u202Efdp.exe'),
      'invoicefdp.exe',
    );
    expect(sanitizeAttachmentFilename('safe\u2066.txt'), 'safe.txt');
  });

  group('new attachment bubbles render their content', () {
    testWidgets('LocationMessageBubble shows the label and geo', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: AppColors.background,
            body: LocationMessageBubble(
              body: '公司',
              geoUri: 'geo:39.9,116.4',
              isMe: false,
              metadata: _metadata,
            ),
          ),
        ),
      );
      expect(find.text('公司'), findsOneWidget);
      expect(find.byIcon(Icons.location_on_rounded), findsOneWidget);
    });

    testWidgets('FileMessageBubble shows the filename', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            backgroundColor: AppColors.background,
            body: FileMessageBubble(
              filename: 'report.pdf',
              caption: '季度报告',
              mediaSourceJson: null,
              isMe: false,
              metadata: _metadata,
            ),
          ),
        ),
      );
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('季度报告'), findsOneWidget);
      expect(find.byIcon(Icons.insert_drive_file_rounded), findsOneWidget);
    });

    testWidgets('large file asks for confirmation instead of being blocked', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: FileMessageBubble(
              filename: 'archive.zip',
              fileSize: 64 * 1024 * 1024 + 1,
              mediaSourceJson: '{}',
              isMe: false,
              metadata: _metadata,
            ),
          ),
        ),
      );
      await tester.tap(find.text('archive.zip'));
      await tester.pumpAndSettle();
      expect(find.text('下载大文件？'), findsOneWidget);
      expect(find.text('继续下载'), findsOneWidget);
      expect(find.textContaining('64.0 MB'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('下载大文件？'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    });

    testWidgets('PollMessageBubble draws the question and options', (
      tester,
    ) async {
      final poll = PollInfo(
        question: '午饭吃什么？',
        answers: const [
          PollAnswerInfo(id: '0', text: '面条'),
          PollAnswerInfo(id: '1', text: '米饭'),
        ],
        disclosed: true,
        maxSelections: 1,
        myAnswerIds: const [],
        results: const [
          PollAnswerResult(answerId: '0', count: 2, isMine: false),
        ],
        totalVoters: 2,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: AppColors.background,
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: false,
                metadata: _metadata,
              ),
            ),
          ),
        ),
      );
      expect(find.text('午饭吃什么？'), findsOneWidget);
      expect(find.text('面条'), findsOneWidget);
      expect(find.text('米饭'), findsOneWidget);
      // Disclosed => tally shown.
      expect(find.text('2'), findsWidgets);
      expect(find.text('2 人已投票'), findsOneWidget);
    });

    testWidgets('undisclosed poll hides tallies until ended', (tester) async {
      final poll = PollInfo(
        question: '匿名？',
        answers: const [PollAnswerInfo(id: '0', text: '是')],
        disclosed: false,
        maxSelections: 1,
        myAnswerIds: const [],
        results: const [
          PollAnswerResult(answerId: '0', count: 5, isMine: false),
        ],
        totalVoters: 5,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              backgroundColor: AppColors.background,
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: false,
                metadata: _metadata,
              ),
            ),
          ),
        ),
      );
      // Per-answer tallies stay hidden, but participation remains visible.
      expect(find.text('5 人已投票'), findsOneWidget);
      expect(find.text('5'), findsNothing);
    });

    testWidgets('multi-select poll uses distinct voter total', (tester) async {
      final poll = PollInfo(
        question: '多选',
        answers: const [
          PollAnswerInfo(id: '0', text: 'A'),
          PollAnswerInfo(id: '1', text: 'B'),
        ],
        disclosed: true,
        maxSelections: 2,
        myAnswerIds: const [],
        results: const [
          PollAnswerResult(answerId: '0', count: 2, isMine: false),
          PollAnswerResult(answerId: '1', count: 1, isMine: false),
        ],
        totalVoters: 2,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: false,
                metadata: _metadata,
                onVote: (_) async {},
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );
      expect(find.text('2 人已投票'), findsOneWidget);
      expect(find.text('3 人已投票'), findsNothing);
    });

    testWidgets('multi-select poll submits the selected answers together', (
      tester,
    ) async {
      final submittedVotes = <List<String>>[];
      final poll = PollInfo(
        question: '多选',
        answers: const [
          PollAnswerInfo(id: '0', text: 'A'),
          PollAnswerInfo(id: '1', text: 'B'),
        ],
        disclosed: true,
        maxSelections: 2,
        myAnswerIds: const [],
        results: const [],
        totalVoters: 0,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: false,
                metadata: _metadata,
                onVote: (answerIds) async => submittedVotes.add(answerIds),
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('B'));
      await tester.pump();

      expect(submittedVotes, isEmpty);
      expect(find.byIcon(Icons.check_box_rounded), findsNWidgets(2));

      await tester.tap(find.text('提交投票'));
      await tester.pumpAndSettle();

      expect(submittedVotes, [
        <String>['0', '1'],
      ]);
      expect(find.text('1 人已投票'), findsOneWidget);
    });

    testWidgets('vote is optimistic, serial, and rolls back on failure', (
      tester,
    ) async {
      final completer = Completer<void>();
      var calls = 0;
      final poll = PollInfo(
        question: '选择',
        answers: const [
          PollAnswerInfo(id: '0', text: 'A'),
          PollAnswerInfo(id: '1', text: 'B'),
        ],
        disclosed: true,
        maxSelections: 1,
        myAnswerIds: const [],
        results: const [],
        totalVoters: 0,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: false,
                metadata: _metadata,
                onVote: (_) {
                  calls++;
                  return completer.future;
                },
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('A'));
      await tester.pump();
      await tester.tap(find.text('B'));
      expect(calls, 1);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      completer.completeError(Exception('network'));
      await tester.pumpAndSettle();
      expect(find.textContaining('投票失败'), findsOneWidget);
      expect(
        find.byIcon(Icons.radio_button_unchecked_rounded),
        findsNWidgets(2),
      );
    });

    testWidgets('poll owner can end an open poll', (tester) async {
      var ended = false;
      final poll = PollInfo(
        question: '结束？',
        answers: const [
          PollAnswerInfo(id: '0', text: 'A'),
          PollAnswerInfo(id: '1', text: 'B'),
        ],
        disclosed: true,
        maxSelections: 1,
        myAnswerIds: const [],
        results: const [],
        totalVoters: 0,
        ended: false,
      );
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: Scaffold(
              body: PollMessageBubble(
                roomId: '!r:ex.org',
                pollStartEventId: '\$poll:ex.org',
                poll: poll,
                isMe: true,
                metadata: _metadata,
                onEnd: () async => ended = true,
                onRefresh: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('结束投票'));
      await tester.pumpAndSettle();
      expect(ended, isTrue);
      expect(find.text('结束投票'), findsNothing);
      expect(find.text('0 人已投票 · 已结束'), findsOneWidget);
    });

    testWidgets('location falls back to an HTTPS map', (tester) async {
      final launched = <Uri>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationMessageBubble(
              body: '公司',
              geoUri: 'geo:39.9,116.4',
              isMe: false,
              metadata: _metadata,
              launchUri: (uri) async {
                launched.add(uri);
                if (uri.scheme == 'geo') throw Exception('unsupported');
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('公司'));
      await tester.pumpAndSettle();
      expect(launched.map((uri) => uri.scheme), ['geo', 'https']);
    });

    testWidgets('invalid location is rejected without launching', (
      tester,
    ) async {
      var launches = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocationMessageBubble(
              body: '坏位置',
              geoUri: 'geo:1e-7,116.4',
              isMe: false,
              metadata: _metadata,
              launchUri: (_) async {
                launches++;
                return true;
              },
            ),
          ),
        ),
      );
      await tester.tap(find.text('坏位置'));
      await tester.pump();
      expect(launches, 0);
      expect(find.text('位置链接无效'), findsOneWidget);
    });
  });
}
