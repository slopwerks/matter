import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/push/firebase_client_config.dart';
import 'package:matter/features/push/fcm_push_runtime.dart';
import 'package:matter/features/push/notification_preferences.dart';
import 'package:matter/features/push/push_build_config.dart';
import 'package:matter/features/push/push_providers.dart';
import 'package:matter/features/push/push_registration_manager.dart';
import 'package:matter/features/push/push_settings.dart';
import 'package:matter/src/rust/api/matrix/notifications.dart';
import 'package:matter/pages/settings/notification_settings_page.dart';
import 'package:matter/widgets/neu_surface.dart';
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

class FakeNotificationPreferencesApi extends NotificationPreferencesApi {
  final values = {
    for (final rule in NotificationRule.values)
      rule: switch (rule) {
        NotificationRule.muteAll ||
        NotificationRule.memberEvent ||
        NotificationRule.reaction ||
        NotificationRule.groupMessage ||
        NotificationRule.encryptedGroupMessage => false,
        _ => true,
      },
  };
  final unsupported = <NotificationRule>{};
  final keywords = <String>[];
  final calls = <(String, NotificationRule, bool)>[];
  final keywordCalls = <(String, String, bool)>[];
  Object? readError;
  Object? writeError;
  Completer<void>? pending;
  final pendingRules = <NotificationRule, Completer<void>>{};
  final pendingKeywords = <String, Completer<void>>{};
  final writeErrors = <NotificationRule, Object>{};
  Completer<NotificationPreferences>? pendingRead;
  int loadCalls = 0;

  @override
  Future<NotificationPreferences> load(String userId) async {
    loadCalls++;
    if (readError case final error?) throw error;
    if (pendingRead != null) return pendingRead!.future;
    return NotificationPreferences(
      rules: [
        for (final entry in values.entries)
          NotificationRuleSetting(
            rule: entry.key,
            enabled: entry.value,
            supported: !unsupported.contains(entry.key),
          ),
      ],
      keywords: [...keywords],
    );
  }

  @override
  Future<void> setRule(
    String userId,
    NotificationRule rule,
    bool enabled,
  ) async {
    calls.add((userId, rule, enabled));
    final wait = pendingRules[rule] ?? pending;
    if (wait != null) await wait.future;
    if ((writeErrors[rule] ?? writeError) case final error?) throw error;
    values[rule] = enabled;
  }

  @override
  Future<void> setKeyword(String userId, String keyword, bool enabled) async {
    keywordCalls.add((userId, keyword, enabled));
    if (pendingKeywords[keyword] case final pending?) await pending.future;
    if (writeError case final error?) throw error;
    if (enabled) {
      keywords.add(keyword);
    } else {
      keywords.remove(keyword);
    }
  }
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
    FakeNotificationPreferencesApi? preferences,
    double width = 800,
    double height = 1600,
  }) async {
    tester.view.physicalSize = Size(width, height);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          notificationPreferencesApiProvider.overrideWithValue(
            preferences ?? FakeNotificationPreferencesApi(),
          ),
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

  Future<void> openPushSettings(WidgetTester tester) async {
    await tester.scrollUntilVisible(find.text('推送服务与网关'), 500);
    await tester.ensureVisible(find.text('推送服务与网关'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('推送服务与网关'));
    await tester.pumpAndSettle();
  }

  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  testWidgets('mute all preserves preferences and allows editing defaults', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    await showPage(tester, preferences: api);
    Finder tile(NotificationRule rule) => find.byKey(ValueKey(rule));
    await tester.tap(tile(NotificationRule.muteAll));
    await tester.pumpAndSettle();
    expect(api.calls, [(userId, NotificationRule.muteAll, true)]);
    final notice = tester.widget<SwitchListTile>(
      tile(NotificationRule.suppressNotices),
    );
    expect(notice.value, isTrue);
    expect(notice.onChanged, isNotNull);
    expect(
      tester
          .widget<DropdownButton<bool>>(tile(NotificationRule.directMessage))
          .onChanged,
      isNotNull,
    );
    await tester.tap(tile(NotificationRule.muteAll));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<SwitchListTile>(tile(NotificationRule.suppressNotices))
          .onChanged,
      isNotNull,
    );
    expect(api.values[NotificationRule.suppressNotices], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('saving one rule leaves layout and other settings available', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi()..pending = Completer<void>();
    await showPage(tester, preferences: api);
    final mention = find.byKey(const ValueKey(NotificationRule.userMention));
    final position = tester.getTopLeft(mention);
    await tester.tap(mention);
    await tester.pump();
    expect(api.calls, [(userId, NotificationRule.userMention, false)]);
    expect(tester.getTopLeft(mention), position);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    expect(tester.widget<SwitchListTile>(mention).onChanged, isNull);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey(NotificationRule.muteAll)),
          )
          .onChanged,
      isNotNull,
    );
    api.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    expect(tester.getTopLeft(mention), position);
    expect(api.loadCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'different rules save concurrently without replacing each other',
    (tester) async {
      final api = FakeNotificationPreferencesApi();
      final first = Completer<void>();
      final second = Completer<void>();
      api.pendingRules[NotificationRule.userMention] = first;
      api.pendingRules[NotificationRule.roomMention] = second;
      await showPage(tester, preferences: api);
      final userMention = find.byKey(
        const ValueKey(NotificationRule.userMention),
      );
      final roomMention = find.byKey(
        const ValueKey(NotificationRule.roomMention),
      );
      await tester.tap(userMention);
      await tester.pump();
      await tester.tap(roomMention);
      await tester.pump();
      expect(api.calls, [
        (userId, NotificationRule.userMention, false),
        (userId, NotificationRule.roomMention, false),
      ]);
      second.complete();
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(userMention).value, isFalse);
      expect(tester.widget<SwitchListTile>(roomMention).value, isFalse);
      expect(tester.widget<SwitchListTile>(roomMention).onChanged, isNotNull);
      first.complete();
      await tester.pumpAndSettle();
      expect(api.values[NotificationRule.userMention], isFalse);
      expect(api.values[NotificationRule.roomMention], isFalse);
      expect(api.loadCalls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed rule does not revert another pending change', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    final first = Completer<void>();
    final second = Completer<void>();
    api.pendingRules[NotificationRule.userMention] = first;
    api.pendingRules[NotificationRule.roomMention] = second;
    api.writeErrors[NotificationRule.userMention] = StateError('offline');
    await showPage(tester, preferences: api);
    final userMention = find.byKey(
      const ValueKey(NotificationRule.userMention),
    );
    final roomMention = find.byKey(
      const ValueKey(NotificationRule.roomMention),
    );
    await tester.tap(userMention);
    await tester.pump();
    await tester.tap(roomMention);
    await tester.pump();
    first.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(userMention).value, isTrue);
    expect(tester.widget<SwitchListTile>(roomMention).value, isFalse);
    expect(tester.widget<SwitchListTile>(roomMention).onChanged, isNull);
    second.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(roomMention).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an older refresh cannot replace a newer saved preference', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    await showPage(tester, preferences: api);
    final oldSnapshot = await api.load(userId);
    final refresh = Completer<NotificationPreferences>();
    api.pendingRead = refresh;
    await tester.tap(find.byTooltip('刷新通知偏好'));
    await tester.pump();
    final mention = find.byKey(const ValueKey(NotificationRule.userMention));
    await tester.tap(mention);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    refresh.complete(oldSnapshot);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    api.pendingRead = null;
    await tester.tap(find.byTooltip('刷新通知偏好'));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed save reports error and retains server state', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi()
      ..writeError = StateError('offline');
    await showPage(tester, preferences: api);
    final mention = find.byKey(const ValueKey(NotificationRule.userMention));
    final position = tester.getTopLeft(mention);
    await tester.tap(mention);
    await tester.pumpAndSettle();
    expect(find.textContaining('保存失败：'), findsOneWidget);
    expect(tester.getTopLeft(mention), position);
    expect(
      tester
          .widget<SwitchListTile>(
            find.byKey(const ValueKey(NotificationRule.userMention)),
          )
          .value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('unsupported rules are disabled and reads can be retried', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi()
      ..readError = StateError('offline')
      ..unsupported.add(NotificationRule.displayName);
    await showPage(tester, preferences: api);
    expect(find.text('读取通知偏好失败'), findsOneWidget);
    api.readError = null;
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const ValueKey(NotificationRule.displayName)),
      300,
    );
    final displayName = tester.widget<SwitchListTile>(
      find.byKey(const ValueKey(NotificationRule.displayName)),
    );
    expect(displayName.onChanged, isNull);
    expect(find.textContaining('此服务器不支持该规则'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keywords can be added and removed on a narrow screen', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    await showPage(tester, preferences: api, width: 390, height: 844);
    await tester.scrollUntilVisible(find.byTooltip('添加关键词'), 500);
    await tapVisible(tester, find.byTooltip('添加关键词'));
    await tester.enterText(find.byType(TextField), '  Matter  ');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(api.keywordCalls, [(userId, 'Matter', true)]);
    expect(find.text('Matter'), findsOneWidget);
    tester.widget<InputChip>(find.byType(InputChip)).onDeleted!();
    await tester.pumpAndSettle();
    expect(api.keywords, isEmpty);
    expect(api.keywordCalls.last, (userId, 'Matter', false));
    await openPushSettings(tester);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending keyword saves allow other notification edits', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    final keywordSave = Completer<void>();
    api.pendingKeywords['Matter'] = keywordSave;
    await showPage(tester, preferences: api);
    await tester.scrollUntilVisible(find.byTooltip('添加关键词'), 500);
    await tapVisible(tester, find.byTooltip('添加关键词'));
    await tester.enterText(find.byType(TextField), 'Matter');
    await tester.tap(find.text('添加'));
    await tester.pumpAndSettle();
    expect(tester.widget<InputChip>(find.byType(InputChip)).onDeleted, isNull);
    final mention = find.byKey(const ValueKey(NotificationRule.userMention));
    await tester.scrollUntilVisible(mention, -500);
    await tapVisible(tester, mention);
    expect(api.calls, [(userId, NotificationRule.userMention, false)]);
    expect(api.loadCalls, 1);
    keywordSave.complete();
    await tester.pumpAndSettle();
    expect(api.keywords, ['Matter']);
    expect(tester.widget<SwitchListTile>(mention).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('chat mode updates only its matching message rule', (
    tester,
  ) async {
    final api = FakeNotificationPreferencesApi();
    await showPage(tester, preferences: api);
    final mode = find.byKey(const ValueKey(NotificationRule.directMessage));
    await tester.tap(mode);
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅提及').last);
    await tester.pumpAndSettle();
    expect(api.calls, [(userId, NotificationRule.directMessage, false)]);
    expect(api.values[NotificationRule.encryptedDirectMessage], isTrue);
    expect(api.values[NotificationRule.userMention], isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unconfigured build starts disabled and cannot enable FCM', (
    tester,
  ) async {
    await showPage(tester);
    expect(find.byType(TextFormField), findsNothing);
    await openPushSettings(tester);
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
    if (!prefilled) {
      expect(find.text('尚未配置 Firebase 项目，暂不可启用 Android 推送'), findsOneWidget);
    }
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
      await openPushSettings(tester);
      final fields = find.byType(TextFormField);
      await tester.ensureVisible(fields.first);
      await tester.enterText(fields.first, gateway);
      await tester.ensureVisible(fields.last);
      await tester.enterText(fields.last, 'user.android');
      await tapVisible(tester, find.text('导入 google-services.json'));
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
    expect(find.text('全部静音'), findsOneWidget);
    await openPushSettings(tester);
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
      await openPushSettings(tester);
      await tapVisible(tester, find.text('关闭推送'));
      expect(find.text('推送未启用'), findsOneWidget);
      expect(find.text('重试注销推送'), findsOneWidget);
      expect(find.textContaining('offline'), findsOneWidget);
      expect(tokenRequests, 0);
      failDelete = false;
      await tapVisible(tester, find.text('重试注销推送'));
      expect((await store.load(userId)).registrations, isEmpty);
      expect(find.text('重试注销推送'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
