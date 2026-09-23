import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:matter/pages/settings/encryption_page.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  List<rust.AccountDevice> accountDevices = const [];
  List<rust.VerificationDevice> verificationDevices = const [];
  bool failAccountDevices = false;
  final renames = <(String, String)>[];
  final verificationStarts = <String>[];

  @override
  Future<List<rust.AccountDevice>> crateApiMatrixListAccountDevices() async {
    if (failAccountDevices) throw Exception('网络不可用');
    return accountDevices;
  }

  @override
  Future<List<rust.VerificationDevice>> crateApiMatrixListOwnDevices() async =>
      verificationDevices;

  @override
  Future<rust.EncryptionRecoveryInfo>
  crateApiMatrixGetEncryptionRecoveryInfo() async =>
      const rust.EncryptionRecoveryInfo(state: 'enabled', deviceVerified: true);

  @override
  Future<rust.DeviceVerificationStatus?>
  crateApiMatrixGetDeviceVerificationStatus() async => null;

  @override
  Future<void> crateApiMatrixRenameAccountDevice({
    required String deviceId,
    required String displayName,
  }) async {
    renames.add((deviceId, displayName));
    accountDevices = [
      for (final device in accountDevices)
        if (device.deviceId == deviceId)
          rust.AccountDevice(
            deviceId: device.deviceId,
            displayName: displayName,
            lastSeenIp: device.lastSeenIp,
            lastSeenTs: device.lastSeenTs,
            isCurrent: device.isCurrent,
          )
        else
          device,
    ];
  }

  @override
  Future<void> crateApiMatrixStartDeviceVerification({
    required String deviceId,
  }) async {
    verificationStarts.add(deviceId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

Widget _app() =>
    MaterialApp(theme: neuTestTheme(), home: const EncryptionPage());

void main() {
  late _FakeRustApi rustApi;

  setUpAll(() {
    rustApi = _FakeRustApi();
    RustLib.initMock(api: rustApi);
  });

  tearDownAll(RustLib.dispose);

  setUp(() {
    rustApi.accountDevices = const [];
    rustApi.verificationDevices = const [];
    rustApi.failAccountDevices = false;
    rustApi.renames.clear();
    rustApi.verificationStarts.clear();
  });

  testWidgets('一份设备列表同时显示会话和验证操作', (tester) async {
    rustApi.accountDevices = const [
      rust.AccountDevice(
        deviceId: 'CURRENT',
        displayName: 'Matter Linux',
        isCurrent: true,
      ),
      rust.AccountDevice(
        deviceId: 'OTHER',
        displayName: '平板',
        isCurrent: false,
      ),
    ];
    rustApi.verificationDevices = const [
      rust.VerificationDevice(
        deviceId: 'CURRENT',
        displayName: 'Matter Linux',
        isCurrent: true,
        isVerified: true,
      ),
      rust.VerificationDevice(
        deviceId: 'OTHER',
        displayName: '平板',
        isCurrent: false,
        isVerified: false,
      ),
    ];

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('Matter Linux'), findsOneWidget);
    expect(find.text('平板'), findsOneWidget);
    expect(find.text('CURRENT'), findsOneWidget);
    expect(find.text('本机'), findsOneWidget);
    expect(find.text('加密恢复'), findsOneWidget);

    await tester.tap(find.text('验证'));
    await tester.pumpAndSettle();
    expect(rustApi.verificationStarts, ['OTHER']);
  });

  testWidgets('设备详情显示活动记录并可重命名', (tester) async {
    final lastSeen = DateTime(2026, 9, 21, 14, 3);
    rustApi.accountDevices = [
      rust.AccountDevice(
        deviceId: 'CURRENT',
        displayName: 'Matter Linux',
        lastSeenIp: '203.0.113.7',
        lastSeenTs: lastSeen.millisecondsSinceEpoch,
        isCurrent: true,
      ),
    ];

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('Matter Linux'));
    await tester.pumpAndSettle();

    expect(find.text('Device ID'), findsOneWidget);
    expect(find.text('203.0.113.7'), findsOneWidget);
    expect(
      find.text(DateFormat('yyyy-MM-dd HH:mm').format(lastSeen)),
      findsOneWidget,
    );

    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '客厅平板');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(rustApi.renames, [('CURRENT', '客厅平板')]);
    expect(find.text('客厅平板'), findsOneWidget);
  });

  testWidgets('其他设备只能查看详情，不能重命名', (tester) async {
    rustApi.accountDevices = const [
      rust.AccountDevice(
        deviceId: 'OTHER',
        displayName: '另一台设备',
        isCurrent: false,
      ),
    ];

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.text('另一台设备'));
    await tester.pumpAndSettle();

    expect(find.text('Device ID'), findsOneWidget);
    expect(find.text('重命名'), findsNothing);
    expect(rustApi.renames, isEmpty);
  });

  testWidgets('服务器设备列表不可用时仍可查看已同步的验证设备', (tester) async {
    rustApi.failAccountDevices = true;
    rustApi.verificationDevices = const [
      rust.VerificationDevice(
        deviceId: 'CACHED',
        displayName: '已同步设备',
        isCurrent: true,
        isVerified: true,
      ),
    ];

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('已同步设备'), findsOneWidget);
    expect(find.text('登录设备信息暂不可用，显示已同步的验证设备'), findsOneWidget);
    expect(find.text('加密恢复'), findsOneWidget);
  });
}
