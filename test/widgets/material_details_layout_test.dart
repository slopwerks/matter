import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/app.dart';
import 'package:matter/pages/chat/space_detail_page.dart';
import 'package:matter/pages/contacts/contact_profile_page.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/pages/settings/composer_keyboard_settings_page.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/providers/composer_keyboard_settings_provider.dart';
import 'package:matter/providers/connection_provider.dart';
import 'package:matter/providers/navigation_provider.dart';
import 'package:matter/providers/startup_page_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/widgets/material_tab_navigation_bar.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _contact = rust.Contact(
  id: '@alice:example.org',
  name: 'Alice',
  status: 'online',
);
const _space = rust.Space(id: '!space:example.org', name: '设计空间');

class _Api implements RustLibApi {
  Completer<String>? dm;
  final requests = <({String account, String user})>[];

  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  Future<String> crateApiMatrixCreateDm({
    required String accountUserId,
    required String userId,
  }) {
    requests.add((account: accountUserId, user: userId));
    return dm!.future;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

Future<void> _resize(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  await tester.binding.setSurfaceSize(Size(width, 800));
  await tester.pumpAndSettle();
}

Future<ProviderContainer> _pump(
  WidgetTester tester, {
  required StartupPage start,
  double width = 400,
  bool dark = false,
}) async {
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await _resize(tester, width);
  final container = ProviderContainer(
    overrides: [
      allChatRoomsProvider.overrideWith((ref) async => []),
      spacesProvider.overrideWith((ref) async => [_space]),
      ungroupedRoomsProvider.overrideWith((ref) async => []),
      contactsProvider.overrideWith((ref) async => [_contact]),
      syncStreamProvider.overrideWith((ref) => null),
      spaceDetailsProvider.overrideWith(
        (ref, id) async =>
            rust.SpaceDetails(id: id, name: _space.name, topic: '一起打磨产品与界面'),
      ),
      spaceChildrenProvider.overrideWith((ref, id) async => []),
      allSpaceChildrenProvider.overrideWith((ref, id) async => []),
      roomMembersProvider.overrideWith((ref, id) async => [_contact]),
    ],
  );
  addTearDown(container.dispose);
  container.read(activeUserIdProvider.notifier).value = '@me:example.org';
  container.read(connectionProvider.notifier).value =
      AppConnectionState.connected;
  await container.read(startupPageProvider.notifier).setPage(start);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: buildMaterialTheme(dark ? Brightness.dark : Brightness.light),
        home: const MatterApp(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  addTearDown(() => tester.pumpWidget(const SizedBox()));
  return container;
}

void main() {
  final api = _Api();
  setUpAll(() => RustLib.initMock(api: api));
  tearDownAll(RustLib.dispose);
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'app_theme_style': 'materialLight',
    });
    api.requests.clear();
    api.dm = null;
  });

  testWidgets('settings keep the detail and edited preference across widths', (
    tester,
  ) async {
    final container = await _pump(tester, start: StartupPage.settings);
    await tester.ensureVisible(find.text('键盘发送与换行'));
    await tester.tap(find.text('键盘发送与换行'));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialTabNavigationBar), findsNothing);
    final detail = tester.element(find.byType(ComposerKeyboardSettingsPage));
    final dropdown = find.byKey(const ValueKey('composer-key-action-enter'));
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('换行').last);
    await tester.pumpAndSettle();
    expect(
      container.read(composerKeyboardSettingsProvider).enter,
      ComposerEnterAction.newline,
    );
    for (final width in [600.0, 840.0, 1200.0, 1600.0, 400.0]) {
      await _resize(tester, width);
      expect(
        tester.element(find.byType(ComposerKeyboardSettingsPage)),
        same(detail),
      );
      expect(
        tester
            .widget<DropdownMenu<ComposerEnterAction>>(dropdown)
            .initialSelection,
        ComposerEnterAction.newline,
      );
      expect(tester.takeException(), isNull);
    }
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComposerKeyboardSettingsPage), findsNothing);
    expect(find.byType(MaterialTabNavigationBar), findsOneWidget);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'phone profile never exposes the split placeholder, dark=$dark',
      (tester) async {
        await _pump(tester, start: StartupPage.contacts, dark: dark);
        await tester.tap(find.text('Alice'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('选择一位联系人'), findsNothing);
        await tester.pumpAndSettle();
        await tester.tap(find.byType(BackButton));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('选择一位联系人'), findsNothing);
        for (var frame = 0; frame < 20; frame++) {
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.byType(ContactProfilePage), findsNothing);
        expect(find.text('Alice'), findsOneWidget);
        expect(find.byType(MaterialTabNavigationBar), findsOneWidget);
        await tester.pumpAndSettle();
      },
    );

    testWidgets('space selection and tabs survive resizing, dark=$dark', (
      tester,
    ) async {
      await _pump(tester, start: StartupPage.spaces, width: 1600, dark: dark);
      await tester.tap(find.text(_space.name));
      await tester.pumpAndSettle();
      final detail = tester.state(find.byType(SpaceDetailPage));
      await tester.tap(find.text('成员'));
      await tester.pumpAndSettle();
      expect(find.text('Alice'), findsOneWidget);
      await _resize(tester, 400);
      expect(tester.state(find.byType(SpaceDetailPage)), same(detail));
      expect(find.text('Alice'), findsOneWidget);
      expect(find.byType(MaterialTabNavigationBar), findsNothing);
      await tester.tap(find.text('关于'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('编辑空间'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).first, '尚未保存的名称');
      await _resize(tester, 1600);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        '尚未保存的名称',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.text('空间管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('system back leaves the inactive destination stack intact', (
    tester,
  ) async {
    await _pump(tester, start: StartupPage.contacts, width: 1200);
    await tester.tap(find.text('Alice'));
    await tester.pumpAndSettle();
    final profile = tester.element(find.byType(ContactProfilePage));
    final rail = find.byType(NavigationRail);
    await tester.tap(find.descendant(of: rail, matching: find.text('设置')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('键盘发送与换行'));
    await tester.tap(find.text('键盘发送与换行'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ComposerKeyboardSettingsPage), findsNothing);
    await tester.tap(find.descendant(of: rail, matching: find.text('通讯录')));
    await tester.pumpAndSettle();
    expect(tester.element(find.byType(ContactProfilePage)), same(profile));
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(ContactProfilePage), findsNothing);
    expect(find.text('选择一位联系人'), findsOneWidget);
  });

  testWidgets(
    'profile copies the real ID and sends after its row is filtered',
    (tester) async {
      api.dm = Completer<String>();
      final container = await _pump(
        tester,
        start: StartupPage.contacts,
        width: 1600,
      );
      final opened = <rust.ChatRoom>[];
      container.read(desktopRoomNavigationProvider).open = (room, {messageId}) {
        opened.add(room);
        return true;
      };
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      expect(find.byType(ContactProfilePage), findsOneWidget);
      String? copiedId;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedId = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await tester.tap(find.text('复制 ID'));
      await tester.pumpAndSettle();
      expect(copiedId, _contact.id);
      await tester.enterText(find.byType(TextField), 'nobody');
      await tester.pumpAndSettle();
      expect(find.text('暂无联系人'), findsOneWidget);
      await tester.tap(find.text('发消息'));
      await tester.pump();
      expect(api.requests, [(account: '@me:example.org', user: _contact.id)]);
      api.dm!.complete('!dm:example.org');
      await tester.pumpAndSettle();
      expect(opened.single.id, '!dm:example.org');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'profile and row share the DM guard and suppress stale navigation',
    (tester) async {
      api.dm = Completer<String>();
      final container = await _pump(
        tester,
        start: StartupPage.contacts,
        width: 1600,
      );
      final opened = <rust.ChatRoom>[];
      container.read(desktopRoomNavigationProvider).open = (room, {messageId}) {
        opened.add(room);
        return true;
      };
      final rowAction = tester
          .widget<IconButton>(
            find.descendant(
              of: find.byType(ContactsPage),
              matching: find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == '发消息',
              ),
            ),
          )
          .onPressed!;
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('发消息'));
      rowAction();
      await tester.pump();
      expect(api.requests, hasLength(1));
      container.read(activeUserIdProvider.notifier).value =
          '@other:example.org';
      await tester.pumpAndSettle();
      api.dm!.complete('!stale:example.org');
      await tester.pumpAndSettle();
      expect(opened, isEmpty);
      expect(find.byType(ContactProfilePage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
