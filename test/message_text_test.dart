import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/message_text.dart';

void main() {
  test('message mentions are rendered with a distinct emphasized style', () {
    const base = TextStyle(color: Colors.white, fontSize: 15);
    final span = messageTextSpan(
      '你好 @alice:example.org、@bob 和 @小明',
      style: base,
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {
        '@bob:example.org': 'Bob',
        '@xiaoming:example.org': '小明',
      },
      mentionedUserIds: const [
        '@alice:example.org',
        '@bob:example.org',
        '@xiaoming:example.org',
      ],
    );
    final mentions = span.children!
        .whereType<TextSpan>()
        .where((child) => child.text?.startsWith('@') == true)
        .toList();

    expect(mentions.map((span) => span.text), [
      '@alice:example.org',
      '@Bob',
      '@小明',
    ]);
    expect(mentions.every((span) => span.style?.color == Colors.cyan), isTrue);
    expect(
      mentions.every((span) => span.style?.fontWeight == FontWeight.w800),
      isTrue,
    );
  });

  test('@ text that mentions nobody is rendered without highlight', () {
    const base = TextStyle(color: Colors.white, fontSize: 15);
    final span = messageTextSpan(
      '邮箱 alice@example.com,还有 @alice:example.org 和 @bob',
      style: base,
      mentionColor: Colors.cyan,
      // The room member list alone must not turn text into a mention: only
      // m.mentions (mentionedUserIds) entries are resolved.
      mentionDisplayNames: const {'@alice:example.org': 'Alice'},
    );

    final highlighted = span.children!
        .whereType<TextSpan>()
        .where((child) => child.style?.color == Colors.cyan)
        .toList();

    expect(highlighted, isEmpty);
    expect(
      span.toPlainText(),
      '邮箱 alice@example.com,还有 @alice:example.org 和 @bob',
    );
  });

  test('mention with an ambiguous display name stays unresolved', () {
    final recognizers = <TapGestureRecognizer>[];
    final span = messageTextSpan(
      '@Sam 你好',
      style: const TextStyle(color: Colors.white, fontSize: 15),
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {
        '@sam-one:example.org': 'Sam',
        '@sam-two:example.org': 'sam',
      },
      mentionedUserIds: const ['@sam-one:example.org', '@sam-two:example.org'],
      onMentionTap: (_) {},
      gestureRecognizers: recognizers,
    );

    expect(
      span.children!.whereType<TextSpan>().where(
        (child) => child.style?.color == Colors.cyan,
      ),
      isEmpty,
    );
    expect(recognizers, isEmpty);
    expect(span.toPlainText(), '@Sam 你好');
  });

  test('mention with spaces in the display name is highlighted in full', () {
    final recognizers = <TapGestureRecognizer>[];
    String? tappedUserId;
    final span = messageTextSpan(
      '@Alice Wonderland 你好',
      style: const TextStyle(color: Colors.white, fontSize: 15),
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {'@alice:example.org': 'Alice Wonderland'},
      mentionedUserIds: const ['@alice:example.org'],
      onMentionTap: (userId) => tappedUserId = userId,
      gestureRecognizers: recognizers,
    );
    final mention = span.children!.whereType<TextSpan>().singleWhere(
      (child) => child.text == '@Alice Wonderland',
    );

    expect(mention.style?.color, Colors.cyan);
    (mention.recognizer! as TapGestureRecognizer).onTap!();
    expect(tappedUserId, '@alice:example.org');
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
  });

  test('display-name prefix does not truncate a Matrix user id', () {
    for (final separator in ['-', '.', '=', '/']) {
      final userId = '@alice${separator}smith:example.org';
      final span = messageTextSpan(
        userId,
        style: const TextStyle(color: Colors.white, fontSize: 15),
        mentionColor: Colors.cyan,
        mentionDisplayNames: {userId: 'Alice'},
        mentionedUserIds: [userId],
      );

      expect(span.toPlainText(), '@Alice', reason: 'separator: $separator');
    }
  });

  test('message mention uses the room member name and profile target', () {
    final recognizers = <TapGestureRecognizer>[];
    String? tappedUserId;
    final span = messageTextSpan(
      '你好 @Ali',
      style: const TextStyle(color: Colors.white, fontSize: 15),
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {'@alice:example.org': 'Alice Wonderland'},
      mentionedUserIds: const ['@alice:example.org'],
      onMentionTap: (userId) => tappedUserId = userId,
      gestureRecognizers: recognizers,
    );
    final mention = span.children!.whereType<TextSpan>().singleWhere(
      (child) => child.text == '@Alice Wonderland',
    );

    (mention.recognizer! as TapGestureRecognizer).onTap!();

    expect(tappedUserId, '@alice:example.org');
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
  });

  test('Matrix user URL is rendered as a member mention, not a web link', () {
    final recognizers = <TapGestureRecognizer>[];
    String? tappedUserId;
    Uri? tappedUri;
    final span = messageTextSpan(
      'https://matrix.to/#/%40alice%3Aexample.org',
      style: const TextStyle(color: Colors.white, fontSize: 15),
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {'@alice:example.org': 'Alice Wonderland'},
      onMentionTap: (userId) => tappedUserId = userId,
      onUrlTap: (uri) async => tappedUri = uri,
      gestureRecognizers: recognizers,
    );
    final mention = span.children!.whereType<TextSpan>().singleWhere(
      (child) => child.text == '@Alice Wonderland',
    );

    (mention.recognizer! as TapGestureRecognizer).onTap!();

    expect(tappedUserId, '@alice:example.org');
    expect(tappedUri, isNull);
    for (final recognizer in recognizers) {
      recognizer.dispose();
    }
  });

  test('multiple partial mentions resolve to unique full member names', () {
    final span = messageTextSpan(
      '@Ali 和 @Bob',
      style: const TextStyle(color: Colors.white, fontSize: 15),
      mentionColor: Colors.cyan,
      mentionDisplayNames: const {
        '@alice:example.org': 'Alice Wonderland',
        '@bob:example.org': 'Bobby Tables',
      },
      mentionedUserIds: const ['@alice:example.org', '@bob:example.org'],
    );

    expect(span.children!.whereType<TextSpan>().map((child) => child.text), [
      '@Alice Wonderland',
      ' 和 ',
      '@Bobby Tables',
    ]);
  });

  test('message urls include bare common domains and http urls', () {
    final urls = detectMessageUrls(
      '看 blog.chs.pub/post/1、foo.moe 和 https://example.com/a?b=1.',
    );

    expect(urls.map((match) => match.text), [
      'blog.chs.pub/post/1',
      'foo.moe',
      'https://example.com/a?b=1',
    ]);
    expect(urls[0].uri.toString(), 'https://blog.chs.pub/post/1');
    expect(urls[1].uri.toString(), 'https://foo.moe');
    expect(urls[2].uri.toString(), 'https://example.com/a?b=1');
  });

  test('message urls skip email addresses and matrix user ids', () {
    final urls = detectMessageUrls(
      'mail alice@example.com or ping @alice:example.org',
    );

    expect(urls, isEmpty);
  });

  test('message urls are rendered with link styling', () {
    const base = TextStyle(color: Colors.white, fontSize: 15);
    final span = messageTextSpan(
      '打开 example.com',
      style: base,
      mentionColor: Colors.cyan,
    );
    final link = span.children!.whereType<TextSpan>().singleWhere(
      (child) => child.text == 'example.com',
    );

    expect(link.style?.color, Colors.cyan);
    expect(link.style?.fontWeight, FontWeight.w700);
    expect(link.style?.decoration, TextDecoration.underline);
  });
}
