import 'dart:io';
import 'dart:typed_data';

import 'package:path_provider/path_provider.dart';
import 'package:video_player/video_player.dart';

class PreparedVideoSource {
  final VideoPlayerController controller;
  final Future<void> Function() cleanup;

  const PreparedVideoSource({required this.controller, required this.cleanup});
}

Future<void> cleanupStaleDecryptedVideoSources() async {
  try {
    final tempDirectory = await getTemporaryDirectory();
    final mediaDirectory = Directory(
      '${tempDirectory.path}/matter_decrypted_media',
    );
    if (await mediaDirectory.exists()) {
      await mediaDirectory.delete(recursive: true);
    }
  } catch (_) {
    // Cleanup must not prevent application startup.
  }
}

Future<PreparedVideoSource> prepareDecryptedVideoSource(
  Uint8List bytes,
  String filename,
) async {
  final tempDirectory = await getTemporaryDirectory();
  final mediaDirectory = Directory(
    '${tempDirectory.path}/matter_decrypted_media',
  );
  await mediaDirectory.create(recursive: true);
  final extension = _safeVideoExtension(filename);
  final file = File(
    '${mediaDirectory.path}/${DateTime.now().microsecondsSinceEpoch}.$extension',
  );
  await file.writeAsBytes(bytes, flush: true);
  return PreparedVideoSource(
    controller: VideoPlayerController.file(file),
    cleanup: () async {
      try {
        if (await file.exists()) await file.delete();
      } catch (_) {
        // Best-effort cleanup; the OS may still hold the file during teardown.
      }
    },
  );
}

String _safeVideoExtension(String filename) {
  final extension = filename.split('.').last.toLowerCase();
  const supported = {'mp4', 'm4v', 'mov', 'webm', 'mkv'};
  return supported.contains(extension) ? extension : 'mp4';
}
