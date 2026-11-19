import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_composer.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:matter/features/matrix_html/matrix_html_parser.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';

void main() {
  const composer = MarkdownComposer();

  group('markdown tables', () {
    test('compile produces a Matrix HTML table and readable fallback', () {
      final result = composer.compile('''
| 客户端 | 特点 |
|---|---|
| **Komai** | 原生、快 |
| Cinny | 轻量 |
''');

      expect(result.formattedBody, contains('<table>'));
      expect(result.formattedBody, contains('<th>客户端</th>'));
      expect(result.formattedBody, contains('<td><strong>Komai</strong></td>'));
      expect(result.body, '客户端 | 特点\nKomai | 原生、快\nCinny | 轻量');
    });

    test('markdownBodyHasTable detects header plus separator', () {
      expect(markdownBodyHasTable('| a | b |\n|---|---|\n| 1 | 2 |'), isTrue);
      expect(markdownBodyHasTable('a | b\n--- | ---\n1 | 2'), isTrue);
      expect(markdownBodyHasTable('just | pipes\nno separator'), isFalse);
      expect(markdownBodyHasTable('no table at all'), isFalse);
    });

    test('recoverDegradedTableHtml rebuilds tables the sender stripped', () {
      final recovered = recoverDegradedTableHtml(
        body: '| a | b |\n|---|---|\n| 1 | 2 |',
        formattedBody: '<p>a\nb\n\n1\n2</p>',
      );

      expect(recovered, isNotNull);
      expect(recovered, contains('<table>'));
    });

    test('recoverDegradedTableHtml keeps proper HTML untouched', () {
      expect(
        recoverDegradedTableHtml(
          body: '| a | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: '<table><tr><td>a</td></tr></table>',
        ),
        isNull,
      );
      expect(
        recoverDegradedTableHtml(body: 'plain message', formattedBody: null),
        isNull,
      );
      expect(
        recoverDegradedTableHtml(
          body: 'a | b\nno separator line',
          formattedBody: '<p>a | b</p>',
        ),
        isNull,
      );
    });

    test('recoverDegradedTableHtml never reinterprets plain-text events', () {
      expect(
        recoverDegradedTableHtml(
          body: '| a | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: null,
        ),
        isNull,
      );
    });

    test('recoverDegradedTableHtml requires the flattened-table shape', () {
      // Legitimate HTML that intentionally has no table is kept untouched.
      expect(
        recoverDegradedTableHtml(
          body: '| a | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: '<p>totally unrelated content</p>',
        ),
        isNull,
      );
      // Short headers mentioned in a different order are not a table.
      expect(
        recoverDegradedTableHtml(
          body: '| Name | Value |\n|---|---|\n| Alice | 30 |',
          formattedBody: '<p>Name: Alice. Value: 30 years.</p>',
        ),
        isNull,
      );
      // A data cell missing from the HTML means it is not the same table.
      expect(
        recoverDegradedTableHtml(
          body: '| Name | Value |\n|---|---|\n| Alice | 30 |',
          formattedBody: '<p>Name Value Alice</p>',
        ),
        isNull,
      );
      // The sequence must not match across word boundaries either.
      expect(
        recoverDegradedTableHtml(
          body: '| a | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: '<p>data b 1 20</p>',
        ),
        isNull,
      );
      // The degraded shape: all cells survive as ordered flattened text.
      expect(
        recoverDegradedTableHtml(
          body: '| **a** | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: '<p>a\nb\n\n<strong>1</strong>\n2</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery sees cells across adjacent block elements', () {
      expect(
        recoverDegradedTableHtml(
          body: '| a | b |\n|---|---|\n| 1 | 2 |',
          formattedBody: '<p>a</p><p>b</p><p>1</p><p>2</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery handles repeated token prefixes without losing a match', () {
      expect(
        recoverDegradedTableHtml(
          body: '| a a | a b |\n|---|---|',
          formattedBody: '<p>prefix a a a a a b suffix</p>',
        ),
        contains('<table>'),
      );
    });

    test('image cells keep their alt text in the plain fallback', () {
      final result = composer.compile('''
| image | status |
|---|---|
| ![logo](https://example.org/logo.png) | ok |
''');

      expect(result.body, 'image | status\nlogo | ok');
    });

    test('recovery matches image cells by their alt text', () {
      expect(
        recoverDegradedTableHtml(
          body:
              '| image | status |\n|---|---|\n| ![logo](https://example.org/logo.png) | ok |',
          formattedBody: '<p>image\nstatus\n\nlogo\nok</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery matches HTML img alt text', () {
      expect(
        recoverDegradedTableHtml(
          body:
              '| image | status |\n|---|---|\n| ![logo](https://example.org/logo.png) | ok |',
          formattedBody:
              '<p>image\nstatus</p>'
              '<img alt="logo" src="https://example.org/logo.png">'
              '<p>ok</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery matches inline img alt without added separators', () {
      expect(
        recoverDegradedTableHtml(
          body:
              '| a | b |\n|---|---|\n| before![logo](https://example.org/l.png)after | ok |',
          formattedBody:
              '<p>a\nb</p><p>before<img alt="logo" src="https://example.org/l.png">after</p><p>ok</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery handles escaped pipes in cells', () {
      expect(
        recoverDegradedTableHtml(
          body: '| expression | note |\n|---|---|\n| a \\| b | ok |',
          formattedBody: '<p>expression\nnote\n\na | b\nok</p>',
        ),
        contains('<table>'),
      );
    });
  });

  group('parser', () {
    test('keeps table structure', () {
      final nodes = const MatrixHtmlParser().parse(
        '<table><thead><tr><th>a</th></tr></thead>'
        '<tbody><tr><td>b</td></tr></tbody></table>',
      );

      final table = nodes.single as MatrixElementNode;
      expect(table.tag, 'table');
      expect(table.textContent, 'ab');
    });
  });

  group('renderer', () {
    testWidgets('renders HTML tables as a Table widget', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<table><thead><tr><th>客户端</th><th>特点</th></tr></thead>'
                  '<tbody><tr><td><strong>Komai</strong></td><td>快</td></tr>'
                  '</tbody></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(find.byType(Table), findsOneWidget);
      expect(find.text('客户端', findRichText: true), findsOneWidget);
      expect(find.text('Komai', findRichText: true), findsOneWidget);
      expect(find.text('快', findRichText: true), findsOneWidget);
    });

    testWidgets('irregular remote tables render without crashing', (
      tester,
    ) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<table><tr><th>a</th><th>b</th></tr>'
                  '<tr><td>1</td></tr>'
                  '<tr><td>x</td><td>y</td><td>z</td></tr></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(Table), findsOneWidget);
      expect(find.text('z', findRichText: true), findsOneWidget);
    });

    testWidgets('pathological ragged tables fall back without grid expansion', (
      tester,
    ) async {
      final wideRow = List.generate(
        40,
        (index) => '<td>wide-$index</td>',
      ).join();
      final narrowRows = List.generate(
        40,
        (index) => '<tr><td>row-$index</td></tr>',
      ).join();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html: '<table><tr>$wideRow</tr>$narrowRows</table>',
              style: const TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byType(Table), findsNothing);
      expect(find.textContaining('wide-39'), findsOneWidget);
      expect(find.textContaining('row-39'), findsOneWidget);
    });

    testWidgets('table cells preserve block structure', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<table><tr><td><p>first</p><p>second</p>'
                  '<ul><li>third</li></ul></td></tr></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('first', findRichText: true), findsOneWidget);
      expect(find.text('second', findRichText: true), findsOneWidget);
      expect(find.text('third', findRichText: true), findsOneWidget);
    });

    testWidgets('table captions stay visible', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<table><caption>Quarterly report</caption>'
                  '<tr><td>data</td></tr></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(find.text('Quarterly report', findRichText: true), findsOneWidget);
      expect(find.text('data', findRichText: true), findsOneWidget);
    });

    testWidgets('caption-only tables still render the caption', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html: '<table><caption>No results</caption></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      expect(find.text('No results', findRichText: true), findsOneWidget);
    });

    testWidgets('mixed th/td rows style cells by cell type', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html:
                  '<table><tbody>'
                  '<tr><th>Name</th><td>Alice</td></tr>'
                  '</tbody></table>',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      TextStyle? styleOf(String text) {
        TextStyle? found;
        void visit(InlineSpan span) {
          if (span is TextSpan) {
            if (span.text == text) found = span.style;
            span.children?.forEach(visit);
          }
        }

        for (final widget in tester.widgetList<RichText>(
          find.byType(RichText),
        )) {
          visit(widget.text);
        }
        return found;
      }

      expect(styleOf('Name')?.fontWeight, FontWeight.w800);
      expect(styleOf('Alice')?.fontWeight, isNot(FontWeight.w800));
    });

    testWidgets('collapses blank-line runs in degraded HTML', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: MatrixHtmlMessage(
              html: '<p>证据</p>\n\n\n\n项目\n信息\n\n\n\n3.44.9 tag',
              style: TextStyle(fontSize: 15),
              accentColor: Colors.cyan,
            ),
          ),
        ),
      );

      final texts = tester
          .widgetList<RichText>(find.byType(RichText))
          .map((widget) => widget.text.toPlainText())
          .toList();
      expect(texts, contains('\n项目\n信息\n3.44.9 tag'));
      expect(texts.any((text) => text.contains('\n\n')), isFalse);
    });
  });
}
