import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/pages/chat/attachment_picker.dart';
import 'package:matter/pages/chat/chat_image_editor_page.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:pro_image_editor/pro_image_editor.dart';

const _locationChannel = MethodChannel('flutter.baseflow.com/geolocator');

void _mockCurrentLocation({
  bool serviceEnabled = true,
  int permission = 2,
  double latitude = 39.9,
  double longitude = 116.4,
}) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_locationChannel, (call) async {
        return switch (call.method) {
          'isLocationServiceEnabled' => serviceEnabled,
          'checkPermission' => permission,
          'requestPermission' => permission,
          'getCurrentPosition' => <String, dynamic>{
            'latitude': latitude,
            'longitude': longitude,
          },
          _ => null,
        };
      });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('gallery requests newest assets first', () {
    expect(attachmentMediaOrder, hasLength(1));
    expect(attachmentMediaOrder.single.type, OrderOptionType.createDate);
    expect(attachmentMediaOrder.single.asc, isFalse);
  });

  test('location sharing resolves the current device position', () async {
    _mockCurrentLocation();
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_locationChannel, null),
    );

    final point = await currentAttachmentLocation();

    expect(point.latitude, 39.9);
    expect(point.longitude, 116.4);
  });

  test('location sharing reports disabled system location', () async {
    _mockCurrentLocation(serviceEnabled: false);
    addTearDown(
      () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_locationChannel, null),
    );

    await expectLater(
      currentAttachmentLocation(),
      throwsA(predicate<Object>((error) => error.toString() == '请先开启系统定位服务')),
    );
  });

  test('attachment MIME fallback classifies common image and video files', () {
    final movMime = resolveAttachmentMime(
      'clip.MOV',
      'application/octet-stream',
    );
    final heicMime = resolveAttachmentMime('photo.HEIC', null);

    expect(movMime, 'video/quicktime');
    expect(classifyAttachmentMime(movMime), AttachmentMediaKind.video);
    expect(heicMime, 'image/heic');
    expect(classifyAttachmentMime(heicMime), AttachmentMediaKind.image);
    expect(classifyAttachmentMime('application/pdf'), AttachmentMediaKind.file);
  });

  test('edited image bytes determine their actual MIME type', () {
    expect(
      detectImageMime(Uint8List.fromList([0xff, 0xd8, 0xff, 0xe0])),
      'image/jpeg',
    );
    expect(
      detectImageMime(
        Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
      ),
      'image/png',
    );
    expect(
      detectImageMime(Uint8List.fromList('GIF89a'.codeUnits)),
      'image/gif',
    );
  });

  test('image editor keeps the original file and unbounded output config', () {
    const page = ChatImageEditorPage(
      imagePath: '/original/photo.png',
      mimeType: 'image/png',
    );
    final config = page.imageGenerationConfigs;

    expect(page.imagePath, '/original/photo.png');
    expect(config.enableUseOriginalBytes, isTrue);
    expect(config.maxOutputSize, Size.infinite);
    expect(config.outputFormat, OutputFormat.png);
    expect(config.jpegQuality, 100);
  });

  test(
    'coordinates are validated and normalized without exponent notation',
    () {
      expect(canonicalGeoUri('39.9000', '+116.400000'), 'geo:39.9,116.4');
      expect(canonicalGeoUri('-0', '.5'), 'geo:0,0.5');
      expect(canonicalGeoUri('NaN', '116.4'), isNull);
      expect(canonicalGeoUri('1e-7', '116.4'), isNull);
    },
  );
}
