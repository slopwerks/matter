import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/create_chat_page.dart';
import 'package:matter/pages/chat/hidden_rooms_page.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/pages/chat/search_page.dart';
import 'package:matter/pages/chat/space_page.dart';
import 'package:matter/pages/contacts/contacts_page.dart';
import 'package:matter/pages/settings/blur_settings_page.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/widgets/glass.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RustApi implements RustLibApi {
  @override
  Future<List<rust.AccountInfo>> crateApiMatrixListAccounts() async => [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected Rust call: ${invocation.memberName}');
}

void main() {
  setUpAll(() => RustLib.initMock(api: _RustApi()));
  tearDownAll(RustLib.dispose);
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final brightness in Brightness.values) {
    for (final example in [
      (page: const ContactsPage(), marker: '搜索联系人'),
      (page: const SpacePage(), marker: '还没有加入空间'),
      (page: const CreateChatPage(), marker: '输入 @用户 ID 发起私聊'),
      (
        page: const MessageReaderPage(html: '<p>First line</p>'),
        marker: 'First line',
      ),
      (page: const BlurSettingsPage(), marker: '总体效果'),
      (page: const HiddenRoomsPage(), marker: '暂无隐藏的聊天'),
      (page: const ChatSearchPage(), marker: null),
      (page: const ChatSearchPage(roomId: '!room:example.org'), marker: null),
    ]) {
      testWidgets(
        '${example.page.runtimeType}${example.page is ChatSearchPage ? ' ${(example.page as ChatSearchPage).roomId ?? 'global'}' : ''} floats above content in $brightness',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.binding.setSurfaceSize(const Size(320, 700));
          tester.view.padding = const FakeViewPadding(top: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          addTearDown(tester.view.resetPadding);
          addTearDown(tester.view.resetViewPadding);
          final container = ProviderContainer(
            overrides: [
              allChatRoomsProvider.overrideWith((ref) async => []),
              contactsProvider.overrideWith((ref) async => []),
              spacesProvider.overrideWith((ref) async => []),
              ungroupedRoomsProvider.overrideWith((ref) async => []),
            ],
          );
          addTearDown(container.dispose);
          final navigator = GlobalKey<NavigatorState>();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp(
                theme: buildMaterialTheme(brightness),
                navigatorKey: navigator,
                home: const SizedBox(),
              ),
            ),
          );
          navigator.currentState!.push(
            MaterialPageRoute<void>(builder: (_) => example.page),
          );
          await tester.pumpAndSettle();

          final header = find.byType(AppBar);
          final appBar = tester.widget<AppBar>(header);
          final scaffold = find
              .ancestor(of: header, matching: find.byType(Scaffold))
              .first;
          expect(
            tester.widget<Scaffold>(scaffold).extendBodyBehindAppBar,
            isTrue,
          );
          expect(appBar.backgroundColor, Colors.transparent);
          final fade = find.descendant(
            of: header,
            matching: find.byType(TopFadeBlur),
          );
          expect(fade, findsOneWidget);
          final background = tester.widget<DecoratedBox>(
            find.descendant(
              of: fade,
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is BoxDecoration &&
                    (widget.decoration as BoxDecoration).gradient
                        is LinearGradient,
              ),
            ),
          );
          final gradient =
              (background.decoration as BoxDecoration).gradient!
                  as LinearGradient;
          expect(gradient.begin, Alignment.topCenter);
          expect(gradient.end, Alignment.bottomCenter);
          expect(
            gradient.colors.first.withValues(alpha: 1),
            Theme.of(tester.element(header)).extension<NeuColors>()!.base,
          );
          expect(gradient.colors.first.a, greaterThan(0));
          expect(gradient.colors.first.a, lessThan(1));
          expect(gradient.colors.last.a, 0);
          expect(tester.getSize(fade), tester.getSize(header));
          expect(
            tester.getRect(header).height,
            appBar.preferredSize.height + 24,
          );
          if (example.marker case final marker?) {
            expect(
              tester.getTopLeft(find.text(marker)).dy,
              greaterThanOrEqualTo(tester.getBottomLeft(header).dy),
            );
          }
          expect(tester.takeException(), isNull);
          // Keep the standard back action reachable above the fading background.
          final back = example.page is ChatSearchPage
              ? find.byTooltip('返回')
              : example.page is MessageReaderPage
              ? find.byTooltip('关闭')
              : find.byType(BackButton);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(header, findsNothing);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }
}
