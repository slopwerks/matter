import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:matter/widgets/app_avatar.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  Widget app(String html, {MatrixHtmlImageResolver? imageResolver}) =>
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: MatrixHtmlMessage(
              html: html,
              style: const TextStyle(fontSize: 15, color: Colors.white),
              accentColor: Colors.cyan,
              imageResolver: imageResolver,
            ),
          ),
        ),
      );

  group('code blocks', () {
    testWidgets('code block fills the available width', (tester) async {
      await tester.pumpWidget(app('<pre><code>short</code></pre>'));

      expect(tester.takeException(), isNull);
      final scroll = tester.getSize(
        find.descendant(
          of: find.byType(MatrixHtmlMessage),
          matching: find.byType(SingleChildScrollView),
        ),
      );
      // The default test surface is 800 logical pixels wide.
      expect(scroll.width, 780);
    });

    testWidgets('long code stays scrollable inside the same width', (
      tester,
    ) async {
      final longLine = 'x' * 5000;
      await tester.pumpWidget(app('<pre><code>$longLine</code></pre>'));

      expect(tester.takeException(), isNull);
      final scroll = tester.getSize(find.byType(SingleChildScrollView));
      expect(scroll.width, 780);
    });

    testWidgets('highlighted code renders without crashing', (tester) async {
      await tester.pumpWidget(
        app(
          '<pre><code class="language-dart">void main() { print(1); }</code></pre>',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.textContaining('print', findRichText: true), findsWidgets);
    });

    testWidgets('unknown languages fall back to plain code', (tester) async {
      await tester.pumpWidget(
        app('<pre><code class="language-brainfuck">++++</code></pre>'),
      );

      expect(tester.takeException(), isNull);
      expect(find.text('++++', findRichText: true), findsOneWidget);
    });
  });

  group('task lists', () {
    testWidgets('checkboxes replace bullet markers', (tester) async {
      await tester.pumpWidget(
        app(
          '<ul><li><input type="checkbox" checked> done</li>'
          '<li><input type="checkbox"> todo</li></ul>',
        ),
      );

      expect(tester.takeException(), isNull);
      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
      expect(find.text(' done', findRichText: true), findsOneWidget);
      expect(find.text(' todo', findRichText: true), findsOneWidget);
      expect(find.text('•', findRichText: true), findsNothing);
    });

    testWidgets('checkboxes nested in paragraphs are detected', (tester) async {
      await tester.pumpWidget(
        app('<ul><li><p><input type="checkbox"> task</p></li></ul>'),
      );

      expect(tester.takeException(), isNull);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
    });

    testWidgets('Matrix-compatible text markers render as checkboxes', (
      tester,
    ) async {
      await tester.pumpWidget(
        app('<ul><li>[x] done</li><li>[ ] todo</li></ul>'),
      );

      expect(find.byIcon(Icons.check_box_rounded), findsOneWidget);
      expect(
        find.byIcon(Icons.check_box_outline_blank_rounded),
        findsOneWidget,
      );
      expect(find.text('•', findRichText: true), findsNothing);
    });
  });

  group('math', () {
    testWidgets('block math renders', (tester) async {
      await tester.pumpWidget(app('<div data-mx-maths="x^2 + y^2"></div>'));

      expect(tester.takeException(), isNull);
    });

    testWidgets('inline math renders inside text', (tester) async {
      await tester.pumpWidget(
        app('<p>a <span data-mx-maths="x^2"></span> b</p>'),
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('broken math falls back to the raw source', (tester) async {
      await tester.pumpWidget(app('<div data-mx-maths="x^"></div>'));

      expect(tester.takeException(), isNull);
      expect(find.text(r'$$x^$$', findRichText: true), findsOneWidget);
    });
  });

  group('spoilers', () {
    TextSpan spanWithText(WidgetTester tester, String text) {
      TextSpan? result;
      void visit(InlineSpan span) {
        if (span is! TextSpan) return;
        if (span.text == text) result = span;
        span.children?.forEach(visit);
      }

      for (final richText in tester.widgetList<RichText>(
        find.byType(RichText),
      )) {
        visit(richText.text);
      }
      return result!;
    }

    testWidgets('spoiler text stays concealed until tapped', (tester) async {
      await tester.pumpWidget(
        app('<p>Plot: <span data-mx-spoiler="ending">Alice wins</span>.</p>'),
      );

      final concealed = spanWithText(tester, 'Alice wins');
      expect(concealed.style?.color?.a, 0);
      expect(concealed.style?.backgroundColor, isNotNull);
      expect(concealed.recognizer, isA<TapGestureRecognizer>());
      expect(spanWithText(tester, 'ending ').style?.color?.a, greaterThan(0));

      (concealed.recognizer! as TapGestureRecognizer).onTap!();
      await tester.pump();

      final revealed = spanWithText(tester, 'Alice wins');
      expect(revealed.style?.color, Colors.white);
      expect(revealed.style?.backgroundColor, isNull);
      expect(revealed.recognizer, isNull);
    });
  });

  group('alignment', () {
    testWidgets('aligned paragraphs render with the matching textAlign', (
      tester,
    ) async {
      await tester.pumpWidget(
        app(
          '<p align="center">middle</p>'
          '<p align="right">right</p>'
          '<div align="center">div middle</div>'
          '<center>legacy center</center>',
        ),
      );

      expect(tester.takeException(), isNull);
      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      TextAlign? alignOf(String text) => richTexts
          .where((rich) => rich.text.toPlainText().contains(text))
          .map((rich) => rich.textAlign)
          .firstOrNull;
      expect(alignOf('middle'), TextAlign.center);
      expect(alignOf('right'), TextAlign.right);
      expect(alignOf('div middle'), TextAlign.center);
      expect(alignOf('legacy center'), TextAlign.center);
    });

    testWidgets('table column alignment reaches the cells', (tester) async {
      await tester.pumpWidget(
        app(
          '<table><thead><tr><th align="center">h</th></tr></thead>'
          '<tbody><tr><td align="right">v</td></tr></tbody></table>',
        ),
      );

      expect(tester.takeException(), isNull);
      final richTexts = tester
          .widgetList<RichText>(find.byType(RichText))
          .toList();
      expect(
        richTexts
            .firstWhere((rich) => rich.text.toPlainText().contains('h'))
            .textAlign,
        TextAlign.center,
      );
      expect(
        richTexts
            .firstWhere((rich) => rich.text.toPlainText().contains('v'))
            .textAlign,
        TextAlign.right,
      );
    });

    testWidgets('table frame hugs the content in a stretched bubble column', (
      tester,
    ) async {
      // The trailing-metadata path renders blocks in a full-width stretch
      // column; the bordered frame must still wrap the table's intrinsic
      // width instead of spanning the column.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            home: const Scaffold(
              body: MatrixHtmlMessage(
                html:
                    '<table><thead><tr><th>能力</th><th>状态</th></tr></thead>'
                    '<tbody><tr><td>Shell</td><td>ok</td></tr></tbody></table>',
                style: TextStyle(fontSize: 15, color: Colors.white),
                accentColor: Colors.cyan,
                trailingMetadata: Text('12:34'),
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final frame = tester
          .widgetList<Container>(find.byType(Container))
          .firstWhere(
            (container) =>
                container.decoration is BoxDecoration &&
                (container.decoration! as BoxDecoration).border != null,
          );
      final frameWidth = tester.getSize(find.byWidget(frame)).width;
      final tableWidth = tester.getSize(find.byType(Table)).width;
      // The frame adds exactly its 1px border on each side.
      expect(frameWidth, closeTo(tableWidth + 2, 1));
    });
  });

  group('horizontal rules', () {
    testWidgets('hr ignores the app divider theme indent', (tester) async {
      // The app-wide DividerTheme uses indent: 72 for settings-style list
      // separators; a markdown rule must stay full-width under it.
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: ThemeData(
              dividerTheme: const DividerThemeData(
                color: Colors.grey,
                thickness: 0.5,
                indent: 72,
              ),
            ),
            home: const Scaffold(
              body: MatrixHtmlMessage(
                html: '<h2>title</h2><hr>',
                style: TextStyle(fontSize: 15, color: Colors.white),
                accentColor: Colors.cyan,
              ),
            ),
          ),
        ),
      );

      expect(tester.takeException(), isNull);
      final divider = tester.widget<Divider>(find.byType(Divider));
      expect(divider.indent, 0);
      expect(divider.endIndent, 0);
      expect(divider.thickness, 1);
      expect(
        tester.getTopLeft(find.byType(Divider)).dx,
        tester.getTopLeft(find.text('title', findRichText: true)).dx,
      );
    });
  });

  group('images', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    testWidgets('image blocks fall back to alt text when unloading', (
      tester,
    ) async {
      // mxc sources need the Rust bridge to resolve; in tests that call
      // fails, so the widget deterministically lands on the alt fallback.
      await tester.pumpWidget(
        app('<p><img src="mxc://example.org/cat" alt="a cat"></p>'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('a cat', findRichText: true), findsOneWidget);
    });

    testWidgets('figure captions render below the image', (tester) async {
      await tester.pumpWidget(
        app(
          '<figure><img src="mxc://example.org/a">'
          '<figcaption>a nice caption</figcaption></figure>',
        ),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('a nice caption', findRichText: true), findsOneWidget);
    });

    testWidgets('img title renders as caption', (tester) async {
      await tester.pumpWidget(
        app('<p><img src="mxc://example.org/a" title="the title"></p>'),
      );
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('the title', findRichText: true), findsOneWidget);
    });

    testWidgets('stale image resolution cannot overwrite a newer source', (
      tester,
    ) async {
      final oldResolution = Completer<String?>();
      final newResolution = Completer<String?>();
      Future<String?> resolver(WidgetRef _, String src) =>
          src.endsWith('/old') ? oldResolution.future : newResolution.future;

      await tester.pumpWidget(
        app(
          '<p><img src="mxc://example.org/old" alt="old"></p>',
          imageResolver: resolver,
        ),
      );
      await tester.pump();
      await tester.pumpWidget(
        app(
          '<p><img src="mxc://example.org/new" alt="new"></p>',
          imageResolver: resolver,
        ),
      );

      newResolution.complete('https://example.org/new.png');
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<AuthenticatedImageMessage>(
              find.byType(AuthenticatedImageMessage),
            )
            .imageUrl,
        'https://example.org/new.png',
      );

      oldResolution.complete('https://example.org/old.png');
      await tester.pump();
      await tester.pump();
      expect(
        tester
            .widget<AuthenticatedImageMessage>(
              find.byType(AuthenticatedImageMessage),
            )
            .imageUrl,
        'https://example.org/new.png',
      );
    });
  });
}
