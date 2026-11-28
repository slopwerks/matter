import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/features/fonts/system_font_catalog.dart';
import 'package:matter/pages/settings/font_settings_page.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Picker interaction is isolated from provider filesystem persistence, which
// is covered by app_font_test.dart.
class _PickerFont extends AppFont {
  @override
  FontChoice? build() => null;

  @override
  Future<void> selectSystemFamily(String family) async {
    state = SystemFontChoice(family);
  }
}

void main() {
  for (final material in [true, false]) {
    testWidgets('font picker builds only visible previews material=$material', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      final families = List.generate(
        2707,
        (i) => 'Test Font ${i.toString().padLeft(4, '0')}',
      );
      var catalogLoads = 0;
      final constrained = ValueNotifier(false);
      addTearDown(constrained.dispose);
      final container = ProviderContainer(
        overrides: [
          appFontProvider.overrideWith(_PickerFont.new),
          systemFontCatalogProvider.overrideWith((ref) async {
            catalogLoads++;
            return SystemFontCatalog(
              families: families,
              monospaceFamilies: {families[1]},
            );
          }),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: material
                ? buildMaterialTheme(Brightness.light)
                : buildNeuTheme(NeuColors.light, Brightness.light),
            builder: (context, child) => ValueListenableBuilder<bool>(
              valueListenable: constrained,
              builder: (context, small, _) => MediaQuery(
                data: small
                    ? MediaQuery.of(context).copyWith(
                        size: const Size(800, 400),
                        viewInsets: const EdgeInsets.only(bottom: 240),
                      )
                    : MediaQuery.of(context),
                child: child!,
              ),
            ),
            home: const FontSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('界面字体'));
      await tester.pumpAndSettle();
      expect(catalogLoads, 0, reason: 'The action menu must not scan fonts');
      await tester.tap(find.text('选择系统字体'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final previewRows = find.byWidgetPredicate(
        (w) => w is Text && (w.data?.startsWith('Test Font ') ?? false),
      );
      expect(previewRows, findsWidgets);
      expect(
        tester
            .widgetList<Text>(previewRows)
            .where((t) => t.style?.fontFamily == t.data),
        isEmpty,
        reason: 'Opening animation must not initialize all visible font faces',
      );
      var previousPreviews = <String>{};
      for (var frame = 0; frame < 45; frame++) {
        await tester.pump(const Duration(milliseconds: 16));
        final previews = tester
            .widgetList<Text>(previewRows)
            .where((t) => t.style?.fontFamily == t.data)
            .map((t) => t.data!)
            .toSet();
        expect(
          previews.difference(previousPreviews).length,
          lessThanOrEqualTo(1),
          reason: 'Cold font previews must be initialized over separate frames',
        );
        previousPreviews = previews;
      }
      expect(previousPreviews, isNotEmpty);
      await tester.pumpAndSettle();
      expect(catalogLoads, 1);
      constrained.value = true;
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text(families.first), findsOneWidget);
      constrained.value = false;
      await tester.pumpAndSettle();
      final rendered = find.byWidgetPredicate(
        (w) => w is Text && (w.data?.startsWith('Test Font ') ?? false),
      );
      expect(
        rendered.evaluate().length,
        lessThan(35),
        reason: '2707 installed fonts must not all be laid out or previewed',
      );
      expect(find.text(families.first), findsOneWidget);
      for (final text in tester.widgetList<Text>(rendered)) {
        expect(text.style?.fontFamily, text.data);
      }
      final list = find
          .descendant(
            of: find.byType(NotificationListener<ScrollNotification>),
            matching: find.byType(ListView),
          )
          .last;
      final position = tester
          .state<ScrollableState>(
            find.descendant(of: list, matching: find.byType(Scrollable)),
          )
          .position;
      final beforeWheel = position.pixels;
      for (var tick = 0; tick < 5; tick++) {
        tester.binding.handlePointerEvent(
          PointerScrollEvent(
            position: tester.getCenter(list),
            scrollDelta: const Offset(0, 24),
          ),
        );
        await tester.pump(const Duration(milliseconds: 16));
        expect(position.pixels, greaterThan(beforeWheel));
        for (final text in tester.widgetList<Text>(rendered)) {
          expect(
            text.style?.fontFamily,
            isNot(text.data),
            reason:
                'Wheel ticks must keep previews deferred until the burst ends',
          );
        }
      }
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      for (final text in tester.widgetList<Text>(rendered)) {
        expect(text.style?.fontFamily, text.data);
      }
      final gesture = await tester.startGesture(tester.getCenter(list));
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      expect(tester.widgetList<Text>(rendered), isNotEmpty);
      for (final text in tester.widgetList<Text>(rendered)) {
        expect(text.style?.fontFamily, isNot(text.data));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      await tester.pump(const Duration(milliseconds: 160));
      await tester.pumpAndSettle();
      for (final text in tester.widgetList<Text>(rendered)) {
        expect(text.style?.fontFamily, text.data);
      }
      await tester.tap(find.text('等宽 (1)'));
      await tester.pumpAndSettle();
      expect(find.text(families[1]), findsOneWidget);
      expect(find.text(families[0]), findsNothing);
      await tester.tap(find.text('全部 (2707)'));
      await tester.pumpAndSettle();
      final search = find.byType(TextField);
      await tester.enterText(search, '2706');
      await tester.pumpAndSettle();
      expect(find.text(families.last), findsOneWidget);
      await tester.tap(find.text(families.last));
      await tester.pumpAndSettle();

      expect(container.read(appFontFamilyProvider), families.last);
      await tester.tap(find.text('界面字体'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('选择系统字体'));
      await tester.pumpAndSettle();
      final reopenedList = find
          .descendant(
            of: find.byType(NotificationListener<ScrollNotification>),
            matching: find.byType(ListView),
          )
          .last;
      tester.binding.handlePointerEvent(
        PointerScrollEvent(
          position: tester.getCenter(reopenedList),
          scrollDelta: const Offset(0, 24),
        ),
      );
      await tester.pump();
      // Disposing while idle restoration is pending must cancel the timer.
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.takeException(), isNull);
    });
  }
}
