import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_layout.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/pages/settings/interaction_mode_settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/interaction_mode_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _Api implements RustLibApi {
  int sent = 0;
  @override
  Future<void> crateApiMatrixSendTypingNotice({
    required String accountUserId,
    required String roomId,
    required bool typing,
  }) async {}
  @override
  Future<bool> crateApiMatrixIsRoomEncrypted({required String roomId}) async =>
      false;
  @override
  Future<String> crateApiMatrixSendMessage({
    required String accountUserId,
    required String roomId,
    required rust.FormattedMessageInput message,
  }) async {
    sent++;
    return r'$sent';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('${invocation.memberName}');
}

Widget _input(ProviderContainer container, TargetPlatform platform) =>
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: neuTestTheme().copyWith(platform: platform),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: MessageInput(
              roomId: '!mode:test',
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
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api.sent = 0;
  });

  test(
    'automatic mode retains platform defaults and overrides are explicit',
    () {
      for (final platform in TargetPlatform.values) {
        expect(
          InteractionMode.auto.usesKeyboardMouse(platform),
          [
            TargetPlatform.linux,
            TargetPlatform.windows,
            TargetPlatform.macOS,
          ].contains(platform),
        );
        expect(InteractionMode.touch.usesKeyboardMouse(platform), isFalse);
        expect(
          InteractionMode.keyboardMouse.usesKeyboardMouse(platform),
          isTrue,
        );
      }
    },
  );

  test(
    'mode persists across containers, with auto as unknown-value fallback',
    () async {
      for (final mode in InteractionMode.values) {
        final first = ProviderContainer();
        await first.read(interactionModeProvider.notifier).setMode(mode);
        first.dispose();
        final next = ProviderContainer();
        next.read(interactionModeProvider);
        await Future<void>.delayed(Duration.zero);
        expect(next.read(interactionModeProvider), mode);
        next.dispose();
      }
      SharedPreferences.setMockInitialValues({'interaction_mode': 'unknown'});
      final container = ProviderContainer();
      container.read(interactionModeProvider);
      await Future<void>.delayed(Duration.zero);
      expect(container.read(interactionModeProvider), InteractionMode.auto);
      container.dispose();
    },
  );

  test('late restore cannot overwrite an immediate mode choice', () async {
    SharedPreferences.setMockInitialValues({'interaction_mode': 'touch'});
    final container = ProviderContainer();
    await container
        .read(interactionModeProvider.notifier)
        .setMode(InteractionMode.keyboardMouse);
    expect(
      container.read(interactionModeProvider),
      InteractionMode.keyboardMouse,
    );
    container.dispose();
  });

  for (final material in [false, true]) {
    testWidgets('all mode settings selectable and persistent ($material)', (
      tester,
    ) async {
      final container = ProviderContainer();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(material: material),
            home: const InteractionModeSettingsPage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      for (final mode in InteractionMode.values.reversed) {
        await tester.tap(find.byKey(ValueKey('interaction-mode-${mode.name}')));
        await tester.pumpAndSettle();
        expect(container.read(interactionModeProvider), mode);
        expect(
          (await SharedPreferences.getInstance()).getString('interaction_mode'),
          mode.name,
        );
      }
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
    });
  }

  for (final width in [360.0, 960.0]) {
    for (final platform in [TargetPlatform.linux, TargetPlatform.android]) {
      testWidgets('mode changes density not width layout ($width/$platform)', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 720);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final container = ProviderContainer();
        container.read(activeUserIdProvider.notifier).value = '@alice:test';
        await tester.pumpWidget(_input(container, platform));
        await tester.enterText(find.byType(TextField), '保留草稿');
        for (final mode in [
          InteractionMode.touch,
          InteractionMode.keyboardMouse,
          InteractionMode.auto,
        ]) {
          await container.read(interactionModeProvider.notifier).setMode(mode);
          await tester.pumpAndSettle();
          expect(
            tester.widget<ComposerLayout>(find.byType(ComposerLayout)).desktop,
            width >= 600,
          );
          expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            '保留草稿',
          );
          if (width >= 600) {
            final button = tester
                .widgetList<ComposerToolButton>(find.byType(ComposerToolButton))
                .first;
            expect(button.compact, mode.usesKeyboardMouse(platform));
            expect(
              tester.getSize(find.byType(ComposerToolButton).first).height,
              mode.usesKeyboardMouse(platform) ? 32 : 48,
            );
          }
          expect(tester.takeException(), isNull);
        }
        await container
            .read(interactionModeProvider.notifier)
            .setMode(InteractionMode.touch);
        await tester.pumpAndSettle();
        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).controller!.text,
          '保留草稿\n',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(api.sent, 1);
        await tester.pumpWidget(const SizedBox.shrink());
        container.read(activeUserIdProvider.notifier).value = null;
        await tester.pump(const Duration(seconds: 10));
        container.dispose();
      });
    }
  }
}
