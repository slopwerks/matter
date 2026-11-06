import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/file_message_bubble.dart';
import 'package:matter/pages/chat/message_reader_page.dart';
import 'package:matter/src/rust/frb_generated.dart';
import 'package:matter/widgets/neu_surface.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';
import 'support/temp_path_provider.dart';

class _AttachmentApi implements RustLibApi {
  Uint8List bytes = Uint8List.fromList(
    utf8.encode('# Heading\n\n**Bold text**'),
  );
  final requests = <String>[];

  @override
  Future<Uint8List?> crateApiMatrixDownloadMediaBytes({
    required String mxcUrl,
  }) async {
    requests.add(mxcUrl);
    return bytes;
  }

  @override
  Future<Uint8List> crateApiMatrixDownloadMediaSourceBytes({
    required String mediaSourceJson,
    int? maxSizeBytes,
  }) async {
    requests.add(mediaSourceJson);
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Paths extends TempPathProvider {
  _Paths(super.root);
  @override
  Future<String?> getDownloadsPath() async => '${root.path}/Downloads';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AttachmentApi api;
  late Directory directory;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    api = _AttachmentApi();
    RustLib.initMock(api: api);
    directory = await Directory.systemTemp.createTemp('matter-md-test');
    final previous = PathProviderPlatform.instance;
    PathProviderPlatform.instance = _Paths(directory);
    addTearDown(() => PathProviderPlatform.instance = previous);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('moe.aks.matter/downloads'),
          (call) async {
            return call.method == 'start' ? 10001 : null;
          },
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('moe.aks.matter/downloads'),
          null,
        );
    RustLib.dispose();
    await directory.delete(recursive: true);
  });

  Future<void> pumpAttachment(
    WidgetTester tester, {
    String filename = 'README.MD',
    bool encrypted = false,
    bool material = false,
    int? fileSize,
  }) => tester.pumpWidget(
    MaterialApp(
      theme: neuTestTheme(material: material),
      home: Scaffold(
        body: Center(
          child: FileMessageBubble(
            filename: filename,
            fileSize: fileSize,
            imageUrl: encrypted ? null : 'mxc://example.org/file',
            mediaSourceJson: encrypted ? 'encrypted-source' : null,
            isMe: false,
            metadata: const SizedBox.shrink(),
          ),
        ),
      ),
    ),
  );

  for (final material in [false, true]) {
    for (final encrypted in [false, true]) {
      testWidgets(
        'Markdown opens in the reader (material=$material, encrypted=$encrypted)',
        (tester) async {
          await pumpAttachment(
            tester,
            encrypted: encrypted,
            material: material,
          );
          await tester.tap(find.text('README.MD'));
          await tester.pumpAndSettle();
          expect(find.byType(MessageReaderPage), findsOneWidget);
          expect(find.text('Heading', findRichText: true), findsOneWidget);
          expect(find.text('Bold text', findRichText: true), findsOneWidget);
          expect(find.byTooltip('下载文件'), findsOneWidget);
          expect(find.byTooltip('用其他应用打开'), findsOneWidget);
          expect(
            api.requests.single,
            encrypted ? 'encrypted-source' : 'mxc://example.org/file',
          );
          final saveButton = tester.widget<NeuIconButton>(
            find.byWidgetPredicate(
              (widget) => widget is NeuIconButton && widget.tooltip == '下载文件',
            ),
          );
          await tester.runAsync(() async {
            expect(
              await Directory('${directory.path}/Downloads').exists(),
              isFalse,
            );
            await (saveButton.onPressed! as Future<void> Function())();
            expect(
              await File('${directory.path}/Downloads/README.MD').readAsBytes(),
              api.bytes,
            );
          });
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final reader in [false, true]) {
    testWidgets('desktop Save As uses the chosen path (reader=$reader)', (
      tester,
    ) async {
      final selected = '${directory.path}/chosen.md';
      const selector = MethodChannel('plugins.flutter.io/file_selector');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(selector, (call) async => selected);
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(selector, null),
      );
      await pumpAttachment(tester);
      if (reader) {
        await tester.tap(find.text('README.MD'));
        await tester.pumpAndSettle();
      }
      final onPressed = reader
          ? tester
                .widget<NeuIconButton>(
                  find.byWidgetPredicate(
                    (widget) =>
                        widget is NeuIconButton && widget.tooltip == '另存为',
                  ),
                )
                .onPressed!
          : tester
                .widget<IconButton>(
                  find.byWidgetPredicate(
                    (widget) => widget is IconButton && widget.tooltip == '另存为',
                  ),
                )
                .onPressed!;
      await tester.runAsync(() async {
        onPressed();
        final file = File(selected);
        for (var i = 0; i < 100; i++) {
          if (await file.exists() && await file.length() == api.bytes.length) {
            break;
          }
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(await file.readAsBytes(), api.bytes);
        expect(
          await Directory('${directory.path}/Downloads').exists(),
          isFalse,
        );
      });
      await tester.pumpAndSettle();
      expect(api.requests, hasLength(1));
    }, variant: TargetPlatformVariant.only(TargetPlatform.linux));
  }

  testWidgets('plain Markdown still opens as readable text', (tester) async {
    api.bytes = Uint8List.fromList(utf8.encode('hello & welcome'));
    await pumpAttachment(tester, filename: 'notes.markdown');
    await tester.tap(find.text('notes.markdown'));
    await tester.pumpAndSettle();
    expect(find.byType(MessageReaderPage), findsOneWidget);
    expect(find.text('hello & welcome', findRichText: true), findsOneWidget);
  });

  testWidgets(
    'invalid UTF-8 reports a preview error without opening the reader',
    (tester) async {
      api.bytes = Uint8List.fromList([0xff, 0xfe, 0x80]);
      await pumpAttachment(tester);
      await tester.tap(find.text('README.MD'));
      await tester.pumpAndSettle();
      expect(find.byType(MessageReaderPage), findsNothing);
      expect(find.textContaining('预览失败'), findsOneWidget);
      expect(find.byTooltip('下载文件'), findsOneWidget);
    },
  );

  for (final declared in [false, true]) {
    testWidgets(
      'oversized Markdown preserves the download action (declared=$declared)',
      (tester) async {
        if (!declared) api.bytes = Uint8List(2 * 1024 * 1024 + 1);
        await pumpAttachment(
          tester,
          fileSize: declared ? 3 * 1024 * 1024 : null,
        );
        await tester.tap(find.text('README.MD'));
        await tester.pumpAndSettle();
        expect(find.byType(MessageReaderPage), findsNothing);
        expect(find.textContaining('文件超过 2 MB'), findsOneWidget);
        expect(find.byTooltip('下载文件'), findsOneWidget);
        expect(api.requests.length, declared ? 0 : 1);
      },
    );
  }

  testWidgets('external opening receives the original Markdown file', (
    tester,
  ) async {
    const channel = MethodChannel('moe.aks.matter/file_saver');
    String? openedPath;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'openFile');
          openedPath = (call.arguments as Map)['path'] as String;
          return true;
        });
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null),
    );
    await pumpAttachment(tester);
    await tester.tap(find.text('README.MD'));
    await tester.pumpAndSettle();
    final button = tester.widget<NeuIconButton>(
      find.byWidgetPredicate(
        (widget) => widget is NeuIconButton && widget.tooltip == '用其他应用打开',
      ),
    );
    await tester.runAsync(() async {
      await (button.onPressed! as Future<void> Function())();
      expect(openedPath, endsWith('/README.MD'));
      expect(openedPath, contains('/matter_open_files/'));
      expect(await File(openedPath!).readAsBytes(), api.bytes);
    });
    await tester.pumpAndSettle();
  });

  testWidgets('ordinary files keep the download action', (tester) async {
    await pumpAttachment(tester, filename: 'report.pdf');
    final dynamic download = tester.widget<InkWell>(find.byType(InkWell)).onTap;
    await tester.runAsync(() async {
      await download();
      expect(
        await File('${directory.path}/Downloads/report.pdf').readAsBytes(),
        api.bytes,
      );
    });
    await tester.pumpAndSettle();
    expect(find.byType(MessageReaderPage), findsNothing);
  });
}
