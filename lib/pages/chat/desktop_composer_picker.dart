import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';

import '../../theme/material_theme.dart';
import 'composer_picker_panel.dart';
import 'desktop_emoji_picker.dart';
import 'sticker_catalog.dart';

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
  late bool _stickersOpened = widget.tab == ComposerPickerTab.sticker;

  @override
  void didUpdateWidget(covariant DesktopComposerPicker oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.tab == ComposerPickerTab.sticker) _stickersOpened = true;
  }

  @override
  void dispose() {
    _stickers.dispose();
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
            child: Material(
              key: const ValueKey('desktop-composer-popup'),
              color: style.fill,
              shape: style.shape,
              elevation: style.elevation,
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: [
                  SizedBox(
                    height: 48,
                    child: Row(
                      children: [
                        for (final tab in ComposerPickerTab.values)
                          Expanded(
                            child: TextButton(
                              key: ValueKey('desktop-picker-tab-${tab.name}'),
                              style: desktopComposerPickerStyle(
                                context,
                                selected: widget.tab == tab,
                              ).tab,
                              onPressed: () => widget.onTabChanged(tab),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    tab == ComposerPickerTab.emoji
                                        ? '表情'
                                        : '贴纸',
                                  ),
                                  if (widget.tab == tab)
                                    SizedBox(
                                      height: 2,
                                      child: Divider(
                                        thickness: 2,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const Divider(height: 1),
                  Expanded(
                    child: IndexedStack(
                      index: widget.tab.index,
                      children: [
                        DesktopEmojiPicker(onSelected: widget.onEmojiSelected),
                        if (_stickersOpened)
                          StickerPackPanel(
                            roomId: widget.roomId,
                            scrollController: _stickers,
                            packStripAtBottom: true,
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
      );
    },
    child: widget.child,
  );
}
