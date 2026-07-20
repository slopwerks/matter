import 'dart:convert';

import 'package:flutter_cache_manager/flutter_cache_manager.dart';

const _cachePrefix = 'matter-auth-media';
final _cacheManagers = <String, CacheManager>{};

bool isMatrixAuthenticatedMediaUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null && uri.path.startsWith('/_matrix/client/');
}

bool isCurrentHomeserverMatrixMediaUrl(String url, String? homeserver) {
  final mediaUri = Uri.tryParse(url);
  final homeserverUri = homeserver == null
      ? null
      : Uri.tryParse(homeserver.trim());
  if (mediaUri == null || homeserverUri == null) return false;
  if (!mediaUri.isScheme('http') && !mediaUri.isScheme('https')) return false;
  return isMatrixAuthenticatedMediaUrl(url) &&
      mediaUri.scheme == homeserverUri.scheme &&
      mediaUri.host == homeserverUri.host &&
      mediaUri.port == homeserverUri.port;
}

String? authenticatedMediaCacheKey({
  required String url,
  required String? userId,
  required String? homeserver,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !isMatrixAuthenticatedMediaUrl(url)) return null;
  final scope = _scopeId(
    userId: userId,
    homeserver: _homeserverScope(uri, homeserver),
  );
  return '$_cachePrefix:$scope:${_cacheToken(url)}';
}

BaseCacheManager? authenticatedMediaCacheManager({
  required String url,
  required String? userId,
  required String? homeserver,
}) {
  final uri = Uri.tryParse(url);
  if (uri == null || !isMatrixAuthenticatedMediaUrl(url)) return null;
  final scope = _scopeId(
    userId: userId,
    homeserver: _homeserverScope(uri, homeserver),
  );
  return _cacheManagers.putIfAbsent(scope, () => _newCacheManager(scope));
}

Future<void> clearAuthenticatedMediaCacheForSession({
  required String userId,
  required String homeserver,
}) async {
  final scope = _scopeId(userId: userId, homeserver: homeserver);
  final manager = _cacheManagers.remove(scope) ?? _newCacheManager(scope);
  await manager.emptyCache();
  await manager.dispose();
}

CacheManager _newCacheManager(String scope) {
  return _AuthenticatedMediaCacheManager(
    Config(
      '$_cachePrefix-$scope',
      stalePeriod: const Duration(days: 30),
      maxNrOfCacheObjects: 500,
    ),
  );
}

class _AuthenticatedMediaCacheManager extends CacheManager
    with ImageCacheManager {
  _AuthenticatedMediaCacheManager(super.config);
}

String _homeserverScope(Uri uri, String? homeserver) {
  final trimmed = homeserver?.trim();
  if (trimmed != null && trimmed.isNotEmpty) return trimmed;
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '${uri.scheme}://${uri.host}$port';
}

String _scopeId({required String? userId, required String homeserver}) {
  return _cacheToken('${userId ?? 'anonymous'}|$homeserver');
}

String _cacheToken(String input) {
  return base64Url.encode(utf8.encode(input)).replaceAll('=', '');
}
