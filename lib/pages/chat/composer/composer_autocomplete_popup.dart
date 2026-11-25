import 'package:material_ui/material_ui.dart';

import '../../../src/rust/api/matrix.dart' as rust;
import '../../../theme/material_theme.dart';
import '../../../theme/neu_colors.dart';
import '../../../widgets/app_avatar.dart';
import '../composer_autocomplete.dart';
import '../sticker_catalog.dart';
import '../sticker_preview.dart';

class ComposerAutocompleteOption {
  const ComposerAutocompleteOption({
    required this.title,
    required this.insertion,
    this.subtitle,
    this.avatarUrl,
    this.emoji,
    this.sticker,
  });

  final String title;
  final String insertion;
  final String? subtitle;
  final String? avatarUrl;
  final String? emoji;
  final StickerItem? sticker;
}

/// Candidate generation is independent of focus, providers and popup state.
List<ComposerAutocompleteOption> composerAutocompleteOptions(
  ComposerAutocompleteMatch match, {
  List<rust.Contact> members = const [],
  List<rust.ChatRoom> rooms = const [],
  List<rust.StickerPack> stickerPacks = const [],
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
      final emoji = emojiAutocompleteOptions(match.query)
          .map(
            (option) => ComposerAutocompleteOption(
              title: ':${option.name}:',
              insertion: option.emoji,
              emoji: option.emoji,
            ),
          )
          .toList();
      final faces = kComposerEmoticons.entries
          .where((entry) => entry.key.contains(query))
          .map(
            (entry) => ComposerAutocompleteOption(
              title: ':${entry.key}:',
              subtitle: '文本表情 · ${entry.value}',
              insertion: entry.value,
              emoji: entry.value,
            ),
          );
      final stickers =
          searchStickerPacks(
            stickerPacksFromRemote(stickerPacks),
            query,
          ).expand(
            (pack) => pack.stickers
                .where((sticker) => sticker.imageUrl != null)
                .map(
                  (sticker) => ComposerAutocompleteOption(
                    title: sticker.shortcode == null
                        ? sticker.body
                        : ':${sticker.shortcode}:',
                    subtitle: '贴纸 · ${pack.title} · 选择后发送',
                    insertion: '',
                    sticker: sticker,
                  ),
                ),
          );
      // Interleave kinds so even a broad query exposes each available kind.
      final groups = [
        emoji.take(50).toList(),
        faces.toList(),
        stickers.take(50).toList(),
      ];
      return [
        for (var i = 0; i < 50; i++)
          for (final group in groups)
            if (i < group.length) group[i],
      ].take(50).toList();
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

// Keyboard scrolling and painting must use the same scaled row geometry.
double composerAutocompleteItemExtent(BuildContext context) {
  if (!context.isMaterial) return 52;
  final text = Theme.of(context).textTheme;
  final scaler = MediaQuery.textScalerOf(context);
  double lineHeight(TextStyle style) =>
      scaler.scale(style.fontSize!) * (style.height ?? 1.0);
  final contentHeight =
      2 * lineHeight(text.titleSmall!) + 2 * lineHeight(text.labelSmall!);
  return contentHeight.clamp(44, double.infinity) + 16;
}

/// The anchor keeps its normal size while candidates paint above the composer.
class ComposerAutocompleteOverlay extends StatefulWidget {
  const ComposerAutocompleteOverlay({
    super.key,
    required this.popup,
    required this.child,
  });

  final Widget? popup;
  final Widget child;

  @override
  State<ComposerAutocompleteOverlay> createState() =>
      _ComposerAutocompleteOverlayState();
}

class _ComposerAutocompleteOverlayState
    extends State<ComposerAutocompleteOverlay> {
  final _portal = OverlayPortalController();

  @override
  void initState() {
    super.initState();
    if (widget.popup != null) _portal.show();
  }

  @override
  void didUpdateWidget(covariant ComposerAutocompleteOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.popup != null) == (oldWidget.popup != null)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.popup != null) {
        _portal.show();
      } else {
        _portal.hide();
      }
    });
  }

  @override
  Widget build(BuildContext context) => OverlayPortal.overlayChildLayoutBuilder(
    controller: _portal,
    overlayChildBuilder: (context, info) {
      final anchor = MatrixUtils.transformRect(
        info.childPaintTransform,
        Offset.zero & info.childSize,
      );
      final top = MediaQuery.paddingOf(context).top + 8;
      final available = (anchor.top - top - 4).clamp(
        0.0,
        info.overlaySize.height,
      );
      return Positioned(
        left: anchor.left,
        width: anchor.width,
        bottom: info.overlaySize.height - anchor.top + 4,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: available),
          child: widget.popup,
        ),
      );
    },
    child: widget.child,
  );
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
    final itemExtent = composerAutocompleteItemExtent(context);
    final height = loading && options.isEmpty
        ? itemExtent
        : visibleItems * itemExtent;
    final colors = context.neu;
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final material = context.isMaterial;
    return TextFieldTapRegion(
      child: Container(
        key: const ValueKey('composer-autocomplete-panel'),
        height: height,
        margin: const EdgeInsets.fromLTRB(10, 4, 10, 0),
        padding: material ? const EdgeInsets.all(1) : null,
        clipBehavior: Clip.antiAlias,
        decoration: material
            ? ShapeDecoration(
                color: scheme.surfaceContainerHigh,
                shape: theme.popupMenuTheme.shape ?? materialListItemShape,
                shadows: desktopPickerPreviewStyle(context)
                    .decoration
                    .boxShadow,
              )
            : BoxDecoration(
                color: colors.surfaceStrong,
                borderRadius: BorderRadius.circular(NeuRadius.button),
                border: Border.all(color: colors.hairline),
                boxShadow: desktopPickerPreviewStyle(context)
                    .decoration
                    .boxShadow,
              ),
        child: loading && options.isEmpty
            ? Center(
                child: SizedBox.square(
                  dimension: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: material ? null : colors.accent,
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
                  itemExtent: itemExtent,
                  itemCount: options.length,
                  itemBuilder: (context, index) {
                    final option = options[index];
                    final selected = index == indexInRange;
                    return Material(
                      key: ValueKey('composer-autocomplete-option-$index'),
                      color: selected
                          ? material
                                ? scheme.secondaryContainer
                                : colors.accentSoft
                          : Colors.transparent,
                      child: InkWell(
                        onHover: (hovering) {
                          if (hovering && selectedIndex != index) {
                            onHover(index);
                          }
                        },
                        onTap: () => onSelected(option),
                        child: Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: material ? 8 : 0,
                          ),
                          child: Row(
                            children: [
                              if (option.sticker case final sticker?)
                                SizedBox.square(
                                  dimension: 34,
                                  child: RemoteStickerPreview(
                                    sticker: sticker,
                                    cacheDimension: 96,
                                  ),
                                )
                              else if (option.emoji case final emoji?)
                                SizedBox(
                                  width: 34,
                                  child: Text(
                                    emoji,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(fontSize: 24),
                                  ),
                                )
                              else
                                AppAvatar(
                                  fallback: option.title,
                                  size: material ? materialListAvatarSize : 32,
                                  radius: 16,
                                  url: option.avatarUrl,
                                ),
                              SizedBox(
                                width: material ? materialListContentGap : 10,
                              ),
                              Expanded(
                                child: Column(
                                  mainAxisAlignment: MainAxisAlignment.center,
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      option.title,
                                      maxLines: material ? 2 : 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: theme.textTheme.titleSmall
                                          ?.copyWith(
                                            color: material && selected
                                                ? scheme.onSecondaryContainer
                                                : null,
                                          ),
                                    ),
                                    if (option.subtitle case final subtitle?)
                                      Text(
                                        subtitle,
                                        maxLines: material ? 2 : 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: theme.textTheme.labelSmall
                                            ?.copyWith(
                                              color: material
                                                  ? selected
                                                        ? scheme
                                                              .onSecondaryContainer
                                                        : scheme
                                                              .onSurfaceVariant
                                                  : null,
                                            ),
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
