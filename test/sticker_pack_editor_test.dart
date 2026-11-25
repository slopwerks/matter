import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matter/pages/chat/sticker_pack_editor.dart';
import 'package:matter/providers/auth_provider.dart';
import 'package:matter/providers/chat_provider.dart';
import 'package:matter/src/rust/api/matrix.dart' as rust;
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/theme/material_theme.dart';
import 'package:matter/theme/neu_colors.dart';
import 'package:matter/theme/neu_theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Api implements RustLibApi {
  bool allowed = true;
  bool conflict = true;
  final writes = <String?>[];

  @override
  Future<bool> crateApiMatrixCanEditStickerPacks({
    required String accountUserId,
    required String roomId,
  }) async => allowed;

  @override
  Future<rust.StickerPackSnapshot> crateApiMatrixGetStickerPackSnapshot({
    required String accountUserId,
    required rust.StickerPackKey key,
  }) async {
    expect(key.stateKey, '');
    return const rust.StickerPackSnapshot(
      legacyVersion: 'legacy-id',
      contentJson: '{"pack":{"display_name":"Cats","attribution":"Artist"},"images":{"cat":{"url":"mxc://example.org/cat","info":{"w":3,"h":2,"mimetype":"image/png"}}}}',
    );
  }

  @override
  Future<void> crateApiMatrixWriteStickerPack({
    required String accountUserId,
    required rust.StickerPackKey key,
    String? stableVersion,
    String? legacyVersion,
    String? contentJson,
  }) async {
    expect(key.stateKey, '');
    expect(accountUserId, '@user:e');
    expect(legacyVersion, 'legacy-id');
    expect(stableVersion, isNull);
    writes.add(contentJson);
    if (conflict) throw '版本冲突';
  }

  @override
  Future<String?> crateApiMatrixMxcToHttpFull({required String mxcUrl}) async =>
      null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Api api;
  late ProviderContainer container;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    api = _Api();
    RustLib.initMock(api: api);
    container = ProviderContainer();
    container.read(activeUserIdProvider.notifier).value = '@user:e';
    container.read(sessionReadyProvider.notifier).value = true;
  });
  tearDown(() {
    container.dispose();
    RustLib.dispose();
  });

  Future<void> open(
    WidgetTester tester, {
    String? key,
    bool neu = false,
  }) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neu
              ? buildNeuTheme(NeuColors.dark, Brightness.dark)
              : buildMaterialTheme(Brightness.light),
          home: StickerPackEditor(
            account: '@user:e',
            roomId: '!room:e',
            stateKey: key,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('empty draft cannot publish', (tester) async {
    await open(tester);
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
          .onPressed,
      isNull,
    );
    expect(api.writes, isEmpty);
  });

  for (final neu in [false, true]) {
    testWidgets(
      'editing keeps draft across conflict and permission changes ($neu)',
      (tester) async {
        await open(tester, key: '', neu: neu);
        await tester.enterText(find.byType(TextFormField).at(0), '新名称');
        await tester.enterText(find.byType(TextFormField).at(1), 'new_cat');
        await tester.enterText(find.byType(TextFormField).at(2), '新描述');
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(find.textContaining('版本冲突'), findsOneWidget);
        final saved = jsonDecode(api.writes.single!);
        expect(saved['pack'], {'display_name': '新名称', 'attribution': 'Artist'});
        expect(saved['images']['new_cat']['body'], '新描述');
        expect(saved['images']['new_cat']['info'], {
          'w': 3,
          'h': 2,
          'mimetype': 'image/png',
        });
        api.allowed = false;
        container.invalidate(stickerPackEditPermissionProvider('!room:e'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<TextButton>(find.widgetWithText(TextButton, '保存'))
              .onPressed,
          isNull,
        );
        expect(find.text('新描述'), findsOneWidget);
      },
    );
  }

  testWidgets('removing last sticker requires explicit pack deletion', (
    tester,
  ) async {
    await open(tester, key: '');
    await tester.tap(find.byTooltip('移除贴纸'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(api.writes, isEmpty);
    await tester.tap(find.byTooltip('移除贴纸'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除贴纸包'));
    await tester.pumpAndSettle();
    expect(api.writes, [null]);
    expect(find.textContaining('版本冲突'), findsOneWidget);
  });
}
