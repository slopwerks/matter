import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:matter/pages/settings/encryption_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/sheets.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  List<rust.AccountDevice> accountDevices = const [];
  List<rust.VerificationDevice> verificationDevices = const [];
  bool failAccountDevices = false;
  bool failVerificationDevices = false;
  bool failRecovery = false;
  bool failVerificationStatus = false;
  Completer<void>? deviceRefresh;
  rust.EncryptionRecoveryInfo? recoveryAfterDeviceRefresh;
  rust.EncryptionRecoveryInfo recoveryInfo = const rust.EncryptionRecoveryInfo(
    state: 'enabled',
    deviceVerified: true,
  );
  int recoveryReads = 0;
  final recoveryResponses = <Future<rust.EncryptionRecoveryInfo>>[];
  final recoveryAccounts = <String?>[];
  final recoveryCalls = <(String?, String)>[];
  final renames = <(String, String)>[];
  final verificationStarts = <String>[];

  @override
  Future<List<rust.AccountDevice>> crateApiMatrixListAccountDevices() async {
    if (failAccountDevices) throw Exception('网络不可用');
    return accountDevices;
  }

  @override
  Future<List<rust.VerificationDevice>> crateApiMatrixListOwnDevices() async {
    if (failVerificationDevices) throw Exception('设备密钥查询失败');
    if (deviceRefresh case final refresh?) await refresh.future;
    if (recoveryAfterDeviceRefresh case final recovery?) {
      recoveryInfo = recovery;
    }
    return verificationDevices;
  }

  @override
  Future<rust.EncryptionRecoveryInfo> crateApiMatrixGetEncryptionRecoveryInfo({
    String? accountUserId,
  }) async {
    recoveryReads++;
    recoveryAccounts.add(accountUserId);
    if (failRecovery) throw Exception('加密状态读取失败');
    if (recoveryResponses.isNotEmpty) return recoveryResponses.removeAt(0);
    return recoveryInfo;
  }

  @override
  Future<rust.DeviceVerificationStatus?>
  crateApiMatrixGetDeviceVerificationStatus() async {
    if (failVerificationStatus) throw Exception('验证流程查询失败');
    return null;
  }

  @override
  Future<void> crateApiMatrixRecoverEncryption({
    required String recoveryKeyOrPassphrase,
    String? accountUserId,
  }) async {
    recoveryCalls.add((accountUserId, recoveryKeyOrPassphrase));
    recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'enabled',
      deviceVerified: true,
    );
  }

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

Widget _app({String? accountUserId}) => ProviderScope(
  overrides: [
    activeUserIdProvider.overrideWith(() => MutableState(accountUserId)),
  ],
  child: MaterialApp(theme: neuTestTheme(), home: const EncryptionPage()),
);

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
    rustApi.failVerificationDevices = false;
    rustApi.failRecovery = false;
    rustApi.failVerificationStatus = false;
    rustApi.deviceRefresh = null;
    rustApi.recoveryAfterDeviceRefresh = null;
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'enabled',
      deviceVerified: true,
    );
    rustApi.recoveryReads = 0;
    rustApi.recoveryResponses.clear();
    rustApi.recoveryAccounts.clear();
    rustApi.recoveryCalls.clear();
    rustApi.renames.clear();
    rustApi.verificationStarts.clear();
  });

  testWidgets('本机的本地信任不会显示成交叉签名已验证', (tester) async {
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'incomplete',
      deviceVerified: false,
    );
    rustApi.accountDevices = const [
      rust.AccountDevice(
        deviceId: 'CURRENT',
        displayName: '本机',
        isCurrent: true,
      ),
    ];
    rustApi.verificationDevices = const [
      rust.VerificationDevice(
        deviceId: 'CURRENT',
        displayName: '本机',
        isCurrent: true,
        isVerified: true,
      ),
    ];

    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('当前设备尚未验证'), findsOneWidget);
    expect(find.byIcon(Icons.verified_rounded), findsNothing);
  });

  for (final failedQuery in ['devices', 'verification']) {
    testWidgets('$failedQuery 查询失败不丢弃成功读取的加密状态', (tester) async {
      rustApi.failVerificationDevices = failedQuery == 'devices';
      rustApi.failVerificationStatus = failedQuery == 'verification';

      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.text('当前设备已验证'), findsOneWidget);
      expect(find.text('已启用，当前设备已持有恢复信息'), findsOneWidget);
    });
  }

  testWidgets('加密状态读取失败不会报告未验证或允许创建恢复密钥', (tester) async {
    rustApi.failRecovery = true;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('当前设备尚未验证'), findsNothing);
    expect(find.text('正在确认设备验证状态'), findsOneWidget);
    expect(find.text('加密状态读取失败，请下拉重试'), findsOneWidget);
    expect(find.text('新建恢复密钥'), findsNothing);
  });

  testWidgets('未知设备验证状态不会显示成尚未验证', (tester) async {
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'incomplete',
    );
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(find.text('正在确认设备验证状态'), findsOneWidget);
    expect(find.text('当前设备尚未验证'), findsNothing);
    expect(find.text('新建恢复密钥'), findsNothing);
  });

  testWidgets('晚到的旧状态不会覆盖手动刷新的结果', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    final oldRead = Completer<rust.EncryptionRecoveryInfo>();
    rustApi.recoveryResponses.add(oldRead.future);
    await tester.pump(const Duration(seconds: 2));
    expect(rustApi.recoveryReads, 2);

    final refresh = tester
        .state<RefreshIndicatorState>(find.byType(RefreshIndicator))
        .show();
    await tester.pumpAndSettle();
    await refresh;
    expect(rustApi.recoveryReads, 3);
    oldRead.complete(
      const rust.EncryptionRecoveryInfo(
        state: 'incomplete',
        deviceVerified: false,
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('当前设备已验证'), findsOneWidget);
    expect(find.text('已启用，当前设备已持有恢复信息'), findsOneWidget);
  });

  testWidgets('切换账号后旧页面停止刷新并丢弃晚到的状态', (tester) async {
    await tester.pumpWidget(_app(accountUserId: '@alice:example.org'));
    await tester.pumpAndSettle();
    expect(rustApi.recoveryAccounts, ['@alice:example.org']);
    final oldRead = Completer<rust.EncryptionRecoveryInfo>();
    rustApi.recoveryResponses.add(oldRead.future);
    await tester.pump(const Duration(seconds: 2));
    final reads = rustApi.recoveryReads;
    final container = ProviderScope.containerOf(
      tester.element(find.byType(EncryptionPage)),
    );
    container.read(activeUserIdProvider.notifier).value = '@bob:example.org';
    await tester.pumpAndSettle();
    oldRead.complete(const rust.EncryptionRecoveryInfo(state: 'disabled'));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 4));

    expect(find.text('当前账号已切换，请返回设置重新打开'), findsOneWidget);
    expect(find.text('新建恢复密钥'), findsNothing);
    expect(rustApi.recoveryReads, reads);
    expect(
      rustApi.recoveryAccounts.every((id) => id == '@alice:example.org'),
      isTrue,
    );
  });

  testWidgets('状态读取失败后可自动恢复正确展示', (tester) async {
    rustApi.failRecovery = true;
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    rustApi.failRecovery = false;
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('当前设备已验证'), findsOneWidget);
    expect(find.text('加密状态读取失败，请下拉重试'), findsNothing);
  });

  testWidgets('身份刷新完成后再读取恢复和验证状态', (tester) async {
    final refresh = Completer<void>();
    rustApi.deviceRefresh = refresh;
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'incomplete',
      deviceVerified: false,
    );
    rustApi.recoveryAfterDeviceRefresh = const rust.EncryptionRecoveryInfo(
      state: 'enabled',
      deviceVerified: true,
    );
    await tester.pumpWidget(_app());
    await tester.pump();
    refresh.complete();
    await tester.pumpAndSettle();

    expect(find.text('当前设备已验证'), findsOneWidget);
    expect(find.text('已启用，当前设备已持有恢复信息'), findsOneWidget);
  });

  testWidgets('页面接收晚到的加密状态变化并在关闭后停止刷新', (tester) async {
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'incomplete',
      deviceVerified: false,
    );
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'enabled',
      deviceVerified: true,
    );
    await tester.pump(const Duration(seconds: 2));
    await tester.pumpAndSettle();

    expect(find.text('当前设备已验证'), findsOneWidget);
    expect(find.text('已启用，当前设备已持有恢复信息'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    final reads = rustApi.recoveryReads;
    await tester.pump(const Duration(seconds: 4));
    expect(rustApi.recoveryReads, reads);
  });

  for (final state in ['incomplete', 'unknown', 'disabled']) {
    testWidgets('$state 恢复状态只在确认未配置时显示创建入口', (tester) async {
      rustApi.recoveryInfo = rust.EncryptionRecoveryInfo(
        state: state,
        deviceVerified: false,
      );
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(
        find.text('新建恢复密钥'),
        state == 'disabled' ? findsOneWidget : findsNothing,
      );
      if (state == 'incomplete') {
        expect(find.text('账号已配置恢复，当前设备需要恢复密钥或恢复口令'), findsOneWidget);
      }
    });
  }

  testWidgets('已有恢复配置仍可用原密钥恢复并绑定打开页面的账号', (tester) async {
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'incomplete',
      deviceVerified: false,
    );
    await tester.pumpWidget(_app(accountUserId: '@alice:example.org'));
    await tester.pumpAndSettle();
    expect(find.text('新建恢复密钥'), findsNothing);
    await tester.enterText(find.byType(TextField), 'existing-recovery-key');
    await tester.ensureVisible(find.text('恢复加密数据'));
    await tester.tap(find.text('恢复加密数据'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    expect(rustApi.recoveryCalls, [
      ('@alice:example.org', 'existing-recovery-key'),
    ]);
    expect(find.text('当前设备已验证'), findsOneWidget);
    expect(find.text('恢复信息已导入，历史消息将按需解密'), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      isEmpty,
    );
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
    expect(find.text('验证'), findsNothing);
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

  testWidgets('其他设备可重命名并刷新列表', (tester) async {
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
    expect(find.text('重命名'), findsOneWidget);
    await tester.tap(find.text('重命名'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '客厅平板');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();

    expect(rustApi.renames, [('OTHER', '客厅平板')]);
    expect(find.text('客厅平板'), findsOneWidget);
  });

  for (final isVerified in [false, true]) {
    testWidgets(isVerified ? '已验证设备可从详情重新验证' : '未验证设备可从详情验证', (tester) async {
      rustApi.accountDevices = const [
        rust.AccountDevice(
          deviceId: 'OTHER',
          displayName: '平板',
          isCurrent: false,
        ),
      ];
      rustApi.verificationDevices = [
        rust.VerificationDevice(
          deviceId: 'OTHER',
          displayName: '平板',
          isCurrent: false,
          isVerified: isVerified,
        ),
      ];

      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(find.text('验证'), isVerified ? findsNothing : findsOneWidget);
      await tester.tap(find.text('平板'));
      await tester.pumpAndSettle();

      final verifyItem = find.widgetWithText(NeuSheetItem, '验证');
      expect(verifyItem, findsOneWidget);
      await tester.tap(verifyItem);
      await tester.pumpAndSettle();

      expect(rustApi.verificationStarts, ['OTHER']);
      expect(find.text('Device ID'), findsNothing);
    });
  }

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
