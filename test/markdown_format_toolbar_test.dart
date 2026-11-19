import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/markdown/markdown_format_toolbar.dart';

TextEditingValue _selected(String text, int start, int end) => TextEditingValue(
  text: text,
  selection: TextSelection(baseOffset: start, extentOffset: end),
);

void main() {
  group('toggleMarkdownWrap', () {
    test('wraps and unwraps selections with each supported marker', () {
      for (final marker in ['**', '*', '~~', '||']) {
        final result = toggleMarkdownWrap(
          _selected('hello world', 6, 11),
          marker,
        );
        expect(result.text, 'hello ${marker}world$marker', reason: marker);
        expect(result.selection.baseOffset, 6 + marker.length);
        expect(result.selection.extentOffset, 11 + marker.length);
        final unwrapped = toggleMarkdownWrap(result, marker);
        expect(unwrapped.text, 'hello world');
        expect(unwrapped.selection, _selected('hello world', 6, 11).selection);
      }
    });

    test('removes markers included in the selection itself', () {
      final result = toggleMarkdownWrap(
        _selected('hello **world**', 6, 15),
        '**',
      );
      expect(result.text, 'hello world');
      expect(result.selection.baseOffset, 6);
      expect(result.selection.extentOffset, 11);
    });

    test('inserts a marker pair around a collapsed cursor', () {
      final result = toggleMarkdownWrap(
        const TextEditingValue(
          text: 'hello ',
          selection: TextSelection.collapsed(offset: 6),
        ),
        '**',
      );
      expect(result.text, 'hello ****');
      expect(result.selection.baseOffset, 8);
      expect(result.selection.isCollapsed, isTrue);
    });

    test('keeps leading/trailing whitespace outside the markers', () {
      final result = toggleMarkdownWrap(_selected('a world b', 1, 8), '**');
      expect(result.text, 'a **world** b');
      expect(result.selection.baseOffset, 4);
      expect(result.selection.extentOffset, 9);
    });

    test('selection covering only whitespace is left unchanged', () {
      final result = toggleMarkdownWrap(_selected('a   b', 1, 4), '**');
      expect(result.text, 'a   b');
    });

    test('invalid selection is left unchanged', () {
      const value = TextEditingValue(text: 'hello');
      expect(toggleMarkdownWrap(value, '**').text, 'hello');
    });

    test('italic on bold text adds italic instead of stripping bold', () {
      final result = toggleMarkdownWrap(_selected('**bold**', 2, 6), '*');
      expect(result.text, '***bold***');
      expect(result.selection.baseOffset, 3);
      expect(result.selection.extentOffset, 7);
    });

    test('italic on a fully selected bold span wraps instead of stripping', () {
      final result = toggleMarkdownWrap(_selected('**bold**', 0, 8), '*');
      expect(result.text, '***bold***');
      expect(result.selection.baseOffset, 1);
      expect(result.selection.extentOffset, 9);
    });

    test('bold on italic text still stacks', () {
      final result = toggleMarkdownWrap(_selected('*italic*', 1, 7), '**');
      expect(result.text, '***italic***');
    });

    test('bold toggles off a fully selected bold span', () {
      final result = toggleMarkdownWrap(_selected('**bold**', 0, 8), '**');
      expect(result.text, 'bold');
    });

    test('a selection holding only the marker pair still unwraps', () {
      final result = toggleMarkdownWrap(_selected('a **** b', 2, 6), '**');
      expect(result.text, 'a  b');
    });

    test('removes bold from a partial selection without crossing markers', () {
      final result = toggleMarkdownWrap(
        _selected('**hello world**', 2, 7),
        '**',
      );
      expect(result.text, 'hello **world**');
      expect(
        result.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
    });

    test('splits a formatted span around a middle selection', () {
      final result = toggleMarkdownWrap(
        _selected('**hello wide world**', 8, 12),
        '**',
      );
      expect(result.text, '**hello** wide **world**');
      expect(
        result.selection,
        const TextSelection(baseOffset: 10, extentOffset: 14),
      );
    });

    test('removes one style from a combined bold italic span', () {
      final withoutBold = toggleMarkdownWrap(
        _selected('***both***', 3, 7),
        '**',
      );
      expect(withoutBold.text, '*both*');
      expect(
        withoutBold.selection,
        const TextSelection(baseOffset: 1, extentOffset: 5),
      );

      final withoutItalic = toggleMarkdownWrap(
        _selected('***both***', 3, 7),
        '*',
      );
      expect(withoutItalic.text, '**both**');
      expect(
        withoutItalic.selection,
        const TextSelection(baseOffset: 2, extentOffset: 6),
      );
    });

    test('removes one style from part of a combined span', () {
      final result = toggleMarkdownWrap(
        _selected('***hello world***', 3, 8),
        '**',
      );
      expect(result.text, '*hello* ***world***');
      expect(
        result.selection,
        const TextSelection(baseOffset: 1, extentOffset: 6),
      );
    });

    test('does not apply a multiline spoiler', () {
      final value = _selected('first\nsecond', 0, 12);
      expect(toggleMarkdownWrap(value, '||'), value);
    });

    test('does not generate delimiters Markdown will treat as literal', () {
      final value = _selected('a"quoted"', 1, 9);
      expect(toggleMarkdownWrap(value, '*'), value);
      expect(toggleMarkdownWrap(value, '**'), value);
    });

    test('does not split a formatted span into invalid punctuation runs', () {
      final value = _selected('**"hello"**', 3, 8);
      expect(toggleMarkdownWrap(value, '**'), value);
    });
  });

  group('markdownWrapActive', () {
    test('is active inside each supported marker', () {
      for (final marker in ['**', '*', '~~', '||']) {
        expect(
          markdownWrapActive(
            _selected(
              '${marker}world$marker',
              marker.length,
              5 + marker.length,
            ),
            marker,
          ),
          isTrue,
          reason: marker,
        );
      }
    });

    test('is active for a selection that includes the markers', () {
      expect(
        markdownWrapActive(_selected('hello **world**', 6, 15), '**'),
        isTrue,
      );
    });

    test('is inactive for unwrapped text', () {
      expect(
        markdownWrapActive(_selected('hello world', 6, 11), '**'),
        isFalse,
      );
    });

    test('is inactive for a collapsed selection', () {
      const value = TextEditingValue(
        text: '**world**',
        selection: TextSelection.collapsed(offset: 5),
      );
      expect(markdownWrapActive(value, '**'), isFalse);
    });

    test('italic is inactive inside bold markers (pressing would stack)', () {
      expect(markdownWrapActive(_selected('**bold**', 2, 6), '*'), isFalse);
    });

    test('is active for a partial selection inside formatted text', () {
      expect(
        markdownWrapActive(_selected('**hello world**', 2, 7), '**'),
        isTrue,
      );
    });

    test('bold and italic are active inside a combined span', () {
      final value = _selected('***both***', 3, 7);
      expect(markdownWrapActive(value, '**'), isTrue);
      expect(markdownWrapActive(value, '*'), isTrue);
    });

    test('escaped markers are inactive but markers after two slashes work', () {
      expect(
        markdownWrapActive(_selected(r'\**literal**', 3, 10), '**'),
        isFalse,
      );
      expect(markdownWrapActive(_selected(r'\\**bold**', 4, 8), '**'), isTrue);
    });
  });

  group('markdownSelectionContextMenuBuilder', () {
    Future<EditableTextState> showToolbar(
      WidgetTester tester,
      TextEditingController controller,
      TextSelection selection, {
      bool readOnly = false,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TextField(
              controller: controller,
              readOnly: readOnly,
              contextMenuBuilder: markdownSelectionContextMenuBuilder,
            ),
          ),
        ),
      );
      // The selection overlay only exists once the field has focus, so tap
      // first and apply the selection afterwards.
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();
      controller.selection = selection;
      await tester.pumpAndSettle();
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      state.showToolbar();
      await tester.pumpAndSettle();
      return state;
    }

    testWidgets('omits format buttons when the field is read-only', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await showToolbar(
        tester,
        controller,
        const TextSelection(baseOffset: 0, extentOffset: 5),
        readOnly: true,
      );
      for (final format in markdownToolbarFormats) {
        expect(find.text(format.label), findsNothing);
      }
    });

    testWidgets('format buttons are available and wrap the selected text', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello world');
      addTearDown(controller.dispose);
      await showToolbar(
        tester,
        controller,
        const TextSelection(baseOffset: 6, extentOffset: 11),
      );
      for (final format in markdownToolbarFormats) {
        expect(find.text(format.label), findsOneWidget);
      }
      await tester.tap(find.text('加粗'));
      await tester.pumpAndSettle();
      expect(controller.text, 'hello **world**');
    });

    testWidgets('shows the remove label for an already formatted selection', (
      tester,
    ) async {
      final controller = TextEditingController(text: 'hello **world**');
      addTearDown(controller.dispose);
      await showToolbar(
        tester,
        controller,
        const TextSelection(baseOffset: 8, extentOffset: 13),
      );
      expect(find.text('取消加粗'), findsOneWidget);
      expect(find.text('加粗'), findsNothing);
      expect(find.text('斜体'), findsOneWidget);

      await tester.tap(find.text('取消加粗'));
      await tester.pumpAndSettle();
      expect(controller.text, 'hello world');
    });

    testWidgets('omits spoiler for a multiline selection', (tester) async {
      final controller = TextEditingController(text: 'first\nsecond');
      addTearDown(controller.dispose);
      await showToolbar(
        tester,
        controller,
        const TextSelection(baseOffset: 0, extentOffset: 12),
      );
      expect(find.text('剧透'), findsNothing);
      expect(find.text('加粗'), findsOneWidget);
    });

    testWidgets('omits formatting inside a link destination', (tester) async {
      final controller = TextEditingController(
        text: '[label](https://host/path)',
      );
      addTearDown(controller.dispose);
      await showToolbar(
        tester,
        controller,
        const TextSelection(baseOffset: 21, extentOffset: 25),
      );
      for (final format in markdownToolbarFormats) {
        expect(find.text(format.label), findsNothing);
      }
    });
  });
}
