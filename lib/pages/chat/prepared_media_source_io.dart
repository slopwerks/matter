import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:media_kit/media_kit.dart';
import 'package:path_provider/path_provider.dart';

import '../../src/rust/api/media_transfer.dart' as rust;
import 'media_preparation.dart';

class PreparedMediaSource {
  final Media media;
  final Future<void> Function() cleanup;
  // Progressive media becomes a local file only after download/verification.
  final Future<String?> Function()? waveformFile;

  const PreparedMediaSource({
    required this.media,
    required this.cleanup,
    this.waveformFile,
  });
}

Future<void> cleanupStaleMediaSources() async {
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

Future<PreparedMediaSource> prepareDecryptedMediaSource(
  Uint8List bytes,
  String filename,
) => _prepareMediaFile(
  filename,
  (file) => file.writeAsBytes(bytes, flush: true),
);

/// Rust writes only a fully verified result to this path; temporary ciphertext
/// and unverified plaintext never become a media source.
Future<PreparedMediaSource> prepareEncryptedMediaSource(
  String mediaSourceJson,
  String filename, {
  required String expectedUserId,
  required MediaPreparation preparation,
}) async {
  preparation.throwIfCancelled();
  final transfer = rust.MediaTransfer();
  final detach = preparation.onCancel(transfer.cancel);
  try {
    return await _prepareMediaFile(
      filename,
      (file) => rust.downloadMediaSourceToFile(
        transfer: transfer,
        mediaSourceJson: mediaSourceJson,
        expectedUserId: expectedUserId,
        destination: file.path,
      ),
      preparation: preparation,
    );
  } finally {
    detach();
  }
}

/// Matrix download endpoints need not support byte ranges. Download once so
/// demuxing and seeking work locally without buffering the whole file in Dart.
Future<PreparedMediaSource> prepareRemoteMediaSource(
  Uri url,
  String filename, {
  Map<String, String> httpHeaders = const {},
  MediaPreparation? preparation,
}) => _prepareMediaFile(filename, (file) async {
  final client = http.Client();
  final detach = preparation?.onCancel(client.close);
  try {
    final response = await client.send(
      http.Request('GET', url)..headers.addAll(httpHeaders),
    );
    if (response.statusCode != 200) {
      throw http.ClientException(
        'Media download failed (HTTP ${response.statusCode})',
        url,
      );
    }
    final sink = file.openWrite();
    try {
      await sink.addStream(response.stream);
      await sink.flush();
    } finally {
      await sink.close();
    }
  } finally {
    detach?.call();
    client.close();
  }
}, preparation: preparation);

Future<PreparedMediaSource> _prepareMediaFile(
  String filename,
  Future<void> Function(File) write, {
  MediaPreparation? preparation,
}) async {
  preparation?.throwIfCancelled();
  final tempDirectory = await getTemporaryDirectory();
  final mediaDirectory = Directory(
    '${tempDirectory.path}/matter_decrypted_media',
  );
  await mediaDirectory.create(recursive: true);
  final sourceDirectory = await mediaDirectory.createTemp('media-');
  final file = File(
    '${sourceDirectory.path}/source.${_safeMediaExtension(filename)}',
  );
  try {
    preparation?.throwIfCancelled();
    await write(file);
    preparation?.throwIfCancelled();
  } catch (_) {
    await sourceDirectory.delete(recursive: true);
    rethrow;
  }
  return PreparedMediaSource(
    media: Media(file.uri.toString()),
    cleanup: () async {
      try {
        if (await sourceDirectory.exists()) {
          await sourceDirectory.delete(recursive: true);
        }
      } catch (_) {
        // Best-effort cleanup; the OS may still hold the file during teardown.
      }
    },
  );
}

String _safeMediaExtension(String filename) {
  final extension = filename.split('.').last.toLowerCase();
  const supported = {
    'mp4',
    'm4v',
    'mov',
    'webm',
    'mkv',
    '3gp',
    'mp3',
    'm4a',
    'aac',
    'ogg',
    'opus',
    'wav',
    'flac',
  };
  return supported.contains(extension) ? extension : 'bin';
}
