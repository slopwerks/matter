import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/push_build_config.dart';
import 'package:matter/features/push/push_providers.dart';
import 'package:matter/features/push/push_registration_manager.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:matter/pages/settings/notification_settings_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'firebase_client_config_test.dart' show googleServices;
import 'helpers/neu_test_theme.dart';

class FirebaseConfigSelector extends FileSelectorPlatform {
  FirebaseConfigSelector(this.file);
  final XFile? file;
  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async => file;
}

void main() {
  const userId = '@alice:example.org';
  const gateway = 'https://push.example.org/_matrix/push/v1/notify';
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    fcmPushRuntime.configurationChanged = false;
    fcmPushRuntime.configuration = null;
  });

  Future<void> showPage(
    WidgetTester tester, {
    PushRegistrationManager? manager,
  }) async {
    tester.view.physicalSize = const Size(800, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          if (manager != null)
            pushRegistrationManagerProvider.overrideWithValue(manager),
        ],
        child: MaterialApp(
          theme: neuTestTheme(),
          home: const NotificationSettingsPage(userId: userId),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('unconfigured build starts disabled and cannot enable FCM', (
    tester,
  ) async {
    await showPage(tester);
    final fields = tester
        .widgetList<TextFormField>(find.byType(TextFormField))
        .toList();
    // A build may carry prefill values; either way enabling stays blocked
    // until a Firebase client config exists.
    if (PushBuildConfig.gatewayUrl.isEmpty) {
      expect(fields.first.controller!.text, isEmpty);
      expect(fields.last.controller!.text, isEmpty);
    } else {
      expect(fields.first.controller!.text, PushBuildConfig.gatewayUrl);
      expect(fields.last.controller!.text, PushBuildConfig.androidAppId);
    }
    expect(find.text('推送未启用'), findsOneWidget);
    // A prefilled build already carries public Firebase client options.
    final prefilled = PushBuildConfig.firebaseOptions != null;
    expect(
      find.text(
        prefilled
            ? '已成功载入客户端配置，可连接 Google FCM 接收通知'
            : '尚未配置 Firebase 项目，暂不可启用 Android 推送',
      ),
      findsOneWidget,
    );
    final enable = tester.widget<NeuButton>(
      find.ancestor(of: find.text('启用推送'), matching: find.byType(NeuButton)),
    );
    expect(enable.onPressed, prefilled ? isNotNull : isNull);
    final selector = tester.widget<DropdownButton<PushBackend>>(
      find.byType(DropdownButton<PushBackend>),
    );
    expect(
      selector.items!
          .singleWhere((item) => item.value == PushBackend.web)
          .enabled,
      isFalse,
    );
    expect(
      selector.items!
          .singleWhere((item) => item.value == PushBackend.android)
          .enabled,
      isTrue,
    );
    expect((await PushSettingsStore().load(userId)).enabled, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'imports user JSON without rebuilding and keeps enable blocked until restart',
    (tester) async {
      final previous = FileSelectorPlatform.instance;
      FileSelectorPlatform.instance = FirebaseConfigSelector(
        XFile.fromData(
          Uint8List.fromList(utf8.encode(jsonEncode(googleServices()))),
          name: 'google-services.json',
          mimeType: 'application/json',
        ),
      );
      addTearDown(() => FileSelectorPlatform.instance = previous);
      await showPage(tester);
      final fields = find.byType(TextFormField);
      await tester.enterText(fields.first, gateway);
      await tester.enterText(fields.last, 'user.android');
      await tester.tap(find.text('导入 google-services.json'));
      await tester.pumpAndSettle();
      expect(
        (await FirebaseClientConfigStore().load())!.projectId,
        'user-project',
      );
      final settings = await PushSettingsStore().load(userId);
      expect(settings.enabled, isFalse);
      expect(settings.gatewayUrl, gateway);
      expect(settings.appId, 'user.android');
      expect(
        find.text('新配置已保存，请在系统设置中强行停止 Matter 后重新打开，再启用推送。'),
        findsOneWidget,
      );
      expect(fcmPushRuntime.configurationChanged, isTrue);
      final enable = tester.widget<NeuButton>(
        find.ancestor(of: find.text('启用推送'), matching: find.byType(NeuButton)),
      );
      expect(enable.onPressed, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('shows unsupported platform without enable controls', (
    tester,
  ) async {
    await showPage(tester);
    expect(find.text('此平台暂不支持消息推送'), findsOneWidget);
    expect(find.byType(TextFormField), findsNothing);
    expect(find.text('启用推送'), findsNothing);
  }, variant: TargetPlatformVariant({TargetPlatform.linux}));

  testWidgets(
    'offline disabling retains a retry and never requests an FCM token',
    (tester) async {
      final store = PushSettingsStore();
      await store.save(
        userId,
        const PushSettings(
          enabled: true,
          gatewayUrl: gateway,
          registrationId: 'id',
          registrations: [
            PushRegistration(token: 'token', appId: 'moe.aks.matter'),
          ],
        ),
      );
      var failDelete = true;
      var tokenRequests = 0;
      final manager = PushRegistrationManager(
        store: store,
        getToken: (_) async {
          tokenRequests++;
          throw StateError('should not request token');
        },
        register: (_, _, _) async => throw StateError('should not register'),
        unregister: (_, _) async {
          if (failDelete) throw StateError('offline');
        },
      );
      await showPage(tester, manager: manager);
      await tester.tap(find.text('关闭推送'));
      await tester.pumpAndSettle();
      expect(find.text('推送未启用'), findsOneWidget);
      expect(find.text('重试注销推送'), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(tokenRequests, 0);
      failDelete = false;
      await tester.tap(find.text('重试注销推送'));
      await tester.pumpAndSettle();
      expect((await store.load(userId)).registrations, isEmpty);
      expect(find.text('重试注销推送'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
