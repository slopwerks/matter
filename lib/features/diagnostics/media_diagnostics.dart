import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';

import '../../src/rust/api/matrix.dart' as rust;
import 'diagnostic_exporter.dart' show redactLogMessage;

final _httpUrlPattern = RegExp(
  r'''https?://[^\s<>"')}]+''',
  caseSensitive: false,
);

bool isMediaDecodeFailure(Object error) =>
    error is! HttpExceptionWithStatus &&
    error is! NetworkImageLoadException &&
    (error.toString().toLowerCase().contains('invalid image data') ||
        error.toString().contains('Failed to decode image') ||
        error.runtimeType.toString() == 'ImageCodecException');

String _sourceKind(String url) {
  final path = Uri.tryParse(url)?.path ?? '';
  if (url.startsWith('memory:')) return 'memory';
  if (path.contains('/thumbnail/')) return 'thumbnail';
  if (path.contains('/download/')) return 'original';
  return 'network';
}

void logMediaFirstFrame({
  required String url,
  required int elapsedMs,
  required bool retainedPreview,
  int? width,
  int? height,
}) => _writeMediaLog(
  'info',
  'media_first_frame url=${_diagnosticUrl(url)} source=${_sourceKind(url)} '
      'elapsed_ms=$elapsedMs retained_preview=$retainedPreview '
      'width=${width ?? 'original'} height=${height ?? 'original'}',
);

void logMediaRecovery({
  required String url,
  required String outcome,
  int? cacheBytes,
  bool? cacheHit,
  int? width,
  int? height,
}) => _writeMediaLog(
  'info',
  'media_decode_recovery url=${_diagnosticUrl(url)} '
      'source=${_sourceKind(url)} '
      'outcome=$outcome cache_hit=${cacheHit ?? 'unknown'} '
      'cache_bytes=${cacheBytes ?? 'unknown'} '
      'width=${width ?? 'original'} height=${height ?? 'original'}',
);

String _diagnosticUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null || !uri.hasAuthority) return '[invalid URL]';
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
    path: uri.path,
  ).toString();
}

/// Records an image failure once per load attempt. Credentials and URL query
/// values are removed before the message reaches the persisted app log.
void logMediaLoadFailure({
  required String url,
  required Object error,
  required int elapsedMs,
  required int attempt,
  required String connection,
  required bool authenticated,
  int? width,
  int? height,
  int? inputBytes,
}) {
  final status = switch (error) {
    HttpExceptionWithStatus(:final statusCode) => statusCode,
    NetworkImageLoadException(:final statusCode) => statusCode,
    _ => null,
  };
  final detail = redactLogMessage(
    error.toString().replaceAllMapped(
      _httpUrlPattern,
      (match) => _diagnosticUrl(match[0]!),
    ),
  );
  final message =
      'media_load_failed url=${_diagnosticUrl(url)} '
      'attempt=$attempt elapsed_ms=$elapsedMs '
      'stage=${status == null ? 'image_load' : 'http_status'} '
      'http_status=${status ?? 'none'} error_type=${error.runtimeType} '
      'failure_kind=${isMediaDecodeFailure(error) ? 'decode' : 'request'} '
      'width=${width ?? 'original'} height=${height ?? 'original'} '
      'source=${_sourceKind(url)} input_bytes=${inputBytes ?? 'unknown'} '
      'connection=$connection authenticated=$authenticated error=$detail';
  _writeMediaLog('error', message);
}

void _writeMediaLog(String level, String message) {
  try {
    rust.logAppMessage(level: level, tag: 'media', message: message);
  } catch (_) {
    // Partial Rust API fakes and uninitialized widget tests have no log sink.
    debugPrint(message);
  }
}
