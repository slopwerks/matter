import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_text_editing_controller.dart';

void main() {
  Future<TextSpan> renderSpan(
    WidgetTester tester,
    MarkdownTextEditingController controller, {
    bool withComposing = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: TextField(controller: controller)),
      ),
    );
    return controller.buildTextSpan(
      context: tester.element(find.byType(EditableText)),
      style: const TextStyle(color: Colors.black),
      withComposing: withComposing,
    );
  }

  testWidgets('renders plain text without extra spans', (tester) async {
    final controller = MarkdownTextEditingController(text: 'hello world');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);
    expect(span.toPlainText(), 'hello world');
    expect(span.children, isNull);
  });

  testWidgets('dims bold markers and bolds the content', (tester) async {
    final controller = MarkdownTextEditingController(text: 'a **b** c');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);
    expect(span.toPlainText(), 'a **b** c');

    final children = span.children!;
    expect(children.map((s) => s.toPlainText()), ['a ', '**', 'b', '**', ' c']);
    expect(children[2].style!.fontWeight, FontWeight.bold);
    expect(
      children[1].style!.color!.a,
      lessThan((children[0].style?.color ?? span.style!.color!).a),
    );
  });

  testWidgets('renders italic, strikethrough and spoiler spans', (
    tester,
  ) async {
    final controller = MarkdownTextEditingController(text: '*i* ~~s~~ ||p||');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);
    expect(span.toPlainText(), '*i* ~~s~~ ||p||');

    final children = span.children!;
    expect(children.map((s) => s.toPlainText()), [
      '*',
      'i',
      '*',
      ' ',
      '~~',
      's',
      '~~',
      ' ',
      '||',
      'p',
      '||',
    ]);
    expect(children[1].style!.fontStyle, FontStyle.italic);
    expect(children[5].style!.decoration, TextDecoration.lineThrough);
    expect(children[9].style!.backgroundColor, isNotNull);
  });

  testWidgets('keeps the text value untouched', (tester) async {
    final controller = MarkdownTextEditingController(text: 'a **b** c');
    addTearDown(controller.dispose);
    await renderSpan(tester, controller);
    expect(controller.text, 'a **b** c');
  });

  testWidgets('combines nested bold and italic styles', (tester) async {
    final controller = MarkdownTextEditingController(text: '***both***');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    final content = span.children!.firstWhere(
      (child) => child.toPlainText() == 'both',
    );
    expect(content.style!.fontWeight, FontWeight.bold);
    expect(content.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('combines styles when nested delimiters close together', (
    tester,
  ) async {
    for (final source in ['**outer *inner***', '*outer **inner***']) {
      final controller = MarkdownTextEditingController(text: source);
      addTearDown(controller.dispose);
      final span = await renderSpan(tester, controller);
      final content = span.children!.firstWhere(
        (child) => child.toPlainText() == 'inner',
      );
      expect(content.style!.fontWeight, FontWeight.bold, reason: source);
      expect(content.style!.fontStyle, FontStyle.italic, reason: source);
    }
  });

  testWidgets('renders formatting across a soft line break', (tester) async {
    final controller = MarkdownTextEditingController(text: '**first\nsecond**');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    final content = span.children!.firstWhere(
      (child) => child.toPlainText() == 'first\nsecond',
    );
    expect(content.style!.fontWeight, FontWeight.bold);
  });

  testWidgets('matches spoiler whitespace and newline rules', (tester) async {
    final controller = MarkdownTextEditingController(
      text: '|| hidden || ||first\nsecond||',
    );
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    final hidden = span.children!.firstWhere(
      (child) => child.toPlainText() == ' hidden ',
    );
    expect(hidden.style!.backgroundColor, isNotNull);
    final multiline = span.children!.firstWhere(
      (child) => child.toPlainText().contains('first\nsecond'),
    );
    expect(multiline.style?.backgroundColor, isNull);
  });

  testWidgets('does not style code, escapes, or whitespace-delimited stars', (
    tester,
  ) async {
    final controller = MarkdownTextEditingController(
      text: r'`**code**` \*literal\* * hello *',
    );
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    expect(span.children, isNull);
  });

  testWidgets('honors the exact backtick run around inline code', (
    tester,
  ) async {
    final controller = MarkdownTextEditingController(
      text: '``one ` **code**``',
    );
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    expect(span.children, isNull);
  });

  testWidgets('does not style fenced code or link destinations', (
    tester,
  ) async {
    final controller = MarkdownTextEditingController(
      text: '~~~\n**code**\n~~~\n[label](https://host/**path**)',
    );
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    expect(span.children, isNull);
  });

  testWidgets('honors punctuation flanking rules for emphasis', (tester) async {
    final controller = MarkdownTextEditingController(text: 'a*"plain"* *"em"*');
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller);

    final plain = span.children!.firstWhere(
      (child) => child.toPlainText().contains('a*"plain"*'),
    );
    expect(plain.style?.fontStyle, isNull);
    final emphasized = span.children!.firstWhere(
      (child) => child.toPlainText() == '"em"',
    );
    expect(emphasized.style!.fontStyle, FontStyle.italic);
  });

  testWidgets('preserves styles around an IME composing range', (tester) async {
    final controller = MarkdownTextEditingController(text: '**bold**');
    controller.value = controller.value.copyWith(
      composing: const TextRange(start: 3, end: 5),
    );
    addTearDown(controller.dispose);
    final span = await renderSpan(tester, controller, withComposing: true);

    final boldParts = span.children!.where(
      (child) => child.toPlainText().contains(RegExp('[bold]')),
    );
    expect(boldParts, isNotEmpty);
    for (final part in boldParts) {
      expect(part.style!.fontWeight, FontWeight.bold);
    }
  });
}
