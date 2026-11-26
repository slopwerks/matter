import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/fonts/system_font_catalog.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:matter/providers/app_font_provider.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:matter/theme/system_font.dart';
import 'package:material_ui/material_ui.dart';

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

  testWidgets(
    'MatrixHtmlMessage keeps inline code and code blocks on monospace scale without double-scaling chatScale',
    (tester) async {
      final theme = buildNeuTheme(
        NeuColors.light,
        Brightness.light,
        chatFontFamily: 'MatterChatFont',
        chatFontScale: 1.5,
        monospaceFontFamily: kBundledMonospaceFamily,
        monoFontScale: 1.2,
      );

      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          home: const Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<p>Run <code>flutter test</code></p>'
                  '<pre><code>print("hi");</code></pre>',
              style: TextStyle(
                fontFamily: 'MatterChatFont',
                fontSize: 15 * 1.5,
              ),
              accentColor: Colors.blue,
              selectable: false,
            ),
          ),
        ),
      );

      final spans = [
        for (final rich in tester.widgetList<RichText>(find.byType(RichText)))
          ..._flattenSpans(rich.text),
      ];
      final inlineCode = spans.firstWhere((s) => s.text == 'flutter test');
      expect(inlineCode.style?.fontFamily, kBundledMonospaceFamily);
      expect(inlineCode.style?.fontSize, closeTo(15 * 1.5 * 1.2, 0.01));

      final blockCode = spans.firstWhere((s) => s.text == 'print("hi");');
      expect(blockCode.style?.fontFamily, kBundledMonospaceFamily);
      // Code block unscales chatScale (1.5) to base 15, steps down 1, then applies monoScale (1.2).
      expect(blockCode.style?.fontSize, closeTo((15 - 1) * 1.2, 0.01));
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
