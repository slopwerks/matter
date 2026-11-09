import 'package:flutter/material.dart';

import '../../../src/rust/api/matrix.dart' as rust;
import '../../../theme/neu_colors.dart';
import '../../../widgets/app_avatar.dart';
import '../composer_autocomplete.dart';

class ComposerAutocompleteOption {
  const ComposerAutocompleteOption({
    required this.title,
    required this.insertion,
    this.subtitle,
    this.avatarUrl,
    this.emoji,
  });

  final String title;
  final String insertion;
  final String? subtitle;
  final String? avatarUrl;
  final String? emoji;
}

/// Candidate generation is independent of focus, providers and popup state.
List<ComposerAutocompleteOption> composerAutocompleteOptions(
  ComposerAutocompleteMatch match, {
  List<rust.Contact> members = const [],
  List<rust.ChatRoom> rooms = const [],
}) {
  final query = match.query.toLowerCase();
  switch (match.kind) {
    case ComposerAutocompleteKind.mention:
      final matches = _boundedMatches(
        members,
        matches: (member) =>
            member.name.toLowerCase().contains(query) ||
            member.id.toLowerCase().contains(query),
        starts: (member) =>
            member.name.toLowerCase().startsWith(query) ||
            member.id.toLowerCase().startsWith('@$query'),
        compare: (left, right) {
          final byName = left.name.toLowerCase().compareTo(
            right.name.toLowerCase(),
          );
          return byName != 0 ? byName : left.id.compareTo(right.id);
        },
      );
      return matches
          .map(
            (member) => ComposerAutocompleteOption(
              title: member.name,
              subtitle: member.id,
              insertion: '${member.id} ',
              avatarUrl: member.avatarUrl,
            ),
          )
          .toList();
    case ComposerAutocompleteKind.room:
      final matches = _boundedMatches(
        rooms,
        matches: (room) {
          if (room.roomType == 'space' || room.roomState != 'joined') {
            return false;
          }
          return room.name.toLowerCase().contains(query) ||
              room.id.toLowerCase().contains(query);
        },
        starts: (room) => room.name.toLowerCase().startsWith(query),
        compare: (left, right) {
          final byName = left.name.toLowerCase().compareTo(
            right.name.toLowerCase(),
          );
          return byName != 0 ? byName : left.id.compareTo(right.id);
        },
      );
      return matches.map((room) {
        final label = '#${room.name}'
            .replaceAll(r'\', r'\\')
            .replaceAll('[', r'\[')
            .replaceAll(']', r'\]');
        final roomId = Uri.encodeComponent(room.id);
        return ComposerAutocompleteOption(
          title: '#${room.name}',
          subtitle: room.id,
          insertion: '[$label](https://matrix.to/#/$roomId) ',
          avatarUrl: room.avatarUrl,
        );
      }).toList();
    case ComposerAutocompleteKind.emoji:
      return emojiAutocompleteOptions(match.query)
          .map(
            (option) => ComposerAutocompleteOption(
              title: ':${option.name}:',
              insertion: option.emoji,
              emoji: option.emoji,
            ),
          )
          .toList();
  }
}

List<T> _boundedMatches<T>(
  Iterable<T> source, {
  required bool Function(T) matches,
  required bool Function(T) starts,
  required int Function(T, T) compare,
}) {
  const limit = 50;
  final leading = <T>[];
  final remaining = <T>[];
  for (final value in source) {
    if (!matches(value)) continue;
    final bucket = starts(value) ? leading : remaining;
    if (bucket.length < limit) bucket.add(value);
    if (leading.length == limit) break;
  }
  leading.sort(compare);
  remaining.sort(compare);
  return [...leading, ...remaining.take(limit - leading.length)];
}

class ComposerAutocompletePopup extends StatelessWidget {
  const ComposerAutocompletePopup({
    super.key,
    required this.options,
    required this.loading,
    required this.viewportItemCount,
    required this.selectedIndex,
    required this.scrollController,
    required this.onHover,
    required this.onSelected,
  });

  final List<ComposerAutocompleteOption> options;
  final bool loading;
  final int viewportItemCount;
  final int selectedIndex;
  final ScrollController scrollController;
  final ValueChanged<int> onHover;
  final ValueChanged<ComposerAutocompleteOption> onSelected;

  @override
  Widget build(BuildContext context) {
    final indexInRange = options.isEmpty
        ? 0
        : selectedIndex.clamp(0, options.length - 1);
    final visibleItems = options.length.clamp(1, viewportItemCount);
    final height = loading && options.isEmpty ? 52.0 : visibleItems * 52.0;
    final colors = context.neu;
    return TextFieldTapRegion(
      child: Container(
        key: const ValueKey('composer-autocomplete-panel'),
        height: height,
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: colors.surfaceStrong,
          borderRadius: BorderRadius.circular(NeuRadius.button),
          border: Border.all(color: colors.hairline),
        ),
        child: loading && options.isEmpty
            ? Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: colors.accent,
                  ),
                ),
              )
            : Scrollbar(
                controller: scrollController,
                thumbVisibility: options.length > viewportItemCount,
                child: ListView.builder(
                  controller: scrollController,
                  padding: EdgeInsets.zero,
                  physics: const ClampingScrollPhysics(),
                  itemExtent: 52,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    return Material(
                      key: ValueKey('composer-autocomplete-option-$index'),
                      color: index == indexInRange
                          ? colors.accentSoft
                          : Colors.transparent,
                      child: InkWell(
                        onHover: (hovering) {
                          if (hovering && selectedIndex != index) {
                            onHover(index);
                          }
                        },
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (option.emoji case final emoji?)
                                SizedBox(
                                  width: 34,
                                  child: Text(
                                    emoji,
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                )
                              else
                                AppAvatar(
                                  fallback: option.title,
                                  size: 32,
                                  radius: 16,
                                  url: option.avatarUrl,
                                ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: Theme.of(context)
                                          .textTheme
                                          .titleSmall,
                                    ),
                                    if (option.subtitle case final subtitle?)
                                      Text(
                                        subtitle,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: Theme.of(context)
                                            .textTheme
                                            .labelSmall,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
      ),
    );
  }
}
