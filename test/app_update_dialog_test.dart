import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/app_update_service.dart';
import 'package:matter/features/app_update/update_dialog.dart';

import 'helpers/neu_test_theme.dart';

class _PendingDownloadService extends AppUpdateService {
  final download = Completer<String>();
  bool cancelled = false;
  int installs = 0;

  @override
  Future<String> downloadUpdate(
    ReleaseUpdate update, {
    required void Function(int received, int total) onProgress,
    Future<void>? cancel,
  }) {
    cancel?.then((_) => cancelled = true);
    return download.future;
  }

  @override
  Future<void> installUpdate(String path) async {
    installs++;
  }
}

void main() {
  for (final useBack in [false, true]) {
    testWidgets(
      'an in-progress update can be cancelled with ${useBack ? 'back' : 'the button'}',
      (tester) async {
        final service = _PendingDownloadService();
        final update = ReleaseUpdate(
          version: '0.2.0',
          notes: '',
          releasePage: Uri.parse(
            'https://github.com/slopwerks/matter/releases/tag/v0.2.0',
          ),
          downloadUrl: Uri.parse(
            'https://github.com/slopwerks/matter/releases/download/v0.2.0/matter.apk',
          ),
          assetSize: 65536,
          digest: null,
        );
        await tester.pumpWidget(
          MaterialApp(
            theme: neuTestTheme(),
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () => showAvailableUpdateDialog(
                  context,
                  service: service,
                  current: const InstalledAppVersion(version: '0.1.0'),
                  update: update,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('下载并安装'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(find.text('正在连接 GitHub…'), findsOneWidget);
        if (useBack) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.text('取消'));
        }
        // A completion during the closing animation must not launch the installer.
        service.download.complete('/tmp/matter.apk');
        await tester.pumpAndSettle();
        expect(service.cancelled, isTrue);
        expect(find.text('正在连接 GitHub…'), findsNothing);
        expect(service.installs, 0);
      },
    );
  }
  testWidgets('update prompt shows versions, package size, and confirmation', (
    tester,
  ) async {
    final service = AppUpdateService();
    const current = InstalledAppVersion(version: '0.1.2');
    final update = ReleaseUpdate(
      version: '0.2.0',
      notes: '## 本次更新\n- 修复若干问题\n- 优化更新体验',
      releasePage: Uri.parse(
        'https://github.com/slopwerks/matter/releases/tag/v0.2.0',
      ),
      downloadUrl: Uri.parse(
        'https://github.com/slopwerks/matter/releases/download/v0.2.0/'
        'matter-android-arm64.apk',
      ),
      assetSize: 36 * 1024 * 1024,
      digest: null,
    );

    await tester.pumpWidget(
      MaterialApp(
        theme: neuTestTheme(),
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => showAvailableUpdateDialog(
              context,
              service: service,
              current: current,
              update: update,
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('发现新版本'), findsOneWidget);
    expect(find.text('v0.2.0'), findsOneWidget);
    expect(find.textContaining('v0.1.2 → v0.2.0'), findsOneWidget);
    expect(find.textContaining('修复若干问题'), findsOneWidget);
    expect(find.text('查看完整发布说明'), findsOneWidget);
    expect(find.text('稍后'), findsOneWidget);
    expect(find.text('下载并安装'), findsOneWidget);

    await tester.tap(find.text('稍后'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本'), findsNothing);
  });

  test('release note summary strips common Markdown and limits lines', () {
    final summary = summarizeReleaseNotes(
      '## What changed\n- First fix\n- Second fix\n- Third fix',
    );

    expect(summary, 'What changed\n• First fix\n• Second fix\n…');
  });
}
