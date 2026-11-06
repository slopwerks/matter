import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_providers.dart';
import 'package:matter/pages/settings/storage_chats_page.dart';
import 'package:matter/pages/settings/storage_detail_page.dart';
import 'package:matter/pages/settings/storage_page.dart';
import 'package:matter/widgets/app_search_field.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/neu_test_theme.dart';

final _roomRevision = NotifierProvider<_RoomRevision, int>(_RoomRevision.new);

class _RoomRevision extends Notifier<int> {
  @override
  int build() => 0;

  void update() => state++;
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  const owner = StorageOwner('account', '!room');
  final now = DateTime(2026, 11, 4);
  final snapshot = StorageSnapshot(
    files: [
      for (var i = 0; i < 100; i++)
        StorageFile(
          path: '/app/cache/report-$i.pdf',
          bytes: 2048 + i,
          modified: now,
          lastUsed: now,
          kind: StorageKind.document,
          cleanable: true,
          owners: const [owner],
        ),
      StorageFile(
        path: '/app/cache/photo.jpg',
        bytes: 1024,
        modified: now,
        lastUsed: now,
        kind: StorageKind.image,
        cleanable: true,
        owners: const [owner],
      ),
    ],
    rooms: {
      owner.key: const StorageRoom(owner, 'Family', StorageChatType.group),
    },
    measuredAt: now,
  );

  ProviderContainer containerFor(Completer<StorageSnapshot> scan) {
    var first = true;
    return ProviderContainer(
      overrides: [
        storageSnapshotProvider.overrideWith((ref) async {
          ref.watch(_roomRevision);
          if (first) {
            first = false;
            return snapshot;
          }
          return scan.future;
        }),
      ],
    );
  }

  Future<void> pumpPage(
    WidgetTester tester,
    ProviderContainer container,
    bool material,
  ) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: neuTestTheme(material: material),
          home: const StoragePage(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void refresh(ProviderContainer container, bool reload) {
    if (reload) {
      container.read(_roomRevision.notifier).update();
    } else {
      container.invalidate(storageSnapshotProvider);
    }
  }

  for (final material in [false, true]) {
    for (final reload in [false, true]) {
      testWidgets('background snapshot update keeps route and chat filter '
          '(material=$material, dependencyReload=$reload)', (tester) async {
        final scan = Completer<StorageSnapshot>();
        var scans = 0;
        final container = ProviderContainer(
          overrides: [
            storageSnapshotProvider.overrideWith((ref) async {
              ref.watch(_roomRevision);
              if (++scans == 1) return snapshot;
              return scan.future;
            }),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: MaterialApp(
              theme: neuTestTheme(material: material),
              home: const StoragePage(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(find.text('全部'), 200);
        await Scrollable.ensureVisible(
          tester.element(find.text('全部')),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('全部'));
        await tester.pumpAndSettle();
        final page = tester.element(find.byType(StorageChatsPage));
        final route = ModalRoute.of(page)!;
        final search = find.descendant(
          of: find.byType(AppSearchField),
          matching: find.byType(TextField),
        );
        final editor = find.descendant(
          of: search,
          matching: find.byType(EditableText),
        );
        await tester.enterText(search, 'no-match');
        await tester.pumpAndSettle();
        expect(find.text('没有匹配的聊天'), findsOneWidget);

        final periodic = Timer.periodic(const Duration(minutes: 5), (_) {
          if (reload) {
            container.read(_roomRevision.notifier).update();
          } else {
            container.invalidate(storageSnapshotProvider);
          }
        });
        addTearDown(periodic.cancel);
        await tester.pump(const Duration(minutes: 5));
        await tester.pump();
        periodic.cancel();
        expect(scans, 2);
        expect(route.isCurrent, isTrue);
        expect(tester.element(find.byType(StorageChatsPage)), same(page));
        expect(
          find.text('没有匹配的聊天'),
          findsOneWidget,
          reason: 'A background scan must keep the current page content',
        );
        expect(tester.widget<EditableText>(editor).controller.text, 'no-match');
        scan.complete(snapshot);
        await tester.pumpAndSettle();
        expect(route.isCurrent, isTrue);
        expect(find.text('没有匹配的聊天'), findsOneWidget);
        expect(tester.widget<EditableText>(editor).controller.text, 'no-match');
        expect(tester.takeException(), isNull);
      });

      testWidgets(
        'background update keeps overview position and cleanup action '
        '(material=$material, dependencyReload=$reload)',
        (tester) async {
          final scan = Completer<StorageSnapshot>();
          final container = containerFor(scan);
          addTearDown(container.dispose);
          await pumpPage(tester, container, material);
          await tester.scrollUntilVisible(find.text('公共应用数据'), 250);
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).first,
          );
          final offset = scroll.position.pixels;
          final cleanup = find.byWidgetPredicate(
            (widget) => widget is FilledButton,
          );
          expect(cleanup, findsOneWidget);
          refresh(container, reload);
          await tester.pump();
          await tester.pump();
          expect(
            cleanup,
            findsOneWidget,
            reason: 'Keep the footer during a background scan',
          );
          expect(
            tester.state<ScrollableState>(find.byType(Scrollable).first),
            same(scroll),
          );
          expect(scroll.position.pixels, closeTo(offset, 0.01));
          scan.complete(snapshot);
          await tester.pumpAndSettle();
          expect(scroll.position.pixels, closeTo(offset, 0.01));
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'background update keeps file route selection query and scroll '
        '(material=$material, dependencyReload=$reload)',
        (tester) async {
          final scan = Completer<StorageSnapshot>();
          final container = containerFor(scan);
          addTearDown(container.dispose);
          await pumpPage(tester, container, material);
          await tester.tap(
            find.byWidgetPredicate((widget) => widget is FilledButton),
          );
          await tester.pumpAndSettle();
          final route = ModalRoute.of(
            tester.element(find.byType(StorageDetailPage)),
          )!;
          final search = find.descendant(
            of: find.byType(AppSearchField),
            matching: find.byType(TextField),
          );
          final editor = find.descendant(
            of: search,
            matching: find.byType(EditableText),
          );
          await tester.enterText(search, 'report');
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Checkbox).first);
          await tester.pumpAndSettle();
          await tester.drag(find.byType(ListView), const Offset(0, -700));
          await tester.pumpAndSettle();
          final scroll = tester.state<ScrollableState>(
            find.byType(Scrollable).last,
          );
          final offset = scroll.position.pixels;
          refresh(container, reload);
          await tester.pump();
          await tester.pump();
          expect(route.isCurrent, isTrue);
          expect(find.textContaining('清理已选 1 项'), findsOneWidget);
          expect(tester.widget<EditableText>(editor).controller.text, 'report');
          expect(
            tester.state<ScrollableState>(find.byType(Scrollable).last),
            same(scroll),
          );
          expect(scroll.position.pixels, closeTo(offset, 0.01));
          scan.complete(snapshot);
          await tester.pumpAndSettle();
          expect(route.isCurrent, isTrue);
          expect(find.textContaining('清理已选 1 项'), findsOneWidget);
          expect(tester.widget<EditableText>(editor).controller.text, 'report');
          expect(scroll.position.pixels, closeTo(offset, 0.01));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
