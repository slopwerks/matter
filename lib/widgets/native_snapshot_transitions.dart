import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

/// A background captured before navigation, without a Dart PNG round trip.
abstract interface class NativeSnapshotBackground {
  int? get nativeBackgroundToken;
}

Future<int?> captureNativeBackBackground() async {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return null;
  try {
    return await _SnapshotCoordinator.channel.invokeMethod<int>(
      'captureBackground',
    );
  } on MissingPluginException {
    return null;
  } on PlatformException catch (error) {
    debugPrint('Snapshot background unavailable: $error');
    return null;
  }
}

/// Android trial: cache route pixels before dragging, then let the platform
/// animate images. The real Navigator is changed only by a committed gesture.
class NativeSnapshotPageTransitionsBuilder extends PageTransitionsBuilder {
  const NativeSnapshotPageTransitionsBuilder();
  static const _entrance = FadeForwardsPageTransitionsBuilder();

  @override
  Duration get reverseTransitionDuration => Duration.zero;
  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) => _SnapshotRoute(
    route: route,
    child: _entrance.buildTransitions(
      route,
      context,
      animation,
      secondaryAnimation,
      _SnapshotContent(route: route, child: child),
    ),
  );
}

/// Custom root routes (including the image viewer) bypass the theme builder.
class NativeSnapshotNavigationObserver extends NavigatorObserver {
  @override
  void didChangeTop(Route<dynamic> topRoute, Route<dynamic>? previousTopRoute) {
    for (final state in _SnapshotCoordinator.states.toList()) {
      state._schedule();
    }
  }
}

class _SnapshotEntry {
  _SnapshotEntry(this.route);
  final PageRoute<dynamic> route;
  final key = GlobalKey();
  Uint8List? pixels;
  bool disposed = false;
  Future<Uint8List?> capture() async {
    final boundary = key.currentContext?.findRenderObject();
    if (disposed ||
        boundary is! RenderRepaintBoundary ||
        boundary.debugNeedsPaint) {
      return pixels;
    }
    final image = await boundary.toImage(
      pixelRatio: MediaQuery.devicePixelRatioOf(key.currentContext!)
          .clamp(1, 2),
    );
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      if (!disposed && data != null) pixels = data.buffer.asUint8List();
      return pixels;
    } finally {
      image.dispose();
    }
  }
}

class _SnapshotContent extends StatelessWidget {
  const _SnapshotContent({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;
  @override
  Widget build(BuildContext context) => RepaintBoundary(
    key: _SnapshotCoordinator.entries
        .putIfAbsent(route, () => _SnapshotEntry(route))
        .key,
    child: child,
  );
}

class _SnapshotCoordinator {
  static const channel = MethodChannel('moe.aks.matter/route_back');
  static final entries = <PageRoute<dynamic>, _SnapshotEntry>{};
  static final states = <_SnapshotRouteState>{};
  static int generation = 0;
  static _SnapshotRouteState? owner;
  static bool installed = false;
  static void install() {
    if (installed) return;
    installed = true;
    channel.setMethodCallHandler((call) async {
      if (call.method != 'commit') throw MissingPluginException();
      final args = Map<Object?, Object?>.from(call.arguments as Map);
      final state = owner;
      if (state == null || args['generation'] != state.generation) return false;
      return state.commit();
    });
  }
}

class _SnapshotRoute extends StatefulWidget {
  const _SnapshotRoute({required this.route, required this.child});
  final PageRoute<dynamic> route;
  final Widget child;
  @override
  State<_SnapshotRoute> createState() => _SnapshotRouteState();
}

class _SnapshotRouteState extends State<_SnapshotRoute>
    implements PopEntry<Object?> {
  @override
  final ValueNotifier<bool> canPopNotifier = ValueNotifier(true);

  @override
  void onPopInvoked(bool didPop) {}

  @override
  void onPopInvokedWithResult(bool didPop, Object? result) {}
  _SnapshotEntry? previous;
  final _ancestorRoutes = <ModalRoute<dynamic>>[];
  Timer? _timer;
  int generation = 0;
  bool _ready = false;
  bool _arming = false;
  bool _nativeArmed = false;
  bool _committing = false;
  bool _preparing = false;
  bool _firstCaptureScheduled = false;
  Future<Uint8List?>? _backgroundCapture;
  bool _supported = true;
  bool? _active;
  PageRoute<dynamic> get route => widget.route;
  bool get eligible =>
      mounted &&
      route.isCurrent &&
      _ancestorRoutes.every((ancestor) => ancestor.isCurrent) &&
      !route.isFirst &&
      route.popDisposition == RoutePopDisposition.pop &&
      !route.popGestureInProgress &&
      route.animation?.status != AnimationStatus.reverse &&
      route.animation?.status != AnimationStatus.dismissed &&
      MediaQuery.viewInsetsOf(context).bottom == 0;

  @override
  void initState() {
    super.initState();
    _SnapshotCoordinator.install();
    _SnapshotCoordinator.states.add(this);
    route.registerPopEntry(this);
    route.animation?.addStatusListener(_status);
    final candidates = _SnapshotCoordinator.entries.values
        .where(
          (e) =>
              e.route != route &&
              e.route.navigator == route.navigator &&
              !e.disposed,
        )
        .toList();
    if (candidates.isNotEmpty) {
      previous = candidates.last;
      // The previous route is still painted while the incoming route enters.
      final hasNativeBackground = switch (route.settings) {
        NativeSnapshotBackground(nativeBackgroundToken: != null) => true,
        _ => false,
      };
      if (!hasNativeBackground) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _backgroundCapture = previous!.capture();
        });
      }
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _ancestorRoutes.clear();
    NavigatorState? navigator = route.navigator;
    while (navigator != null) {
      final ancestor = ModalRoute.of(navigator.context);
      if (ancestor != null) _ancestorRoutes.add(ancestor);
      navigator = navigator.context.findAncestorStateOfType<NavigatorState>();
    }
    _schedule();
  }

  @override
  void didUpdateWidget(_SnapshotRoute oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  void _status(AnimationStatus status) => _schedule();
  void _schedule() {
    // Covered nested routes must not intercept an ordinary system back either.
    canPopNotifier.value = _ancestorRoutes.every(
      (ancestor) => ancestor.isCurrent,
    );
    if (!_supported || _committing) return;
    if (!eligible) {
      _timer?.cancel();
      if (_SnapshotCoordinator.owner == this && _active != false) {
        _active = false;
        unawaited(_setActive(false));
      }
      return;
    }
    if (_ready && _SnapshotCoordinator.owner == this && _active != true) {
      _active = true;
      unawaited(_setActive(true));
    }
    final settings = route.settings;
    if (settings case NativeSnapshotBackground(:final nativeBackgroundToken?)) {
      if (!_ready && !_arming) unawaited(_arm(nativeBackgroundToken));
      return;
    }
    if (!_ready) {
      if (!_firstCaptureScheduled && !_preparing) {
        _firstCaptureScheduled = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _firstCaptureScheduled = false;
          if (mounted) unawaited(_prepare());
        });
      }
      return;
    }
    _timer?.cancel();
    _timer = Timer(
      const Duration(milliseconds: 180),
      () => unawaited(_prepare()),
    );
  }

  Future<void> _arm(int backgroundToken) async {
    _arming = true;
    generation = ++_SnapshotCoordinator.generation;
    _SnapshotCoordinator.owner = this;
    try {
      final accepted = await _SnapshotCoordinator.channel.invokeMethod<bool>(
        'arm',
        {'generation': generation, 'backgroundToken': backgroundToken},
      );
      if (!mounted || accepted != true) {
        await _SnapshotCoordinator.channel.invokeMethod<void>('clear', {
          'generation': generation,
        });
        return;
      }
      _ready = true;
      _nativeArmed = true;
      _active = eligible;
      if (!eligible) await _setActive(false);
    } on MissingPluginException {
      _supported = false;
    } finally {
      _arming = false;
    }
  }

  Future<void> _setActive(bool value) async {
    try {
      await _SnapshotCoordinator.channel.invokeMethod<void>('setActive', {
        'generation': generation,
        'eligible': value,
      });
    } on MissingPluginException {
      _supported = false;
    }
  }

  Future<void> _prepare() async {
    if (!eligible || _preparing || previous == null || _nativeArmed) return;
    _preparing = true;
    try {
      await _backgroundCapture;
      if (!mounted || !eligible || previous?.pixels == null) return;
      final entry = _SnapshotCoordinator.entries[route];
      final pixels = await entry?.capture();
      if (!mounted || !eligible || pixels == null) return;
      final box = entry!.key.currentContext!.findRenderObject()! as RenderBox;
      final position = box.localToGlobal(Offset.zero);
      final ratio = MediaQuery.devicePixelRatioOf(context);
      final refresh = _ready && _SnapshotCoordinator.owner == this;
      if (!refresh) {
        _ready = false;
        generation = ++_SnapshotCoordinator.generation;
        _SnapshotCoordinator.owner = this;
      }
      final result = await _SnapshotCoordinator.channel.invokeMethod<bool>(
        refresh ? 'refresh' : 'prepare',
        {
          'generation': generation,
          'foreground': pixels,
          'background': previous!.pixels,
          'x': position.dx * ratio,
          'y': position.dy * ratio,
          'width': box.size.width * ratio,
          'height': box.size.height * ratio,
        },
      );
      // A declined refresh leaves the installed pixels and commit token intact.
      if (refresh) return;
      if (!mounted || !eligible || result != true) {
        await _SnapshotCoordinator.channel.invokeMethod<void>('clear', {
          'generation': generation,
        });
        return;
      }
      _ready = true;
      _active = true;
      await _setActive(true);
    } on MissingPluginException {
      _supported = false;
    } on PlatformException catch (error) {
      debugPrint('Snapshot back unavailable: $error');
    } finally {
      _preparing = false;
    }
  }

  Future<bool> commit() async {
    if (!_ready || !eligible) return false;
    _committing = true;
    try {
      route.navigator!.pop();
      await route.completed;
      await WidgetsBinding.instance.endOfFrame;
      await _SnapshotCoordinator.channel.invokeMethod<void>('finish', {
        'generation': generation,
      });
      return true;
    } finally {
      _committing = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _SnapshotCoordinator.states.remove(this);
    route.unregisterPopEntry(this);
    canPopNotifier.dispose();
    route.animation?.removeStatusListener(_status);
    final entry = _SnapshotCoordinator.entries.remove(route);
    if (entry != null) {
      entry.disposed = true;
      entry.pixels = null;
    }
    if (_SnapshotCoordinator.owner == this) {
      _SnapshotCoordinator.owner = null;
      if (!_committing) {
        unawaited(
          _SnapshotCoordinator.channel
              .invokeMethod<void>('clear', {'generation': generation})
              .catchError((Object error) {
                if (error is! MissingPluginException) {
                  debugPrint('Snapshot back cleanup failed: $error');
                }
              }),
        );
      }
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    _schedule();
    return Listener(onPointerUp: (_) => _schedule(), child: widget.child);
  }
}
