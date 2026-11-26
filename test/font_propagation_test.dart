import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/fonts/system_font_catalog.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:matter/pages/settings/font_settings_page.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/system_font.dart';
import 'package:matter/theme/tokens/app_typography.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

List<TextSpan> _flattenSpans(InlineSpan span) => [
  if (span is TextSpan) ...[
    span,
    for (final child in span.children ?? const <InlineSpan>[])
      ..._flattenSpans(child),
  ],
];

List<String?> _resolvedFamilies(WidgetTester tester) => [
  for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
    if (rich.text case final TextSpan span) span.style?.fontFamily,
];

void main() {
  testWidgets('chips and list rows follow the picked font', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: applySystemFont(ThemeData(), 'MatterCustomFont'),
        home: Scaffold(
          body: Column(
            children: [
              ChoiceChip(
                label: const Text('全部'),
                selected: true,
                onSelected: (_) {},
              ),
              ActionChip(label: const Text('未归属群组'), onPressed: () {}),
              const ListTile(title: Text('主题'), subtitle: Text('新拟物 · 跟随系统')),
              const Text('裸文本'),
            ],
          ),
        ),
      ),
    );

    final families = _resolvedFamilies(tester);
    expect(families, isNotEmpty);
    expect(families.where((family) => family != 'MatterCustomFont'), isEmpty);
  });

  testWidgets('the app theme keeps the picked font on chips and text fields', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(
          Brightness.light,
          fontFamily: 'MatterCustomFont',
        ),
        home: Scaffold(
          body: Column(
            children: [
              ChoiceChip(
                label: const Text('未读'),
                selected: false,
                onSelected: (_) {},
              ),
              ActionChip(label: const Text('私聊'), onPressed: () {}),
              const TextField(),
              const DefaultTabController(
                length: 1,
                child: TabBar(tabs: [Tab(text: '关注')]),
              ),
            ],
          ),
        ),
      ),
    );

    final families = _resolvedFamilies(tester);
    expect(families, isNotEmpty);
    expect(families.where((family) => family != 'MatterCustomFont'), isEmpty);
  });

  testWidgets('preview theme preserves parent app, chat and monospace fonts', (
    tester,
  ) async {
    final parent = buildMaterialTheme(
      Brightness.light,
      fontFamily: 'MatterUiFont',
      fontFamilyFallback: const ['MatterFallback'],
      chatFontFamily: 'MatterChatFont',
      chatFontScale: 1.15,
      monospaceFontFamily: kBundledMonospaceFamily,
      monoFontScale: 1.2,
    );
    late ThemeData captured;

    await tester.pumpWidget(
      MaterialApp(
        theme: parent,
        home: Builder(
          builder: (context) {
            captured = buildMaterialPreviewTheme(
              Theme.of(context),
              Theme.of(context).colorScheme,
            );
            return const SizedBox.shrink();
          },
        ),
      ),
    );

    expect(captured.textTheme.bodyMedium?.fontFamily, 'MatterUiFont');
    expect(captured.textTheme.bodyMedium?.fontFamilyFallback, [
      'MatterFallback',
    ]);
    final typo = AppTypography.maybeOf(tester.element(find.byType(SizedBox)))!;
    expect(typo.chatBody.fontFamily, 'MatterChatFont');
    expect(typo.monospace.fontFamily, kBundledMonospaceFamily);
    expect(typo.monoScale, 1.2);
  });

  testWidgets(
    'inline code in MatrixHtmlMessage uses configured monospace font',
    (tester) async {
      final theme = buildNeuTheme(
        NeuColors.light,
        Brightness.light,
        chatFontFamily: 'MatterChatFont',
        monospaceFontFamily: kBundledMonospaceFamily,
        monoFontScale: 1.25,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: MatrixHtmlMessage(
              html: '<p>Run <code>flutter test</code> now</p>',
              style: TextStyle(fontFamily: 'MatterChatFont', fontSize: 16),
              accentColor: Colors.blue,
              selectable: false,
            ),
          ),
        ),
      );

      final rich = tester.widget<RichText>(find.byType(RichText));
      final codeSpan = _flattenSpans(rich.text)
          .firstWhere((s) => s.text == 'flutter test');
      expect(codeSpan.style?.fontFamily, kBundledMonospaceFamily);
      expect(codeSpan.style?.fontSize, closeTo(16 * 1.25, 0.01));
    },
  );

  testWidgets(
    'FontSettingsPage renders in Material and Neu and resets scales',
    (tester) async {
      for (final material in [true, false]) {
        SharedPreferences.setMockInitialValues({'mono_font_scale': 1.25});
        final container = ProviderContainer();
        addTearDown(container.dispose);

        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: material
                  ? buildMaterialTheme(
                      Brightness.light,
                      monospaceFontFamily: kBundledMonospaceFamily,
                    )
                  : buildNeuTheme(
                      NeuColors.light,
                      Brightness.light,
                      monospaceFontFamily: kBundledMonospaceFamily,
                    ),
              home: const FontSettingsPage(),
            ),
          ),
        );
        await tester.pumpAndSettle();

        final listScrollable = find.byType(Scrollable).first;
        expect(find.text('字体与排版'), findsOneWidget);
        await tester.scrollUntilVisible(
          find.text('界面字体'),
          200,
          scrollable: listScrollable,
        );
        expect(find.text('界面字体'), findsOneWidget);
        expect(find.text('聊天正文字体'), findsOneWidget);
        expect(find.text('等宽字体'), findsOneWidget);
        expect(find.text('回退字体'), findsOneWidget);

        await tester.scrollUntilVisible(
          find.text('125%'),
          200,
          scrollable: listScrollable,
        );
        expect(find.text('125%'), findsOneWidget);

        final resetFinder = find.text('恢复默认字体设置');
        await tester.scrollUntilVisible(
          resetFinder,
          200,
          scrollable: listScrollable,
        );
        await tester.ensureVisible(resetFinder);
        await tester.pumpAndSettle();
        await tester.tap(resetFinder);
        await tester.pumpAndSettle();
        expect(container.read(fontScaleSettingsProvider).isDefault, isTrue);
      }
    },
  );

  test('a serif pick carries the loaded CJK fallback', () {
    final theme = applySystemFont(
      ThemeData(),
      'serif',
      fallback: const [kCjkFallbackFamily],
    );
    expect(theme.textTheme.bodyMedium?.fontFamily, 'serif');
    expect(theme.textTheme.bodyMedium?.fontFamilyFallback, [
      kCjkFallbackFamily,
    ]);
  });

  test('system families are readable on the host', () async {
    final families = await loadSystemFontFamilies();
    expect(families, isA<List<String>>());
  });
}
