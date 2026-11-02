import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/pages/settings/composer_keyboard_settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/composer_keyboard_settings_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:matter/widgets/glass.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  Completer<String>? pendingSend;
  int sendCalls = 0;

  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) {
    sendCalls++;
    return (pendingSend ??= Completer<String>()).future;
  }

  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;

  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

LogicalKeyboardKey? _modifier(ComposerEnterShortcut shortcut) =>
    switch (shortcut) {
      ComposerEnterShortcut.enter => null,
      ComposerEnterShortcut.shiftEnter => LogicalKeyboardKey.shiftLeft,
      ComposerEnterShortcut.altEnter => LogicalKeyboardKey.altLeft,
    };

Widget _input(
  ProviderContainer container, {
  bool material = const bool.fromEnvironment('MATTER_TEST_MATERIAL'),
  bool dark = true,
  TargetPlatform platform = TargetPlatform.linux,
}) => UncontrolledProviderScope(
  container: container,
  child: MaterialApp(
    theme: neuTestTheme(
      material: material,
      dark: dark,
    ).copyWith(platform: platform),
    home: Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!keyboard:example.org',
          totalMembers: 2,
          panelMode: InputPanelMode.none,
          pickerHeight: 0,
          pickerFullHeight: 300,
          pickerBaseHeight: 300,
          pickerMaxHeight: 500,
          animatePickerHeight: false,
          onPanelModeChanged: (_) {},
          onPickerHeightChanged: (_) {},
          resolveSendPresentation: () => MessageSendPresentation.quiet,
          onMessageQueued: (_, _) {},
          onMessageSent: (_, _) {},
        ),
      ),
    ),
  ),
);

void main() {
  final api = _FakeRustApi();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    api.pendingSend = null;
    api.sendCalls = 0;
    SharedPreferences.setMockInitialValues({});
  });

  test('persists independent choices across provider containers', () async {
    final first = ProviderContainer();
    final notifier = first.read(composerKeyboardSettingsProvider.notifier);
    for (final shortcut in ComposerEnterShortcut.values) {
      await notifier.setAction(shortcut, ComposerEnterAction.newline);
    }
    await notifier.setAction(
      ComposerEnterShortcut.shiftEnter,
      ComposerEnterAction.send,
    );
    first.dispose();
    final restored = ProviderContainer();
    addTearDown(restored.dispose);
    restored.read(composerKeyboardSettingsProvider);
    await Future<void>.delayed(Duration.zero);
    final settings = restored.read(composerKeyboardSettingsProvider);
    expect(settings.enter, ComposerEnterAction.newline);
    expect(settings.shiftEnter, ComposerEnterAction.send);
    expect(settings.altEnter, ComposerEnterAction.newline);
  });

  test(
    'restoring does not overwrite an early edit or other saved keys',
    () async {
      SharedPreferences.setMockInitialValues({
        'composer_keyboard_enter': 'newline',
        'composer_keyboard_altEnter': 'newline',
        'composer_keyboard_shiftEnter': 'invalid',
      });
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await container
          .read(composerKeyboardSettingsProvider.notifier)
          .setAction(ComposerEnterShortcut.enter, ComposerEnterAction.send);
      final settings = container.read(composerKeyboardSettingsProvider);
      expect(settings.enter, ComposerEnterAction.send);
      expect(settings.shiftEnter, ComposerEnterAction.newline);
      expect(settings.altEnter, ComposerEnterAction.newline);
    },
  );

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      testWidgets(
        'all three settings can change at narrow width ($material, $dark)',
        (tester) async {
          await tester.binding.setSurfaceSize(const Size(320, 720));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final container = ProviderContainer();
          addTearDown(container.dispose);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: neuTestTheme(material: material, dark: dark),
                home: const ComposerKeyboardSettingsPage(),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final shortcut in ComposerEnterShortcut.values) {
            final next = shortcut == ComposerEnterShortcut.shiftEnter
                ? ComposerEnterAction.send
                : ComposerEnterAction.newline;
            await tester.tap(
              find.byKey(ValueKey('composer-key-action-${shortcut.name}')),
            );
            await tester.pumpAndSettle();
            await tester.tap(
              find.text(next == ComposerEnterAction.send ? '发送消息' : '换行').last,
            );
            await tester.pumpAndSettle();
            expect(
              container
                  .read(composerKeyboardSettingsProvider)
                  .actionFor(shortcut),
              next,
            );
            expect(tester.takeException(), isNull);
          }
        },
      );
    }
  }

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      for (final width in [360.0, 960.0]) {
        testWidgets(
          'desktop editor and quick settings retain draft ($material, $dark, $width)',
          (tester) async {
            await tester.binding.setSurfaceSize(Size(width, 600));
            addTearDown(() => tester.binding.setSurfaceSize(null));
            final container = ProviderContainer();
            addTearDown(container.dispose);
            await tester.pumpWidget(
              _input(container, material: material, dark: dark),
            );
            await tester.pumpAndSettle();
            final field = find.byType(TextField);
            final emptyRect = tester.getRect(field);
            final toolbarRect = tester.getRect(
              find.byKey(const ValueKey('desktop-composer-toolbar')),
            );
            expect(emptyRect.height, greaterThanOrEqualTo(80));
            expect(emptyRect.height, lessThan(96));
            expect(find.byType(GlassPanel), findsNothing);
            expect(find.byType(BackdropFilter), findsNothing);
            expect(tester.getSize(find.byType(IconButton).first).height, 32);
            expect(
              tester.widget<TextField>(field).decoration!.border,
              InputBorder.none,
            );
            expect(emptyRect.width, greaterThan(width - 90));
            expect(toolbarRect.top, greaterThanOrEqualTo(emptyRect.bottom));
            await tester.enterText(
              field,
              List.filled(12, 'long draft').join('\n'),
            );
            await tester.pumpAndSettle();
            final expandedRect = tester.getRect(field);
            expect(expandedRect.height, greaterThan(emptyRect.height));
            expect(expandedRect.height, lessThanOrEqualTo(180));
            await tester.enterText(field, 'first\ndraft');
            await tester.tap(find.byTooltip('更多'));
            await tester.pumpAndSettle();
            expect(find.text('Markdown 编辑器'), findsOneWidget);
            await tester.tap(find.text('发送与换行按键'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            await tester.tap(
              find.byKey(const ValueKey('composer-key-action-enter')),
            );
            await tester.pumpAndSettle();
            await tester.tap(find.text('换行').last);
            await tester.pumpAndSettle();
            await tester.tap(find.text('完成'));
            await tester.pumpAndSettle();
            final input = tester.widget<TextField>(field);
            expect(input.controller!.text, 'first\ndraft');
            expect(input.focusNode!.hasFocus, isTrue);
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
            expect(input.controller!.text, 'first\ndraft\n');
            expect(api.sendCalls, 0);
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pumpAndSettle();
          },
        );
      }
    }
  }

  testWidgets('Android keeps the compact editor and attachment tools', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _input(container, platform: TargetPlatform.android),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('desktop-composer-layout')), findsNothing);
    expect(tester.getSize(find.byType(TextField)).height, lessThan(96));
    expect(find.byTooltip('更多'), findsNothing);
    await tester.longPress(find.byIcon(Icons.add_rounded));
    await tester.pumpAndSettle();
    expect(find.text('Markdown 编辑器'), findsOneWidget);
    expect(find.text('发送与换行按键'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final material in [false, true]) {
    testWidgets(
      'tablet rotates into a wide touch editor without losing draft ($material)',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(600, 960);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer();
        addTearDown(container.dispose);
        await tester.pumpWidget(
          _input(
            container,
            material: material,
            platform: TargetPlatform.android,
          ),
        );
        await tester.enterText(find.byType(TextField), 'tablet draft');
        final controller = tester
            .widget<TextField>(find.byType(TextField))
            .controller;
        tester.view.physicalSize = const Size(960, 600);
        await tester.pumpAndSettle();
        final input = tester.widget<TextField>(find.byType(TextField));
        expect(input.controller, same(controller));
        expect(input.controller!.text, 'tablet draft');
        expect(input.focusNode!.hasFocus, isTrue);
        expect(tester.getSize(find.byType(IconButton).first).height, 48);
        expect(
          tester.getSize(find.byType(TextField)).height,
          greaterThanOrEqualTo(96),
        );
        expect(find.byType(GlassPanel), findsNothing);
        await tester.tap(find.byTooltip('更多'));
        await tester.pumpAndSettle();
        expect(find.text('Markdown 编辑器'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  for (final shortcut in ComposerEnterShortcut.values) {
    for (final action in ComposerEnterAction.values) {
      for (final key in [
        LogicalKeyboardKey.enter,
        LogicalKeyboardKey.numpadEnter,
      ]) {
        testWidgets('$shortcut $key performs configured $action immediately', (
          tester,
        ) async {
          final container = ProviderContainer();
          addTearDown(container.dispose);
          container.read(activeUserIdProvider.notifier).value =
              '@alice:example.org';
          await tester.pumpWidget(_input(container));
          final text = action == ComposerEnterAction.newline
              ? ':thinking:'
              : 'send this';
          await tester.enterText(find.byType(TextField), text);
          // Change while the existing input is mounted: no recreation required.
          await container
              .read(composerKeyboardSettingsProvider.notifier)
              .setAction(shortcut, action);
          await tester.pump();
          final modifier = _modifier(shortcut);
          if (modifier != null) await tester.sendKeyDownEvent(modifier);
          await tester.sendKeyEvent(key);
          if (modifier != null) await tester.sendKeyUpEvent(modifier);
          await tester.pump();
          final input = tester.widget<TextField>(find.byType(TextField));
          if (action == ComposerEnterAction.newline) {
            expect(input.controller!.text, '$text\n');
            expect(api.sendCalls, 0);
          } else {
            expect(input.controller!.text, isEmpty);
            expect(api.sendCalls, 1);
            expect(input.focusNode!.hasFocus, isTrue);
            api.pendingSend!.complete(r'$sent');
            await tester.pump();
          }
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 1));
          await tester.pumpAndSettle();
        });
      }
    }

    testWidgets('autocomplete wins over configured send for $shortcut', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_input(container));
      await container
          .read(composerKeyboardSettingsProvider.notifier)
          .setAction(shortcut, ComposerEnterAction.send);
      await tester.enterText(find.byType(TextField), ':thinking:');
      await tester.pump();
      final modifier = _modifier(shortcut);
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '🤔',
      );
      expect(api.sendCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('composition wins over configured send for $shortcut', (
      tester,
    ) async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.pumpWidget(_input(container));
      await container
          .read(composerKeyboardSettingsProvider.notifier)
          .setAction(shortcut, ComposerEnterAction.send);
      await tester.enterText(find.byType(TextField), ':thinking:');
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: ':thinking:',
          selection: TextSelection.collapsed(offset: 10),
          composing: TextRange(start: 1, end: 9),
        ),
      );
      await tester.pump();
      final input = tester.widget<TextField>(find.byType(TextField));
      final modifier = _modifier(shortcut);
      if (modifier != null) await tester.sendKeyDownEvent(modifier);
      expect(
        input.focusNode!.onKeyEvent!(
          input.focusNode!,
          const KeyDownEvent(
            physicalKey: PhysicalKeyboardKey.enter,
            logicalKey: LogicalKeyboardKey.enter,
            timeStamp: Duration.zero,
          ),
        ),
        KeyEventResult.ignored,
      );
      if (modifier != null) await tester.sendKeyUpEvent(modifier);
      expect(input.controller!.text, ':thinking:');
      expect(api.sendCalls, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
