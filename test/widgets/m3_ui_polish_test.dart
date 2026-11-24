import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/material_unread_pill.dart';
import 'package:matter/pages/chat/space_detail_page.dart';
import 'package:matter/pages/settings/material_color_settings_page.dart';
import 'package:matter/pages/settings/settings_profile_card.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/material_color_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/app_component_theme.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/floating_app_bar.dart';
import 'package:matter/widgets/material_dock_lens.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _TestRustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

void main() {
  setUpAll(() => RustLib.initMock(api: _TestRustApi()));
  tearDownAll(RustLib.dispose);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('MaterialUnreadPill spinner uses onPrimary inside FilledButton', (
    tester,
  ) async {
    final theme = buildMaterialTheme(Brightness.dark);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        home: Scaffold(
          body: MaterialUnreadPill(
            label: '3 条新消息',
            onJump: () {},
            onMarkRead: () {},
            below: true,
            loading: true,
            failed: false,
          ),
        ),
      ),
    );
    final spinner = tester.widget<CircularProgressIndicator>(
      find.byType(CircularProgressIndicator),
    );
    expect(spinner.color, theme.colorScheme.onPrimary);
  });

  testWidgets('DockSurface and MaterialColorSettings toggle dock blur', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final theme = buildMaterialTheme(Brightness.light);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: Consumer(
            builder: (context, ref, _) {
              final blurEnabled = ref.watch(
                materialColorSettingsProvider.select((s) => s.dockBlurEnabled),
              );
              return Scaffold(
                bottomNavigationBar: DockSurface(
                  blurEnabled: blurEnabled,
                  child: const SizedBox(height: 62),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsOneWidget);
    final blurredTint = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(DockSurface),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(blurredTint.color.a, lessThan(1));

    await container
        .read(materialColorSettingsProvider.notifier)
        .setDockBlurEnabled(false);
    await tester.pumpAndSettle();
    expect(find.byType(BackdropFilter), findsNothing);
    final solidTint = tester.widget<ColoredBox>(
      find.descendant(
        of: find.byType(DockSurface),
        matching: find.byType(ColoredBox),
      ),
    );
    expect(solidTint.color, theme.colorScheme.surfaceContainer);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: theme,
          home: const MaterialColorSettingsPage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final toggle = find.byKey(const ValueKey('material-dock-blur-switch'));
    await tester.scrollUntilVisible(toggle, 200);
    expect(tester.widget<SwitchListTile>(toggle).value, isFalse);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(
      container.read(materialColorSettingsProvider).dockBlurEnabled,
      isTrue,
    );
  });

  testWidgets(
    'MaterialTabNavigationBar paints unread Badge outside lens tint',
    (tester) async {
      final position = ValueNotifier(0.0);
      addTearDown(position.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: Scaffold(
            bottomNavigationBar: MaterialTabNavigationBar(
              position: position,
              selectedIndex: 0,
              onDestinationSelected: (_) {},
              badges: const {0: 12},
              destinations: const [
                NavigationDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: '聊天',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_outlined),
                  selectedIcon: Icon(Icons.settings),
                  label: '设置',
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('12'), findsOneWidget);
      expect(
        find.ancestor(
          of: find.byType(Badge),
          matching: find.byType(DockLensContents),
        ),
        findsNothing,
      );
    },
  );

  testWidgets('SettingsProfileCard InkWell paints directly on Card Material', (
    tester,
  ) async {
    var tapped = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: SettingsProfileCard(
            user: const CurrentUser(
              id: '@alice:example.org',
              displayName: 'Alice',
              homeserver: 'https://example.org',
            ),
            onTap: () => tapped++,
          ),
        ),
      ),
    );
    final inkWell = find.descendant(
      of: find.byType(SettingsProfileCard),
      matching: find.byType(InkWell),
    );
    expect(
      find.ancestor(of: inkWell, matching: find.byType(Card)),
      findsOneWidget,
    );
    await tester.tap(inkWell);
    expect(tapped, 1);
  });

  testWidgets(
    'buildFloatingAppBar styles implied BackButton with MaterialToolbar',
    (tester) async {
      final theme = buildMaterialTheme(Brightness.light);
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          navigatorKey: navigator,
          home: const SizedBox(),
        ),
      );
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            appBar: buildFloatingAppBar(title: const Text('子页面')),
            body: const SizedBox(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final back = tester.element(find.byType(BackButton));
      expect(
        IconButtonTheme.of(back).style,
        AppComponentTheme.of(back).toolbarStyle,
      );
    },
  );

  testWidgets('SegmentedButton and SearchBar expose distinct theme fills', (
    tester,
  ) async {
    final theme = buildMaterialTheme(Brightness.light);
    expect(
      theme.searchBarTheme.backgroundColor!.resolve({}),
      theme.colorScheme.surfaceContainer,
    );
    expect(
      theme.segmentedButtonTheme.style!.backgroundColor!.resolve({}),
      theme.colorScheme.surfaceContainer,
    );
    expect(
      theme.segmentedButtonTheme.style!.backgroundColor!.resolve({
        WidgetState.selected,
      }),
      theme.colorScheme.secondaryContainer,
    );
  });

  testWidgets('SpaceDetailPage keeps per-tab scroll positions independent', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final members = [
      for (var i = 0; i < 30; i++)
        rust.Contact(id: '@user$i:example.org', name: '成员 $i', status: '在线'),
    ];
    final container = ProviderContainer(
      overrides: [
        spaceDetailsProvider.overrideWith(
          (ref, id) async =>
              rust.SpaceDetails(id: id, name: '测试空间', topic: '空间说明'),
        ),
        spaceChildrenProvider.overrideWith((ref, id) async => const []),
        allSpaceChildrenProvider.overrideWith((ref, id) async => const []),
        roomMembersProvider.overrideWith((ref, id) async => members),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@me:example.org';

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: buildMaterialTheme(Brightness.light),
          home: const SpaceDetailPage(
            space: rust.Space(id: '!space:example.org', name: '测试空间'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    Finder verticalScroll() => find.descendant(
      of: find.descendant(
        of: find.byType(SpaceDetailPage),
        matching: find.byType(CustomScrollView),
      ),
      matching: find.byType(Scrollable),
    );

    await tester.tap(find.text('成员'));
    await tester.pumpAndSettle();
    tester.state<ScrollableState>(verticalScroll()).position.jumpTo(400);
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(verticalScroll()).position.pixels,
      greaterThan(300),
    );

    await tester.tap(find.text('关于'));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(verticalScroll()).position.pixels,
      0.0,
    );

    await tester.tap(find.text('成员'));
    await tester.pumpAndSettle();
    expect(
      tester.state<ScrollableState>(verticalScroll()).position.pixels,
      greaterThan(300),
    );
  });
}
