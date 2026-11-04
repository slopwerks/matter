import 'dart:js_interop';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:web/web.dart';

import '../../src/rust/api/matrix.dart' as rust;
import 'media_preparation.dart';
import 'attachment_media_utils.dart';

class PreparedMediaSource {
  final Media media;
  final Future<void> Function() cleanup;
  final Future<String?> Function()? waveformFile;

  const PreparedMediaSource({
    required this.media,
    required this.cleanup,
    this.waveformFile,
  });
}

Future<void> cleanupStaleMediaSources() async {}

// Browsers retain the bounded Blob preview path; native platforms use files.
Future<PreparedMediaSource> prepareEncryptedMediaSource(
  String mediaSourceJson,
  String filename, {
  required String expectedUserId,
  required MediaPreparation preparation,
}) async {
  preparation.throwIfCancelled();
  final bytes = await rust.downloadMediaSourceBytes(
    mediaSourceJson: mediaSourceJson,
    maxSizeBytes: 16 * 1024 * 1024,
  );
  preparation.throwIfCancelled();
  return prepareDecryptedMediaSource(bytes, filename);
}

Future<PreparedMediaSource> prepareRemoteMediaSource(
  Uri url,
  String filename, {
  Map<String, String> httpHeaders = const {},
  MediaPreparation? preparation,
}) async {
  preparation?.throwIfCancelled();
  final response = await http.get(url, headers: httpHeaders);
  if (response.statusCode != 200) {
    throw http.ClientException(
      'Media download failed (HTTP ${response.statusCode})',
      url,
    );
  }
  preparation?.throwIfCancelled();
  return prepareDecryptedMediaSource(response.bodyBytes, filename);
}

Future<PreparedMediaSource> prepareDecryptedMediaSource(
  Uint8List bytes,
  String filename,
) async {
  final blob = Blob(
    <JSUint8Array>[bytes.toJS].toJS,
    BlobPropertyBag(
      type: resolveAttachmentMime(filename, null) ?? 'application/octet-stream',
    ),
  );
  final objectUrl = URL.createObjectURL(blob);
  return PreparedMediaSource(
    media: Media(objectUrl),
    cleanup: () async => URL.revokeObjectURL(objectUrl),
  );
}
