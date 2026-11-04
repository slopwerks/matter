import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/media_preparation.dart';
import 'package:matter/pages/chat/prepared_media_source.dart';
import 'package:matter/src/rust/frb_generated.dart';

import 'support/media_transfer_api.dart';
import 'support/temp_path_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late MediaTransferApi api;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('matter-encrypted-media-');
    installTempPathProvider(root);
    api = MediaTransferApi();
    RustLib.initMock(api: api);
  });
  tearDown(() async {
    RustLib.dispose();
    await root.delete(recursive: true);
  });

  Future<PreparedMediaSource> prepare(MediaPreparation preparation) =>
      prepareEncryptedMediaSource(
        '{"file":{"url":"mxc://example.org/media","key":{}}}',
        '../../clip.mp4',
        expectedUserId: '@alice:example.org',
        preparation: preparation,
      );

  Future<void> expectEmpty() async {
    final directory = Directory('${root.path}/matter_decrypted_media');
    if (await directory.exists()) {
      expect(await directory.list().toList(), isEmpty);
    }
  }

  test(
    'pre-cancellation creates neither native transfer nor temporary files',
    () async {
      final preparation = MediaPreparation()..cancel();
      await expectLater(prepare(preparation), throwsStateError);
      expect(api.transfers, isEmpty);
      expect(await root.list().toList(), isEmpty);
    },
  );

  test(
    'cancels native I/O and cleans partial files before returning failure',
    () async {
      final preparation = MediaPreparation();
      final pending = prepare(preparation);
      final failure = expectLater(pending, throwsStateError);
      await api.waitForRequests(1);
      final request = api.requests.single;
      await File('${File(request.destination).parent.path}/ciphertext')
          .writeAsBytes([9]);
      preparation.cancel();
      preparation.cancel();
      await failure;
      expect(request.transfer.cancelled, isTrue);
      await expectEmpty();
    },
  );

  test('late verified result cannot be published after cancellation', () async {
    final preparation = MediaPreparation();
    final pending = prepare(preparation);
    final failure = expectLater(pending, throwsStateError);
    await api.waitForRequests(1);
    final request = api.requests.single;
    await File(request.destination).writeAsBytes([1, 2, 3]);
    preparation.cancel();
    request.completion.complete();
    await failure;
    await expectEmpty();
  });

  test('failure can retry with a fresh transfer and a large account-scoped file', () async {
    final failed = prepare(MediaPreparation());
    final failure = expectLater(failed, throwsStateError);
    await api.waitForRequests(1);
    api.requests.single.fail();
    await failure;
    await expectEmpty();

    final preparation = MediaPreparation();
    final pending = prepare(preparation);
    await api.waitForRequests(2);
    final request = api.requests.last;
    expect(request.expectedUserId, '@alice:example.org');
    expect(request.destination, endsWith('.mp4'));
    final handle = await File(request.destination).open(mode: FileMode.write);
    await handle.truncate(17 * 1024 * 1024);
    await handle.close();
    request.completion.complete();
    final prepared = await pending;
    expect(await File(prepared.media.uri).length(), 17 * 1024 * 1024);
    expect(identical(api.transfers.first, api.transfers.last), isFalse);
    // Cancelling an already finished preparation cannot delete a playing file.
    preparation.cancel();
    expect(request.transfer.cancelled, isFalse);
    expect(await File(prepared.media.uri).exists(), isTrue);
    await prepared.cleanup();
    await prepared.cleanup();
    await expectEmpty();
  });
}
