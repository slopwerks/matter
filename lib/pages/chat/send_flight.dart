import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../providers/chat_provider.dart';
import '../../theme/app_theme.dart';

enum SendFlightKind { text, sticker }

const BorderRadius outgoingTextBubbleBorderRadius = BorderRadius.only(
  topLeft: Radius.circular(AppRadii.content),
  topRight: Radius.circular(AppRadii.content),
  bottomLeft: Radius.circular(AppRadii.content),
  bottomRight: Radius.circular(AppRadii.tag),
);

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

final Map<String, _PendingFlight> _pendingSendFlights = {};
final Map<String, _ActiveFlight> _activeSendFlights = {};
final ValueNotifier<int> _sendFlightStateRevision = ValueNotifier<int>(0);

class _PendingFlight {
  final SendFlightSpec spec;
  final Completer<void> completer = Completer<void>();

  _PendingFlight(this.spec);
}

class _ActiveFlight {
  final Completer<void> completer;
  VoidCallback? cancel;

  _ActiveFlight(this.completer);
}

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

/// Resolves the identity shared by an optimistic message and its server event.
String? messageSendFlightId(
  String messageId,
  Map<String, String> remoteToLocalFlightId,
) {
  final matchedFlightId = remoteToLocalFlightId[messageId];
  if (matchedFlightId != null) return matchedFlightId;
  if (isLocalOutgoingMessage(messageId)) return sendFlightId(messageId);
  return null;
}

void notifySendFlightTargetReady(BuildContext context) {
  context.findAncestorStateOfType<_SendFlightTargetState>()?._markTargetReady();
}

void _notifySendFlightStateChanged() {
  _sendFlightStateRevision.value++;
}

bool _shouldHideSendFlightTarget(String id) =>
    _pendingSendFlights.containsKey(id) || _activeSendFlights.containsKey(id);

bool get hasOngoingSendFlight =>
    _pendingSendFlights.isNotEmpty || _activeSendFlights.isNotEmpty;

/// Stops the current flight before a rapid send inserts another target row.
/// The existing target is revealed at its current slot, then the normal row
/// insertion animation can move it without competing with a floating overlay.
void cancelOngoingSendFlights() {
  final pending = _pendingSendFlights.values.toList();
  final active = _activeSendFlights.values.toList();
  if (pending.isEmpty && active.isEmpty) return;

  _pendingSendFlights.clear();
  _activeSendFlights.clear();
  _notifySendFlightStateChanged();

  for (final flight in pending) {
    if (!flight.completer.isCompleted) flight.completer.complete();
  }
  for (final flight in active) {
    final cancel = flight.cancel;
    if (cancel != null) {
      cancel();
    } else if (!flight.completer.isCompleted) {
      flight.completer.complete();
    }
  }
}

Rect projectSendFlightTargetToLatest(Rect currentRect, ScrollMetrics metrics) {
  final distance = math.max(0.0, metrics.pixels - metrics.minScrollExtent);
  return switch (metrics.axisDirection) {
    AxisDirection.up => currentRect.translate(0, -distance),
    AxisDirection.down => currentRect.translate(0, distance),
    AxisDirection.left => currentRect.translate(-distance, 0),
    AxisDirection.right => currentRect.translate(distance, 0),
  };
}

/// Registers a send flight and returns a [Future] that completes when the
/// flight animation finishes (or times out). If a flight for the same message
/// id is already registered, the existing future is returned.
Future<void> registerSendFlight(String messageId, SendFlightSpec spec) {
  final id = sendFlightId(messageId);
  final existing = _pendingSendFlights[id];
  if (existing != null) {
    return existing.completer.future;
  }
  final active = _activeSendFlights[id];
  if (active != null) return active.completer.future;
  final pending = _PendingFlight(spec);
  _pendingSendFlights[id] = pending;
  _notifySendFlightStateChanged();
  unawaited(
    Future<void>.delayed(const Duration(seconds: 2), () {
      if (identical(_pendingSendFlights[id], pending)) {
        _pendingSendFlights.remove(id);
        _notifySendFlightStateChanged();
        if (!pending.completer.isCompleted) pending.completer.complete();
      }
    }),
  );
  return pending.completer.future;
}

class SendFlightTarget extends StatefulWidget {
  final String messageId;
  final String? flightId;
  final ScrollController? latestScrollController;
  final bool lockEndAtLatest;
  final bool waitForTargetReady;
  final BorderRadius? endBorderRadius;

  /// Current bottom inset that vertically positions the timeline.
  final double bottomInset;
  final Widget child;

  const SendFlightTarget({
    super.key,
    required this.messageId,
    this.flightId,
    this.latestScrollController,
    this.lockEndAtLatest = false,
    this.waitForTargetReady = false,
    this.endBorderRadius,
    this.bottomInset = 0,
    required this.child,
  });

  @override
  State<SendFlightTarget> createState() => _SendFlightTargetState();
}

class _SendFlightTargetState extends State<SendFlightTarget> {
  static const _targetReadyTimeout = Duration(seconds: 5);

  final GlobalKey _targetKey = GlobalKey();
  bool _hideTarget = false;
  bool _handoffVisible = false;
  bool _targetReady = false;
  Completer<void>? _targetReadyCompleter;
  String? _scheduledFlightId;

  String get _flightId => widget.flightId ?? sendFlightId(widget.messageId);

  @override
  void initState() {
    super.initState();
    _sendFlightStateRevision.addListener(_handleFlightStateChanged);
    _hideTarget = _shouldHideSendFlightTarget(_flightId);
    _maybeStartFlight(_flightId);
  }

  @override
  void didUpdateWidget(covariant SendFlightTarget oldWidget) {
    super.didUpdateWidget(oldWidget);
    final oldId = oldWidget.flightId ?? sendFlightId(oldWidget.messageId);
    final newId = _flightId;
    if (oldId != newId) {
      _scheduledFlightId = null;
      _handoffVisible = false;
      _targetReady = false;
      _targetReadyCompleter = null;
    }
    _syncHiddenState();
    _maybeStartFlight(newId);
  }

  @override
  void dispose() {
    _sendFlightStateRevision.removeListener(_handleFlightStateChanged);
    super.dispose();
  }

  void _handleFlightStateChanged() {
    if (!mounted) return;
    _syncHiddenState();
    _maybeStartFlight(_flightId);
  }

  void _syncHiddenState() {
    final shouldHide =
        !_handoffVisible && _shouldHideSendFlightTarget(_flightId);
    if (_hideTarget == shouldHide) return;
    setState(() => _hideTarget = shouldHide);
  }

  void _markTargetReady() {
    if (_targetReady) return;
    _targetReady = true;
    final completer = _targetReadyCompleter;
    if (completer != null && !completer.isCompleted) completer.complete();
  }

  Future<void> _waitForTargetReady() async {
    if (_targetReady) return;
    final completer = _targetReadyCompleter ??= Completer<void>();
    await completer.future.timeout(_targetReadyTimeout, onTimeout: () {});
  }

  Future<void> _prepareTargetHandoff() async {
    await _waitForTargetReady();
    if (!mounted) return;
    setState(() {
      _handoffVisible = true;
      _hideTarget = false;
    });
    // Keep the flight over the target until the real bubble has painted once.
    await WidgetsBinding.instance.endOfFrame;
  }

  void _maybeStartFlight(String id) {
    if (!_pendingSendFlights.containsKey(id) || _scheduledFlightId == id) {
      return;
    }
    _scheduledFlightId = id;
    WidgetsBinding.instance.addPostFrameCallback((_) => _startFlight(id));
  }

  Future<void> _startFlight(String id) async {
    final pending = _pendingSendFlights.remove(id);
    final activeFlight = pending == null
        ? null
        : _ActiveFlight(pending.completer);
    if (pending != null) {
      _activeSendFlights[id] = activeFlight!;
      _notifySendFlightStateChanged();
    }
    if (pending == null || !mounted) {
      if (pending != null && !pending.completer.isCompleted) {
        _activeSendFlights.remove(id);
        _notifySendFlightStateChanged();
        pending.completer.complete();
      }
      return;
    }
    final spec = pending.spec;
    final overlay = Overlay.of(context, rootOverlay: true);
    final overlayBox = overlay.context.findRenderObject() as RenderBox?;
    if (overlayBox == null || !overlayBox.hasSize) {
      _activeSendFlights.remove(id);
      _notifySendFlightStateChanged();
      if (!pending.completer.isCompleted) pending.completer.complete();
      return;
    }

    Rect inOverlay(Rect rect) => Rect.fromPoints(
      overlayBox.globalToLocal(rect.topLeft),
      overlayBox.globalToLocal(rect.bottomRight),
    );

    Rect? targetRect() {
      final targetBox =
          _targetKey.currentContext?.findRenderObject() as RenderBox?;
      if (targetBox == null || !targetBox.hasSize || !targetBox.attached) {
        return null;
      }
      final topLeft = targetBox.localToGlobal(
        Offset.zero,
        ancestor: overlayBox,
      );
      return topLeft & targetBox.size;
    }

    Rect? lockedTargetRect() {
      final rect = targetRect();
      if (rect == null) return null;
      final controller = widget.latestScrollController;
      if (!widget.lockEndAtLatest ||
          controller == null ||
          !controller.hasClients) {
        return rect;
      }
      return projectSendFlightTargetToLatest(rect, controller.position);
    }

    final lockedEnd = lockedTargetRect();
    final end = lockedEnd ?? inOverlay(spec.sourceRect);
    final initialBottomInset = widget.bottomInset;

    Rect? resolveEnd() {
      if (!widget.lockEndAtLatest) return targetRect();
      if (lockedEnd == null) return null;
      // Follow composer reflow without chasing a row moved by newer messages.
      return lockedEnd.translate(0, initialBottomInset - widget.bottomInset);
    }

    final overlayCompleter = Completer<void>();
    var overlayFinished = false;
    late final OverlayEntry entry;
    void finishOverlay() {
      if (overlayFinished) return;
      overlayFinished = true;
      entry.remove();
      if (!overlayCompleter.isCompleted) overlayCompleter.complete();
    }

    entry = OverlayEntry(
      builder: (_) => _SendFlightOverlay(
        spec: spec,
        begin: inOverlay(spec.sourceRect),
        end: end,
        resolveEnd: resolveEnd,
        resolveEndBorderRadius: () =>
            widget.endBorderRadius ?? outgoingTextBubbleBorderRadius,
        waitForTargetReady: widget.waitForTargetReady
            ? _prepareTargetHandoff
            : null,
        onCompleted: finishOverlay,
      ),
    );
    activeFlight!.cancel = finishOverlay;
    overlay.insert(entry);
    try {
      await overlayCompleter.future;
    } finally {
      _activeSendFlights.remove(id);
      _notifySendFlightStateChanged();
      if (!pending.completer.isCompleted) pending.completer.complete();
    }
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
  final Rect? Function()? resolveEnd;
  final BorderRadius Function()? resolveEndBorderRadius;
  final Future<void> Function()? waitForTargetReady;
  final VoidCallback onCompleted;

  const _SendFlightOverlay({
    required this.spec,
    required this.begin,
    required this.end,
    this.resolveEnd,
    this.resolveEndBorderRadius,
    this.waitForTargetReady,
    required this.onCompleted,
  });

  @override
  State<_SendFlightOverlay> createState() => _SendFlightOverlayState();
}

class _SendFlightOverlayState extends State<_SendFlightOverlay>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _animation;
  bool _isCompleting = false;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.spec.kind == SendFlightKind.sticker ? 360 : 300,
      ),
    );
    _animation =
        CurvedAnimation(
          parent: _controller,
          curve: Curves.easeInOutCubicEmphasized,
        )..addStatusListener((status) {
          if (status == AnimationStatus.completed) {
            unawaited(_completeWhenReady());
          }
        });
    _controller.forward();
  }

  Future<void> _completeWhenReady() async {
    if (_isCompleting) return;
    _isCompleting = true;
    await widget.waitForTargetReady?.call();
    if (mounted) widget.onCompleted();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle(
          style: const TextStyle(
            color: AppColors.onBackground,
            fontSize: 15,
            fontWeight: FontWeight.w400,
            decoration: TextDecoration.none,
          ),
          child: AnimatedBuilder(
            animation: _animation,
            child: widget.spec.child,
            builder: (context, child) {
              final progress = _animation.value;
              final end = widget.resolveEnd?.call() ?? widget.end;
              final rect = Rect.lerp(widget.begin, end, progress)!;
              final isText = widget.spec.kind == SendFlightKind.text;
              final endBorderRadius =
                  widget.resolveEndBorderRadius?.call() ??
                  outgoingTextBubbleBorderRadius;
              final borderRadius = BorderRadius.lerp(
                BorderRadius.circular(AppRadii.surface),
                endBorderRadius,
                progress,
              )!;
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
                        borderRadius: borderRadius,
                      ),
                      child: ClipRRect(
                        borderRadius: borderRadius,
                        child: child,
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
