import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'emoji_keywords.dart';

enum ComposerAutocompleteKind { mention, room, emoji }

@immutable
class ComposerAutocompleteMatch {
  final ComposerAutocompleteKind kind;
  final int start;
  final int end;
  final String query;

  const ComposerAutocompleteMatch({
    required this.kind,
    required this.start,
    required this.end,
    required this.query,
  });

  @override
  int get hashCode => Object.hash(kind, start, end, query);

  @override
  bool operator ==(Object other) =>
      other is ComposerAutocompleteMatch &&
      other.kind == kind &&
      other.start == start &&
      other.end == end &&
      other.query == query;
}

@immutable
class EmojiAutocompleteOption {
  final String emoji;
  final String name;

  const EmojiAutocompleteOption({required this.emoji, required this.name});
}

final _wordCharacter = RegExp(r'[\p{L}\p{N}_]', unicode: true);
final _tokenJoiner = RegExp(r'[.=+\-/:]');
final _asciiEmojiName = RegExp(r'^[a-z0-9_+-]+$');

/// Named text faces share the :shortcode trigger with emoji and image packs.
const kComposerEmoticons = <String, String>{
  'shrug': r'¯\_(ツ)_/¯',
  'tableflip': '(╯°□°）╯︵ ┻━┻',
  'unflip': '┬─┬ ノ( ゜-゜ノ)',
  'lenny': '( ͡° ͜ʖ ͡°)',
  'disapprove': 'ಠ_ಠ',
  'happy': '(^_^)',
  'sad': '(T_T)',
  'wave': '( ・ω・)ノ',
  'hug': '(づ｡◕‿‿◕｡)づ',
};

ComposerAutocompleteMatch? composerAutocompleteMatch(TextEditingValue value) {
  final selection = value.selection;
  if (!selection.isValid || !selection.isCollapsed) return null;
  final cursor = selection.extentOffset;
  if (cursor <= 0 || cursor > value.text.length) return null;

  for (var index = cursor - 1; index >= 0; index--) {
    final character = value.text[index];
    if (RegExp(r'\s').hasMatch(character)) break;
    final kind = switch (character) {
      '@' => ComposerAutocompleteKind.mention,
      '#' => ComposerAutocompleteKind.room,
      ':' => ComposerAutocompleteKind.emoji,
      _ => null,
    };
    if (kind == null) continue;
    if (index > 0 && _wordCharacter.hasMatch(value.text[index - 1])) {
      continue;
    }

    var query = value.text.substring(index + 1, cursor);
    if (kind == ComposerAutocompleteKind.emoji && query.endsWith(':')) {
      query = query.substring(0, query.length - 1);
    }
    if (query.contains('@') || query.contains('#') || query.contains(':')) {
      return null;
    }
    return ComposerAutocompleteMatch(
      kind: kind,
      start: index,
      end: _autocompleteTokenEnd(value.text, cursor, kind),
      query: query,
    );
  }
  return null;
}

int _autocompleteTokenEnd(
  String text,
  int cursor,
  ComposerAutocompleteKind kind,
) {
  var scan = cursor;
  var tokenEnd = cursor;
  while (scan < text.length) {
    final character = text[scan];
    if (_wordCharacter.hasMatch(character)) {
      scan++;
      tokenEnd = scan;
      continue;
    }
    if (kind != ComposerAutocompleteKind.emoji &&
        _tokenJoiner.hasMatch(character)) {
      scan++;
      continue;
    }
    if (kind == ComposerAutocompleteKind.emoji &&
        (character == '+' || character == '-')) {
      scan++;
      tokenEnd = scan;
      continue;
    }
    break;
  }
  if (kind == ComposerAutocompleteKind.emoji &&
      tokenEnd < text.length &&
      text[tokenEnd] == ':') {
    tokenEnd++;
  }
  return tokenEnd;
}

TextEditingValue applyComposerAutocomplete(
  TextEditingValue value,
  ComposerAutocompleteMatch match,
  String replacement,
) {
  final insertion = match.end < value.text.length
      ? replacement.trimRight()
      : replacement;
  final text = value.text.replaceRange(match.start, match.end, insertion);
  return TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: match.start + insertion.length),
  );
}

List<EmojiAutocompleteOption> emojiAutocompleteOptions(String query) {
  final normalizedQuery = query.toLowerCase();
  final matches = <({EmojiAutocompleteOption option, int score, int order})>[];
  var order = 0;
  for (final entry in kEmojiKeywords.entries) {
    final keywords = entry.value.map((keyword) => keyword.toLowerCase());
    final matchingKeywords = keywords
        .where((keyword) => keyword.contains(normalizedQuery))
        .toList();
    if (matchingKeywords.isEmpty) {
      order++;
      continue;
    }
    final names = keywords.where(_asciiEmojiName.hasMatch).toList();
    if (names.isEmpty) {
      order++;
      continue;
    }
    final exact = names.where((name) => name == normalizedQuery);
    final prefixes = names.where((name) => name.startsWith(normalizedQuery));
    final name = exact.firstOrNull ?? prefixes.firstOrNull ?? names.first;
    final score = exact.isNotEmpty ? 0 : (prefixes.isNotEmpty ? 1 : 2);
    matches.add((
      option: EmojiAutocompleteOption(emoji: entry.key, name: name),
      score: score,
      order: order,
    ));
    order++;
  }
  matches.sort((left, right) {
    final byScore = left.score.compareTo(right.score);
    return byScore != 0 ? byScore : left.order.compareTo(right.order);
  });
  return matches.map((match) => match.option).toList();
}
