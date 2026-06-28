import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../features/matrix_html/matrix_link_router.dart';

final RegExp _mentionPattern = RegExp(
  r'(?<![\w@])@[A-Za-z0-9\u3400-\u9FFF._=\-/]+(?::[A-Za-z0-9.-]+)?',
  unicode: true,
);

final RegExp _urlCandidatePattern = RegExp(
  r'''https?:\/\/[^\s<>"'，。！？；：、（）【】《》]+|(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}(?:(?:[/?#])[^\s<>"'，。！？；：、（）【】《》]*)?''',
  caseSensitive: false,
);

final RegExp _domainLabelPattern = RegExp(
  r'^[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?$',
);

const Set<String> _commonTlds = {
  'ai',
  'app',
  'art',
  'au',
  'blog',
  'biz',
  'ca',
  'cc',
  'ch',
  'cloud',
  'club',
  'cn',
  'co',
  'com',
  'de',
  'dev',
  'edu',
  'email',
  'finance',
  'fr',
  'fun',
  'games',
  'gg',
  'gov',
  'id',
  'info',
  'ink',
  'io',
  'jp',
  'kr',
  'link',
  'live',
  'me',
  'media',
  'mil',
  'moe',
  'name',
  'net',
  'news',
  'one',
  'online',
  'org',
  'page',
  'pro',
  'pub',
  'ru',
  'shop',
  'site',
  'social',
  'space',
  'store',
  'systems',
  'tech',
  'top',
  'tv',
  'uk',
  'us',
  'vip',
  'website',
  'wiki',
  'world',
  'xyz',
  'zone',
};

const Set<String> _trailingUrlPunctuation = {
  '.',
  ',',
  '!',
  '?',
  ';',
  ':',
  '，',
  '。',
  '！',
  '？',
  '；',
  '：',
  '、',
  ')',
  ']',
  '}',
  '）',
  '】',
  '》',
  '>',
};

typedef MessageUrlTapHandler = Future<void> Function(Uri uri);
typedef MessageMentionTapHandler = void Function(String userId);

class MessageUrlMatch {
  final String text;
  final Uri uri;
  final int start;
  final int end;

  const MessageUrlMatch({
    required this.text,
    required this.uri,
    required this.start,
    required this.end,
  });
}

class MessageText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final Color mentionColor;
  final Color? linkColor;
  final MessageUrlTapHandler? onUrlTap;
  final Map<String, String> mentionDisplayNames;
  final List<String> mentionedUserIds;
  final MessageMentionTapHandler? onMentionTap;
  final TextOverflow? overflow;
  final int? maxLines;
  final bool softWrap;

  const MessageText(
    this.text, {
    super.key,
    required this.style,
    required this.mentionColor,
    this.linkColor,
    this.onUrlTap,
    this.mentionDisplayNames = const {},
    this.mentionedUserIds = const [],
    this.onMentionTap,
    this.overflow,
    this.maxLines,
    this.softWrap = true,
  });

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  List<TapGestureRecognizer> _recognizers = [];

  @override
  void dispose() {
    for (final recognizer in _recognizers) {
      recognizer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final previousRecognizers = _recognizers;
    final recognizers = <TapGestureRecognizer>[];
    final span = messageTextSpan(
      widget.text,
      style: widget.style,
      mentionColor: widget.mentionColor,
      linkColor: widget.linkColor,
      onUrlTap: widget.onUrlTap,
      mentionDisplayNames: widget.mentionDisplayNames,
      mentionedUserIds: widget.mentionedUserIds,
      onMentionTap: widget.onMentionTap,
      gestureRecognizers: recognizers,
    );
    _recognizers = recognizers;
    if (previousRecognizers.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        for (final recognizer in previousRecognizers) {
          recognizer.dispose();
        }
      });
    }
    return Text.rich(
      span,
      softWrap: widget.softWrap,
      overflow: widget.overflow,
      maxLines: widget.maxLines,
    );
  }
}

TextSpan messageTextSpan(
  String text, {
  required TextStyle style,
  required Color mentionColor,
  Color? linkColor,
  MessageUrlTapHandler? onUrlTap,
  Map<String, String> mentionDisplayNames = const {},
  List<String> mentionedUserIds = const [],
  MessageMentionTapHandler? onMentionTap,
  List<TapGestureRecognizer>? gestureRecognizers,
}) {
  final children = <InlineSpan>[];
  final tokens = _messageTextTokens(text);
  final mentionCount = tokens.whereType<_MentionToken>().length;
  var offset = 0;
  for (final token in tokens) {
    if (token.start > offset) {
      children.add(TextSpan(text: text.substring(offset, token.start)));
    }
    if (token is _MentionToken) {
      final userId = _mentionUserId(
        token,
        mentionCount: mentionCount,
        mentionDisplayNames: mentionDisplayNames,
        mentionedUserIds: mentionedUserIds,
      );
      TapGestureRecognizer? recognizer;
      if (userId != null &&
          onMentionTap != null &&
          gestureRecognizers != null) {
        recognizer = TapGestureRecognizer()..onTap = () => onMentionTap(userId);
        gestureRecognizers.add(recognizer);
      }
      children.add(
        TextSpan(
          text: userId == null
              ? token.text
              : matrixMentionLabel(userId, mentionDisplayNames[userId]),
          style: style.copyWith(
            color: mentionColor,
            fontWeight: FontWeight.w800,
            backgroundColor: mentionColor.withValues(alpha: 0.12),
          ),
          recognizer: recognizer,
        ),
      );
    } else if (token is _UrlToken) {
      final mentionUserId = matrixUserIdFromUri(token.uri);
      if (mentionUserId != null) {
        TapGestureRecognizer? recognizer;
        if (onMentionTap != null && gestureRecognizers != null) {
          recognizer = TapGestureRecognizer()
            ..onTap = () => onMentionTap(mentionUserId);
          gestureRecognizers.add(recognizer);
        }
        children.add(
          TextSpan(
            text: matrixMentionLabel(
              mentionUserId,
              mentionDisplayNames[mentionUserId],
            ),
            style: style.copyWith(
              color: mentionColor,
              fontWeight: FontWeight.w800,
              backgroundColor: mentionColor.withValues(alpha: 0.12),
            ),
            recognizer: recognizer,
          ),
        );
        offset = token.end;
        continue;
      }
      final color = linkColor ?? mentionColor;
      TapGestureRecognizer? recognizer;
      if (onUrlTap != null && gestureRecognizers != null) {
        recognizer = TapGestureRecognizer()
          ..onTap = () {
            onUrlTap(token.uri);
          };
        gestureRecognizers.add(recognizer);
      }
      children.add(
        TextSpan(
          text: token.text,
          style: style.copyWith(
            color: color,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
            decorationColor: color.withValues(alpha: 0.8),
          ),
          recognizer: recognizer,
        ),
      );
    }
    offset = token.end;
  }
  if (offset < text.length) {
    children.add(TextSpan(text: text.substring(offset)));
  }
  return TextSpan(style: style, children: children);
}

String? _mentionUserId(
  _MentionToken token, {
  required int mentionCount,
  required Map<String, String> mentionDisplayNames,
  required List<String> mentionedUserIds,
}) {
  if (mentionedUserIds.contains(token.text) ||
      mentionDisplayNames.containsKey(token.text)) {
    return token.text;
  }
  final partialName = token.text.substring(1).toLowerCase();
  final matchingUserIds = mentionedUserIds.where((userId) {
    final displayName = mentionDisplayNames[userId]?.trim();
    if (displayName == null || displayName.isEmpty) return false;
    return displayName
        .replaceFirst(RegExp(r'^@'), '')
        .toLowerCase()
        .startsWith(partialName);
  }).toList();
  if (matchingUserIds.length == 1) return matchingUserIds.single;
  if (mentionCount == 1 && mentionedUserIds.length == 1) {
    return mentionedUserIds.single;
  }
  return null;
}

List<MessageUrlMatch> detectMessageUrls(String text) {
  final matches = <MessageUrlMatch>[];
  for (final candidate in _urlCandidatePattern.allMatches(text)) {
    if (_hasBlockedLeadingChar(text, candidate.start)) continue;
    final parsed = _urlMatchFromCandidate(text, candidate);
    if (parsed == null) continue;
    if (matches.any((match) => _rangesOverlap(match, parsed))) continue;
    matches.add(parsed);
  }
  return matches;
}

Uri? normalizeMessageUrl(String raw) {
  final value = raw.trim();
  if (value.isEmpty) return null;
  final hasHttpScheme = RegExp(
    r'^https?://',
    caseSensitive: false,
  ).hasMatch(value);
  if (!hasHttpScheme && value.contains('://')) return null;

  final uri = Uri.tryParse(hasHttpScheme ? value : 'https://$value');
  if (uri == null || uri.host.isEmpty) return null;

  final scheme = uri.scheme.toLowerCase();
  if (scheme != 'http' && scheme != 'https') return null;
  final host = uri.host.toLowerCase();
  if (!hasHttpScheme && !_isCommonDomainHost(host)) return null;

  return uri.replace(scheme: scheme, host: host);
}

List<_MessageTextToken> _messageTextTokens(String text) {
  final urlTokens = detectMessageUrls(text)
      .map((match) => _UrlToken(match.start, match.end, match.text, match.uri))
      .toList();
  final tokens = <_MessageTextToken>[...urlTokens];
  for (final match in _mentionPattern.allMatches(text)) {
    final token = _MentionToken(match.start, match.end, match.group(0)!);
    if (urlTokens.any((url) => _rangesOverlap(url, token))) continue;
    tokens.add(token);
  }
  tokens.sort((a, b) {
    final byStart = a.start.compareTo(b.start);
    if (byStart != 0) return byStart;
    return b.end.compareTo(a.end);
  });
  return tokens;
}

MessageUrlMatch? _urlMatchFromCandidate(String text, RegExpMatch candidate) {
  var end = candidate.end;
  while (end > candidate.start &&
      _trailingUrlPunctuation.contains(text.substring(end - 1, end))) {
    end--;
  }
  if (end <= candidate.start) return null;

  final raw = text.substring(candidate.start, end);
  final uri = normalizeMessageUrl(raw);
  if (uri == null) return null;
  return MessageUrlMatch(text: raw, uri: uri, start: candidate.start, end: end);
}

bool _hasBlockedLeadingChar(String text, int start) {
  if (start == 0) return false;
  final previous = text.substring(start - 1, start);
  return RegExp(r'[A-Za-z0-9_@.:/-]').hasMatch(previous);
}

bool _isCommonDomainHost(String host) {
  final labels = host.split('.');
  if (labels.length < 2) return false;
  if (!_commonTlds.contains(labels.last)) return false;
  return labels.every((label) => _domainLabelPattern.hasMatch(label));
}

bool _rangesOverlap(dynamic a, dynamic b) => a.start < b.end && b.start < a.end;

sealed class _MessageTextToken {
  final int start;
  final int end;
  final String text;

  const _MessageTextToken(this.start, this.end, this.text);
}

class _MentionToken extends _MessageTextToken {
  const _MentionToken(super.start, super.end, super.text);
}

class _UrlToken extends _MessageTextToken {
  final Uri uri;

  const _UrlToken(super.start, super.end, super.text, this.uri);
}
