import 'dart:async';

import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';

enum SendFlightKind { text, sticker }

class SendFlightSpec {
  final Rect sourceRect;
  final Widget child;
  final SendFlightKind kind;

  const SendFlightSpec({
    required this.sourceRect,
    required this.child,
    required this.kind,
  });
}

final Map<String, SendFlightSpec> _pendingSendFlights = {};

String sendFlightId(String messageId) {
  for (final prefix in [
    localOutgoingPendingPrefix,
    localOutgoingSentPrefix,
    localOutgoingFailedPrefix,
  ]) {
    if (messageId.startsWith(prefix)) {
      return messageId.substring(prefix.length);
    }
  }
  return messageId;
}

void registerSendFlight(String messageId, SendFlightSpec spec) {
  final id = sendFlightId(messageId);
  _pendingSendFlights[id] = spec;
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (identical(_pendingSendFlights[id], spec)) {
        _pendingSendFlights.remove(id);
      }
    }),
  );
}

class SendFlightTarget extends StatefulWidget {
  final String messageId;
  final Widget child;

  const SendFlightTarget({
    super.key,
    required this.messageId,
    required this.child,
  });

  @override
  State<SendFlightTarget> createState() => _SendFlightTargetState();
}

class _SendFlightTargetState extends State<SendFlightTarget> {
  final GlobalKey _targetKey = GlobalKey();
  bool _hideTarget = false;

  @override
  void initState() {
    super.initState();
    final id = sendFlightId(widget.messageId);
    _hideTarget = _pendingSendFlights.containsKey(id);
    if (_hideTarget) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startFlight(id));
    }
  }

  Future<void> _startFlight(String id) async {
    if (!mounted) return;
    final spec = _pendingSendFlights.remove(id);
    final targetBox =
        _targetKey.currentContext?.findRenderObject() as RenderBox?;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (spec == null ||
        targetBox == null ||
        !targetBox.hasSize ||
        overlayBox == null ||
        !overlayBox.hasSize) {
      if (mounted) setState(() => _hideTarget = false);
      return;
    }

    Rect inOverlay(Rect rect) => Rect.fromPoints(
      overlayBox.globalToLocal(rect.topLeft),
      overlayBox.globalToLocal(rect.bottomRight),
    );

    final targetTopLeft = targetBox.localToGlobal(Offset.zero);
    final targetRect = targetTopLeft & targetBox.size;
    Rect? currentTargetRect() {
      if (!mounted) return null;
      final currentBox =
          _targetKey.currentContext?.findRenderObject() as RenderBox?;
      if (currentBox == null || !currentBox.attached || !currentBox.hasSize) {
        return null;
      }
      final topLeft = currentBox.localToGlobal(Offset.zero);
      return inOverlay(topLeft & currentBox.size);
    }

    final completer = Completer<void>();
    late final OverlayEntry entry;
    entry = OverlayEntry(
      builder: (_) => _SendFlightOverlay(
        spec: spec,
        begin: inOverlay(spec.sourceRect),
        end: inOverlay(targetRect),
        currentEnd: currentTargetRect,
        onCompleted: () {
          entry.remove();
          if (!completer.isCompleted) completer.complete();
        },
      ),
    );
    overlay.insert(entry);
    await completer.future;
    if (mounted) setState(() => _hideTarget = false);
  }

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _targetKey,
      child: Opacity(opacity: _hideTarget ? 0 : 1, child: widget.child),
    );
  }
}

class _SendFlightOverlay extends StatefulWidget {
  final SendFlightSpec spec;
  final Rect begin;
  final Rect end;
  final Rect? Function() currentEnd;
  final VoidCallback onCompleted;

  const _SendFlightOverlay({
    required this.spec,
    required this.begin,
    required this.end,
    required this.currentEnd,
    required this.onCompleted,
  });

  @override
  State<_SendFlightOverlay> createState() => _SendFlightOverlayState();
}

class _SendFlightOverlayState extends State<_SendFlightOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller =
        AnimationController(
          vsync: this,
          duration: Duration(
            milliseconds: widget.spec.kind == SendFlightKind.sticker
                ? 360
                : 300,
          ),
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) widget.onCompleted();
        });
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: AnimatedBuilder(
        animation: _controller,
        child: widget.spec.child,
        builder: (context, child) {
          final progress = Curves.easeInOutCubicEmphasized.transform(
            _controller.value,
          );
          final rect = Rect.lerp(
            widget.begin,
            widget.currentEnd() ?? widget.end,
            progress,
          )!;
          final isText = widget.spec.kind == SendFlightKind.text;
          return Stack(
            children: [
              Positioned.fromRect(
                rect: rect,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: isText
                        ? Color.lerp(
                            AppColors.surfaceVariant,
                            AppColors.primary,
                            progress,
                          )
                        : Colors.transparent,
                    borderRadius: BorderRadius.lerp(
                      BorderRadius.circular(AppRadii.surface),
                      BorderRadius.circular(AppRadii.content),
                      progress,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(AppRadii.content),
                    child: child,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
