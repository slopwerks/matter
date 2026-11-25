import 'package:material_ui/material_ui.dart';

import '../../theme/material_theme.dart';
import 'emoji_data.dart';
import 'emoji_keywords.dart';
import 'desktop_picker_preview.dart';

import 'package:pro_image_editor/plugins/emoji_picker_flutter/emoji_picker_flutter.dart'
    as emoji_metadata;

/// Continuous categories with a footer that tracks the leading visible section.
class DesktopEmojiPicker extends StatefulWidget {
  const DesktopEmojiPicker({
    super.key,
    required this.onSelected,
    this.query = '',
  });

  final String query;

  final ValueChanged<String> onSelected;

  @override
  State<DesktopEmojiPicker> createState() => _DesktopEmojiPickerState();
}

class _DesktopEmojiPickerState extends State<DesktopEmojiPicker> {
  final _scroll = ScrollController();
  final _strip = ScrollController();
  final _icons = List.generate(kEmojiCategories.length, (_) => GlobalKey());
  List<double> _offsets = const [];
  int _active = 0;
  static final _names = {
    for (final category in emoji_metadata.defaultEmojiSet)
      for (final emoji in category.emoji) emoji.emoji: emoji.name,
  };

  Widget _cell(String emoji) => DesktopPickerPreview(
    enableHoldPreview: true,
    preview: Text(emoji, style: const TextStyle(fontSize: 72)),
    name: _names[emoji] ?? emoji,
    details: emoji.runes
        .map(
          (rune) => 'U+${rune.toRadixString(16).toUpperCase().padLeft(4, '0')}',
        )
        .join(' '),
    child: InkWell(
      customBorder: materialEmojiPickerStyle(Theme.of(context)).cellShape,
      onTap: () => widget.onSelected(emoji),
      child: Center(child: Text(emoji, style: const TextStyle(fontSize: 24))),
    ),
  );

  @override
  void didUpdateWidget(covariant DesktopEmojiPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_trackSection);
  }

  void _trackSection() {
    if (_offsets.isEmpty || widget.query.trim().isNotEmpty) return;
    var index = 0;
    for (var i = 1; i < _offsets.length; i++) {
      if (_offsets[i] > _scroll.offset + 24) break;
      index = i;
    }
    if (index == _active) return;
    setState(() => _active = index);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final iconContext = _icons[_active].currentContext;
      if (iconContext != null) {
        Scrollable.ensureVisible(
          iconContext,
          alignment: .5,
          duration: const Duration(milliseconds: 120),
        );
      }
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _strip.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final style = materialEmojiPickerStyle(Theme.of(context));
    final query = widget.query.trim().toLowerCase();
    if (query.isNotEmpty) {
      final matches = kEmojiCategories
          .expand((category) => category.emojis)
          .toSet()
          .where(
            (emoji) =>
                emoji.contains(query) ||
                (_names[emoji]?.toLowerCase().contains(query) ?? false) ||
                (kEmojiKeywords[emoji]?.any(
                      (keyword) => keyword.toLowerCase().contains(query),
                    ) ??
                    false),
          )
          .toList();
      return matches.isEmpty
          ? const Center(child: Text('没有匹配的表情'))
          : GridView.builder(
              controller: _scroll,
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 44,
              ),
              itemCount: matches.length,
              itemBuilder: (context, index) => _cell(matches[index]),
            );
    }
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final columns = ((constraints.maxWidth - 16) / 40).floor().clamp(
                1,
                12,
              );
              final cell = (constraints.maxWidth - 16) / columns;
              final headingHeight =
                  24 * MediaQuery.textScalerOf(context).scale(1) + 16;
              var offset = 0.0;
              _offsets = [
                for (final category in kEmojiCategories)
                  () {
                    final start = offset;
                    offset +=
                        headingHeight +
                        (category.emojis.length / columns).ceil() * cell;
                    return start;
                  }(),
              ];
              return Scrollbar(
                controller: _scroll,
                child: CustomScrollView(
                  key: const ValueKey('desktop-emoji-scroll'),
                  controller: _scroll,
                  slivers: [
                    for (final category in kEmojiCategories) ...[
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: headingHeight,
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Text(category.label, style: style.heading),
                            ),
                          ),
                        ),
                      ),
                      SliverPadding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        sliver: SliverGrid(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: columns,
                              ),
                          delegate: SliverChildBuilderDelegate((
                            context,
                            index,
                          ) {
                            final emoji = category.emojis[index];
                            return _cell(emoji);
                          }, childCount: category.emojis.length),
                        ),
                      ),
                    ],
                    // Let the final category reach the activation line too.
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height: constraints.maxHeight - headingHeight > 0
                            ? constraints.maxHeight - headingHeight
                            : 0,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        ),
        const Divider(height: 1),
        SizedBox(
          height: desktopPickerFooterHeight,
          child: Align(
            alignment: Alignment.centerLeft,
            child: SingleChildScrollView(
              controller: _strip,
              padding: const EdgeInsets.all(desktopPickerGroupInset),
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < kEmojiCategories.length; i++)
                    Padding(
                      padding: EdgeInsets.only(
                        right: i == kEmojiCategories.length - 1
                            ? 0
                            : desktopPickerGroupGap,
                      ),
                      child: Semantics(
                        key: _icons[i],
                        selected: i == _active,
                        button: true,
                        child: IconButton(
                          key: ValueKey('desktop-emoji-category-$i'),
                          tooltip: kEmojiCategories[i].label,
                          isSelected: i == _active,
                          style: desktopPickerGroupButtonStyle(
                            context,
                            selected: i == _active,
                          ),
                          onPressed: () => _scroll.animateTo(
                            _offsets[i].clamp(
                              0,
                              _scroll.position.maxScrollExtent,
                            ),
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOutCubic,
                          ),
                          icon: Text(
                            kEmojiCategories[i].icon,
                            style: const TextStyle(fontSize: 20),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
