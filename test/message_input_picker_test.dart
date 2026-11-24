import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/composer/composer_text_field.dart';
import 'package:matter/pages/chat/composer_picker_panel.dart';
import 'package:matter/pages/chat/latest_message_control.dart';
import 'package:matter/pages/chat/message_input.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/glass.dart';

import 'helpers/neu_test_theme.dart';

void main() {
  testWidgets(
    'picker button reopens the previously selected sticker tab',
    (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: neuTestTheme(),
            home: const _MessageInputHarness(),
          ),
        ),
      );
      await tester.pump();

      await tester.tap(find.text('贴纸'));
      await tester.pumpAndSettle();
      expect(find.byType(StickerPackPanel), findsOneWidget);

      await tester.tap(find.byIcon(Icons.keyboard_rounded));
      await tester.pump();
      expect(find.byIcon(Icons.interests_rounded), findsOneWidget);
      expect(find.byIcon(Icons.sticky_note_2_rounded), findsNothing);

      await tester.tap(find.byIcon(Icons.interests_rounded));
      await tester.pump();
      await tester.pump();

      expect(find.byType(StickerPackPanel), findsOneWidget);
    },
    variant: TargetPlatformVariant({
      TargetPlatform.android,
      TargetPlatform.linux,
    }),
  );

  final inputWidths = ValueVariant<double>({320, 400});
  testWidgets('input respects safe area and appearance effects', (
    tester,
  ) async {
    tester.view.physicalSize = Size(inputWidths.currentValue!, 800);
    tester.view.devicePixelRatio = 1;
    tester.view.padding = const FakeViewPadding(bottom: 34);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPadding);

    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const _MessageInputHarness(),
        ),
      ),
    );
    await tester.pump();

    final surfaceFinder = find.byKey(const ValueKey('message-input-surface'));
    final material = tester.element(find.byType(MessageInput)).isMaterial;
    if (!material) {
      final surface = tester.widget<GlassPanel>(surfaceFinder);
      expect(surface.radius, NeuRadius.nav);
      expect(surface.blur, 18);
      expect(
        surface.padding,
        const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      );
      final surfaceMargin = tester.widget<Padding>(
        find
            .ancestor(
              of: find.byKey(const ValueKey('message-input-surface')),
              matching: find.byType(Padding),
            )
            .first,
      );
      expect(surfaceMargin.padding, const EdgeInsets.fromLTRB(10, 4, 10, 12));
    }
    expect(
      find.byType(BottomFadeBlur),
      material ? findsNothing : findsOneWidget,
    );

    final backdropFilters = find.descendant(
      of: find.byType(MessageInput),
      matching: find.byType(BackdropFilter),
    );
    if (material) {
      // Material needs no shadow clearance: most of the row is for composing.
      expect(
        tester.getSize(find.byType(TextField).first).width,
        greaterThan(tester.getSize(surfaceFinder).width - 160),
      );
      expect(backdropFilters, findsNothing);
      final surface = tester.widget<Material>(surfaceFinder);
      final theme = Theme.of(tester.element(surfaceFinder));
      expect(surface.color, theme.colorScheme.surfaceContainerHigh);
      expect(surface.borderRadius, BorderRadius.circular(28));
      expect(tester.getBottomLeft(find.byType(MessageInput)).dy, 800);
    } else {
      // GlassPanel 一层 + BottomFadeBlur 的渐进模糊条带。
      expect(backdropFilters, findsAtLeastNWidgets(3));
      expect(tester.getBottomLeft(backdropFilters.first).dy, 800);
    }
  }, variant: inputWidths);

  testWidgets('plus toggles an inline attachment panel at picker height', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const _MessageInputHarness(
            initialPanelMode: InputPanelMode.keyboard,
          ),
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
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('attachment panel stays mounted while keyboard replaces it', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const _MessageInputHarness(
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

  testWidgets(
    'Material capsule aligns single-line editor vertically and trims redundant side inset',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.dark),
            home: const _MessageInputHarness(
              initialPanelMode: InputPanelMode.none,
            ),
          ),
        ),
      );
      await tester.pump();

      final surfaceRect = tester.getRect(
        find.byKey(const ValueKey('message-input-surface')),
      );
      final editorRect = tester.getRect(find.byType(ComposerTextField));
      final plusIconRect = tester.getRect(find.byIcon(Icons.add_rounded));
      final emojiIconRect = tester.getRect(
        find.byIcon(Icons.sentiment_satisfied_alt_rounded),
      );
      final field = tester.widget<TextField>(find.byType(TextField));
      final padding = field.decoration!.contentPadding! as EdgeInsets;

      expect(surfaceRect.height, 56);
      expect(editorRect.height, 48);
      expect(
        (editorRect.center.dy - plusIconRect.center.dy).abs(),
        lessThanOrEqualTo(0.5),
      );
      expect(
        (editorRect.center.dy - emojiIconRect.center.dy).abs(),
        lessThanOrEqualTo(0.5),
      );
      expect(padding.horizontal, lessThanOrEqualTo(8));
      expect(editorRect.width, greaterThanOrEqualTo(170));
    },
    variant: TargetPlatformVariant.only(TargetPlatform.android),
  );
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
