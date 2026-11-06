import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/settings/storage_number_picker.dart';

import 'helpers/neu_test_theme.dart';

const _downloadStops = {
  0: '点击下载',
  1: '1 MiB',
  5: '5 MiB',
  10: '10 MiB',
  20: '20 MiB',
  50: '50 MiB',
  100: '100 MiB',
  500: '500 MiB',
};
final _screenshots =
    Platform.environment['MATTER_STORAGE_PICKER_SCREENSHOTS'] == '1';

ThemeData _previewTheme(ThemeData theme) {
  const font = 'StoragePickerFont';
  final label = WidgetStatePropertyAll(
    theme.textTheme.labelLarge?.copyWith(fontFamily: font),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: font),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: font),
    dialogTheme: theme.dialogTheme.copyWith(
      titleTextStyle: theme.dialogTheme.titleTextStyle?.copyWith(
        fontFamily: font,
      ),
      contentTextStyle: theme.dialogTheme.contentTextStyle?.copyWith(
        fontFamily: font,
      ),
    ),
    listTileTheme: theme.listTileTheme.copyWith(
      titleTextStyle: theme.listTileTheme.titleTextStyle?.copyWith(
        fontFamily: font,
      ),
      subtitleTextStyle: theme.listTileTheme.subtitleTextStyle?.copyWith(
        fontFamily: font,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: theme.textButtonTheme.style?.copyWith(textStyle: label),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: theme.filledButtonTheme.style?.copyWith(textStyle: label),
    ),
  );
}

Future<GlobalKey> _open(
  WidgetTester tester, {
  bool material = true,
  bool dark = false,
  double scale = 1,
  int current = 10,
  Map<int, String> stops = _downloadStops,
  String unit = 'MiB',
  String? zeroLabel = '关闭自动下载',
  ValueChanged<int?>? onPicked,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final boundary = GlobalKey();
  final theme = neuTestTheme(material: material, dark: dark);
  await tester.pumpWidget(
    RepaintBoundary(
      key: boundary,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: _screenshots ? _previewTheme(theme) : theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async {
                final result = await pickStorageNumber(
                  context,
                  unit == '天' ? '私聊 · 保留时长' : '移动数据 · 图片原图',
                  current,
                  stops,
                  unit: unit,
                  zeroLabel: zeroLabel,
                );
                onPicked?.call(result);
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return boundary;
}

void main() {
  setUpAll(() async {
    if (_screenshots) {
      final bytes = await File(
        '/usr/share/fonts/sarasa-gothic/Sarasa-Regular.ttc',
      ).readAsBytes();
      await (FontLoader(
        'StoragePickerFont',
      )..addFont(Future.value(ByteData.sublistView(bytes)))).load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });

  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        testWidgets('compact picker material=$material dark=$dark scale=$scale', (
          tester,
        ) async {
          final key = await _open(
            tester,
            material: material,
            dark: dark,
            scale: scale,
          );
          if (_screenshots && scale == 1) {
            await tester.runAsync(() async {
              final boundary =
                  key.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              final image = await boundary.toImage(pixelRatio: 2);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final prefix =
                  Platform.environment['MATTER_STORAGE_PICKER_PREFIX'] ??
                  'after';
              await File(
                '/tmp/matter-storage-picker-$prefix-${material ? 'material' : 'neu'}-${dark ? 'dark' : 'light'}.png',
              ).writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          if (scale == 1) {
            final surface = find
                .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(Material),
                )
                .first;
            expect(
              tester.getSize(surface).height,
              lessThan(400),
              reason: 'Do not fill the screen with preset rows',
            );
          }
          expect(find.byType(Slider), findsOneWidget);
          expect(find.byType(TextField), findsOneWidget);
          expect(find.byType(ListTile), findsNothing);
          expect(
            tester.widget<Slider>(find.byType(Slider)).divisions,
            _downloadStops.length - 1,
          );
          expect(find.textContaining('0 表示关闭自动下载'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets(
    'dragging the slider updates the input and confirms a common value',
    (tester) async {
      int? result;
      await _open(tester, current: 0, onPicked: (value) => result = value);
      await tester.drag(find.byType(Slider), const Offset(85, 0));
      await tester.pumpAndSettle();
      final value = int.parse(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
      );
      expect(value, greaterThan(0));
      expect(_downloadStops.keys, contains(value));
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, value);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  for (final value in [0, 17, 1500]) {
    testWidgets('exact input $value stays synchronized and saves unchanged', (
      tester,
    ) async {
      int? result;
      await _open(tester, onPicked: (value) => result = value);
      await tester.enterText(find.byType(TextField), '$value');
      await tester.pumpAndSettle();
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(
        slider.semanticFormatterCallback!(slider.value),
        value == 0 ? '关闭自动下载' : '$value MiB',
      );
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, value);
    });
  }

  for (final text in ['', '-1', '1.5', 'abc']) {
    testWidgets('invalid input "$text" cannot confirm', (tester) async {
      var picked = false;
      await _open(tester, onPicked: (_) => picked = true);
      await tester.enterText(find.byType(TextField), text);
      await tester.pumpAndSettle();
      expect(find.text('请输入 0 或正整数'), findsOneWidget);
      final confirm = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确定'),
      );
      expect(confirm.onPressed, isNull);
      expect(picked, isFalse);
      expect(find.byType(AlertDialog), findsOneWidget);
    });
  }

  testWidgets('cancel discards edits', (tester) async {
    int? result = 99;
    await _open(tester, onPicked: (value) => result = value);
    await tester.enterText(find.byType(TextField), '17');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });

  for (final current in [17, 99999]) {
    testWidgets('opening a custom value $current preserves it', (tester) async {
      int? result;
      await _open(
        tester,
        current: current,
        onPicked: (value) => result = value,
      );
      final slider = tester.widget<Slider>(find.byType(Slider));
      expect(slider.semanticFormatterCallback!(slider.value), '$current MiB');
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(result, current);
    });
  }

  for (final material in [false, true]) {
    testWidgets(
      'keyboard and large text fit on a small screen material=$material',
      (tester) async {
        await _open(tester, material: material, scale: 2);
        tester.view.physicalSize = const Size(320, 568);
        tester.view.viewInsets = const FakeViewPadding(bottom: 260);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '25');
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(find.byType(AlertDialog), findsNothing);
      },
    );
  }

  testWidgets('retention and quota preserve their zero meanings', (
    tester,
  ) async {
    await _open(
      tester,
      current: 0,
      unit: '天',
      zeroLabel: null,
      stops: const {0: '永久保留', 3: '3 天', 7: '7 天', 30: '30 天', 90: '90 天'},
    );
    expect(find.textContaining('0 表示永久保留'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await _open(
      tester,
      current: 0,
      stops: storageCachePresets,
      zeroLabel: null,
    );
    expect(find.textContaining('0 表示不限制'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
