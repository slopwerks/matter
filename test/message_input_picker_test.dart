import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';

void main() {
  testWidgets('picker button reopens the previously selected sticker tab', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    await tester.tap(find.text('贴纸'));
    await tester.pumpAndSettle();
    expect(find.byType(StickerPackPanel), findsOneWidget);

    await tester.tap(find.byIcon(Icons.keyboard_rounded));
    await tester.pump();
    expect(find.byIcon(Icons.interests_rounded), findsOneWidget);
    expect(find.byIcon(Icons.sticky_note_2_rounded), findsNothing);

    await tester.tap(find.byType(IconButton).first);
    await tester.pump();
    await tester.pump();

    expect(find.byType(StickerPackPanel), findsOneWidget);
  });
}

class _MessageInputHarness extends StatefulWidget {
  const _MessageInputHarness();

  @override
  State<_MessageInputHarness> createState() => _MessageInputHarnessState();
}

class _MessageInputHarnessState extends State<_MessageInputHarness> {
  InputPanelMode _panelMode = InputPanelMode.emoji;

  @override
  Widget build(BuildContext context) {
    const pickerHeight = 300.0;
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!room:example.org',
          totalMembers: 2,
          panelMode: _panelMode,
          pickerHeight: _panelMode == InputPanelMode.emoji ? pickerHeight : 0,
          pickerFullHeight: pickerHeight,
          pickerBaseHeight: pickerHeight,
          pickerMaxHeight: 500,
          animatePickerHeight: false,
          onPanelModeChanged: (mode) => setState(() => _panelMode = mode),
          onPickerHeightChanged: (_) {},
          resolveSendPresentation: () => MessageSendPresentation.flight,
          onMessageQueued: (_, _) {},
          onMessageSent: (_, _) {},
        ),
      ),
    );
  }
}
