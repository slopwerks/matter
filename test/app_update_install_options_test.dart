import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/app_update/app_update_service.dart';
import 'package:matter/features/app_update/update_dialog.dart';
import 'package:matter/features/app_update/update_exception.dart';

import 'helpers/neu_test_theme.dart';

class _InstallOptionsService extends AppUpdateService {
  bool failInstall = false;
  bool failFiles = false;
  int downloads = 0;
  int installs = 0;
  final shownFiles = <String>[];

  @override
  Future<String> downloadUpdate(
    ReleaseUpdate update, {
    required void Function(int received, int total) onProgress,
    Future<void>? cancel,
  }) async {
    downloads++;
    return '/cache/updates/matter.apk';
  }

  @override
  Future<void> installUpdate(String path) async {
    installs++;
    if (failInstall) throw const AppUpdateException('无法打开系统安装器');
  }

  @override
  Future<void> showDownloadedUpdate(String path) async {
    shownFiles.add(path);
    if (failFiles) throw const AppUpdateException('无法打开下载目录');
  }
}

Future<void> _openDownload(
  WidgetTester tester,
  _InstallOptionsService service,
  bool material, {
  bool dark = true,
}) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await tester.pumpWidget(
    MaterialApp(
      theme: neuTestTheme(material: material, dark: dark),
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () => showAvailableUpdateDialog(
            context,
            service: service,
            current: const InstalledAppVersion(version: '0.1.0'),
            update: ReleaseUpdate(
              version: '0.2.0',
              notes: '',
              releasePage: Uri.parse(
                'https://github.com/slopwerks/matter/releases',
              ),
              downloadUrl: Uri.parse(
                'https://github.com/slopwerks/matter/matter.apk',
              ),
              assetSize: 100,
              digest: null,
            ),
          ),
          child: const Text('open'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text('下载并安装'));
  await tester.pumpAndSettle();
}

void main() {
  for (final material in [false, true]) {
    for (final dark in [false, true]) {
      for (final failedInstall in [false, true]) {
        testWidgets(
          'downloaded update keeps both install options (material=$material, dark=$dark, failed=$failedInstall)',
          (tester) async {
            final service = _InstallOptionsService()
              ..failInstall = failedInstall;
            await _openDownload(tester, service, material, dark: dark);
            expect(service.installs, 1);
            expect(find.text('在文件管理器中查看'), findsOneWidget);
            expect(find.text('安装更新'), findsOneWidget);
            await tester.tap(find.text('在文件管理器中查看'));
            await tester.pumpAndSettle();
            expect(service.shownFiles, ['/cache/updates/matter.apk']);
            expect(service.downloads, 1);
            expect(find.text('安装包已保存到下载目录'), findsOneWidget);
            service.failInstall = false;
            await tester.tap(find.text('安装更新'));
            await tester.pumpAndSettle();
            expect(service.installs, 2);
            expect(service.downloads, 1);
            await tester.tap(find.text('关闭'));
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsNothing);
          },
        );
      }
    }
  }

  testWidgets(
    'file manager failure preserves the downloaded APK and install action',
    (tester) async {
      final service = _InstallOptionsService()..failFiles = true;
      await _openDownload(tester, service, true);
      await tester.tap(find.text('在文件管理器中查看'));
      await tester.pumpAndSettle();
      expect(find.text('无法打开下载目录'), findsOneWidget);
      expect(find.text('安装更新'), findsOneWidget);
      await tester.tap(find.text('安装更新'));
      await tester.pumpAndSettle();
      expect(service.installs, 2);
      expect(service.downloads, 1);
    },
  );
}
