import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/desktop_room_details_panel.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';

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
      ],
    );
    addTearDown(container.dispose);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(
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
}
