import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/space_detail_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  @override
  Future<void> crateApiMatrixUpdateSpaceDetails({
    required String accountUserId,
    required String spaceId,
    required String name,
    String? topic,
  }) async {
    throw StateError('空间名称已更新，但主题更新失败');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

void main() {
  const spaceId = '!space:example.org';
  var detailsName = '旧名称';
  var detailsCalls = 0;

  setUpAll(() {
    RustLib.initMock(api: _FakeRustApi());
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    detailsName = '旧名称';
    detailsCalls = 0;
  });

  testWidgets('partial detail update refreshes the visible space details', (
    tester,
  ) async {
    final container = ProviderContainer(
      overrides: [
        spaceDetailsProvider.overrideWith((ref, id) async {
          detailsCalls++;
          return rust.SpaceDetails(id: id, name: detailsName);
        }),
        spaceChildrenProvider.overrideWith((ref, id) async => const []),
        roomMembersProvider.overrideWith((ref, id) async => const []),
      ],
    );
    addTearDown(container.dispose);
    container.read(activeUserIdProvider.notifier).value = '@alice:example.org';
    container.read(sessionReadyProvider.notifier).value = true;

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const SpaceDetailPage(
            space: rust.Space(id: spaceId, name: '旧名称'),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(detailsCalls, 1);

    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑空间').last);
    await tester.pumpAndSettle();

    detailsName = '新名称';
    await tester.enterText(find.byType(TextField).first, detailsName);
    await tester.tap(find.widgetWithText(NeuButton, '保存'));
    await tester.pumpAndSettle();

    expect(detailsCalls, 2);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is Text && widget.data == detailsName,
      ),
      findsOneWidget,
    );
    expect(find.textContaining('空间名称已更新'), findsOneWidget);
  });
}
