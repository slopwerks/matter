import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:flutter/scheduler.dart' show Ticker;

import '../theme/neu_colors.dart';
import 'material_dock_lens.dart';

/// The floating platter the Material navigation sits on: a blurred, tinted
/// capsule instead of a full-bleed bar, with a soft iOS-style drop rather than
/// a Material elevation.
class DockSurface extends StatelessWidget {
  const DockSurface({
    super.key,
    this.radius = NeuRadius.nav,
    this.lift,
    required this.child,
  });

  final double radius;

  /// 0 at rest, 1 while pressed. Scaling the platter itself -- shadow, blur and
  /// all -- is what makes the bar read as pushed into something soft. Scaling
  /// only the content inside leaves the capsule its original size, which looks
  /// like the icons growing rather than the dock giving.
  final ValueListenable<double>? lift;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final surface = DecoratedBox(
      decoration: ShapeDecoration(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radius),
        ),
        shadows: _dockShadows(Theme.of(context).colorScheme),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
          // Blur first, tint second: the other order paints an opaque colour
          // over the backdrop filter and the blur never shows.
          child: ColoredBox(color: context.neu.glassFill, child: child),
        ),
      ),
    );
    final lift = this.lift;
    if (lift == null) return surface;
    return LayoutBuilder(
      builder: (context, constraints) {
        final growth = math.min(_pressGrowth, 16 / constraints.maxWidth);
        return AnimatedBuilder(
          animation: lift,
          builder: (context, child) =>
              Transform.scale(scale: 1 + lift.value * growth, child: child),
          child: surface,
        );
      },
    );
  }
}

/// A soft, wide drop in the manner of iOS rather than a Material elevation: a
/// bar this shallow reads as hovering only if the shadow spreads and stays
/// faint.
List<BoxShadow> _dockShadows(ColorScheme scheme) {
  final strength = scheme.brightness == Brightness.dark ? 3.0 : 1.0;
  return [
    BoxShadow(
      color: scheme.shadow.withValues(alpha: .08 * strength),
      blurRadius: 24,
      offset: const Offset(0, 8),
    ),
    BoxShadow(
      color: scheme.shadow.withValues(alpha: .04 * strength),
      blurRadius: 3,
      offset: const Offset(0, 1),
    ),
  ];
}

/// A value that springs toward a target the finger may move every frame.
///
/// [AnimationController.animateWith] restarts its ticker, whose first frame
/// reads no elapsed time, so retargeting it on every pointer move would hold
/// the value still for as long as the finger keeps moving.
class _Spring extends ChangeNotifier implements ValueListenable<double> {
  _Spring(TickerProvider vsync, this._value) {
    _ticker = vsync.createTicker(_tick);
  }

  late final Ticker _ticker;
  double _value;
  double _target = 0;
  SpringSimulation? _simulation;
  SpringDescription? _spring;
  double _now = 0;
  double _start = 0;

  @override
  double get value => _value;

  double get target => _simulation == null ? _value : _target;
  double get velocity => _simulation?.dx(_now - _start) ?? 0;
  bool get isAnimating => _simulation != null;

  void springTo(double target, SpringDescription spring) {
    if (target == this.target && (_simulation == null || _spring == spring)) {
      return;
    }
    // Retarget from the current velocity: restarting at zero on every pointer
    // event erases the inertia, particularly when the finger reverses.
    _simulation = SpringSimulation(spring, _value, target, velocity);
    _spring = spring;
    _target = target;
    if (_ticker.isActive) {
      _start = _now;
      return;
    }
    _now = _start = 0;
    _ticker.start();
  }

  void jumpTo(double value) {
    _simulation = null;
    _ticker.stop();
    _value = value;
    notifyListeners();
  }

  void _tick(Duration elapsed) {
    _now = elapsed.inMicroseconds / Duration.microsecondsPerSecond;
    final simulation = _simulation!;
    final time = _now - _start;
    if (simulation.isDone(time)) {
      _value = _target;
      _simulation = null;
      _ticker.stop();
    } else {
      _value = simulation.x(time);
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }
}

// A held lens has its own spring. At rest, page swipes drive its position
// directly so the page and selection remain aligned.
final _followSpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 1024,
  ratio: .9,
);
final _travelSpring = SpringDescription.withDurationAndBounce(
  duration: const Duration(milliseconds: 240),
  bounce: .15,
);
final _liftSpring = SpringDescription.withDurationAndBounce(
  duration: const Duration(milliseconds: 250),
);

/// Underdamped and stiff: the jelly has to be visible within a frame or two of
/// the lens moving, and still overshoot when it stops. A soft spring here
/// trails the finger so far behind that the stretch never shows.
final _jellySpring = SpringDescription.withDampingRatio(
  mass: 1,
  stiffness: 900,
  ratio: 0.35,
);

const double _barHeight = 62;
const double _barPadding = 4;
const double _iconSize = 26;
const double _labelGap = 2;
const double _labelSize = 10;
const double _lensGrowth = 8;
const double _lensMagnify = .16;

/// The platter grows on press, capped at 16 logical pixels by DockSurface so
/// a wide dock keeps both end caps inside the screen.
const double _pressGrowth = 1 / 12;

/// Speed turns into horizontal stretch and vertical squash, so the lens reads
/// as jelly rather than as a box sliding on rails.
const double _jellyStretch = .2;
const double _jellySquash = .15;
const double _jellyAspect = 1.4;
const double _jellySpeed = 3;
const double _jellyBrake = 25;

/// Maps an unbounded input into 0..1 without a hard knee.
double _saturate(double value) => 1 - 2 / (math.exp(2 * value) + 1);

/// The bar's height grows with the label, so enlarged text never overflows:
/// the bar keeps its resting height plus however much the label grew by.
/// `NavigationBar` did this for us before the dock took over its layout.
double _barHeightOf(BuildContext context) {
  final scaled = MediaQuery.textScalerOf(context).scale(_labelSize);
  return _barHeight + scaled - _labelSize;
}

/// The lens's box, measured from the start edge of the destination at 0.
/// It overhangs its destination by [_barPadding] on each side, so a resting
/// lens covers the no-man's land between two icons.
Rect _lensRect({
  required double pitch,
  required double index,
  required double height,
  required double lift,
  required double stretch,
}) {
  final growth = _lensGrowth * lift;
  // Stretch widens and squashes at once: equal scaling would just look bigger.
  final width = (pitch + _barPadding * 2 + growth) * (1 + stretch);
  // The lens fills the bar's usable height and may grow outwards, but never
  // past the bar's own edges: anything beyond them is clipped away and reads
  // as the highlight bleeding through the corner.
  final lensHeight = math.min(
    (height - _barPadding * 2) *
        (1 + growth / height) *
        (1 - stretch * _jellyAspect),
    height,
  );
  return Rect.fromLTWH(
    (index + .5) * pitch - width / 2,
    (height - lensHeight) / 2,
    width,
    lensHeight,
  );
}

/// A floating pill of destinations whose selection is a lens that springs
/// between them, after iOS's tab bar. The destination inside the lens is
/// magnified and tinted, so the selection is carried by the icon and label
/// rather than by a block drawn behind them.
class MaterialTabNavigationBar extends StatefulWidget {
  const MaterialTabNavigationBar({
    super.key,
    required this.position,
    required this.selectedIndex,
    required this.onDestinationSelected,
    required this.destinations,
    this.lift,
  });

  /// Continuous page position, so a drag or a swipe moves the lens with the
  /// pages rather than jumping when the selection changes.
  final ValueNotifier<double> position;
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;
  final List<NavigationDestination> destinations;

  /// Mirrors the press (0 at rest, 1 held) so the platter this bar sits on can
  /// scale with it. The platter is above this widget, so the value has to be
  /// published outwards; scaling inside here would only grow the contents.
  final ValueNotifier<double>? lift;

  @override
  State<MaterialTabNavigationBar> createState() =>
      _MaterialTabNavigationBarState();
}

class _MaterialTabNavigationBarState extends State<MaterialTabNavigationBar>
    with TickerProviderStateMixin {
  /// 0 at rest, 1 while a finger is down: grows and deepens the lens, and
  /// magnifies the destination under the finger in place.
  late final _Spring _lift = _Spring(this, 0);

  /// Horizontal stretch and vertical squash of the lens: the jelly. Driven by
  /// the lens's own speed, so it stretches while travelling and snaps back as
  /// it brakes.
  late final _Spring _jelly = _Spring(this, 0);
  late final _Spring _lens = _Spring(this, widget.position.value);

  /// Pointer motion owns the lens until it and the selected page have settled.
  /// Page animation must not pull it back to a page the finger already left.
  bool _followingPage = true;
  int? _pressedIndex;
  int? _pointer;
  int? _dispatchedIndex;
  double _pressX = 0;
  bool _dragging = false;

  double _lastPosition = 0;
  double _lastSpeed = 0;

  @override
  void initState() {
    super.initState();
    _lastPosition = widget.position.value;
    widget.position.addListener(_syncPage);
    _lens.addListener(_wobble);
    _lift.addListener(_publishLift);
  }

  void _publishLift() {
    final lift = widget.lift;
    if (lift != null) lift.value = _lift.value;
  }

  @override
  void didUpdateWidget(MaterialTabNavigationBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.position != widget.position) {
      oldWidget.position.removeListener(_syncPage);
      widget.position.addListener(_syncPage);
    }
    if (_pointer == null) {
      if (!_followingPage && oldWidget.selectedIndex != widget.selectedIndex) {
        _lens.springTo(widget.selectedIndex.toDouble(), _travelSpring);
      }
      _syncPage();
    }
  }

  @override
  void dispose() {
    widget.position.removeListener(_syncPage);
    _lens.removeListener(_wobble);
    _lift.removeListener(_publishLift);
    _lens.dispose();
    _lift.dispose();
    _jelly.dispose();
    super.dispose();
  }

  bool get _canFollowPage =>
      _pointer == null &&
      !_lens.isAnimating &&
      (widget.position.value - widget.selectedIndex).abs() < .001 &&
      (_lens.value - widget.position.value).abs() < .001;

  void _syncPage() {
    if (_pointer != null) return;
    if (!_followingPage && _canFollowPage) _followingPage = true;
    if (_followingPage) _lens.jumpTo(widget.position.value);
  }

  /// Stretch follows actual lens motion, including inertia after the pointer
  /// stops; it relaxes to zero when the lens finishes its spring.
  void _wobble() {
    final position = _lens.value;
    final speed = _lens.isAnimating
        ? _lens.velocity.abs() / 60
        : _followingPage
        ? (position - _lastPosition).abs()
        : 0.0;
    _lastPosition = position;
    final reach = _saturate(speed * _jellySpeed);
    final braking = speed < _lastSpeed ? _lastSpeed - speed : 0.0;
    _lastSpeed = speed;
    final brake = _saturate(braking * _jellyBrake);
    final settled =
        !_lens.isAnimating &&
        (!_followingPage || (position - position.round()).abs() < .001);
    final target = speed == 0 || settled
        ? 0.0
        : _jellyStretch * reach - _jellySquash * brake;
    _jelly.springTo(target, _jellySpring);
    if (!_followingPage && _canFollowPage) _followingPage = true;
  }

  void _setPressed(int? index) {
    if (index == _pressedIndex) return;
    setState(() => _pressedIndex = index);
    _lift.springTo(index == null ? 0 : 1, _liftSpring);
  }

  double _positionAt(Offset local, double pitch, TextDirection direction) {
    final last = widget.destinations.length - 1;
    final visual = ((local.dx - _barPadding) / pitch - .5).clamp(
      0.0,
      last.toDouble(),
    );
    return direction == TextDirection.ltr ? visual : last - visual;
  }

  void _press(PointerDownEvent event, double pitch, TextDirection direction) {
    if (_pointer != null || event.buttons & kPrimaryButton == 0) return;
    _pointer = event.pointer;
    _pressX = event.localPosition.dx;
    _dragging = false;
    final index = _positionAt(event.localPosition, pitch, direction).round();
    _followingPage = false;
    _dispatchedIndex = widget.selectedIndex;
    _setPressed(index);
    _lens.springTo(index.toDouble(), _travelSpring);
  }

  void _slide(PointerEvent event, double pitch, TextDirection direction) {
    if (event.pointer != _pointer) return;
    if (!_dragging && (event.localPosition.dx - _pressX).abs() < kTouchSlop) {
      return;
    }
    _dragging = true;
    final position = _positionAt(event.localPosition, pitch, direction);
    _pressedIndex = position.round();
    _lens.springTo(position, _followSpring);
    _select(_pressedIndex!);
  }

  void _select(int index) {
    if (index == _dispatchedIndex) return;
    _dispatchedIndex = index;
    widget.onDestinationSelected(index);
  }

  void _release(PointerEvent event, double pitch, TextDirection direction) {
    if (event.pointer != _pointer) return;
    if (event is PointerUpEvent) _slide(event, pitch, direction);
    final index = _pressedIndex;
    final target = event is PointerUpEvent && index != null
        ? index
        : widget.selectedIndex;
    _pointer = null;
    _dragging = false;
    _setPressed(null);
    _lens.springTo(target.toDouble(), _travelSpring);
    if (event is PointerUpEvent && index != null) _select(index);
    _syncPage();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final count = widget.destinations.length;
    final text = Theme.of(context).textTheme;
    final direction = Directionality.of(context);

    return LayoutBuilder(
      builder: (context, constraints) {
        final height = _barHeightOf(context);
        final span = constraints.maxWidth - _barPadding * 2;
        final pitch = span / count;
        return SizedBox(
          height: height,
          // The dock sits outside the page's gesture area. One pointer owns
          // the whole bar, so crossing items never cancels the selection.
          child: Listener(
            behavior: HitTestBehavior.opaque,
            onPointerDown: (event) => _press(event, pitch, direction),
            onPointerMove: (event) => _slide(event, pitch, direction),
            onPointerUp: (event) => _release(event, pitch, direction),
            onPointerCancel: (event) => _release(event, pitch, direction),
            child: RepaintBoundary(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(height / 2),
                child: AnimatedBuilder(
                  animation: Listenable.merge([_lens, _lift, _jelly]),
                  builder: (context, _) {
                    final lift = _lift.value;
                    final index = _lens.value;
                    final rect = _lensRect(
                      pitch: pitch,
                      index: direction == TextDirection.ltr
                          ? index
                          : count - 1 - index,
                      height: height,
                      lift: lift,
                      stretch: _jelly.value,
                    ).translate(_barPadding, 0);
                    final lens = RRect.fromRectAndRadius(
                      rect,
                      Radius.circular(rect.height / 2),
                    );
                    // Both destination passes and the background share the
                    // same lens, including its current jelly shape.
                    return Stack(
                      children: [
                        Positioned.fill(
                          child: IgnorePointer(
                            child: CustomPaint(
                              painter: _LensPainter(
                                rect: rect,
                                color: scheme.primary.withValues(
                                  alpha: .14 + .1 * lift,
                                ),
                              ),
                            ),
                          ),
                        ),
                        Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _barPadding,
                          ),
                          child: Row(
                            children: [
                              for (var index = 0; index < count; index++)
                                Expanded(
                                  child: _DockItem(
                                    destination: widget.destinations[index],
                                    selected: index == widget.selectedIndex,
                                    lens: lens.shift(
                                      Offset(
                                        -_barPadding -
                                            (direction == TextDirection.ltr
                                                    ? index
                                                    : count - 1 - index) *
                                                pitch,
                                        0,
                                      ),
                                    ),
                                    magnification: 1 + _lensMagnify * lift,
                                    labelStyle: text.labelSmall,
                                    scheme: scheme,
                                    onTap: () =>
                                        widget.onDestinationSelected(index),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DockItem extends StatelessWidget {
  const _DockItem({
    required this.destination,
    required this.selected,
    required this.lens,
    required this.magnification,
    required this.labelStyle,
    required this.scheme,
    required this.onTap,
  });

  final NavigationDestination destination;
  final bool selected;
  final RRect lens;
  final double magnification;
  final TextStyle? labelStyle;
  final ColorScheme scheme;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    container: true,
    button: true,
    selected: selected,
    label: destination.label,
    onTap: onTap,
    child: DockLensContents(
      lens: lens,
      color: scheme.primary,
      magnification: magnification,
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconTheme.merge(
              data: IconThemeData(
                size: _iconSize,
                color: scheme.onSurfaceVariant,
              ),
              // Both passes paint the same glyph. Only the covered pixels
              // change colour, without swapping the entire icon mid-drag.
              child: destination.selectedIcon ?? destination.icon,
            ),
            const SizedBox(height: _labelGap),
            Text(
              destination.label,
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.ellipsis,
              style: labelStyle?.copyWith(
                fontSize: _labelSize,
                fontWeight: FontWeight.w500,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _LensPainter extends CustomPainter {
  _LensPainter({required this.rect, required this.color});

  final Rect rect;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, Radius.circular(rect.height / 2)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_LensPainter oldDelegate) =>
      oldDelegate.rect != rect || oldDelegate.color != color;
}
