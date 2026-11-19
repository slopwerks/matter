import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Keeps the conversation usable while the room list and details share a window.
class DesktopSplitView extends StatefulWidget {
  final Widget roomList;
  final Widget chat;
  final Widget? details;

  const DesktopSplitView({
    super.key,
    required this.roomList,
    required this.chat,
    this.details,
  });

  @override
  State<DesktopSplitView> createState() => _DesktopSplitViewState();
}

class _DesktopSplitViewState extends State<DesktopSplitView> {
  static const _defaultListWidth = 348.0;
  static const _minimumListWidth = 260.0;
  static const _minimumChatWidth = 360.0;
  static const _detailsWidth = 300.0;
  static const _dividerWidth = 8.0;
  double _preferredListWidth = _defaultListWidth;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final showDetails =
            widget.details != null &&
            constraints.maxWidth >=
                _minimumListWidth +
                    _dividerWidth +
                    _minimumChatWidth +
                    _detailsWidth +
                    1;
        final maxListWidth = math.min(
          480.0,
          constraints.maxWidth -
              _minimumChatWidth -
              _dividerWidth -
              (showDetails ? _detailsWidth + 1 : 0),
        );
        final minListWidth = math.min(_minimumListWidth, maxListWidth);
        final listWidth = _preferredListWidth.clamp(minListWidth, maxListWidth);
        void resize(double delta) => setState(() {
          _preferredListWidth = (listWidth + delta).clamp(
            minListWidth,
            maxListWidth,
          );
        });

        return Row(
          children: [
            SizedBox(
              key: const ValueKey('desktop-room-list'),
              width: listWidth,
              child: widget.roomList,
            ),
            Semantics(
              label: '会话列表宽度',
              value: '${listWidth.round()}',
              increasedValue:
                  '${(listWidth + 24).clamp(minListWidth, maxListWidth).round()}',
              decreasedValue:
                  '${(listWidth - 24).clamp(minListWidth, maxListWidth).round()}',
              onIncrease: () => resize(24),
              onDecrease: () => resize(-24),
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeColumn,
                child: GestureDetector(
                  key: const ValueKey('desktop-list-divider'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) => resize(
                    Directionality.of(context) == TextDirection.rtl
                        ? -details.delta.dx
                        : details.delta.dx,
                  ),
                  onDoubleTap: () =>
                      setState(() => _preferredListWidth = _defaultListWidth),
                  child: const SizedBox(
                    width: _dividerWidth,
                    child: Center(
                      child: VerticalDivider(width: 1, thickness: 1),
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, pane) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(size: Size(pane.maxWidth, pane.maxHeight)),
                  child: widget.chat,
                ),
              ),
            ),
            if (showDetails) ...[
              const VerticalDivider(width: 1, thickness: 1),
              SizedBox(width: _detailsWidth, child: widget.details),
            ],
          ],
        );
      },
    );
  }
}
