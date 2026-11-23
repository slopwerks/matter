import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/create_chat_page.dart';
import 'package:matter/pages/chat/room_directory_page.dart';
import 'package:matter/pages/settings/material_color_settings_page.dart';
import 'package:matter/providers/material_color_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/theme_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/widgets/glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

class _ThemeHarness extends ConsumerWidget {
  const _ThemeHarness();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = ref.watch(appThemeStyleProvider);
    final colors = style.isMaterial
        ? ref.watch(materialColorSchemesProvider)
        : null;
    return MaterialApp(
      theme: style.isMaterial
          ? buildMaterialTheme(Brightness.light, colorScheme: colors!.light)
          : buildNeuTheme(NeuColors.light, Brightness.light),
      darkTheme: style.isMaterial
          ? buildMaterialTheme(Brightness.dark, colorScheme: colors!.dark)
          : buildNeuTheme(NeuColors.dark, Brightness.dark),
      themeMode: style.themeMode,
      home: const MatterApp(),
    );
  }
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RustApi()));
  tearDownAll(RustLib.dispose);

  for (final width in [320.0, 600.0, 840.0, 1200.0, 1600.0]) {
    for (final style in [
      (family: ThemeFamily.material, themeMode: ThemeMode.light),
      (family: ThemeFamily.material, themeMode: ThemeMode.dark),
    ]) {
      testWidgets('$style navigates every main page at width $width', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({'app_theme_style': style.name});
        await tester.binding.setSurfaceSize(Size(width, 800));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = ProviderContainer(
          overrides: [
            allChatRoomsProvider.overrideWith((ref) async => const []),
            spacesProvider.overrideWith((ref) async => const []),
            ungroupedRoomsProvider.overrideWith((ref) async => const []),
            contactsProvider.overrideWith((ref) async => const []),
            syncStreamProvider.overrideWith((ref) => null),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const _ThemeHarness(),
          ),
        );
        for (var i = 0; i < 5; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        final desktop = width >= 600;
        expect(
          desktop
              ? find.byKey(const ValueKey('material-navigation-rail'))
              : find.byType(MaterialTabNavigationBar),
          findsOneWidget,
        );
        if (!desktop) {
          expect(find.byType(DockSurface), findsOneWidget);
          for (final label in ['聊天', '空间', '通讯录', '设置']) {
            expect(
              find.descendant(
                of: find.byType(MaterialTabNavigationBar),
                matching: find.text(label),
              ),
              findsOneWidget,
            );
          }
          final compose = find.byKey(const ValueKey('new-chat-action'));
          expect(compose, findsOneWidget);
          expect(
            tester.getBottomLeft(compose).dy,
            lessThan(
              tester.getTopLeft(find.byKey(const ValueKey('material-dock'))).dy,
            ),
          );
          await tester.tap(compose);
          await tester.pumpAndSettle();
          expect(find.byType(CreateChatPage), findsOneWidget);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
        }
        for (final destination in [
          (label: '空间', icon: Icons.workspaces_outline),
          (label: '通讯录', icon: Icons.people_outline),
          (label: '设置', icon: Icons.settings_outlined),
        ]) {
          final navigation = desktop
              ? find.byKey(const ValueKey('material-navigation-rail'))
              : find.byType(MaterialTabNavigationBar);
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: desktop && width < 1200
                  ? find.byTooltip(destination.label)
                  : find.text(destination.label),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AppBar), findsOneWidget);
          final appBar = find.byType(AppBar);
          final scheme = Theme.of(tester.element(appBar)).colorScheme;
          expect(
            tester.widget<AppBar>(appBar).backgroundColor,
            desktop ? scheme.surface : scheme.primaryContainer,
          );
          expect(
            find.descendant(of: appBar, matching: find.byType(TopFadeBlur)),
            findsNothing,
          );
          final scaffold = find
              .ancestor(of: appBar, matching: find.byType(Scaffold))
              .first;
          expect(
            tester.widget<Scaffold>(scaffold).extendBodyBehindAppBar,
            isFalse,
          );
          if (desktop && width < 1200) {
            await tester.pumpAndSettle();
            final button = find.byTooltip(destination.label);
            expect(
              tester.getRect(button),
              tester.getRect(find.byKey(const ValueKey('rail-indicator'))),
            );
          } else {
            expect(find.text(destination.label), findsWidgets);
          }
          expect(tester.takeException(), isNull);
          if (width >= 840 && destination.label == '空间') {
            await tester.tap(find.byTooltip('探索公开房间'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            expect(
              tester.getTopLeft(find.byType(RoomDirectoryPage)).dx,
              greaterThan(tester.getCenter(find.byTooltip('探索公开房间')).dx),
            );
            await tester.binding.handlePopRoute();
            await tester.pumpAndSettle();
            expect(find.byType(RoomDirectoryPage), findsNothing);
          }
        }
        if (width >= 840) {
          // Global rail actions also work when another tab is active.
          await tester.tap(find.byTooltip('查找房间'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          final directory = find.byType(RoomDirectoryPage);
          final list = find.byKey(const ValueKey('material-conversation-list'));
          expect(
            tester.getTopLeft(directory).dx,
            greaterThanOrEqualTo(tester.getTopRight(list).dx),
          );
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(directory, findsNothing);
          await tester.tap(
            find.descendant(
              of: find.byKey(const ValueKey('material-navigation-rail')),
              matching: width < 1200 ? find.byTooltip('设置') : find.text('设置'),
            ),
          );
          await tester.pumpAndSettle();
        }
        expect(find.text('外观与显示'), findsOneWidget);
        expect(find.widgetWithText(ListTile, '外观与显示'), findsNothing);
        await tester.ensureVisible(find.text('Material 配色'));
        await tester.pumpAndSettle();
        expect(find.text('消息气泡阴影'), findsNothing);
        await tester.tap(find.text('Material 配色'));
        await tester.pumpAndSettle();
        expect(find.byType(MaterialColorSettingsPage), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        Future<void> press(Finder target) async {
          await Scrollable.ensureVisible(tester.element(target), alignment: .5);
          await tester.pumpAndSettle();
          await tester.tap(target);
          await tester.pumpAndSettle();
        }

        expect(find.byType(ChoiceChip), findsNothing);
        expect(
          find.text('Material · ${style.themeMode.label}'),
          findsOneWidget,
        );
        await press(find.text('主题'));
        await press(find.byKey(const ValueKey(ThemeFamily.neu)));
        await press(find.text('应用主题'));
        expect(container.read(appThemeStyleProvider), (
          family: ThemeFamily.neu,
          themeMode: style.themeMode,
        ));
        expect(find.byType(MaterialTabNavigationBar), findsNothing);
        await press(find.text('主题'));
        await press(find.byKey(const ValueKey(ThemeMode.system)));
        await press(find.byKey(const ValueKey(ThemeFamily.material)));
        await press(find.text('应用主题'));
        expect(container.read(appThemeStyleProvider), (
          family: ThemeFamily.material,
          themeMode: ThemeMode.system,
        ));
        await press(find.text('主题'));
        await press(find.byKey(const ValueKey(ThemeMode.dark)));
        await press(find.text('应用主题'));
        expect(container.read(appThemeStyleProvider).themeMode, ThemeMode.dark);
        expect(
          desktop
              ? find.byKey(const ValueKey('material-navigation-rail'))
              : find.byType(MaterialTabNavigationBar),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
