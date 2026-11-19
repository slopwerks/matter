import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/create_chat_page.dart';
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

  for (final width in [320.0, 400.0, 1200.0]) {
    for (final style in [
      AppThemeStyle.materialLight,
      AppThemeStyle.materialDark,
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
        final desktop = width >= 960;
        expect(
          find.byType(desktop ? NavigationRail : MaterialTabNavigationBar),
          findsOneWidget,
        );
        if (!desktop) {
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
          final navigation = find.byType(
            desktop ? NavigationRail : MaterialTabNavigationBar,
          );
          await tester.tap(
            find.descendant(
              of: navigation,
              matching: desktop
                  ? find.byIcon(destination.icon)
                  : find.text(destination.label),
            ),
          );
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 300));
          expect(find.byType(AppBar), findsOneWidget);
          final appBar = find.byType(AppBar);
          expect(
            tester.widget<AppBar>(appBar).backgroundColor,
            Colors.transparent,
          );
          expect(
            find.descendant(of: appBar, matching: find.byType(TopFadeBlur)),
            findsOneWidget,
          );
          final scaffold = find
              .ancestor(of: appBar, matching: find.byType(Scaffold))
              .first;
          expect(
            tester.widget<Scaffold>(scaffold).extendBodyBehindAppBar,
            isTrue,
          );
          expect(find.text(destination.label), findsWidgets);
          expect(tester.takeException(), isNull);
        }
        expect(find.text('消息头像吸附'), findsOneWidget);
        expect(find.text('消息气泡阴影'), findsNothing);
        await tester.tap(find.text('Material 配色'));
        await tester.pumpAndSettle();
        expect(find.byType(MaterialColorSettingsPage), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();
        expect(find.text('Material · 跟随系统'), findsOneWidget);
        await tester.tap(find.text('新拟物 · 跟随系统'));
        await tester.pumpAndSettle();
        expect(container.read(appThemeStyleProvider), AppThemeStyle.neuSystem);
        expect(find.byType(MaterialTabNavigationBar), findsNothing);
        expect(find.text('Material 配色'), findsNothing);
        await tester.tap(find.text('主题'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Material · 深色'));
        await tester.pumpAndSettle();
        expect(
          container.read(appThemeStyleProvider),
          AppThemeStyle.materialDark,
        );
        expect(
          find.byType(desktop ? NavigationRail : MaterialTabNavigationBar),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      });
    }
  }
}
