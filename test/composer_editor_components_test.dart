import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer/composer_autocomplete_popup.dart';
import 'package:matter/pages/chat/composer/composer_text_field.dart';
import 'package:matter/pages/chat/composer_autocomplete.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

void main() {
  test('mention candidates prioritize prefixes and keep the 50-item bound', () {
    final options = composerAutocompleteOptions(
      const ComposerAutocompleteMatch(
        kind: ComposerAutocompleteKind.mention,
        start: 0,
        end: 3,
        query: 'al',
      ),
      members: [
        _contact('xal'),
        ...List.generate(
          60,
          (index) => _contact('al${index.toString().padLeft(2, '0')}'),
        ),
      ],
    );
    expect(options, hasLength(50));
    expect(options.first.title, 'al00');
    expect(options.last.title, 'al49');
    expect(options.first.insertion, '@al00:example.org ');
    expect(options.any((option) => option.title == 'xal'), isFalse);
  });

  test('room candidates filter membership and escape markdown labels', () {
    final options = composerAutocompleteOptions(
      const ComposerAutocompleteMatch(
        kind: ComposerAutocompleteKind.room,
        start: 0,
        end: 1,
        query: '',
      ),
      rooms: [
        _room('A[room]'),
        _room('Hidden space', type: 'space'),
        _room('Left', state: 'left'),
      ],
    );
    expect(options, hasLength(1));
    expect(options.single.title, '#A[room]');
    expect(
      options.single.insertion,
      '[#A\\[room\\]](https://matrix.to/#/!room%3Aexample.org) ',
    );
  });

  for (final material in [false, true]) {
    for (final brightness in Brightness.values) {
      final label = '${material ? 'Material' : 'Neu'} $brightness';
      testWidgets(
        '$label editor keeps geometry and controller across rebuild',
        (tester) async {
          final text = TextEditingController(text: 'hello');
          final focus = FocusNode();
          final boundary = GlobalKey();
          addTearDown(text.dispose);
          addTearDown(focus.dispose);
          final theme = material
              ? buildMaterialTheme(brightness)
              : buildNeuTheme(
                  brightness == Brightness.dark
                      ? NeuColors.dark
                      : NeuColors.light,
                  brightness,
                );
          Future<void> pump({bool readOnly = false}) => tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: Scaffold(
                body: Align(
                  alignment: Alignment.bottomCenter,
                  child: SizedBox(
                    width: 320,
                    child: ComposerTextField(
                      key: boundary,
                      controller: text,
                      focusNode: focus,
                      expanded: false,
                      compact: false,
                      readOnly: readOnly,
                      onTap: () {},
                    ),
                  ),
                ),
              ),
            ),
          );
          await pump();
          final before = tester.getRect(find.byKey(boundary));
          expect(before.width, 320);
          expect(before.height, greaterThanOrEqualTo(44));
          expect(boundary.currentContext!.findRenderObject(), isA<RenderBox>());
          final field = tester.widget<TextField>(find.byType(TextField));
          expect(field.controller, same(text));
          expect(field.focusNode, same(focus));
          await pump(readOnly: true);
          expect(
            tester.widget<TextField>(find.byType(TextField)).readOnly,
            isTrue,
          );
          expect(tester.getRect(find.byKey(boundary)), before);
          expect(text.text, 'hello');
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}

rust.Contact _contact(String name) =>
    rust.Contact(id: '@$name:example.org', name: name, status: '');

rust.ChatRoom _room(
  String name, {
  String type = 'group',
  String state = 'joined',
}) => rust.ChatRoom(
  id: '!room:example.org',
  name: name,
  lastMessage: '',
  lastMessageTime: '',
  lastEventId: '',
  unreadCount: 0,
  isMarkedUnread: false,
  roomType: type,
  isEncrypted: false,
  isMuted: false,
  roomState: state,
);
