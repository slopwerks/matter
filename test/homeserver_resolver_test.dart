import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:matter/pages/login/homeserver_resolver.dart';

void main() {
  http.Client clientWith(Map<String, http.Response> responses) {
    return MockClient((request) async {
      final key = '${request.url}';
      final response = responses[key];
      if (response != null) return response;
      return http.Response('', 404);
    });
  }

  group('resolveHomeserver - explicit scheme', () {
    test('https input is returned verbatim without probing', () async {
      var probed = false;
      final client = MockClient((_) async {
        probed = true;
        return http.Response('', 200);
      });

      final result = await resolveHomeserver(
        'https://matrix.org',
        client: client,
      );

      expect(probed, isFalse, reason: 'must not probe when scheme is given');
      expect(result.url, 'https://matrix.org');
      expect(result.isHttp, isFalse);
      expect(result.source, 'input');
    });

    test('http input is flagged insecure without probing', () async {
      final result = await resolveHomeserver(
        'http://10.0.2.2:8008',
        client: MockClient((_) async => http.Response('', 200)),
      );

      expect(result.url, 'http://10.0.2.2:8008');
      expect(result.isHttp, isTrue);
      expect(result.source, 'input');
    });

    test('trailing slash is stripped', () async {
      final result = await resolveHomeserver(
        'https://matrix.org/',
        client: MockClient((_) async => http.Response('', 200)),
      );
      expect(result.url, 'https://matrix.org');
    });
  });

  group('resolveHomeserver - well-known discovery', () {
    test('uses m.homeserver.base_url when present', () async {
      final client = clientWith({
        'https://example.com/.well-known/matrix/client': http.Response(
          '{"m.homeserver":{"base_url":"https://matrix.example.com"}}',
          200,
        ),
      });

      final result = await resolveHomeserver('example.com', client: client);

      expect(result.url, 'https://matrix.example.com');
      expect(result.isHttp, isFalse);
      expect(result.source, 'well-known');
    });

    test('http base_url from well-known is flagged insecure', () async {
      final client = clientWith({
        'https://example.com/.well-known/matrix/client': http.Response(
          '{"m.homeserver":{"base_url":"http://insecure.example.com"}}',
          200,
        ),
      });

      final result = await resolveHomeserver('example.com', client: client);

      expect(result.url, 'http://insecure.example.com');
      expect(result.isHttp, isTrue);
      expect(result.source, 'well-known');
    });

    test('falls through when well-known JSON lacks base_url', () async {
      final responses = <String, http.Response>{
        'https://example.com/.well-known/matrix/client': http.Response(
          '{"m.identity_server":{"base_url":"https://id.example.com"}}',
          200,
        ),
        'https://example.com/_matrix/client/versions': http.Response(
          '{"versions":["v1.11"]}',
          200,
        ),
      };
      final client = MockClient((request) async {
        return responses['${request.url}'] ?? http.Response('', 404);
      });

      final result = await resolveHomeserver('example.com', client: client);

      expect(result.source, 'https');
      expect(result.isHttp, isFalse);
    });
  });

  group('resolveHomeserver - direct connect', () {
    test('https direct connect when well-known 404s', () async {
      final client = clientWith({
        'https://example.com/.well-known/matrix/client': http.Response('', 404),
        'https://example.com/_matrix/client/versions': http.Response(
          '{"versions":["v1.11"]}',
          200,
        ),
      });

      final result = await resolveHomeserver('example.com', client: client);

      expect(result.url, 'https://example.com');
      expect(result.isHttp, isFalse);
      expect(result.source, 'https');
    });

    test('http fallback when https probe fails', () async {
      final client = clientWith({
        'https://example.com/.well-known/matrix/client': http.Response('', 404),
        'https://example.com/_matrix/client/versions': http.Response('', 502),
        'http://example.com/_matrix/client/versions': http.Response(
          '{"versions":["v1.11"]}',
          200,
        ),
      });

      final result = await resolveHomeserver('example.com', client: client);

      expect(result.url, 'http://example.com');
      expect(result.isHttp, isTrue);
      expect(result.source, 'http');
    });

    test('local host with port resolves over http', () async {
      final client = clientWith({
        'https://10.0.2.2:8008/.well-known/matrix/client': http.Response(
          '',
          404,
        ),
        'https://10.0.2.2:8008/_matrix/client/versions': http.Response('', 502),
        'http://10.0.2.2:8008/_matrix/client/versions': http.Response(
          '{"versions":["v1.11"]}',
          200,
        ),
      });

      final result = await resolveHomeserver('10.0.2.2:8008', client: client);

      expect(result.url, 'http://10.0.2.2:8008');
      expect(result.isHttp, isTrue);
      expect(result.source, 'http');
    });

    test('network errors on all probes throw', () async {
      final client = MockClient((_) async => throw Exception('socket closed'));

      await expectLater(
        resolveHomeserver('unreachable.example.com', client: client),
        throwsA(isA<Exception>()),
      );
    });

    test('all probes returning 4xx/5xx throw', () async {
      final client = MockClient((_) async => http.Response('', 503));

      await expectLater(
        resolveHomeserver('down.example.com', client: client),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('resolveHomeserver - validation', () {
    test('empty input throws', () async {
      await expectLater(
        resolveHomeserver('   '),
        throwsA(isA<FormatException>()),
      );
    });

    test('strips leading // before probing', () async {
      final seen = <String>[];
      final client = MockClient((request) async {
        seen.add('${request.url}');
        return http.Response('', 404);
      });

      await expectLater(
        resolveHomeserver('//matrix.org', client: client),
        throwsA(isA<Exception>()),
      );
      // hostInput after stripping '//' is 'matrix.org'
      expect(seen, contains('https://matrix.org/.well-known/matrix/client'));
    });
  });

  group('normalizeUrl', () {
    test('strips trailing slashes', () {
      expect(normalizeUrl('https://matrix.org/'), 'https://matrix.org');
      expect(normalizeUrl('https://matrix.org///'), 'https://matrix.org');
      expect(normalizeUrl('https://matrix.org'), 'https://matrix.org');
    });

    test('trims surrounding whitespace', () {
      expect(normalizeUrl('  https://matrix.org/  '), 'https://matrix.org');
    });
  });
}
