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
    );
    final mentions = span.children!
        .whereType<TextSpan>()
        .where((child) => child.text?.startsWith('@') == true)
        .toList();

    expect(mentions.map((span) => span.text), [
      '@alice:example.org',
      '@bob',
      '@小明',
    ]);
    expect(mentions.every((span) => span.style?.color == Colors.cyan), isTrue);
    expect(
      mentions.every((span) => span.style?.fontWeight == FontWeight.w800),
      isTrue,
    );
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
