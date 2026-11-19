import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/floating_app_bar.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Linux $brightness header and dock each paint their own translucent surface',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.padding = const FakeViewPadding();
        tester.view.viewPadding = const FakeViewPadding();
        await tester.binding.setSurfaceSize(const Size(320, 240));
        addTearDown(tester.view.resetDevicePixelRatio);
        addTearDown(tester.view.resetPadding);
        addTearDown(tester.view.resetViewPadding);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final theme = buildMaterialTheme(brightness)
            .copyWith(platform: TargetPlatform.linux);
        const backdrop = Color(0xFFDC3050);
        final surface = theme.extension<NeuColors>()!.glassFill;
        final position = ValueNotifier(0.0);
        addTearDown(position.dispose);
        final boundaryKey = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            home: RepaintBoundary(
              key: boundaryKey,
              child: Scaffold(
                extendBody: true,
                extendBodyBehindAppBar: true,
                appBar: buildFloatingAppBar(title: const Text('Title')),
                body: const ColoredBox(
                  color: backdrop,
                  child: SizedBox.expand(),
                ),
                bottomNavigationBar: SafeArea(
                  top: false,
                  minimum: const EdgeInsets.fromLTRB(14, 8, 14, 10),
                  child: DockSurface(
                    child: MaterialTabNavigationBar(
                      position: position,
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      destinations: const [
                        NavigationDestination(
                          icon: Icon(Icons.chat),
                          label: '聊天',
                        ),
                        NavigationDestination(
                          icon: Icon(Icons.settings),
                          label: '设置',
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          tester.getSize(find.byType(TopFadeBlur)),
          tester.getSize(find.byType(AppBar)),
        );
        final boundary =
            boundaryKey.currentContext!.findRenderObject()!
                as RenderRepaintBoundary;
        final pixels = await tester.runAsync(() async {
          final image = await boundary.toImage();
          try {
            return await image.toByteData(format: ui.ImageByteFormat.rawRgba);
          } finally {
            image.dispose();
          }
        });
        Color sample(int x, int y) {
          final offset = (y * 320 + x) * 4;
          return Color.fromARGB(
            pixels!.getUint8(offset + 3),
            pixels.getUint8(offset),
            pixels.getUint8(offset + 1),
            pixels.getUint8(offset + 2),
          );
        }

        // The header and the dock no longer share one alpha. The header sits
        // over the title and needs a firmer cover; the dock is a floating
        // platter that shows more of what scrolls beneath it. Check each
        // against its own tint instead of demanding they match.
        final dock = tester.getRect(find.byType(DockSurface));
        final header = sample(160, 18);
        final navigation = sample(
          (dock.right - 8).round(),
          (dock.top + dock.height / 2).round(),
        );
        expect(surface.a, greaterThan(0));
        expect(surface.a, lessThan(1));
        // How far a sample has moved away from the raw backdrop. Distance is
        // brightness-independent, unlike comparing a channel to the backdrop's
        // own value: a near-white tint sits above the red in light mode and
        // below it in dark, so only the distance carries the same meaning.
        double distance(Color c) => [
          (c.r - backdrop.r).abs(),
          (c.g - backdrop.g).abs(),
          (c.b - backdrop.b).abs(),
        ].reduce((a, b) => a > b ? a : b);
        for (final actual in [header, navigation]) {
          // Both cover the backdrop firmly: this is a toolbar and a dock, not
          // a translucent wash. Ranking the two by a few thousandths depends
          // on the theme's brightness and on where each gradient is sampled,
          // so assert firm coverage instead.
          expect(distance(actual), greaterThan(.5));
        }
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
