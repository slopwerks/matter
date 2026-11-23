import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/desktop_room_details_panel.dart';
import 'package:matter/pages/chat/material_room_member_rows.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

import '../helpers/neu_test_theme.dart';

void main() {
  testWidgets('shows room members in the desktop details panel', (
    tester,
  ) async {
    const roomId = '!room:example.org';
    final container = ProviderContainer(
      overrides: [
        roomMembersProvider(roomId).overrideWith(
          (ref) async => const [
            Contact(
              id: '@alice:example.org',
              name: 'Alice',
              status: '@alice:example.org',
            ),
          ],
        ),
        allChatRoomsProvider.overrideWith((ref) async => []),
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 600,
              child: DesktopRoomDetailsPanel(
                roomId: roomId,
                roomName: 'Project chat',
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Project chat'), findsOneWidget);
    expect(find.text('成员 1'), findsOneWidget);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('@alice:example.org'), findsOneWidget);
  });

  testWidgets(
    'Material details keep long member identities readable in a narrow pane',
    (tester) async {
      const roomId = '!room:example.org';
      const userId = '@alice-with-a-long-identity:matrix.example.org';
      final container = ProviderContainer(
        overrides: [
          allChatRoomsProvider.overrideWith((ref) async => []),
          roomMembersProvider(roomId).overrideWith(
            (ref) async => const [
              Contact(id: userId, name: 'Alice 的较长显示名称', status: userId),
            ],
          ),
        ],
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: neuTestTheme(material: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(1.6)),
              child: child!,
            ),
            home: const Scaffold(
              body: SizedBox(
                width: 300,
                child: DesktopRoomDetailsPanel(
                  roomId: roomId,
                  roomName: 'Project chat',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('成员 1'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('成员 1'));
      await tester.pumpAndSettle();
      expect(find.text(userId), findsOneWidget);
      expect(find.byType(MaterialMemberIdentity), findsOneWidget);
      expect(find.byType(DecoratedSliver), findsNothing);
      expect(tester.widget<Text>(find.text(userId)).maxLines, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
