import 'dart:convert';
import 'package:http/http.dart' as http;

/// Result of resolving a user-entered homeserver input to a full URL.
class ResolvedHomeserver {
  /// Full homeserver URL with scheme, e.g. `https://matrix.org`.
  final String url;

  /// Whether the resolved URL is plain HTTP (insecure).
  final bool isHttp;

  /// How the URL was determined:
  /// `input` (user gave a full scheme), `well-known`, `https`, or `http`.
  final String source;

  const ResolvedHomeserver({
    required this.url,
    required this.isHttp,
    required this.source,
  });

  @override
  String toString() =>
      'ResolvedHomeserver(url: $url, isHttp: $isHttp, source: $source)';
}

const _defaultTimeout = Duration(seconds: 6);
const _versionsPath = '/_matrix/client/versions';
const _wellKnownPath = '/.well-known/matrix/client';

/// Resolve a user-entered homeserver string to a full URL.
///
/// Resolution order when the input has no scheme:
///  1. `https://<host>/.well-known/matrix/client` server discovery — if it
///     returns `m.homeserver.base_url`, use that URL as-is.
///  2. `https://<host>` probed via `GET /_matrix/client/versions`.
///  3. `http://<host>` probed the same way (insecure fallback).
///  4. Fail.
///
/// When the input already carries an `http://` / `https://` scheme it is
/// returned verbatim (no probing), so an explicit user choice is respected.
Future<ResolvedHomeserver> resolveHomeserver(
  String rawInput, {
  http.Client? client,
  Duration timeout = _defaultTimeout,
}) async {
  final raw = rawInput.trim();
  if (raw.isEmpty) {
    throw const FormatException('Homeserver 地址不能为空');
  }

  final ownsClient = client == null;
  final c = client ?? http.Client();
  try {
    final parsed = Uri.tryParse(raw);
    if (parsed != null &&
        (parsed.scheme == 'http' || parsed.scheme == 'https') &&
        parsed.host.isNotEmpty) {
      return ResolvedHomeserver(
        url: normalizeUrl(raw),
        isHttp: parsed.scheme == 'http',
        source: 'input',
      );
    }

    final hostInput = raw.replaceAll(RegExp(r'^//'), '');

    final wellKnown = await _discoverWellKnown(c, hostInput, timeout);
    if (wellKnown != null) return wellKnown;

    if (await _probe(c, 'https://$hostInput$_versionsPath', timeout)) {
      return ResolvedHomeserver(
        url: normalizeUrl('https://$hostInput'),
        isHttp: false,
        source: 'https',
      );
    }

    if (await _probe(c, 'http://$hostInput$_versionsPath', timeout)) {
      return ResolvedHomeserver(
        url: normalizeUrl('http://$hostInput'),
        isHttp: true,
        source: 'http',
      );
    }

    throw Exception('无法连接到「$hostInput」，请检查地址是否正确');
  } finally {
    if (ownsClient) c.close();
  }
}

/// Strip trailing slashes so persisted homeserver URLs are stable.
String normalizeUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  return u;
}

Future<ResolvedHomeserver?> _discoverWellKnown(
  http.Client c,
  String hostInput,
  Duration timeout,
) async {
  try {
    final response = await c
        .get(Uri.parse('https://$hostInput$_wellKnownPath'))
        .timeout(timeout);
    if (response.statusCode < 200 || response.statusCode >= 300) return null;

    final body = response.body;
    if (body.isEmpty) return null;
    final decoded = _parseJson(body);
    if (decoded is! Map<String, dynamic>) return null;

    final homeserver = decoded['m.homeserver'];
    if (homeserver is! Map<String, dynamic>) return null;
    final baseUrl = homeserver['base_url'];
    if (baseUrl is! String || baseUrl.trim().isEmpty) return null;

    final parsed = Uri.tryParse(baseUrl.trim());
    if (parsed == null ||
        parsed.host.isEmpty ||
        (parsed.scheme != 'http' && parsed.scheme != 'https')) {
      return null;
    }
    return ResolvedHomeserver(
      url: normalizeUrl(baseUrl.trim()),
      isHttp: parsed.scheme == 'http',
      source: 'well-known',
    );
  } catch (_) {
    return null;
  }
}

dynamic _parseJson(String body) {
  try {
    return jsonDecode(body);
  } catch (_) {
    return null;
  }
}

Future<bool> _probe(http.Client c, String url, Duration timeout) async {
  try {
    final response = await c.get(Uri.parse(url)).timeout(timeout);
    return response.statusCode >= 200 && response.statusCode < 400;
  } catch (_) {
    return false;
  }
}
