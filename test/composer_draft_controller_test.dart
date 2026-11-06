import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer/composer_draft_controller.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _key = (roomId: '!room:example.org', userId: '@alice:example.org');

class _RustApi implements RustLibApi {
  final pending = <Completer<bool>>[];

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) {
    final request = Completer<bool>();
    pending.add(request);
    return request.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

void main() {
  late _RustApi api;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _RustApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  testWidgets('own draft echoes preserve selection and IME composing range', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    final text = tester.widget<TextField>(find.byType(TextField)).controller!;
    text.value = const TextEditingValue(
      text: 'draft',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 0, end: 3),
    );
    await tester.pump();
    expect(container.read(messageDraftProvider(_key)), 'draft');
    expect(text.selection.baseOffset, 2);
    expect(text.value.composing, const TextRange(start: 0, end: 3));

    container.read(messageDraftProvider(_key).notifier).value = 'external';
    await tester.pump();
    expect(text.text, 'external');
    expect(text.selection.baseOffset, 8);
  });

  testWidgets('an empty matching edit draft wins over stored original', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(messageDraftProvider(_key).notifier).value = 'plain';
    container.read(editingDraftProvider(_key).notifier).value = (
      editingId: 'edit',
      text: '',
    );
    container.read(editingMessageProvider(_key).notifier).value = _message(
      'edit',
    );
    await tester.pumpWidget(_app(container));
    await tester.pump();
    expect(_text(tester), '');
    expect(api.pending, isEmpty);
    expect(container.read(messageDraftProvider(_key)), 'plain');
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });

  testWidgets('an old prefill cannot overwrite a newly selected edit', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(_app(container));
    container.read(editingMessageProvider(_key).notifier).value = _message(
      'old',
    );
    await tester.pump();
    expect(api.pending, hasLength(1));
    container.read(editingMessageProvider(_key).notifier).value = _message(
      'new',
    );
    await tester.pump();
    expect(api.pending, hasLength(2));
    api.pending.last.complete(false);
    await tester.pumpAndSettle();
    expect(_text(tester), 'new original');
    api.pending.first.complete(false);
    await tester.pumpAndSettle();
    expect(_text(tester), 'new original');
    expect(container.read(editingDraftProvider(_key))?.editingId, 'new');
  });

  testWidgets('cancelling a pending prefill restores the ordinary draft', (
    tester,
  ) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    container.read(messageDraftProvider(_key).notifier).value = 'plain';
    await tester.pumpWidget(_app(container));
    container.read(editingMessageProvider(_key).notifier).value = _message(
      'edit',
    );
    await tester.pump();
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isFalse);
    container.read(editingMessageProvider(_key).notifier).value = null;
    await tester.pump();
    api.pending.single.complete(false);
    await tester.pumpAndSettle();
    expect(_text(tester), 'plain');
    expect(container.read(messageDraftProvider(_key)), 'plain');
    expect(container.read(editingDraftProvider(_key)), isNull);
    expect(tester.widget<TextField>(find.byType(TextField)).enabled, isTrue);
  });
}

String _text(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.text;

rust.ChatMessage _message(String id) => rust.ChatMessage(
  id: id,
  senderId: _key.userId,
  senderName: 'Alice',
  content: '$id original',
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '1',
  isMe: true,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

Widget _app(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: const MaterialApp(home: Scaffold(body: _Editor())),
);

class _Editor extends ConsumerStatefulWidget {
  const _Editor();

  @override
  ConsumerState<_Editor> createState() => _EditorState();
}

class _EditorState extends ConsumerState<_Editor> {
  final text = TextEditingController();
  late final ComposerDraftController drafts;

  @override
  void initState() {
    super.initState();
    drafts = ComposerDraftController(
      ref: ref,
      draftKey: _key,
      textController: text,
      onTextRestored: () => setState(() {}),
      onEditingCancelled: () {},
      onTextChanged: _save,
    );
    drafts.restoreInitialText();
    text.addListener(_save);
  }

  void _save() => drafts.saveText();

  @override
  Widget build(BuildContext context) {
    drafts.synchronize(ref.watch(editingMessageProvider(_key)));
    return TextField(controller: text, enabled: !drafts.isSourceLoading);
  }

  @override
  void dispose() {
    drafts.dispose();
    text.removeListener(_save);
    text.dispose();
    super.dispose();
  }
}
