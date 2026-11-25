import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_composer.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:matter/features/matrix_html/matrix_html_parser.dart';

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
          body: '| image | status |\n|---|---|\n| ![logo](https://example.org/logo.png) | ok |',
          formattedBody: '<p>image\nstatus\n\nlogo\nok</p>',
        ),
        contains('<table>'),
      );
    });

    test('recovery matches HTML img alt text', () {
      expect(
        recoverDegradedTableHtml(
          body: '| image | status |\n|---|---|\n| ![logo](https://example.org/logo.png) | ok |',
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
          body: '| a | b |\n|---|---|\n| before![logo](https://example.org/l.png)after | ok |',
          formattedBody: '<p>a\nb</p><p>before<img alt="logo" src="https://example.org/l.png">after</p><p>ok</p>',
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
}
