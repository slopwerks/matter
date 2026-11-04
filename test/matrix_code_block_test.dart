import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_code_block.dart';
import 'package:matter/features/matrix_html/matrix_html_node.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Widget buildCodeBlock({
    required String code,
    String? language,
    double width = 500,
    TextStyle baseStyle = const TextStyle(fontSize: 15, color: Colors.white),
    Brightness brightness = Brightness.dark,
  }) {
    return MaterialApp(
      theme: ThemeData(brightness: brightness, fontFamily: 'Roboto'),
      home: Scaffold(
        body: Center(
          child: MatrixCodeBlock(
            code: code,
            language: language,
            width: width,
            baseStyle: baseStyle,
            accentColor: Colors.blue,
          ),
        ),
      ),
    );
  }

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

  group('MatrixCodeBlock Widget', () {
    testWidgets('renders language label in header bar', (tester) async {
      await tester.pumpWidget(
        buildCodeBlock(code: 'final x = 1;', language: 'dart'),
      );

      expect(find.text('Dart'), findsOneWidget);
      expect(find.byIcon(Icons.code_rounded), findsOneWidget);
      expect(
        find.byKey(const ValueKey('code-block-copy-button')),
        findsOneWidget,
      );
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets('renders default Code label when language is omitted', (
      tester,
    ) async {
      await tester.pumpWidget(
        buildCodeBlock(code: 'echo test', language: null),
      );

      expect(find.text('Code'), findsOneWidget);
      expect(find.byIcon(Icons.code_rounded), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
    });

    testWidgets(
      'copies code to clipboard on copy button tap and shows feedback',
      (tester) async {
        String? clipboardData;
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (MethodCall methodCall) async {
            if (methodCall.method == 'Clipboard.setData') {
              clipboardData = (methodCall.arguments as Map)['text'] as String?;
              return null;
            }
            if (methodCall.method == 'Clipboard.getData') {
              return {'text': clipboardData};
            }
            if (methodCall.method == 'HapticFeedback.vibrate') {
              return null;
            }
            return null;
          },
        );

        const testCode =
            'const greeting = "Hello, Matter!";\nconsole.log(greeting);';

        await tester.pumpWidget(buildCodeBlock(code: testCode, language: 'ts'));

        expect(find.text('TypeScript'), findsOneWidget);
        expect(find.text('复制'), findsOneWidget);
        expect(find.byKey(const ValueKey('copy-icon')), findsOneWidget);

        // Tap the copy button
        await tester.tap(find.byKey(const ValueKey('code-block-copy-button')));
        await tester.pump();

        // Verify clipboard received the exact code text
        expect(clipboardData, testCode);

        // Verify copied state feedback
        expect(find.text('已复制'), findsOneWidget);
        expect(find.byKey(const ValueKey('copied-icon')), findsOneWidget);

        // Wait 1.5s timer
        await tester.pump(const Duration(milliseconds: 1600));

        // Verify state reverts to default
        expect(find.text('复制'), findsOneWidget);
        expect(find.byKey(const ValueKey('copy-icon')), findsOneWidget);
      },
    );

    testWidgets('adapts colors for dark mode and light mode', (tester) async {
      // Dark mode:
      await tester.pumpWidget(
        buildCodeBlock(
          code: 'int a = 10;',
          language: 'c',
          brightness: Brightness.dark,
          baseStyle: const TextStyle(color: Colors.white),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('C'), findsOneWidget);

      // Light mode:
      await tester.pumpWidget(
        buildCodeBlock(
          code: 'int a = 10;',
          language: 'c',
          brightness: Brightness.light,
          baseStyle: const TextStyle(color: Colors.black87),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('C'), findsOneWidget);
    });

    testWidgets(
      'renders Scrollbar and SingleChildScrollView for horizontal scrolling',
      (tester) async {
        final longCode = 'final buffer = "${'abc' * 100}";';

        await tester.pumpWidget(
          buildCodeBlock(code: longCode, language: 'dart', width: 300),
        );

        expect(find.byType(Scrollbar), findsOneWidget);
        expect(find.byType(SingleChildScrollView), findsOneWidget);
      },
    );
  });
}
