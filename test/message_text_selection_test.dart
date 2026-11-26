import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/matrix_html/matrix_html_renderer.dart';
import 'package:matter/pages/chat/timeline/timeline_text_bubble.dart';
import 'package:matter/pages/chat/timeline/timeline_message_menu.dart';
import 'package:matter/providers/interaction_mode_provider.dart';
import 'package:matter/providers/text_selection_target.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';

const _html = '<p>hello <strong>there</strong></p>';

rust.ChatMessage _message() => rust.ChatMessage(
  id: r'$a',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: 'hello there',
  formattedBody: _html,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '1700000000000',
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

rust.ChatMessage _plainMessage() => rust.ChatMessage(
  id: r'$b',
  senderId: '@alice:example.org',
  senderName: 'Alice',
  content: 'hello there',
  formattedBody: null,
  mentionedUserIds: const [],
  mentionsRoom: false,
  timestamp: '1700000000000',
  isMe: false,
  msgType: rust.MessageType.text,
  isEdited: false,
  editHistory: const [],
  reactions: const [],
  readers: const [],
  totalMembers: 2,
);

class _FixedMode extends InteractionModeNotifier {
  _FixedMode(this.mode);

  final InteractionMode mode;

  @override
  InteractionMode build() => mode;
}

Future<ProviderContainer> _pumpBubble(
  WidgetTester tester, {
  required TargetPlatform platform,
  required InteractionMode mode,
  rust.ChatMessage? message,
  String? formattedBody = _html,
}) async {
  debugDefaultTargetPlatformOverride = platform;
  addTearDown(() => debugDefaultTargetPlatformOverride = null);
  final container = ProviderContainer(
    overrides: [interactionModeProvider.overrideWith(() => _FixedMode(mode))],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildNeuTheme(NeuColors.light, Brightness.light),
        home: Scaffold(
          body: TimelineTextBubble(
            message: message ?? _message(),
            isMe: false,
            isFirst: true,
            isLast: true,
            formattedBody: formattedBody,
            mentionDisplayNames: const {},
            onMentionTap: (_) {},
            messageIndex: const {},
            metadata: const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
  return container;
}

void main() {
  testWidgets('a formatted body is selectable unless told otherwise', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MatrixHtmlMessage(
            html: _html,
            style: TextStyle(),
            accentColor: Colors.blue,
          ),
        ),
      ),
    );
    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: MatrixHtmlMessage(
            html: _html,
            style: TextStyle(),
            accentColor: Colors.blue,
            selectable: false,
          ),
        ),
      ),
    );
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('touch input leaves the formatted body for the message menu', (
    tester,
  ) async {
    await _pumpBubble(
      tester,
      platform: TargetPlatform.android,
      mode: InteractionMode.auto,
    );
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('a mouse keeps the formatted body selectable', (tester) async {
    await _pumpBubble(
      tester,
      platform: TargetPlatform.linux,
      mode: InteractionMode.auto,
    );
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('the chosen message hands its body over to text selection', (
    tester,
  ) async {
    final container = await _pumpBubble(
      tester,
      platform: TargetPlatform.android,
      mode: InteractionMode.auto,
    );
    expect(find.byType(SelectionArea), findsNothing);

    container.read(textSelectionTargetProvider.notifier).enter(r'$a');
    await tester.pump();
    expect(find.byType(SelectionArea), findsOneWidget);

    container.read(textSelectionTargetProvider.notifier).enter(r'$other');
    await tester.pump();
    expect(find.byType(SelectionArea), findsNothing);
  });

  testWidgets('a plain body follows the same selection mode', (tester) async {
    final container = await _pumpBubble(
      tester,
      platform: TargetPlatform.android,
      mode: InteractionMode.auto,
      message: _plainMessage(),
      formattedBody: null,
    );
    expect(find.byType(SelectionArea), findsNothing);

    container.read(textSelectionTargetProvider.notifier).enter(r'$b');
    await tester.pump();
    expect(find.byType(SelectionArea), findsOneWidget);
  });

  testWidgets('a touch outside the bubble drops the selection mode', (
    tester,
  ) async {
    final container = await _pumpBubble(
      tester,
      platform: TargetPlatform.android,
      mode: InteractionMode.auto,
    );
    container.read(textSelectionTargetProvider.notifier).enter(r'$a');
    await tester.pump();
    expect(find.byType(SelectionArea), findsOneWidget);

    await tester.tapAt(const Offset(400, 550));
    await tester.pump();
    expect(container.read(textSelectionTargetProvider), isNull);
  });

  testWidgets('the message menu offers selecting a part of the text', (
    tester,
  ) async {
    var selected = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildNeuTheme(NeuColors.light, Brightness.light),
        home: Scaffold(
          body: TimelineMessageMenu(
            message: _message(),
            isMe: false,
            bubbleRect: const Rect.fromLTWH(10, 10, 200, 40),
            onClose: () {},
            onCopy: () {},
            onSelectText: () => selected++,
            onReply: () {},
            onForward: () {},
            onEdit: () {},
            onRecall: () {},
            isPinned: null,
            pinStateLoading: false,
            onPin: null,
            onReact: (_) {},
            onShowFullEmojiPicker: () {},
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.text('选择文字'));
    expect(selected, 1);
  });
}
