import 'dart:js_interop';
import 'dart:typed_data';

import 'package:video_player/video_player.dart';
import 'package:web/web.dart';

class PreparedVideoSource {
  final VideoPlayerController controller;
  final Future<void> Function() cleanup;

  const PreparedVideoSource({required this.controller, required this.cleanup});
}

Future<void> cleanupStaleDecryptedVideoSources() async {}

Future<PreparedVideoSource> prepareDecryptedVideoSource(
  Uint8List bytes,
  String filename,
) async {
  final mimeType = filename.toLowerCase().endsWith('.webm')
      ? 'video/webm'
      : 'video/mp4';
  final blob = Blob(
    <JSUint8Array>[bytes.toJS].toJS,
    BlobPropertyBag(type: mimeType),
  );
  final objectUrl = URL.createObjectURL(blob);
  return PreparedVideoSource(
    controller: VideoPlayerController.networkUrl(Uri.parse(objectUrl)),
    cleanup: () async => URL.revokeObjectURL(objectUrl),
  );
}
