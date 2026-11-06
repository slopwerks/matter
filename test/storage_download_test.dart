import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_download_policy.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_providers.dart';
import 'package:matter/features/storage/storage_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('dev.fluttercommunity.plus/connectivity');
  var networks = <String>['wifi'];
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    networks = ['wifi'];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (_) async => networks);
  });
  tearDown(
    () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null),
  );

  test('actual network applies independent file-type thresholds', () async {
    await saveStorageSettings(
      const StorageSettings(
        wifiDownloads: DownloadRules(
          limits: {
            StorageKind.image: 20 * storageMiB,
            StorageKind.video: 100 * storageMiB,
            StorageKind.audio: 10 * storageMiB,
            StorageKind.document: 50 * storageMiB,
          },
        ),
        mobileDownloads: DownloadRules(
          limits: {
            StorageKind.image: storageMiB,
            StorageKind.video: 2 * storageMiB,
            StorageKind.audio: 0,
            StorageKind.document: 0,
          },
        ),
      ),
    );
    for (final network in ['wifi', 'ethernet']) {
      networks = [network];
      expect(await mayAutoDownload(StorageKind.image, 10 * storageMiB), isTrue);
      expect(await mayAutoDownload(StorageKind.video, 80 * storageMiB), isTrue);
      expect(
        await mayAutoDownload(StorageKind.document, 25 * storageMiB),
        isTrue,
      );
    }
    networks = ['mobile'];
    expect(await mayAutoDownload(StorageKind.image, 10 * storageMiB), isFalse);
    expect(await mayAutoDownload(StorageKind.image, storageMiB), isTrue);
    expect(await mayAutoDownload(StorageKind.video, 3 * storageMiB), isFalse);
    expect(await mayAutoDownload(StorageKind.audio, 1), isFalse);
    expect(await mayAutoDownload(StorageKind.document, 1), isFalse);
    for (final network in ['wifi', 'mobile']) {
      networks = [network];
      expect(await mayAutoDownload(StorageKind.image, null), isFalse);
      expect(await mayAutoDownload(StorageKind.image, 0), isFalse);
    }
    networks = ['none'];
    expect(await mayAutoDownload(StorageKind.image, 1), isFalse);
    networks = ['vpn'];
    expect(await mayAutoDownload(StorageKind.document, 1), isFalse);
    expect(await mayAutoDownload(StorageKind.image, 2 * storageMiB), isFalse);
    networks = ['wifi', 'mobile'];
    expect(await mayAutoDownload(StorageKind.image, 2 * storageMiB), isFalse);
  });

  test('old global settings migrate without enabling a network or increasing limits', () {
    for (final network in ['any', 'unmetered', 'never']) {
      final settings = StorageSettings.fromJson({
        'network': network,
        'limits': {'image': 7 * storageMiB, 'document': 0},
      });
      expect(
        settings.wifiDownloads.permits(StorageKind.image, storageMiB),
        network != 'never',
      );
      expect(
        settings.mobileDownloads.permits(StorageKind.image, storageMiB),
        network == 'any',
      );
      expect(
        settings.wifiDownloads.permits(StorageKind.image, 8 * storageMiB),
        isFalse,
      );
      expect(
        settings.mobileDownloads.permits(StorageKind.document, 1),
        isFalse,
      );
      expect(
        StorageSettings.fromJson(settings.toJson()).toJson(),
        settings.toJson(),
      );
    }
  });

  test('unknown network uses the intersection and offline never downloads', () {
    const settings = StorageSettings(
      wifiDownloads: DownloadRules(enabled: false),
    );
    expect(
      permitsOnConnection(
        settings,
        StorageConnection.mobile,
        StorageKind.image,
        1,
      ),
      isTrue,
    );
    expect(
      permitsOnConnection(
        settings,
        StorageConnection.unknown,
        StorageKind.image,
        1,
      ),
      isFalse,
    );
    expect(
      classifyStorageConnection([ConnectivityResult.vpn]),
      StorageConnection.unknown,
    );
    expect(
      classifyStorageConnection([ConnectivityResult.ethernet]),
      StorageConnection.wifi,
    );
  });

  test(
    'network changes notify the same policy watched by visible media',
    () async {
      final events = StreamController<StorageConnection>();
      final container = ProviderContainer(
        overrides: [
          storageConnectionProvider.overrideWith((ref) => events.stream),
        ],
      );
      final observed = <StorageConnection>[];
      final subscription = container.listen(
        storageAutoDownloadPolicyProvider,
        (_, next) => observed.add(next.connection),
        fireImmediately: true,
      );
      events.add(StorageConnection.wifi);
      await container.read(storageConnectionProvider.future);
      await container.read(storageSettingsProvider.future);
      events.add(StorageConnection.mobile);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      events.add(StorageConnection.wifi);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(
        observed,
        containsAllInOrder([
          StorageConnection.wifi,
          StorageConnection.mobile,
          StorageConnection.wifi,
        ]),
      );
      subscription.close();
      container.dispose();
      await events.close();
    },
  );
}
