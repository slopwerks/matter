import '../../pages/chat/media_preparation.dart';

Future<List<double>> extractAudioWaveform(
  String uri,
  MediaPreparation preparation, {
  int sampleCount = 160,
}) async {
  preparation.throwIfCancelled();
  throw UnsupportedError('Local audio waveform decoding is unavailable on web');
}
