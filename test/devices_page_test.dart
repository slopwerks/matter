import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:matter/pages/settings/devices_page.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  List<rust.AccountDevice> devices = const [];
  final renames = <(String, String)>[];

  @override
  Future<List<rust.AccountDevice>> crateApiMatrixListAccountDevices() async =>
      devices;

  @override
  Future<void> crateApiMatrixRenameAccountDevice({
    required String deviceId,
    required String displayName,
  }) async {
    renames.add((deviceId, displayName));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

Widget _app(Widget child) => MaterialApp(theme: neuTestTheme(), home: child);

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(() {
    RustLib.dispose();
  });

  setUp(() {
    rustApi.devices = const [];
    rustApi.renames.clear();
  });

  testWidgets('列表展示设备名、Device ID 与本机标记', (tester) async {
    rustApi.devices = const [
      rust.AccountDevice(
        deviceId: 'fqBB968RWm',
        displayName: 'Matter Linux',
        isCurrent: true,
      ),
      rust.AccountDevice(deviceId: 'AbC123xyz', isCurrent: false),
    ];

    await tester.pumpWidget(_app(const DevicesPage()));
    await tester.pumpAndSettle();

    expect(find.text('Matter Linux'), findsOneWidget);
    expect(find.text('fqBB968RWm'), findsOneWidget);
    expect(find.text('本机'), findsOneWidget);
    expect(find.text('未命名设备'), findsOneWidget);
  });

  testWidgets('详情弹层展示 Device ID、IP 地址与上次活动时间', (tester) async {
    final lastSeen = DateTime(2026, 9, 21, 14, 3);
    rustApi.devices = [
      rust.AccountDevice(
        deviceId: 'fqBB968RWm',
        displayName: 'Matter Linux',
        lastSeenIp: '203.0.113.7',
        lastSeenTs: lastSeen.millisecondsSinceEpoch,
        isCurrent: true,
      ),
    ];

    await tester.pumpWidget(_app(const DevicesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Matter Linux'));
    await tester.pumpAndSettle();

    expect(find.text('Device ID'), findsOneWidget);
    expect(find.text('fqBB968RWm'), findsNWidgets(2));
    expect(find.text('203.0.113.7'), findsOneWidget);
    expect(
      find.text(DateFormat('yyyy-MM-dd HH:mm').format(lastSeen)),
      findsOneWidget,
    );
  });

  testWidgets('会话没有活动记录时显示占位文案', (tester) async {
    rustApi.devices = const [
      rust.AccountDevice(deviceId: 'AbC123xyz', isCurrent: false),
    ];

    await tester.pumpWidget(_app(const DevicesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('未命名设备'));
    await tester.pumpAndSettle();

    expect(find.text('无活动记录'), findsOneWidget);
    expect(find.text('未知'), findsOneWidget);
  });

  testWidgets('重命名会调用改名接口', (tester) async {
    rustApi.devices = const [
      rust.AccountDevice(
        deviceId: 'fqBB968RWm',
        displayName: 'Matter Linux',
        isCurrent: true,
      ),
    ];

    await tester.pumpWidget(_app(const DevicesPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Matter Linux'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '客厅平板');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(rustApi.renames, [('fqBB968RWm', '客厅平板')]);
  });
}
