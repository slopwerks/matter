import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_providers.dart';
import 'package:matter/features/storage/storage_settings.dart';
import 'package:matter/widgets/app_search_field.dart';
import 'package:matter/pages/settings/storage_page.dart';
import 'package:matter/pages/settings/storage_detail_page.dart';
import 'package:matter/pages/settings/storage_settings_page.dart';
import 'package:matter/pages/settings/storage_chats_page.dart';
import 'package:matter/pages/settings/storage_policy_page.dart';
import 'package:matter/pages/settings/storage_download_settings.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

class _DelayedStorageSettings extends StorageSettingsNotifier {
  final completeSave = Completer<void>();
  bool saveStarted = false;

  @override
  Future<void> save(StorageSettings settings) async {
    saveStarted = true;
    await completeSave.future;
    await super.save(settings);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const owner = StorageOwner('account', '!room');
  final now = DateTime(2026, 11, 4);
  final snapshot = StorageSnapshot(
    files: [
      StorageFile(
        path: '/app/cache/photo.jpg',
        bytes: 1024,
        modified: now,
        lastUsed: now,
        kind: StorageKind.image,
        cleanable: true,
        owners: const [owner],
      ),
      StorageFile(
        path: '/app/data/matrix.db',
        bytes: 2048,
        modified: now,
        lastUsed: now,
        kind: StorageKind.database,
        cleanable: false,
      ),
    ],
    rooms: {
      owner.key: const StorageRoom(owner, 'Family', StorageChatType.group),
    },
    measuredAt: now,
    systemDataBytes: 4096,
    systemCacheBytes: 1024,
    appBytes: 8192,
  );

  Future<void> pump(
    WidgetTester tester,
    Widget page,
    bool material, {
    StorageSettingsNotifier? settingsNotifier,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          storageSnapshotProvider.overrideWith((_) async => snapshot),
          if (settingsNotifier != null)
            storageSettingsProvider.overrideWith(() => settingsNotifier),
        ],
        child: MaterialApp(
          theme: neuTestTheme(material: material),
          home: page,
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  for (final material in [false, true]) {
    testWidgets(
      'storage totals navigate to protected file details (material=$material)',
      (tester) async {
        await pump(tester, const StoragePage(), material);
        expect(find.text('应用文件占用'), findsOneWidget);
        expect(find.text('安装包与本地库'), findsOneWidget);
        await tester.scrollUntilVisible(find.text('聊天与加密数据库'), 200);
        await Scrollable.ensureVisible(
          tester.element(find.text('聊天与加密数据库')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('聊天与加密数据库'));
        await tester.pumpAndSettle();
        expect(find.byType(StorageDetailPage), findsOneWidget);
        expect(find.textContaining('matrix.db'), findsWidgets);
        expect(
          tester.widget<Checkbox>(find.byType(Checkbox)).onChanged,
          isNull,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'file selections survive filtering and cancellation (material=$material)',
      (tester) async {
        await pump(tester, const StorageDetailPage(title: '全部文件'), material);
        final selectable = find.byWidgetPredicate(
          (w) => w is Checkbox && w.onChanged != null,
        );
        await tester.tap(selectable);
        await tester.pumpAndSettle();
        final search = find.descendant(
          of: find.byType(AppSearchField),
          matching: find.byType(TextField),
        );
        await tester.enterText(search, 'no-match');
        await tester.pumpAndSettle();
        expect(find.text('另有 1 项已选'), findsOneWidget);
        await tester.enterText(search, '');
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(selectable).value, isTrue);
        await tester.tap(find.textContaining('清理已选 1 项'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('取消'));
        await tester.pumpAndSettle();
        expect(tester.widget<Checkbox>(selectable).value, isTrue);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'download settings persist independent profiles (material=$material)',
      (tester) async {
        await pump(tester, const StorageSettingsPage(), material);
        await tester.tap(find.text('移动数据'));
        await tester.pumpAndSettle();
        await tester.tap(find.byType(SwitchListTile).first);
        await tester.pumpAndSettle();
        final settings = await loadStorageSettings();
        expect(settings.mobileDownloads.enabled, isFalse);
        expect(settings.wifiDownloads.enabled, isTrue);
        expect(
          tester
              .widget<SegmentedButton<DownloadProfile>>(
                find.byType(SegmentedButton<DownloadProfile>),
              )
              .selected,
          {DownloadProfile.mobile},
          reason: 'Saving must keep the currently selected network profile',
        );
        expect(
          tester
              .widget<SwitchListTile>(find.byType(SwitchListTile).first)
              .value,
          isFalse,
        );
        await tester.tap(find.text('Wi-Fi / 有线'));
        await tester.pumpAndSettle();
        expect(
          tester
              .widget<SwitchListTile>(find.byType(SwitchListTile).first)
              .value,
          isTrue,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'saving keeps download profile and scroll position (material=$material)',
      (tester) async {
        final notifier = _DelayedStorageSettings();
        addTearDown(() {
          if (!notifier.completeSave.isCompleted) {
            notifier.completeSave.complete();
          }
        });
        await pump(
          tester,
          const StorageSettingsPage(),
          material,
          settingsNotifier: notifier,
        );
        await tester.tap(find.text('移动数据'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('省流量'), 150);
        await Scrollable.ensureVisible(
          tester.element(find.text('省流量')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        final scrollable = tester.state<ScrollableState>(
          find.descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          ),
        );
        final offset = scrollable.position.pixels;
        final downloadElement = tester.element(
          find.byType(StorageDownloadSettings),
        );
        await tester.tap(find.text('省流量'));
        await tester.pump();
        expect(notifier.saveStarted, isTrue);
        expect(
          tester
              .widget<SegmentedButton<DownloadProfile>>(
                find.byType(SegmentedButton<DownloadProfile>),
              )
              .selected,
          {DownloadProfile.mobile},
          reason: 'Saving must not replace the selected network with Wi-Fi',
        );
        expect(
          tester.element(find.byType(StorageDownloadSettings)),
          same(downloadElement),
        );
        expect(scrollable.position.pixels, closeTo(offset, 0.01));
        notifier.completeSave.complete();
        await tester.pumpAndSettle();
        expect(find.byType(LinearProgressIndicator), findsNothing);
        expect(
          tester.element(find.byType(StorageDownloadSettings)),
          same(downloadElement),
        );
        expect(scrollable.position.pixels, closeTo(offset, 0.01));
        final saved = await loadStorageSettings();
        expect(saved.mobileDownloads.limits[StorageKind.image], storageMiB);
        expect(
          saved.wifiDownloads.toJson(),
          const StorageSettings().wifiDownloads.toJson(),
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'compact chats open a dedicated searchable list (material=$material)',
      (tester) async {
        await pump(tester, const StoragePage(), material);
        await tester.scrollUntilVisible(find.text('全部'), 200);
        await Scrollable.ensureVisible(
          tester.element(find.text('全部')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部'));
        await tester.pumpAndSettle();
        expect(find.byType(StorageChatsPage), findsOneWidget);
        expect(find.byType(AppSearchField), findsOneWidget);
        await tester.tap(find.text('Family'));
        await tester.pumpAndSettle();
        expect(find.byType(StorageDetailPage), findsOneWidget);
        expect(find.text('photo.jpg'), findsOneWidget);
        expect(find.text('matrix.db'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'retention settings live on their own page and persist (material=$material)',
      (tester) async {
        await pump(tester, const StorageSettingsPage(), material);
        await tester.scrollUntilVisible(find.text('保留策略'), 200);
        await Scrollable.ensureVisible(
          tester.element(find.text('保留策略')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        expect(find.text('保留时长'), findsNothing);
        await tester.tap(find.text('保留策略'));
        await tester.pumpAndSettle();
        expect(find.byType(StoragePolicyPage), findsOneWidget);
        await tester.tap(find.text('保留时长').first);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField), '7');
        await tester.tap(find.text('确定'));
        await tester.pumpAndSettle();
        expect(
          (await loadStorageSettings()).policy(StorageChatType.direct).keepDays,
          7,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
