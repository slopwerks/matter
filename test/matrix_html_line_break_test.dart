import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_composer.dart';
import 'package:matter/features/matrix_html/matrix_code_block.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  Future<void> render(
    WidgetTester tester,
    String html, {
    bool metadata = false,
    bool material = false,
    bool dark = false,
    double width = 320,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(material: material, dark: dark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: MatrixHtmlMessage(
                html: html,
                style: const TextStyle(fontSize: 15, height: 1.35),
                accentColor: Colors.blue,
                trailingMetadata: metadata ? const Text('12:34') : null,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  }

  List<String> paintedText(WidgetTester tester) => tester
      .widgetList<RichText>(
        find.descendant(
          of: find.byType(MatrixHtmlMessage),
          matching: find.byType(RichText),
        ),
      )
      .map((widget) => widget.text.toPlainText())
      .where((text) => text != '12:34')
      .toList();

  final breaks = <String, String>{
    '<p>first<br>\nsecond</p>': 'first\nsecond',
    '<p>first</br>\nsecond</p>': 'first\nsecond',
    '<p>first<br/>\nsecond</p>': 'first\nsecond',
    '<p>first<br />\r\n  second</p>': 'first\nsecond',
    '<p>first\n<br>second</p>': 'first\nsecond',
    '<p>first\n<br>\nsecond</p>': 'first\nsecond',
    '<p><strong>first\n</strong><br><em>\nsecond</em></p>': 'first\nsecond',
    '<p>first<br>\n<br>\nsecond</p>': 'first\n\nsecond',
    '<p>first\nsecond</p>': 'first\nsecond',
    '<p>first<br>second<br>third</p>': 'first\nsecond\nthird',
    '<p>first <strong>bold</strong> second</p>': 'first bold second',
    '<p>first&nbsp;&nbsp;second</p>': 'first\u00a0\u00a0second',
  };
  for (final entry in breaks.entries) {
    for (final metadata in [false, true]) {
      testWidgets('line breaks metadata=$metadata: ${entry.key}', (
        tester,
      ) async {
        await render(tester, entry.key, metadata: metadata);
        expect(paintedText(tester), [entry.value]);
      });
    }
  }

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      for (final width in [200.0, 520.0]) {
        testWidgets(
          'inline flow before blocks material=$material dark=$dark width=$width',
          (tester) async {
            const source =
                '<strong>first</strong> <em>second</em><br>third'
                '<p>last paragraph</p>';
            await render(
              tester,
              source,
              material: material,
              dark: dark,
              width: width,
            );
            final expected = paintedText(tester);
            List<(double, double)> paragraphGeometry() => tester
                .widgetList<RichText>(
                  find.descendant(
                    of: find.byType(MatrixHtmlMessage),
                    matching: find.byType(RichText),
                  ),
                )
                .where((text) => text.text.toPlainText() != '12:34')
                .map((text) {
                  final bounds = tester.getRect(find.byWidget(text));
                  return (bounds.top, bounds.height);
                })
                .toList();
            final expectedGeometry = paragraphGeometry();
            await render(
              tester,
              source,
              metadata: true,
              material: material,
              dark: dark,
              width: width,
            );
            expect(paintedText(tester), expected);
            // Metadata may need its own final row on narrow bubbles; the
            // text itself must keep the same line heights and block positions.
            final actualGeometry = paragraphGeometry();
            expect(actualGeometry, hasLength(expectedGeometry.length));
            for (var i = 0; i < expectedGeometry.length; i++) {
              expect(actualGeometry[i].$1, closeTo(expectedGeometry[i].$1, 1));
              expect(actualGeometry[i].$2, closeTo(expectedGeometry[i].$2, 1));
            }
          },
        );
      }
    }
  }

  for (final metadata in [false, true]) {
    testWidgets(
      'root inline whitespace stays between styles metadata=$metadata',
      (tester) async {
        await render(
          tester,
          '<strong>first</strong>\n<em>second</em>',
          metadata: metadata,
        );
        expect(paintedText(tester), ['first\nsecond']);
      },
    );

    testWidgets('Markdown hard break renders exactly once metadata=$metadata', (
      tester,
    ) async {
      for (final source in [
        '**first**  \nsecond',
        '**first**\\\nsecond',
        '**first**<br>\nsecond',
      ]) {
        final compiled = const MarkdownComposer().compile(source);
        await render(tester, compiled.formattedBody!, metadata: metadata);
        expect(paintedText(tester), ['first\nsecond'], reason: source);
      }
    });
  }

  final markdownCases = <String, String>{
    'headings and paragraphs':
        '# Heading\n\n**first**\nsecond\n\nlast paragraph',
    'tight lists': '- **first**<br>\n  second\n- third',
    'loose lists': '- **first**\n\n  second paragraph\n\n- third',
    'nested lists': '- first\n  - **second**<br>\n    third\n- last',
    'ordered lists': '3. **first**\n4. second',
    'task lists': '- [x] **first**\n- [ ] second',
    'quotes': '> **first**<br>\n> second\n>\n> last paragraph',
    'nested quotes': '> first\n>\n> > **second**<br>\n> > third',
    'tables':
        '| name | value |\n| --- | --- |\n| **first** | second<br>third |',
    'links and inline code': '**first** [second](https://example.org) `third`',
    'horizontal rule': '**first**\n\n---\n\nsecond',
    'code between paragraphs':
        '**first**\n\n```text\na\n\n  b<br>\n```\n\nlast',
  };
  for (final entry in markdownCases.entries) {
    for (final width in [200.0, 520.0]) {
      testWidgets('Markdown ${entry.key} preserves flow at width=$width', (
        tester,
      ) async {
        final compiled = const MarkdownComposer().compile(entry.value);
        expect(compiled.formattedBody, isNotNull);
        await render(tester, compiled.formattedBody!, width: width);
        final expected = paintedText(tester);
        expect(expected, isNotEmpty);
        await render(
          tester,
          compiled.formattedBody!,
          metadata: true,
          width: width,
        );
        expect(paintedText(tester), expected);
      });
    }
  }

  testWidgets('code blocks preserve line breaks and literal br text', (
    tester,
  ) async {
    final compiled = const MarkdownComposer().compile(
      '```text\nfirst\n\n  second<br>\nthird\n```',
    );
    await render(tester, compiled.formattedBody!);
    expect(
      tester.widget<MatrixCodeBlock>(find.byType(MatrixCodeBlock)).code,
      'first\n\n  second<br>\nthird\n',
    );
  });
}
