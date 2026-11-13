import 'dart:io';

import 'package:flutter/painting.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matter/features/diagnostics/media_diagnostics.dart';
import 'package:matter/src/rust/frb_generated.dart';

class _LogApi implements RustLibApi {
  final entries = <({String level, String tag, String message})>[];

  @override
  void crateApiMatrixLogAppMessage({
    required String level,
    required String tag,
    required String message,
  }) => entries.add((level: level, tag: tag, message: message));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _LogApi api;
  setUp(() {
    api = _LogApi();
    RustLib.initMock(api: api);
  });
  tearDown(RustLib.dispose);

  void record(Object error) => logMediaLoadFailure(
    url:
        'https://alice:password-secret@matrix.example/media/id'
        '?access_token=query-secret&width=96#fragment-secret',
    error: error,
    elapsedMs: 321,
    attempt: 2,
    connection: 'disconnected',
    authenticated: true,
  );

  test(
    'persists socket details and request context without URL credentials',
    () {
      record(
        const SocketException(
          'Failed host lookup: matrix.example',
          osError: OSError('No address associated with hostname', 7),
        ),
      );
      final entry = api.entries.single;
      expect(entry.level, 'error');
      expect(entry.tag, 'media');
      expect(entry.message, contains('url=https://matrix.example/media/id'));
      expect(entry.message, contains('attempt=2 elapsed_ms=321'));
      expect(entry.message, contains('error_type=SocketException'));
      expect(entry.message, contains('http_status=none'));
      expect(
        entry.message,
        contains('connection=disconnected authenticated=true'),
      );
      expect(entry.message, contains('No address associated with hostname'));
      expect(entry.message, contains('errno = 7'));
      expect(entry.message, isNot(contains('secret')));
      expect(entry.message, isNot(contains('alice')));
    },
  );

  test(
    'records cache-manager HTTP status and sanitizes repeated error URLs',
    () {
      record(
        HttpExceptionWithStatus(
          401,
          'Invalid statusCode: 401',
          uri: Uri.parse(
            'https://u:uri-secret@matrix.example/media/id?token=url-secret',
          ),
        ),
      );
      final message = api.entries.single.message;
      expect(message, contains('stage=http_status http_status=401'));
      expect(message, contains('error_type=HttpExceptionWithStatus'));
      expect(message, isNot(contains('secret')));
    },
  );

  test('removes credentials from IPv6 URLs in request and error context', () {
    const url =
        'https://alice:ipv6-secret@[::1]:8448/media/id?token=query-secret';
    logMediaLoadFailure(
      url: url,
      error: HttpExceptionWithStatus(403, 'Forbidden', uri: Uri.parse(url)),
      elapsedMs: 12,
      attempt: 1,
      connection: 'connected',
      authenticated: false,
    );
    final message = api.entries.single.message;
    expect(message, contains('https://[::1]:8448/media/id'));
    expect(message, isNot(contains('secret')));
    expect(message, isNot(contains('alice')));
  });

  test('records Flutter network image status', () {
    record(
      NetworkImageLoadException(
        statusCode: 503,
        uri: Uri.parse('https://matrix.example/media/id'),
      ),
    );
    expect(api.entries.single.message, contains('http_status=503'));
  });

  test('retains decode failures without inventing an HTTP status', () {
    record(StateError('Invalid image data'));
    final message = api.entries.single.message;
    expect(message, contains('stage=image_load http_status=none'));
    expect(message, contains('error_type=StateError'));
    expect(message, contains('Invalid image data'));
  });

  test('HTTP failures containing decode text are not cache corruption', () {
    expect(
      isMediaDecodeFailure(HttpExceptionWithStatus(502, 'Invalid image data')),
      isFalse,
    );
    expect(
      isMediaDecodeFailure(const SocketException('Connection reset')),
      isFalse,
    );
  });

  test('redacts credentials echoed in error messages before persistence', () {
    record(
      Exception(
        'Authorization: Bearer bearer-secret access_token=token-secret',
      ),
    );
    final message = api.entries.single.message;
    expect(message, contains('Bearer [REDACTED]'));
    expect(message, contains('access_token=[REDACTED]'));
    expect(message, isNot(contains('secret')));
  });
}
