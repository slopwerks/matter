import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/floating_app_bar.dart';
import 'package:matter/widgets/glass.dart';
import 'package:matter/widgets/material_adaptive_shell.dart';
import 'package:matter/widgets/material_root_header.dart';
import 'package:matter/widgets/material_search_header.dart';

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'Linux $brightness header and native dock paint opaque theme surfaces',
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
                  minimum: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(28),
                    child: NavigationBar(
                      selectedIndex: 0,
                      onDestinationSelected: (_) {},
                      labelBehavior:
                          NavigationDestinationLabelBehavior.alwaysHide,
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
        expect(find.byType(TopFadeBlur), findsNothing);
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

        final dock = tester.getRect(find.byType(NavigationBar));
        expect(dock.height, 56);
        expect(dock.left, 16);
        expect(sample(160, 18), theme.appBarTheme.backgroundColor);
        expect(
          sample((dock.right - 8).round(), dock.center.dy.round()),
          theme.navigationBarTheme.backgroundColor,
        );
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'compact root header clips decoration strictly to bottom corners',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(top: 24);
      tester.view.viewPadding = const FakeViewPadding(top: 24);
      await tester.binding.setSurfaceSize(const Size(360, 220));
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPadding);
      addTearDown(tester.view.resetViewPadding);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final scheme = applyMaterialBackground(
        materialColorScheme(brightness: Brightness.dark),
        MaterialBackground.pure,
      );
      final theme = buildMaterialTheme(Brightness.dark, colorScheme: scheme);
      final boundaryKey = GlobalKey();

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: RepaintBoundary(
            key: boundaryKey,
            child: ColoredBox(
              color: theme.colorScheme.surface,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  MaterialRootHeader(
                    title: 'Chat',
                    compact: true,
                    search: const SearchBar(hintText: 'Search'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

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
        final offset = (y * 360 + x) * 4;
        return Color.fromARGB(
          pixels!.getUint8(offset + 3),
          pixels.getUint8(offset),
          pixels.getUint8(offset + 1),
          pixels.getUint8(offset + 2),
        );
      }

      final headerRect = tester.getRect(find.byType(MaterialRootHeader));
      expect(headerRect.height, 24 + 56 + 68);
      final cornerY = headerRect.bottom.round() - 2;
      expect(sample(2, cornerY), Colors.black);
      expect(sample(357, cornerY), Colors.black);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'MaterialSearchHeader collapse keeps root header profile state alive',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final theme = buildMaterialTheme(Brightness.dark);
      final position = ValueNotifier(0.0);
      addTearDown(position.dispose);
      var collapsed = false;
      late StateSetter updateState;

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: MaterialAdaptiveShell(
            window: MaterialWindowClass.compact,
            index: 0,
            onNavigate: (_) {},
            position: position,
            unreadCount: 0,
            chatOpen: false,
            profile: const IconButton(onPressed: null, icon: _StateMarker()),
            railAccount: const SizedBox.shrink(),
            railActions: (_) => const SizedBox.shrink(),
            railSpaces: const SizedBox.shrink(),
            pages: [
              StatefulBuilder(
                builder: (context, setState) {
                  updateState = setState;
                  return Scaffold(
                    body: MaterialSearchHeader(
                      title: '聊天',
                      collapsed: collapsed,
                      searchLabel: '搜索',
                      search: const SearchBar(hintText: '搜索'),
                      onSearch: () {},
                    ),
                  );
                },
              ),
              const SizedBox.shrink(),
              const SizedBox.shrink(),
              const SizedBox.shrink(),
            ],
          ),
        ),
      );
      await tester.pumpAndSettle();

      final initialState = tester.state<_StateMarkerState>(
        find.byType(_StateMarker),
      );
      updateState(() => collapsed = true);
      await tester.pumpAndSettle();
      expect(
        tester.state<_StateMarkerState>(find.byType(_StateMarker)),
        same(initialState),
      );

      updateState(() => collapsed = false);
      await tester.pumpAndSettle();
      expect(
        tester.state<_StateMarkerState>(find.byType(_StateMarker)),
        same(initialState),
      );
    },
  );
}

class _StateMarker extends StatefulWidget {
  const _StateMarker();
  @override
  State<_StateMarker> createState() => _StateMarkerState();
}

class _StateMarkerState extends State<_StateMarker> {
  @override
  Widget build(BuildContext context) => const SizedBox.square(dimension: 28);
}
