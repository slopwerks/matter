import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/app_update_service.dart';
import 'package:matter/features/app_update/update_dialog.dart';

import 'helpers/neu_test_theme.dart';

void main() {
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
