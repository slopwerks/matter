import 'package:flutter/material.dart';

import '../../theme/neu_colors.dart';
import '../../theme/material_theme.dart';
import '../../widgets/neu_surface.dart';
import '../../widgets/app_search_field.dart';
import 'emoji_data.dart';
import 'emoji_keywords.dart';

/// A pure-Dart emoji picker panel with category tabs and optional search.
///
/// Used for message reactions. No native plugin dependency (avoids the
/// Kotlin Gradle Plugin warning and stays compatible with future Flutter).
class EmojiPickerPanel extends StatefulWidget {
  /// Called with the selected emoji string when a cell is tapped.
  final ValueChanged<String> onEmojiSelected;
  final ScrollController? scrollController;

  const EmojiPickerPanel({
    super.key,
    required this.onEmojiSelected,
    this.scrollController,
  });

  @override
  State<EmojiPickerPanel> createState() => _EmojiPickerPanelState();
}

class _EmojiPickerPanelState extends State<EmojiPickerPanel> {
  int _categoryIndex = 0;
  String _query = '';
  bool _showSearch = false;
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  List<String> get _currentEmojis {
    if (_query.isNotEmpty) {
      final q = _query.toLowerCase();
      // Match against per-emoji keywords (Chinese + English). Emoji without a
      // keyword entry simply won't match a search.
      final matched = <String>[];
      final seen = <String>{};
      for (final category in kEmojiCategories) {
        for (final emoji in category.emojis) {
          if (seen.contains(emoji)) continue;
          final keywords = kEmojiKeywords[emoji];
          if (keywords == null) continue;
          if (keywords.any((kw) => kw.toLowerCase().contains(q))) {
            matched.add(emoji);
            seen.add(emoji);
          }
        }
      }
      return matched;
    }
    return kEmojiCategories[_categoryIndex].emojis;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final theme = Theme.of(context);
    final style = context.isMaterial ? materialEmojiPickerStyle(theme) : null;
    final emojis = _currentEmojis;
    return Column(
      children: [
        // Search bar (toggleable).
        if (_showSearch)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: [
                Expanded(
                  child: AppSearchField(
                    controller: _searchController,
                    focusNode: _searchFocus,
                    hint: '搜索表情，如 笑 / heart',
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                const SizedBox(width: 8),
                NeuIconButton(
                  icon: Icons.close_rounded,
                  size: 36,
                  onPressed: () {
                    setState(() {
                      _showSearch = false;
                      _query = '';
                      _searchController.clear();
                    });
                  },
                ),
              ],
            ),
          ),
        // Emoji grid.
        Expanded(
          child: Material(
            type: MaterialType.transparency,
            child: GridView.builder(
              controller: widget.scrollController,
              physics: const ClampingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 44,
                childAspectRatio: 1,
                crossAxisSpacing: 2,
                mainAxisSpacing: 2,
              ),
              itemCount: emojis.length,
              itemBuilder: (context, index) {
                final emoji = emojis[index];
                return InkWell(
                  customBorder: style?.cellShape,
                  borderRadius: style == null
                      ? BorderRadius.circular(NeuRadius.tag)
                      : null,
                  onTap: () => widget.onEmojiSelected(emoji),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                );
              },
            ),
          ),
        ),
        // Category bar (hidden while searching).
        if (_query.isEmpty)
          Column(
            children: [
              Divider(height: 1, color: style == null ? colors.hairline : null),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: List.generate(kEmojiCategories.length, (i) {
                          final cat = kEmojiCategories[i];
                          final selected = i == _categoryIndex;
                          if (context.isMaterial) {
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 3,
                                vertical: 4,
                              ),
                              child: ChoiceChip(
                                label: Text(
                                  cat.icon,
                                  style: const TextStyle(fontSize: 20),
                                ),
                                tooltip: cat.label,
                                selected: selected,
                                showCheckmark: false,
                                onSelected: (_) =>
                                    setState(() => _categoryIndex = i),
                              ),
                            );
                          }
                          return IconButton(
                            onPressed: () => setState(() => _categoryIndex = i),
                            icon: Text(
                              cat.icon,
                              style: TextStyle(
                                fontSize: 20,
                                color: selected
                                    ? colors.accent
                                    : colors.textTertiary,
                              ),
                            ),
                            tooltip: cat.label,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 8,
                            ),
                            constraints: const BoxConstraints(),
                          );
                        }),
                      ),
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      _showSearch ? Icons.close_rounded : Icons.search_rounded,
                      color: style == null
                          ? colors.textTertiary
                          : theme.colorScheme.onSurfaceVariant,
                      size: 20,
                    ),
                    onPressed: () {
                      setState(() {
                        _showSearch = !_showSearch;
                        if (!_showSearch) {
                          _query = '';
                          _searchController.clear();
                        }
                      });
                      if (_showSearch) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) _searchFocus.requestFocus();
                        });
                      }
                    },
                    tooltip: _showSearch ? '关闭表情搜索' : '搜索表情',
                  ),
                ],
              ),
            ],
          ),
      ],
    );
  }
}
