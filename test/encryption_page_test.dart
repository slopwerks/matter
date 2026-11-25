import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/encryption_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/mutable_state.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';

import 'helpers/neu_test_theme.dart';

class _FakeRustApi implements RustLibApi {
  List<rust.AccountDevice> accountDevices = const [];
  List<rust.VerificationDevice> verificationDevices = const [];
  bool failAccountDevices = false;
  bool failVerificationDevices = false;
  bool failRecovery = false;
  bool failVerificationStatus = false;
  rust.EncryptionRecoveryInfo recoveryInfo = const rust.EncryptionRecoveryInfo(
    state: 'enabled',
    deviceVerified: true,
  );

  @override
  Future<List<rust.AccountDevice>> crateApiMatrixListAccountDevices() async {
    if (failAccountDevices) throw Exception('网络不可用');
    return accountDevices;
  }

  @override
  Future<List<rust.VerificationDevice>> crateApiMatrixListOwnDevices() async {
    if (failVerificationDevices) throw Exception('设备密钥查询失败');
    return verificationDevices;
  }

  @override
  Future<rust.EncryptionRecoveryInfo> crateApiMatrixGetEncryptionRecoveryInfo({
    String? accountUserId,
  }) async {
    if (failRecovery) throw Exception('加密状态读取失败');
    return recoveryInfo;
  }

  @override
  Future<rust.DeviceVerificationStatus?>
  crateApiMatrixGetDeviceVerificationStatus() async {
    if (failVerificationStatus) throw Exception('验证流程查询失败');
    return null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
  }
}

Widget _app({
  String? accountUserId,
  bool material = const bool.fromEnvironment('MATTER_TEST_MATERIAL'),
  TextScaler textScaler = TextScaler.noScaling,
}) => ProviderScope(
  overrides: [
    activeUserIdProvider.overrideWith(() => MutableState(accountUserId)),
  ],
  child: MaterialApp(
    theme: neuTestTheme(material: material),
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: textScaler),
      child: child!,
    ),
    home: const EncryptionPage(),
  ),
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
    rustApi.recoveryInfo = const rust.EncryptionRecoveryInfo(
      state: 'enabled',
      deviceVerified: true,
    );
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
}
