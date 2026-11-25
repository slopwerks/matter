import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/scheduler.dart';

import '../../theme/material_theme.dart';

/// Shared by the popup so scrolling one section cancels every hover card.
class DesktopPickerHoverScope extends StatefulWidget {
  const DesktopPickerHoverScope({
    super.key,
    required this.identity,
    required this.child,
  });
  final Object identity;
  final Widget child;

  @override
  State<DesktopPickerHoverScope> createState() =>
      _DesktopPickerHoverScopeState();
}

class _HoverGate extends ChangeNotifier {
  Timer? _cooldown;
  bool blocked = false;
  final Set<ScrollPosition> _scrolling = {};

  void suspend() {
    blocked = true;
    _cooldown?.cancel();
    notifyListeners();
    _cooldown = Timer(const Duration(milliseconds: 250), () {
      blocked = _scrolling.isNotEmpty;
    });
  }

  void scroll(ScrollNotification event) {
    if (event is! ScrollStartNotification &&
        event is! ScrollEndNotification &&
        event is! OverscrollNotification &&
        !(event is ScrollUpdateNotification && (event.scrollDelta ?? 0) != 0)) {
      return;
    }
    final position = Scrollable.maybeOf(event.context!)?.position;
    if (position != null) {
      if (event is ScrollStartNotification) _scrolling.add(position);
      if (event is ScrollEndNotification) _scrolling.remove(position);
    }
    suspend();
  }

  @override
  void dispose() {
    _cooldown?.cancel();
    super.dispose();
  }
}

class _HoverScope extends InheritedWidget {
  const _HoverScope({required this.gate, required super.child});
  final _HoverGate gate;
  @override
  bool updateShouldNotify(_HoverScope oldWidget) => oldWidget.gate != gate;
}

class _DesktopPickerHoverScopeState extends State<DesktopPickerHoverScope> {
  final _gate = _HoverGate();

  @override
  void didUpdateWidget(covariant DesktopPickerHoverScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.identity != oldWidget.identity) _gate.suspend();
  }

  @override
  void dispose() {
    _gate.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _HoverScope(
    gate: _gate,
    child: Listener(
      onPointerSignal: (_) => _gate.suspend(),
      onPointerDown: (_) => _gate.suspend(),
      child: NotificationListener<ScrollNotification>(
        onNotification: (event) {
          _gate.scroll(event);
          return false;
        },
        child: widget.child,
      ),
    ),
  );
}

/// Only actual pointer movement arms this preview; layout-driven enter events do not.
class DesktopPickerPreview extends StatefulWidget {
  const DesktopPickerPreview({
    super.key,
    required this.preview,
    required this.name,
    required this.details,
    required this.child,
  });

  final Widget preview;
  final String name;
  final String details;
  final Widget child;

  @override
  State<DesktopPickerPreview> createState() => _DesktopPickerPreviewState();
}

class _DesktopPickerPreviewState extends State<DesktopPickerPreview> {
  final _overlay = OverlayPortalController();
  final _anchor = GlobalKey();
  _HoverGate? _gate;
  Timer? _wait;
  Offset? _settlePosition;
  int _dismissGeneration = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final gate = context
        .dependOnInheritedWidgetOfExactType<_HoverScope>()
        ?.gate;
    if (gate == _gate) return;
    _gate?.removeListener(_dismiss);
    _gate = gate;
    _gate?.addListener(_dismiss);
  }

  void _dismiss() {
    final generation = ++_dismissGeneration;
    _wait?.cancel();
    _wait = null;
    _settlePosition = null;
    if (!_overlay.isShowing) return;
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && generation == _dismissGeneration) _overlay.hide();
      });
    } else {
      _overlay.hide();
    }
  }

  void _hover(Offset position) {
    if (_gate?.blocked == true) return;
    if (_settlePosition != null &&
        (position - _settlePosition!).distance <= 4) {
      return;
    }
    _wait?.cancel();
    _settlePosition = position;
    if (_overlay.isShowing) return;
    _wait = Timer(const Duration(milliseconds: 500), () {
      if (mounted && _gate?.blocked != true) {
        _dismissGeneration++;
        _overlay.show();
      }
    });
  }

  @override
  void didUpdateWidget(covariant DesktopPickerPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.name != widget.name || oldWidget.details != widget.details) {
      _dismiss();
    }
  }

  @override
  void dispose() {
    _wait?.cancel();
    _gate?.removeListener(_dismiss);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => OverlayPortal(
    controller: _overlay,
    overlayChildBuilder: (overlayContext) {
      final style = desktopPickerPreviewStyle(context);
      final anchor = _anchor.currentContext!.findRenderObject()! as RenderBox;
      final overlay =
          Overlay.of(overlayContext).context.findRenderObject()! as RenderBox;
      final rect =
          anchor.localToGlobal(Offset.zero, ancestor: overlay) & anchor.size;
      return Positioned.fill(
        child: IgnorePointer(
          child: ExcludeSemantics(
            child: CustomSingleChildLayout(
              delegate: _PreviewPosition(rect),
              child: DecoratedBox(
                decoration: style.decoration,
                child: Padding(
                  padding: style.padding,
                  child: DefaultTextStyle(
                    style: style.details,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          height: 112,
                          width: 140,
                          child: Center(child: widget.preview),
                        ),
                        Text(
                          widget.name,
                          style: style.name,
                          textAlign: TextAlign.center,
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          widget.details,
                          textAlign: TextAlign.center,
                          maxLines: 4,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    },
    child: MouseRegion(
      key: _anchor,
      onHover: (event) => _hover(event.position),
      onExit: (event) {
        // Overlay/layout changes can synthesize exits without leaving the cell.
        final box = _anchor.currentContext?.findRenderObject() as RenderBox?;
        if (box != null &&
            box.attached &&
            box.hasSize &&
            (Offset.zero & box.size).contains(
              box.globalToLocal(event.position),
            )) {
          return;
        }
        _dismiss();
      },
      child: widget.child,
    ),
  );
}

class _PreviewPosition extends SingleChildLayoutDelegate {
  const _PreviewPosition(this.anchor);
  final Rect anchor;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints.tightFor(
        width: math.min(208, math.max(0, constraints.maxWidth - 16)).toDouble(),
      ).copyWith(maxHeight: math.max(0, constraints.maxHeight - 16).toDouble());

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    final x = (anchor.center.dx - childSize.width / 2).clamp(
      8.0,
      math.max(8.0, size.width - childSize.width - 8),
    );
    final above = anchor.top - childSize.height - 8;
    final y = (above >= 8 ? above : anchor.bottom + 8).clamp(
      8.0,
      math.max(8.0, size.height - childSize.height - 8),
    );
    return Offset(x.toDouble(), y.toDouble());
  }

  @override
  bool shouldRelayout(_PreviewPosition oldDelegate) =>
      anchor != oldDelegate.anchor;
}
