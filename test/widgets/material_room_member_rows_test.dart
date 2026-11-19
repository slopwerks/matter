import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/material_room_member_rows.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;

import '../helpers/neu_test_theme.dart';

void main() {
  testWidgets('member and knock actions fit narrow rows with enlarged text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var ignored = false;
    var approved = false;
    var rejected = false;
    const reason = '希望加入这个房间，一起讨论项目进展和后续安排。';
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: neuTestTheme(material: true),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.6)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  MaterialRoomMemberRow(
                    member: const rust.Contact(
                      id: '@long-member-id:example.org',
                      name: '很长的房间成员名称',
                      status: 'online',
                    ),
                    isCurrentUser: false,
                    ignored: false,
                    tooltip: '忽略用户',
                    onToggleIgnored: () => ignored = true,
                  ),
                  MaterialRoomKnockRow(
                    request: const rust.KnockRequest(
                      userId: '@long-applicant-id:example.org',
                      displayName: '很长的申请加入者名称',
                      reason: reason,
                    ),
                    onApprove: () => approved = true,
                    onReject: () => rejected = true,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      tester.getTopLeft(find.byTooltip('批准')).dy,
      greaterThan(tester.getBottomLeft(find.text(reason)).dy),
    );
    await tester.tap(find.byTooltip('忽略用户'));
    await tester.ensureVisible(find.text('批准'));
    await tester.tap(find.text('批准'));
    await tester.ensureVisible(find.text('拒绝'));
    await tester.tap(find.text('拒绝'));
    expect(ignored, isTrue);
    expect(approved, isTrue);
    expect(rejected, isTrue);
    expect(tester.takeException(), isNull);
  });
}
