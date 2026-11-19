import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/desktop_file_drop.dart';

void main() {
  late Directory temp;
  setUp(
    () async => temp = await Directory.systemTemp.createTemp('matter-drop-'),
  );
  tearDown(() async => temp.delete(recursive: true));

  testWidgets(
    'hover overlay and mixed files arrive in order, folders stay out',
    (tester) async {
      final image = File('${temp.path}/shot.png')..writeAsBytesSync([1]);
      final document = File('${temp.path}/report.pdf')..writeAsBytesSync([2]);
      final received = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData(platform: TargetPlatform.linux),
          home: Scaffold(
            body: DesktopFileDrop(
              onFiles: (files) async =>
                  received.addAll(files.map((f) => f.path)),
              child: const SizedBox.expand(),
            ),
          ),
        ),
      );
      var target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragEntered!(
        DropEventDetails(
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      await tester.pump();
      expect(find.text('松开以预览并发送附件'), findsOneWidget);
      target = tester.widget<DropTarget>(find.byType(DropTarget));
      target.onDragDone!(
        DropDoneDetails(
          files: [
            DropItemFile(image.path),
            DropItemFile(temp.path),
            DropItemFile(document.path),
          ],
          localPosition: Offset.zero,
          globalPosition: Offset.zero,
        ),
      );
      for (var i = 0; i < 10; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump();
      }
      expect(received, [image.path, document.path]);
      expect(find.text('松开以预览并发送附件'), findsNothing);
      expect(find.textContaining('暂不支持发送文件夹'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('covering routes disable drop targets until they close', (
    tester,
  ) async {
    late BuildContext home;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.linux),
        home: Builder(
          builder: (context) {
            home = context;
            return Scaffold(
              body: DesktopFileDrop(
                onFiles: (_) async {},
                child: const SizedBox.expand(),
              ),
            );
          },
        ),
      ),
    );
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);
    final dialog = showDialog<void>(
      context: home,
      builder: (_) => const AlertDialog(content: Text('预览')),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<DropTarget>(find.byType(DropTarget, skipOffstage: false))
          .enable,
      isFalse,
    );
    Navigator.of(home).pop();
    await dialog;
    await tester.pumpAndSettle();
    expect(tester.widget<DropTarget>(find.byType(DropTarget)).enable, isTrue);
  });

  testWidgets('phone and tablet keep native touch interaction', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(platform: TargetPlatform.android),
        home: DesktopFileDrop(
          onFiles: (_) async {},
          child: const Text('touch'),
        ),
      ),
    );
    expect(find.byType(DropTarget), findsNothing);
    expect(find.text('touch'), findsOneWidget);
  });
}
