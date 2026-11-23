import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/room_directory_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/src/rust/api/matrix.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';

class _DirectoryApi implements RustLibApi {
  final searches = <String>[];
  final previews = <String>[];
  final writes = <String>[];
  late final Completer<void> write;
  DirectoryRoom room = const DirectoryRoom(
    id: '!test:example.org',
    name: '开发讨论',
    alias: '#dev:example.org',
    isSpace: false,
    state: 'left',
    joinRule: 'knock',
    via: ['example.org'],
  );
  @override
  Future<DirectoryRoomPage> crateApiMatrixSearchRoomDirectory({
    required String accountUserId,
    required String query,
    String? since,
  }) async {
    searches.add(query);
    return DirectoryRoomPage(rooms: [room]);
  }

  @override
  Future<DirectoryRoom> crateApiMatrixPreviewRoomAddress({
    required String accountUserId,
    required String address,
  }) async {
    previews.add(address);
    return room;
  }

  @override
  Future<void> crateApiMatrixEnterDirectoryRoom({
    required String accountUserId,
    required String roomId,
    required List<String> via,
    required bool knock,
  }) {
    writes.add('$accountUserId $roomId ${via.single} $knock');
    return write.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final api = _DirectoryApi();
  setUpAll(() => RustLib.initMock(api: api));
  testWidgets(
    'directory search and exact preview only request membership on tap',
    (tester) async {
      api.write = Completer<void>();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(activeUserIdProvider.notifier).value = '@me:example.org';
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            theme: buildMaterialTheme(Brightness.light),
            home: const RoomDirectoryPage(focusAddress: true),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(api.searches, ['']);
      expect(find.text('#dev:example.org'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '开发');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.searches.last, '开发');
      const link = 'https://matrix.to/#/!test:example.org?via=example.org';
      await tester.enterText(find.byType(TextField), link);
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(api.previews, [link]);
      expect(api.writes, isEmpty);
      await tester.tap(find.text('申请加入'));
      await tester.tap(find.text('申请加入'));
      expect(api.writes, [
        '@me:example.org !test:example.org example.org true',
      ]);
      api.write.complete();
      await tester.pumpAndSettle();
      expect(find.text('已申请'), findsOneWidget);
      // A query before sync catches up must retain the successful request.
      await tester.enterText(find.byType(TextField), '#dev:example.org');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('已申请'), findsOneWidget);
      api.room = DirectoryRoom(
        id: api.room.id,
        name: api.room.name,
        alias: api.room.alias,
        isSpace: false,
        state: 'invited',
        joinRule: 'knock',
        via: api.room.via,
      );
      await tester.enterText(find.byType(TextField), '开发');
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pumpAndSettle();
      expect(find.text('接受邀请'), findsOneWidget);
      await tester.tap(find.text('接受邀请'));
      await tester.pumpAndSettle();
      expect(
        api.writes.last,
        '@me:example.org !test:example.org example.org false',
      );
      expect(find.text('打开会话'), findsOneWidget);
    },
  );
}
