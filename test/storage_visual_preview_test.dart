import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_providers.dart';
import 'package:matter/pages/settings/storage_page.dart';
import 'package:matter/pages/settings/storage_chats_page.dart';
import 'package:matter/pages/settings/storage_detail_page.dart';
import 'package:matter/pages/settings/storage_settings_page.dart';
import 'package:matter/pages/settings/storage_policy_page.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

ThemeData _screenshotTheme(ThemeData theme) {
  const font = 'StoragePreviewFont';
  ButtonStyle? buttonStyle(ButtonStyle? style) => style?.copyWith(
    textStyle: WidgetStateProperty.resolveWith(
      (states) =>
          (style.textStyle?.resolve(states) ?? theme.textTheme.labelLarge)
              ?.copyWith(fontFamily: font),
    ),
  );
  return theme.copyWith(
    textTheme: theme.textTheme.apply(fontFamily: font),
    primaryTextTheme: theme.primaryTextTheme.apply(fontFamily: font),
    appBarTheme: theme.appBarTheme.copyWith(
      titleTextStyle: theme.appBarTheme.titleTextStyle?.copyWith(
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
      leadingAndTrailingTextStyle: theme
          .listTileTheme
          .leadingAndTrailingTextStyle
          ?.copyWith(fontFamily: font),
    ),
    chipTheme: theme.chipTheme.copyWith(
      labelStyle: theme.chipTheme.labelStyle?.copyWith(fontFamily: font),
      secondaryLabelStyle: theme.chipTheme.secondaryLabelStyle?.copyWith(
        fontFamily: font,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: buttonStyle(theme.textButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: buttonStyle(theme.outlinedButtonTheme.style),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: buttonStyle(theme.filledButtonTheme.style),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: buttonStyle(theme.elevatedButtonTheme.style),
    ),
  );
}

void main() {
  final screenshots = Platform.environment['MATTER_STORAGE_SCREENSHOTS'] == '1';
  setUpAll(() async {
    const font = '/usr/share/fonts/sarasa-gothic/Sarasa-Regular.ttc';
    if (screenshots && File(font).existsSync()) {
      final loader = FontLoader('StoragePreviewFont')
        ..addFont(
          Future.value(ByteData.sublistView(File(font).readAsBytesSync())),
        );
      await loader.load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    }
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final now = DateTime(2026, 11, 4, 14, 30);
  const owner = StorageOwner('sample', '!family');
  final snapshot = StorageSnapshot(
    files: [
      for (final (name, kind, mib, cleanable) in [
        ('mountains.jpg', StorageKind.image, 42, true),
        ('weekend.mp4', StorageKind.video, 68, true),
        ('voice.ogg', StorageKind.audio, 9, true),
        ('旅行计划.pdf', StorageKind.document, 6, true),
        ('download.tmp', StorageKind.temporary, 3, true),
        ('matrix.db', StorageKind.database, 32, false),
        ('search-index', StorageKind.search, 8, false),
      ])
        StorageFile(
          path: '/sample/$name',
          bytes: mib * 1024 * 1024,
          modified: now,
          lastUsed: now,
          kind: kind,
          cleanable: cleanable,
          owners: cleanable ? const [owner] : const [],
        ),
    ],
    rooms: {
      owner.key: const StorageRoom(owner, '家人 · 周末旅行', StorageChatType.group),
    },
    measuredAt: now,
    systemDataBytes: 180 * 1024 * 1024,
    systemCacheBytes: 130 * 1024 * 1024,
    appBytes: 96 * 1024 * 1024,
    freeBytes: 28 * 1024 * 1024 * 1024,
    volumeBytes: 128 * 1024 * 1024 * 1024,
  );
  for (final page in ['overview', 'chats', 'files', 'settings', 'policies']) {
    for (final material in [false, true]) {
      for (final dark in [false, true]) {
        for (final scale in [1.0, 1.5]) {
          testWidgets(
            'storage $page visual previews material=$material dark=$dark scale=$scale',
            (tester) async {
              tester.view.physicalSize = const Size(390, 844);
              tester.view.devicePixelRatio = 1;
              addTearDown(tester.view.resetPhysicalSize);
              addTearDown(tester.view.resetDevicePixelRatio);
              final theme = neuTestTheme(material: material, dark: dark);
              final key = GlobalKey();
              await tester.pumpWidget(
                ProviderScope(
                  overrides: [
                    storageSnapshotProvider.overrideWith(
                      (ref) async => snapshot,
                    ),
                  ],
                  child: MaterialApp(
                    theme: screenshots ? _screenshotTheme(theme) : theme,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context)
                          .copyWith(textScaler: TextScaler.linear(scale)),
                      child: child!,
                    ),
                    home: RepaintBoundary(
                      key: key,
                      child: switch (page) {
                        'chats' => const StorageChatsPage(),
                        'files' => const StorageDetailPage(title: '全部文件'),
                        'settings' => const StorageSettingsPage(),
                        'policies' => const StoragePolicyPage(),
                        _ => const StoragePage(),
                      },
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              expect(tester.takeException(), isNull);
              if (screenshots && scale == 1) {
                final prefix =
                    Platform.environment['MATTER_STORAGE_SCREENSHOT_PREFIX'] ??
                    'after';
                Future<void> capture(String suffix) async {
                  await tester.runAsync(() async {
                    final boundary =
                        key.currentContext!.findRenderObject()!
                            as RenderRepaintBoundary;
                    final image = await boundary.toImage(pixelRatio: 2);
                    final png = await image.toByteData(
                      format: ui.ImageByteFormat.png,
                    );
                    final path =
                        '/tmp/matter-storage-$prefix-$page$suffix-${material ? 'material' : 'neu'}-${dark ? 'dark' : 'light'}.png';
                    await File(path).writeAsBytes(png!.buffer.asUint8List());
                    image.dispose();
                  });
                }

                await capture('');
                if (page == 'overview') {
                  await tester.drag(
                    find.byType(ListView).first,
                    const Offset(0, -800),
                  );
                  await tester.pumpAndSettle();
                  expect(tester.takeException(), isNull);
                  await capture('-bottom');
                }
              }
            },
          );
        }
      }
    }
  }
}
