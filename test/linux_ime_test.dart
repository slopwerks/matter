import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:matter/pages/chat/composer/composer_keyboard_controller.dart';
import 'package:matter/providers/composer_keyboard_settings_provider.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/composer/composer_text_field.dart';
import 'package:matter/pages/chat/composer/linux_ime_model.dart';
import 'package:matter/theme/material_theme.dart';

void main() {
  test('middle preedit updates atomically, commits once and keeps suffix', () {
    final model = LinuxImeModel(
      const TextEditingValue(
        text: 'left right',
        selection: TextSelection.collapsed(offset: 5),
      ),
    );
    model.preedit('n', 1);
    model.preedit('ni', 2);
    expect(model.value.text, 'left niright');
    expect(model.value.composing, const TextRange(start: 5, end: 7));
    model.commit('你');
    model.cancel();
    expect(model.value.text, 'left 你right');
    expect(model.value.selection.extentOffset, 6);
    expect(model.value.composing, TextRange.empty);
  });
  test(
    'cancel restores reversed selection; empty preedit can still commit',
    () {
      const before = TextEditingValue(
        text: 'A😀B',
        selection: TextSelection(baseOffset: 3, extentOffset: 1),
      );
      final model = LinuxImeModel(before);
      model.preedit('😀ni', 2);
      expect(model.value.selection.extentOffset, 4);
      model.cancel();
      expect(model.value, before);
      model.preedit('ni', 2);
      model.preedit('', 0);
      model.commit('你');
      expect(model.value.text, 'A你B');
    },
  );
  test('external edits win over cancellation and scalar surrounding deletion is safe', () {
    final model = LinuxImeModel(
      const TextEditingValue(
        text: 'A😀中B',
        selection: TextSelection.collapsed(offset: 4),
      ),
    );
    expect(model.deleteSurrounding(-2, 1), isTrue);
    expect(model.value.text, 'A中B');
    expect(model.value.selection.extentOffset, 2);
    expect(model.deleteSurrounding(-9, 1), isFalse);
    model.preedit('ni', 2);
    model.synchronize(
      const TextEditingValue(
        text: 'new draft',
        selection: TextSelection.collapsed(offset: 0),
      ),
    );
    model.cancel();
    expect(model.value.text, 'new draft');
  });

  test('surrounding deletion during preedit survives cancel with reversed selection', () {
    final model = LinuxImeModel(
      const TextEditingValue(
        text: 'A😀BC',
        selection: TextSelection(baseOffset: 4, extentOffset: 3),
      ),
    );
    model.preedit('ni', 2);
    expect(model.deleteSurrounding(-3, 1), true);
    model.cancel();
    expect(
      model.value,
      const TextEditingValue(
        text: 'ABC',
        selection: TextSelection(baseOffset: 2, extentOffset: 1),
      ),
    );
  });

  test('empty preedit must not erase selected committed text', () {
    const original = TextEditingValue(
      text: 'already written',
      selection: TextSelection(baseOffset: 15, extentOffset: 0),
    );
    final model = LinuxImeModel(original);
    model.start();
    model.preedit('', 0);
    expect(model.value, original);
    model.commit('replacement');
    expect(model.value.text, 'replacement');
  });

  test(
    'surrounding deletion before first preedit is not resurrected on cancel',
    () {
      final model = LinuxImeModel(
        const TextEditingValue(
          text: 'ABC',
          selection: TextSelection.collapsed(offset: 2),
        ),
      );
      model.start();
      expect(model.deleteSurrounding(-1, 1), true);
      expect(model.value.text, 'AC');
      model.preedit('n', 1);
      model.cancel();
      expect(
        model.value,
        const TextEditingValue(
          text: 'AC',
          selection: TextSelection.collapsed(offset: 1),
        ),
      );
    },
  );

  const channel = MethodChannel('moe.aks.matter/linux_ime');
  final calls = <MethodCall>[];
  late TextEditingController controller;
  late FocusNode focus;
  String? clipboard;

  setUp(() {
    calls.clear();
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'Clipboard.setData') {
            clipboard = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': clipboard};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': clipboard != null};
          }
          return null;
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
    controller = TextEditingController();
    focus = FocusNode();
  });
  tearDown(() {
    controller.dispose();
    focus.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    TextInput.restorePlatformInputControl();
    debugDefaultTargetPlatformOverride = null;
  });
  Future<void> pump(WidgetTester tester, {bool readOnly = false}) async {
    if (debugDefaultTargetPlatformOverride == null) {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
    }
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMaterialTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              ComposerTextField(
                controller: controller,
                focusNode: focus,
                expanded: false,
                compact: false,
                readOnly: readOnly,
                onTap: () {},
              ),
              const TextField(key: Key('other')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
  }

  int epoch() =>
      (calls
                  .lastWhere(
                    (c) =>
                        c.method == 'focus' &&
                        (c.arguments as Map)['active'] == true,
                  )
                  .arguments
              as Map)['epoch']
          as int;
  Future<void> event(
    WidgetTester tester,
    String type, {
    int? session,
    String? text,
    int cursor = 0,
  }) async {
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
      channel.name,
      const StandardMethodCodec().encodeMethodCall(
        MethodCall('event', {
          'epoch': session ?? epoch(),
          'type': type,
          'text': text,
          'cursor': cursor,
        }),
      ),
      (_) {},
    );
    await tester.pump();
  }

  testWidgets(
    'real composer remains editable; preedit, stale epoch, caret and loading',
    (tester) async {
      controller.value = const TextEditingValue(
        text: 'A😀B',
        selection: TextSelection.collapsed(offset: 3),
      );
      await pump(tester);
      focus.requestFocus();
      await tester.pump();
      await tester.pump();
      expect(calls.where((c) => c.method == 'focus'), isNotEmpty);
      final oldEpoch = epoch();
      final state =
          calls.lastWhere((c) => c.method == 'state').arguments as Map;
      expect(state['cursor'], 5); // UTF-8 bytes, not UTF-16.
      expect(calls.where((c) => c.method == 'cursor'), isNotEmpty);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).readOnly,
        isFalse,
      );
      await event(tester, 'preedit', text: 'ni', cursor: 2);
      expect(controller.text, 'A😀niB');
      controller.selection = const TextSelection.collapsed(offset: 0);
      await tester.pump();
      expect(epoch(), greaterThan(oldEpoch));
      await event(tester, 'commit', session: oldEpoch, text: '你');
      expect(controller.text, 'A😀niB');
      await event(tester, 'commit', text: '新');
      expect(controller.text, '新A😀niB');
      await event(tester, 'preedit', text: 'test', cursor: 4);
      await event(tester, 'blur');
      expect(controller.text, '新A😀niB');
      await pump(tester, readOnly: true);
      final before = controller.value;
      await event(tester, 'commit', session: oldEpoch, text: '坏');
      expect(controller.value, before);
      expect(
        (calls.lastWhere((c) => c.method == 'focus').arguments
            as Map)['active'],
        false,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('selection survives empty GTK preedit and remains replaceable', (
    tester,
  ) async {
    controller.text = 'already written';
    await pump(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    final selected = controller.value;
    await event(tester, 'start');
    await event(tester, 'preedit', text: '', cursor: 0);
    expect(controller.value, selected);
    await event(tester, 'end');
    expect(controller.value, selected);
    await event(tester, 'preedit', text: 'ni', cursor: 2);
    await event(tester, 'preedit', text: '', cursor: 0);
    expect(controller.value, selected);
    await event(tester, 'commit', text: '你');
    expect(controller.text, '你');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'existing Flutter shortcuts, clipboard, undo, focus handover and disposal',
    (tester) async {
      await pump(tester);
      focus.requestFocus();
      await tester.pump();
      await tester.pump();
      await event(tester, 'commit', text: 'hello');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(
        controller.selection,
        const TextSelection(baseOffset: 0, extentOffset: 5),
      );
      expect(clipboard, 'hello');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyX);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.text, '');
      await tester.pump(const Duration(milliseconds: 600));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyZ);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(controller.text, 'hello');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      expect(controller.selection.isCollapsed, true);
      clipboard = 'paste';
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.text, contains('paste'));
      final previous = epoch();
      await tester.tap(find.byKey(const Key('other')));
      await tester.pump();
      expect(focus.hasFocus, false);
      await event(tester, 'commit', session: previous, text: 'stale');
      expect(controller.text, isNot(contains('stale')));
      tester.testTextInput.enterText('other works');
      await tester.pump();
      final other = tester.state<EditableTextState>(
        find.descendant(
          of: find.byKey(const Key('other')),
          matching: find.byType(EditableText),
        ),
      );
      expect(other.textEditingValue.text, 'other works');
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('focused remount and disposal cancel only the owning editor', (
    tester,
  ) async {
    await pump(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    await event(tester, 'commit', text: 'base');
    await event(tester, 'preedit', text: 'ni', cursor: 2);
    await tester.pumpWidget(const SizedBox());
    expect(controller.text, 'base');
    await pump(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(
      (calls.lastWhere((c) => c.method == 'focus').arguments as Map)['active'],
      true,
    );
    await event(tester, 'commit', text: 'new');
    expect(controller.text, 'basenew');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'Linux bridge keeps composer Enter settings, image paste routing and autocomplete',
    (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      SharedPreferences.setMockInitialValues({});
      final container = ProviderContainer();
      addTearDown(container.dispose);
      var pasted = 0;
      var sent = 0;
      late ComposerKeyboardController keyboard;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              return MaterialApp(
                theme: buildMaterialTheme(Brightness.light),
                home: Builder(
                  builder: (context) {
                    keyboard = ComposerKeyboardController(
                      ref: ref,
                      roomId: '!test:example.org',
                      text: controller,
                      focus: focus,
                      context: () => context,
                      isMounted: () => true,
                      keyboardMouse: () => true,
                      onChanged: () {},
                      onPaste: (_) async {
                        pasted++;
                      },
                      onSend: () async {
                        sent++;
                      },
                      onStickerSelected: (_) {},
                    );
                    keyboard.initialize();
                    focus.onKeyEvent = keyboard.handleKey;
                    return Scaffold(
                      body: ComposerTextField(
                        controller: controller,
                        focusNode: focus,
                        expanded: false,
                        compact: false,
                        readOnly: false,
                        onTap: () {},
                      ),
                    );
                  },
                ),
              );
            },
          ),
        ),
      );
      focus.requestFocus();
      await tester.pump();
      await tester.pump();
      await event(tester, 'preedit', text: 'ni', cursor: 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, 0);
      await event(tester, 'commit', text: '你');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(pasted, 1);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      expect(controller.text, '你\n');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(sent, 1);
      await container
          .read(composerKeyboardSettingsProvider.notifier)
          .setAction(ComposerEnterShortcut.enter, ComposerEnterAction.newline);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(controller.text, '你\n\n');
      expect(sent, 1);
      controller.value = const TextEditingValue(
        text: ':thinking',
        selection: TextSelection.collapsed(offset: 9),
      );
      keyboard.textChanged();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      expect(controller.text, '🤔');
      await tester.pumpWidget(const SizedBox());
      keyboard.scroll.dispose();
    },
  );

  testWidgets('readOnly and other platforms never start GTK', (tester) async {
    await pump(tester, readOnly: true);
    focus.requestFocus();
    await tester.pump();
    expect(calls, isEmpty);
    focus.unfocus();
    await tester.pump();
    await pump(tester);
    focus.requestFocus();
    await tester.pump();
    await tester.pump();
    expect(calls.where((call) => call.method == 'focus'), isNotEmpty);
    focus.unfocus();
    await tester.pump();
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await pump(tester);
    focus.requestFocus();
    await tester.pump();
    expect(calls, isEmpty);
    await tester.pumpWidget(const SizedBox());
  });
}
