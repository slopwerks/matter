import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/theme/app_theme.dart';
import 'package:matter/widgets/liquid_glass.dart';

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

  testWidgets('input floats above a dimmed and blurred safe area', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(
      const ProviderScope(child: MaterialApp(home: _MessageInputHarness())),
    );
    await tester.pump();

    final surface = tester.widget<LiquidGlassContainer>(
      find.byKey(const ValueKey('message-input-surface')),
    );
    expect(surface.borderRadius, AppRadii.nav);
    expect(surface.blurSigma, 18);
    expect(surface.margin, const EdgeInsets.fromLTRB(10, 4, 10, 12));
    expect(find.byType(ShaderMask), findsOneWidget);

    final backdropFilters = find.descendant(
      of: find.byType(MessageInput),
      matching: find.byType(BackdropFilter),
    );
    expect(backdropFilters, findsNWidgets(2));
    expect(tester.getBottomLeft(backdropFilters.first).dy, 800);
  });

  testWidgets('plus toggles an inline attachment panel at picker height', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: _MessageInputHarness(initialPanelMode: InputPanelMode.keyboard),
        ),
      ),
    );
    await tester.pump();

    final plus = find.byIcon(Icons.add_rounded);
    await tester.tap(plus);
    await tester.pumpAndSettle();

    expect(find.byType(AttachmentPicker), findsOneWidget);
    expect(tester.getSize(find.byType(AttachmentPicker)).height, 300);
    expect(plus, findsOneWidget);

    await tester.tap(plus);
    await tester.pumpAndSettle();

    expect(find.byType(AttachmentPicker), findsNothing);
  });

  testWidgets('attachment panel stays mounted while keyboard replaces it', (
    tester,
  ) async {
    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: _MessageInputHarness(
            initialPanelMode: InputPanelMode.attachment,
            keepPickerWhileKeyboard: true,
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(AttachmentPicker), findsOneWidget);
    await tester.tap(find.byType(TextField).first);
    await tester.pump();

    expect(find.byType(AttachmentPicker), findsOneWidget);
    expect(find.byType(ComposerPickerPanel), findsNothing);
  });
}

class _MessageInputHarness extends StatefulWidget {
  final InputPanelMode initialPanelMode;
  final bool keepPickerWhileKeyboard;

  const _MessageInputHarness({
    this.initialPanelMode = InputPanelMode.emoji,
    this.keepPickerWhileKeyboard = false,
  });

  @override
  State<_MessageInputHarness> createState() => _MessageInputHarnessState();
}

class _MessageInputHarnessState extends State<_MessageInputHarness> {
  late InputPanelMode _panelMode;

  @override
  void initState() {
    super.initState();
    _panelMode = widget.initialPanelMode;
  }

  @override
  Widget build(BuildContext context) {
    const pickerHeight = 300.0;
    final pickerOpen =
        _panelMode == InputPanelMode.emoji ||
        _panelMode == InputPanelMode.attachment ||
        (widget.keepPickerWhileKeyboard &&
            _panelMode == InputPanelMode.keyboard);
    return Scaffold(
      body: Align(
        alignment: Alignment.bottomCenter,
        child: MessageInput(
          roomId: '!room:example.org',
          totalMembers: 2,
          panelMode: _panelMode,
          pickerHeight: pickerOpen ? pickerHeight : 0,
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
