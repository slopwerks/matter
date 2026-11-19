import 'dart:ui' show ImageByteFormat, SemanticsAction;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';

const _labels = ['Chats', 'Spaces', 'Contacts', 'Settings'];

Future<void> _pumpDock(
  WidgetTester tester,
  List<int> selections, {
  TextDirection direction = TextDirection.ltr,
  Brightness brightness = Brightness.light,
  bool pixelGlyphs = false,
}) async {
  final position = ValueNotifier(0.0);
  addTearDown(position.dispose);
  var selected = 0;
  await tester.pumpWidget(
    MaterialApp(
      theme: buildMaterialTheme(brightness),
      home: Directionality(
        textDirection: direction,
        child: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: const ValueKey('dock-pixels'),
              child: SizedBox(
                width: 360,
                child: StatefulBuilder(
                  builder: (context, setState) => MaterialTabNavigationBar(
                    position: position,
                    selectedIndex: selected,
                    onDestinationSelected: (index) {
                      selections.add(index);
                      setState(() => selected = index);
                      position.value = index.toDouble();
                    },
                    destinations: [
                      for (var index = 0; index < _labels.length; index++)
                        NavigationDestination(
                          icon: pixelGlyphs
                              ? Builder(
                                  builder: (context) => ColoredBox(
                                    key: ValueKey('glyph-$index'),
                                    color: IconTheme.of(context).color!,
                                    child: const SizedBox(
                                      width: 26,
                                      height: 26,
                                    ),
                                  ),
                                )
                              : const Icon(Icons.circle),
                          label: _labels[index],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox()));
}

Offset _itemCenter(WidgetTester tester, int index) {
  final label = tester.getCenter(find.text(_labels[index]));
  final dock = tester.getRect(find.byType(MaterialTabNavigationBar));
  return Offset(label.dx, dock.center.dy);
}

RRect _lensRectOf(WidgetTester tester) {
  final finder = find.descendant(
    of: find.byType(MaterialTabNavigationBar),
    matching: find.byType(CustomPaint),
  );
  final canvas = _LensCanvas();
  tester
      .widget<CustomPaint>(finder)
      .painter!
      .paint(canvas, tester.getSize(finder));
  return canvas.rect!.shift(tester.getTopLeft(finder));
}

Offset _lensCenter(WidgetTester tester) => _lensRectOf(tester).center;

class _LensCanvas implements Canvas {
  RRect? rect;

  @override
  void drawRRect(RRect rrect, Paint paint) => rect = rrect;

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  for (final direction in TextDirection.values) {
    testWidgets(
      'hold and slide selects destinations before release in $direction',
      (tester) async {
        final selections = <int>[];
        await _pumpDock(tester, selections, direction: direction);
        final start = _itemCenter(tester, 0);
        final next = _itemCenter(tester, 1);
        final destination = _itemCenter(tester, 3);
        final gesture = await tester.startGesture(start);
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        final midway = Offset.lerp(start, next, .4)!;
        await gesture.moveTo(midway);
        await tester.pumpAndSettle();
        expect(_lensCenter(tester).dx, closeTo(midway.dx, 1));
        expect(selections, isEmpty);
        await gesture.moveTo(destination);
        await tester.pumpAndSettle();
        expect(_lensCenter(tester).dx, closeTo(destination.dx, 1));
        expect(selections, [3]);
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selections, [3]);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'a slide selects on crossing, reverses and does not repeat on up',
    (tester) async {
      final selections = <int>[];
      await _pumpDock(tester, selections);
      final gesture = await tester.startGesture(_itemCenter(tester, 0));
      await gesture.moveTo(_itemCenter(tester, 3));
      await tester.pumpAndSettle();
      await gesture.moveTo(_itemCenter(tester, 1));
      await tester.pumpAndSettle();
      expect(selections, [3, 1]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(selections, [3, 1]);
    },
  );

  testWidgets('cancelling keeps the page reached while dragging', (
    tester,
  ) async {
    final selections = <int>[];
    await _pumpDock(tester, selections);
    final origin = _itemCenter(tester, 0);
    final destination = _itemCenter(tester, 3);
    final gesture = await tester.startGesture(origin);
    await gesture.moveTo(destination);
    await tester.pumpAndSettle();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selections, [3]);
    expect(_lensCenter(tester).dx, closeTo(destination.dx, 1));
  });

  testWidgets(
    'sliding past the bar clamps to its first and last destinations',
    (tester) async {
      final selections = <int>[];
      await _pumpDock(tester, selections);
      final dock = tester.getRect(find.byType(MaterialTabNavigationBar));
      for (final (x, expected) in [
        (dock.right + 100, 3),
        (dock.left - 100, 0),
      ]) {
        final gesture = await tester.startGesture(_itemCenter(tester, 1));
        await gesture.moveTo(Offset(x, dock.center.dy));
        await tester.pumpAndSettle();
        await gesture.up();
        await tester.pumpAndSettle();
        expect(selections.last, expected);
      }
    },
  );

  testWidgets('a second pointer cannot take over or release the first press', (
    tester,
  ) async {
    final selections = <int>[];
    await _pumpDock(tester, selections);
    final first = await tester.startGesture(_itemCenter(tester, 0), pointer: 1);
    final second = await tester.startGesture(
      _itemCenter(tester, 2),
      pointer: 2,
    );
    await second.up();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    await first.moveTo(_itemCenter(tester, 3));
    await first.up();
    await tester.pumpAndSettle();
    expect(selections, [3]);
  });

  testWidgets('taps still select, and secondary mouse buttons do not', (
    tester,
  ) async {
    final selections = <int>[];
    await _pumpDock(tester, selections);
    await tester.tapAt(_itemCenter(tester, 2));
    await tester.pumpAndSettle();
    expect(selections, [2]);
    final mouse = await tester.startGesture(
      _itemCenter(tester, 3),
      kind: PointerDeviceKind.mouse,
      buttons: kSecondaryMouseButton,
    );
    await mouse.up();
    await tester.pumpAndSettle();
    expect(selections, [2]);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
      'only glyph pixels covered by the lens are tinted in $brightness',
      (tester) async {
        final selections = <int>[];
        await _pumpDock(
          tester,
          selections,
          brightness: brightness,
          pixelGlyphs: true,
        );
        final start = _itemCenter(tester, 0);
        final next = _itemCenter(tester, 1);
        final gesture = await tester.startGesture(start);
        await tester.pumpAndSettle();
        await gesture.moveTo(Offset.lerp(start, next, .65)!);
        await tester.pumpAndSettle();
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('dock-pixels')),
        );
        final captured = await tester.runAsync(() async {
          final image = await boundary.toImage();
          final bytes = (await image.toByteData(
            format: ImageByteFormat.rawRgba,
          ))!;
          final width = image.width;
          image.dispose();
          return (bytes: bytes, width: width);
        });
        final bytes = captured!.bytes;
        final glyph = tester.getRect(find.byKey(const ValueKey('glyph-0')));
        final origin = tester.getTopLeft(
          find.byKey(const ValueKey('dock-pixels')),
        );
        Color pixel(Offset global) {
          final local = global - origin;
          final offset =
              (local.dy.floor() * captured.width + local.dx.floor()) * 4;
          return Color.fromARGB(
            bytes.getUint8(offset + 3),
            bytes.getUint8(offset),
            bytes.getUint8(offset + 1),
            bytes.getUint8(offset + 2),
          );
        }

        final scheme = Theme.of(
          tester.element(find.byType(MaterialTabNavigationBar)),
        ).colorScheme;
        expect(
          pixel(Offset(glyph.left + 2, glyph.center.dy)).toARGB32(),
          scheme.onSurfaceVariant.toARGB32(),
        );
        expect(
          pixel(Offset(glyph.right - 2, glyph.center.dy)).toARGB32(),
          scheme.primary.toARGB32(),
        );
        await gesture.cancel();
        await tester.pumpAndSettle();
      },
    );
  }

  testWidgets(
    'continuous moves retain inertia, stretch and settle on release',
    (tester) async {
      final selections = <int>[];
      await _pumpDock(tester, selections);
      final start = _itemCenter(tester, 0);
      final destination = _itemCenter(tester, 3);
      final gesture = await tester.startGesture(start);
      await tester.pumpAndSettle();
      final resting = _lensRectOf(tester);
      var widest = resting.width;
      var shortest = resting.height;
      for (var frame = 1; frame <= 16; frame++) {
        await gesture.moveTo(Offset.lerp(start, destination, frame / 16)!);
        await tester.pump(const Duration(milliseconds: 16));
        final rect = _lensRectOf(tester);
        if (rect.width > widest) widest = rect.width;
        if (rect.height < shortest) shortest = rect.height;
      }
      final travelling = _lensCenter(tester).dx;
      expect(travelling, greaterThan(_itemCenter(tester, 2).dx));
      expect(travelling, lessThan(destination.dx));
      expect(widest, greaterThan(resting.width * 1.04));
      expect(shortest, lessThan(resting.height * .96));
      expect(selections, [1, 2, 3]);

      // Reversing the target cannot teleport the lens or discard its momentum.
      await gesture.moveTo(start);
      await tester.pump();
      expect(_lensCenter(tester).dx, closeTo(travelling, .1));
      await tester.pump(const Duration(milliseconds: 16));
      expect(_lensCenter(tester).dx, greaterThan(start.dx));
      await tester.pumpAndSettle();
      expect(_lensCenter(tester).dx, closeTo(start.dx, .1));
      expect(_lensRectOf(tester).width, closeTo(resting.width, .1));
      expect(_lensRectOf(tester).height, closeTo(resting.height, .1));

      // A fractional release snaps to the selected item without repainting at
      // the old page first; the following page swipe still owns an idle lens.
      await gesture.moveTo(Offset.lerp(start, _itemCenter(tester, 1), .7)!);
      await tester.pumpAndSettle();
      final beforeUp = _lensCenter(tester).dx;
      await gesture.up();
      await tester.pump();
      expect(_lensCenter(tester).dx, closeTo(beforeUp, .1));
      await tester.pumpAndSettle();
      expect(_lensCenter(tester).dx, closeTo(_itemCenter(tester, 1).dx, .1));
      expect(selections, [1, 2, 3, 0, 1]);
    },
  );

  testWidgets(
    'tapping the current item still hands the idle lens to page swipes',
    (tester) async {
      final selections = <int>[];
      await _pumpDock(tester, selections);
      final start = _itemCenter(tester, 0);
      final next = _itemCenter(tester, 1);
      await tester.tapAt(start);
      await tester.pumpAndSettle();
      final position = tester
          .widget<MaterialTabNavigationBar>(
            find.byType(MaterialTabNavigationBar),
          )
          .position;
      position.value = .4;
      await tester.pump();
      expect(
        _lensCenter(tester).dx,
        closeTo(Offset.lerp(start, next, .4)!.dx, .1),
      );
      position.value = 0;
      await tester.pumpAndSettle();
      expect(_lensCenter(tester).dx, closeTo(start.dx, .1));
      expect(selections, isEmpty);
    },
  );

  testWidgets('cancelling an unmoved press does not change pages', (
    tester,
  ) async {
    final selections = <int>[];
    await _pumpDock(tester, selections);
    final gesture = await tester.startGesture(_itemCenter(tester, 3));
    await tester.pumpAndSettle();
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(selections, isEmpty);
    expect(_lensCenter(tester).dx, closeTo(_itemCenter(tester, 0).dx, .1));
  });

  for (final width in [320.0, 390.0]) {
    testWidgets('the pressed platter keeps both end caps on screen at $width', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(Size(width, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final lift = ValueNotifier(1.0);
      addTearDown(lift.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            bottomNavigationBar: Padding(
              padding: const EdgeInsets.all(14),
              child: DockSurface(
                lift: lift,
                child: const SizedBox(
                  key: ValueKey('platter-bounds'),
                  height: 62,
                ),
              ),
            ),
          ),
        ),
      );
      final pressed = tester.getRect(
        find.byKey(const ValueKey('platter-bounds')),
      );
      expect(pressed.width, greaterThan(width - 28));
      expect(pressed.left, greaterThanOrEqualTo(4));
      expect(pressed.right, lessThanOrEqualTo(width - 4));
      await tester.pumpWidget(const SizedBox());
    });
  }

  testWidgets('screen reader activation still selects its destination', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    try {
      final selections = <int>[];
      await _pumpDock(tester, selections);
      final node = tester.getSemantics(find.text('Settings'));
      final owner = tester
          .renderObject(find.byType(MaterialTabNavigationBar))
          .owner!;
      owner.semanticsOwner!.performAction(node.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(selections, [3]);
    } finally {
      semantics.dispose();
    }
  });
}
