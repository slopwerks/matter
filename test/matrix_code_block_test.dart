import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_code_block.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

void main() {
  group('formatCodeLanguage', () {
    test('formats known languages and aliases nicely', () {
      expect(formatCodeLanguage('dart'), 'Dart');
      expect(formatCodeLanguage('py'), 'Python');
      expect(formatCodeLanguage('python'), 'Python');
      expect(formatCodeLanguage('js'), 'JavaScript');
      expect(formatCodeLanguage('javascript'), 'JavaScript');
      expect(formatCodeLanguage('ts'), 'TypeScript');
      expect(formatCodeLanguage('typescript'), 'TypeScript');
      expect(formatCodeLanguage('rs'), 'Rust');
      expect(formatCodeLanguage('rust'), 'Rust');
      expect(formatCodeLanguage('go'), 'Go');
      expect(formatCodeLanguage('cpp'), 'C++');
      expect(formatCodeLanguage('c++'), 'C++');
      expect(formatCodeLanguage('cs'), 'C#');
      expect(formatCodeLanguage('csharp'), 'C#');
      expect(formatCodeLanguage('json'), 'JSON');
      expect(formatCodeLanguage('yaml'), 'YAML');
      expect(formatCodeLanguage('yml'), 'YAML');
      expect(formatCodeLanguage('html'), 'HTML');
      expect(formatCodeLanguage('xml'), 'XML');
      expect(formatCodeLanguage('sql'), 'SQL');
      expect(formatCodeLanguage('bash'), 'Bash');
      expect(formatCodeLanguage('sh'), 'Shell');
      expect(formatCodeLanguage('dockerfile'), 'Dockerfile');
      expect(formatCodeLanguage('docker'), 'Dockerfile');
      expect(formatCodeLanguage('graphql'), 'GraphQL');
      expect(formatCodeLanguage('powershell'), 'PowerShell');
      expect(formatCodeLanguage('cmake'), 'CMake');
      expect(formatCodeLanguage('ini'), 'INI');
    });

    test('falls back to raw string for unknown languages', () {
      expect(formatCodeLanguage('brainfuck'), 'brainfuck');
      expect(formatCodeLanguage('zig'), 'zig');
    });

    test('falls back to Code when language is null or empty', () {
      expect(formatCodeLanguage(null), 'Code');
      expect(formatCodeLanguage(''), 'Code');
      expect(formatCodeLanguage('   '), 'Code');
    });
  });

  group('extractCodeLanguage', () {
    test('extracts language from standard class="language-xyz"', () {
      final pre = MatrixElementNode(
        tag: 'pre',
        children: [
          MatrixElementNode(
            tag: 'code',
            children: const [MatrixTextNode('hello')],
            attributes: const {'class': 'language-dart'},
          ),
        ],
      );
      expect(extractCodeLanguage(pre), 'dart');
    });

    test(
      'extracts language from multiple classes such as hljs language-rust',
      () {
        final pre = MatrixElementNode(
          tag: 'pre',
          children: [
            MatrixElementNode(
              tag: 'code',
              children: const [MatrixTextNode('hello')],
              attributes: const {'class': 'hljs language-rust extra-class'},
            ),
          ],
        );
        expect(extractCodeLanguage(pre), 'rust');
      },
    );

    test('extracts language from lang-xyz prefix', () {
      final pre = MatrixElementNode(
        tag: 'pre',
        children: [
          MatrixElementNode(
            tag: 'code',
            children: const [MatrixTextNode('hello')],
            attributes: const {'class': 'lang-python'},
          ),
        ],
      );
      expect(extractCodeLanguage(pre), 'python');
    });

    test('extracts language from data-language attribute', () {
      final pre = MatrixElementNode(
        tag: 'pre',
        children: [
          MatrixElementNode(
            tag: 'code',
            children: const [MatrixTextNode('hello')],
            attributes: const {'data-language': 'go'},
          ),
        ],
      );
      expect(extractCodeLanguage(pre), 'go');
    });

    test('returns null when no code tag or language is specified', () {
      final pre = MatrixElementNode(
        tag: 'pre',
        children: const [MatrixTextNode('plain text')],
      );
      expect(extractCodeLanguage(pre), isNull);
    });
  });

  group('highlightedCodeSpan', () {
    test('returns styled tokens for known language', () {
      final span = highlightedCodeSpan(
        code: 'void main() { print(42); }',
        language: 'dart',
        base: const TextStyle(fontSize: 14, color: Colors.white),
        themeMap: atomOneDarkTheme,
      );
      expect(span.children, isNotNull);
      expect(span.children!.isNotEmpty, isTrue);
    });

    test('supports language aliases like py for python', () {
      final span = highlightedCodeSpan(
        code: 'def hello(): pass',
        language: 'py',
        base: const TextStyle(fontSize: 14, color: Colors.white),
        themeMap: atomOneDarkTheme,
      );
      expect(span.children, isNotNull);
      expect(span.children!.isNotEmpty, isTrue);
    });

    test('falls back to plain span for unknown language', () {
      final span = highlightedCodeSpan(
        code: '+++[>++++<-]>++.',
        language: 'brainfuck',
        base: const TextStyle(fontSize: 14, color: Colors.white),
        themeMap: atomOneDarkTheme,
      );
      expect(span.text, '+++[>++++<-]>++.');
    });

    test('falls back to plain span when language is null', () {
      final span = highlightedCodeSpan(
        code: 'echo hello',
        language: null,
        base: const TextStyle(fontSize: 14, color: Colors.white),
        themeMap: atomOneDarkTheme,
      );
      expect(span.text, 'echo hello');
    });
  });
}
