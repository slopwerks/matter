import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/storage/storage_local_media.dart';
import 'package:matter/features/storage/storage_models.dart';
import 'package:matter/features/storage/storage_registry.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    root = await Directory.systemTemp.createTemp('matter-local-preview-');
  });
  tearDown(() async {
    await storageRegistry.flush();
    await root.delete(recursive: true);
  });
  Future<StorageFile> entry(
    File file, {
    StorageKind kind = StorageKind.image,
  }) async {
    final stat = await file.stat();
    return StorageFile(
      path: file.path,
      bytes: stat.size,
      modified: stat.modified,
      lastUsed: stat.modified,
      kind: kind,
      cleanable: true,
    );
  }

  test(
    'local image preview bounds decoding and protects the file until released',
    () async {
      final recorder = ui.PictureRecorder();
      ui.Canvas(recorder).drawRect(
        const ui.Rect.fromLTWH(0, 0, 160, 80),
        ui.Paint()..color = const ui.Color(0xff3862a8),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(160, 80);
      final png = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      final file = File('${root.path}/photo.png');
      await file.writeAsBytes(png!.buffer.asUint8List());
      final lease = await openStorageMedia(await entry(file));
      expect(storageRegistry.isBusy(file.path), isTrue);
      final bytes = await lease.preview(edge: 64);
      final codec = await ui.instantiateImageCodec(bytes!);
      final frame = await codec.getNextFrame();
      expect(frame.image.width, 64);
      expect(frame.image.height, 32);
      frame.image.dispose();
      codec.dispose();
      await lease.close();
      await lease.close();
      expect(storageRegistry.isBusy(file.path), isFalse);
      expect(await file.readAsBytes(), png.buffer.asUint8List());
    },
  );
  test(
    'changed files and symlinks are rejected without leaking a lease',
    () async {
      final file = File('${root.path}/video.mp4');
      await file.writeAsBytes([1, 2, 3]);
      final snapshot = await entry(file, kind: StorageKind.video);
      await file.writeAsBytes([1, 2, 3, 4]);
      await expectLater(openStorageMedia(snapshot), throwsStateError);
      expect(storageRegistry.isBusy(file.path), isFalse);
      final link = Link('${root.path}/alias.mp4');
      await link.create(file.path);
      final linked = StorageFile(
        path: link.path,
        bytes: 4,
        modified: snapshot.modified,
        lastUsed: snapshot.lastUsed,
        kind: StorageKind.video,
        cleanable: true,
      );
      await expectLater(openStorageMedia(linked), throwsStateError);
      expect(storageRegistry.isBusy(link.path), isFalse);
    },
  );
  test(
    'damaged image errors retain protection until the reader closes',
    () async {
      final file = File('${root.path}/broken.png');
      await file.writeAsBytes([1, 2, 3]);
      final lease = await openStorageMedia(await entry(file));
      await expectLater(lease.preview(), throwsA(anything));
      expect(storageRegistry.isBusy(file.path), isTrue);
      await lease.close();
      expect(storageRegistry.isBusy(file.path), isFalse);
    },
  );
}
