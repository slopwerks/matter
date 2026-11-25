import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../theme/material_theme.dart';
import 'composer_picker_panel.dart';
import 'desktop_emoji_picker.dart';
import 'sticker_catalog.dart';
import 'desktop_picker_preview.dart';
import '../../widgets/app_search_field.dart';

/// Desktop-only anchored overlay; it never reserves space below the composer.
class DesktopComposerPicker extends StatefulWidget {
  const DesktopComposerPicker({
    super.key,
    required this.controller,
    required this.roomId,
    required this.tab,
    required this.onTabChanged,
    required this.onEmojiSelected,
    required this.onStickerSelected,
    required this.onOpenChanged,
    required this.child,
  });

  final MenuController controller;
  final String roomId;
  final ComposerPickerTab tab;
  final ValueChanged<ComposerPickerTab> onTabChanged;
  final ValueChanged<String> onEmojiSelected;
  final void Function(StickerItem, Rect?) onStickerSelected;
  final ValueChanged<bool> onOpenChanged;
  final Widget child;

  @override
  State<DesktopComposerPicker> createState() => _DesktopComposerPickerState();
}

class _DesktopComposerPickerState extends State<DesktopComposerPicker> {
  final _stickers = ScrollController();
  final _search = TextEditingController();
  String _query = '';
  late bool _stickersOpened = widget.tab == ComposerPickerTab.sticker;

  @override
  void didUpdateWidget(covariant DesktopComposerPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab == ComposerPickerTab.sticker) _stickersOpened = true;
  }

  @override
  void dispose() {
    _stickers.dispose();
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => RawMenuAnchor(
    controller: widget.controller,
    onOpen: () => widget.onOpenChanged(true),
    onClose: () => widget.onOpenChanged(false),
    overlayBuilder: (context, info) {
      const margin = 8.0;
      final width = math.min(
        380.0,
        math.max(0.0, info.overlaySize.width - margin * 2),
      );
      final height = math.min(
        460.0,
        math.max(0.0, info.overlaySize.height - margin * 2),
      );
      final left = (info.anchorRect.left).clamp(
        margin,
        math.max(margin, info.overlaySize.width - width - margin),
      );
      final top = (info.anchorRect.top - height - margin).clamp(
        margin,
        math.max(margin, info.overlaySize.height - height - margin),
      );
      final style = desktopComposerPickerStyle(context, selected: false);
      return Positioned(
        left: left.toDouble(),
        top: top.toDouble(),
        width: width,
        height: height,
        child: TapRegion(
          groupId: info.tapRegionGroupId,
          onTapOutside: (_) => widget.controller.close(),
          child: Focus(
            autofocus: true,
            onKeyEvent: (node, event) {
              if (event is KeyDownEvent &&
                  event.logicalKey == LogicalKeyboardKey.escape) {
                widget.controller.close();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            child: DesktopPickerHoverScope(
              identity: (widget.tab, _query),
              child: Material(
                key: const ValueKey('desktop-composer-popup'),
                color: style.fill,
                shape: style.shape,
                elevation: style.elevation,
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    SizedBox(
                      key: const ValueKey('desktop-picker-tabs'),
                      height: 48,
                      child: Stack(
                        children: [
                          Row(
                            children: [
                              for (final tab in ComposerPickerTab.values)
                                Expanded(
                                  child: SizedBox(
                                    height: double.infinity,
                                    child: TextButton(
                                      key: ValueKey(
                                        'desktop-picker-tab-${tab.name}',
                                      ),
                                      style: desktopComposerPickerStyle(
                                        context,
                                        selected: widget.tab == tab,
                                      ).tab,
                                      onPressed: () => widget.onTabChanged(tab),
                                      child: Text(
                                        tab == ComposerPickerTab.emoji
                                            ? '表情'
                                            : '贴纸',
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                          const Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Divider(height: 1),
                          ),
                          Positioned.fill(
                            child: IgnorePointer(
                              child: AnimatedAlign(
                                alignment: widget.tab == ComposerPickerTab.emoji
                                    ? Alignment.bottomLeft
                                    : Alignment.bottomRight,
                                duration:
                                    MediaQuery.disableAnimationsOf(context)
                                    ? Duration.zero
                                    : const Duration(milliseconds: 160),
                                curve: Curves.easeOutCubic,
                                child: FractionallySizedBox(
                                  widthFactor: .5,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Container(
                                      key: const ValueKey(
                                        'desktop-picker-indicator',
                                      ),
                                      height: 3,
                                      decoration: BoxDecoration(
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                        borderRadius:
                                            const BorderRadius.vertical(
                                              top: Radius.circular(3),
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
                      child: AppSearchField(
                        key: const ValueKey('desktop-picker-search'),
                        controller: _search,
                        hint: widget.tab == ComposerPickerTab.emoji
                            ? '搜索表情'
                            : '搜索贴纸包、名称或 :shortcode:',
                        onChanged: (value) => setState(() => _query = value),
                        trailing: _query.isEmpty
                            ? null
                            : IconButton(
                                tooltip: '清除搜索',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _search.clear();
                                  setState(() => _query = '');
                                },
                              ),
                      ),
                    ),
                    Expanded(
                      child: IndexedStack(
                        index: widget.tab.index,
                        children: [
                          DesktopEmojiPicker(
                            onSelected: widget.onEmojiSelected,
                            query: _query,
                          ),
                          if (_stickersOpened)
                            StickerPackPanel(
                              roomId: widget.roomId,
                              scrollController: _stickers,
                              packStripAtBottom: true,
                              active: widget.tab == ComposerPickerTab.sticker,
                              query: _query,
                              onPackNavigation: () async {},
                              onStickerSelected: widget.onStickerSelected,
                            )
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
    },
    child: widget.child,
  );
}
