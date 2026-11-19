import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' as html;
import 'package:http/http.dart' as http;

import '../../features/matrix_html/matrix_link_router.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../theme/neu_colors.dart';
import '../../widgets/app_avatar.dart';

class LinkPreviewCard extends ConsumerWidget {
  final Uri uri;
  final bool isMe;
  final double width;
  final MatrixLinkHandler? onOpen;

  const LinkPreviewCard({
    super.key,
    required this.uri,
    required this.isMe,
    required this.width,
    this.onOpen,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentUser = ref.watch(currentUserProvider);
    final accessToken = ref.watch(currentAccessTokenProvider);
    final serverSource =
        currentUser == null || accessToken == null || accessToken.isEmpty
        ? null
        : LinkPreviewServerSource(
            homeserver: currentUser.homeserver,
            accessToken: accessToken,
          );
    return FutureBuilder<LinkPreviewData>(
      future: LinkPreviewRepository.fetch(uri, serverSource: serverSource),
      builder: (context, snapshot) {
        final preview = snapshot.data ?? LinkPreviewData.fallback(uri);
        return _LinkPreviewFrame(
          preview: preview,
          isMe: isMe,
          width: width,
          onOpen: onOpen ?? const MatrixLinkRouter().open,
        );
      },
    );
  }
}

class _LinkPreviewFrame extends StatelessWidget {
  static const double _height = 128;

  final LinkPreviewData preview;
  final bool isMe;
  final double width;
  final MatrixLinkHandler onOpen;

  const _LinkPreviewFrame({
    required this.preview,
    required this.isMe,
    required this.width,
    required this.onOpen,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final textTheme = Theme.of(context).textTheme;
    final background = isMe
        ? Colors.white.withValues(alpha: 0.14)
        : colors.base.withValues(alpha: 0.55);
    final border = isMe
        ? Colors.white.withValues(alpha: 0.16)
        : colors.hairline;
    final titleColor = isMe ? colors.onAccent : colors.text;
    final secondaryColor = isMe
        ? colors.onAccent.withValues(alpha: 0.72)
        : colors.textTertiary;
    final linkColor = isMe
        ? colors.onAccent.withValues(alpha: 0.86)
        : colors.accent;
    final imageUrl = preview.imageUrl;
    final showImage = imageUrl != null && width >= 300;
    final imageWidth = math.min(156.0, math.max(112.0, width * 0.34));

    return SizedBox(
      width: width,
      height: _height,
      child: InkWell(
        onTap: () => onOpen(preview.uri),
        borderRadius: BorderRadius.circular(NeuRadius.tag),
        child: Container(
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(NeuRadius.tag),
            border: Border.all(color: border),
          ),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(14, 11, 12, 11),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _PreviewSourceRow(
                        preview: preview,
                        color: secondaryColor,
                        fallbackColor: linkColor,
                      ),
                      const SizedBox(height: 7),
                      Text(
                        preview.titleLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.titleSmall?.copyWith(
                          color: titleColor,
                          height: 1.2,
                        ),
                      ),
                      if (preview.descriptionLabel != null) ...[
                        const SizedBox(height: 5),
                        Text(
                          preview.descriptionLabel!,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: textTheme.bodySmall?.copyWith(
                            color: secondaryColor,
                            height: 1.28,
                          ),
                        ),
                      ],
                      const Spacer(),
                      Text(
                        preview.displayUrl,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: textTheme.bodySmall?.copyWith(
                          color: linkColor,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (showImage)
                SizedBox(
                  width: imageWidth,
                  height: _height,
                  child: _PreviewImage(
                    imageUrl: imageUrl,
                    width: imageWidth,
                    height: _height,
                    fit: BoxFit.cover,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewSourceRow extends StatelessWidget {
  final LinkPreviewData preview;
  final Color color;
  final Color fallbackColor;

  const _PreviewSourceRow({
    required this.preview,
    required this.color,
    required this.fallbackColor,
  });

  @override
  Widget build(BuildContext context) {
    final faviconUrl = preview.faviconUrl;
    return Row(
      children: [
        SizedBox.square(
          dimension: 16,
          child: faviconUrl == null
              ? Icon(Icons.public_rounded, size: 15, color: fallbackColor)
              : ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: Image.network(
                    faviconUrl,
                    fit: BoxFit.cover,
                    errorBuilder: (context, error, stackTrace) =>
                        Icon(Icons.public_rounded, size: 15, color: color),
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            preview.sourceLabel,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
          ),
        ),
      ],
    );
  }
}

class _PreviewImage extends ConsumerWidget {
  final String imageUrl;
  final double width;
  final double height;
  final BoxFit fit;

  const _PreviewImage({
    required this.imageUrl,
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pixelRatio = MediaQuery.devicePixelRatioOf(context);
    final cacheWidth = math.max(128, (width * pixelRatio).round());
    final cacheHeight = math.max(128, (height * pixelRatio).round());
    if (!imageUrl.startsWith('mxc://')) {
      return AuthenticatedImageMessage(
        imageUrl: imageUrl,
        fit: fit,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
      );
    }

    return FutureBuilder<String?>(
      future: resolveMxcUrl(
        ref,
        imageUrl,
        width: cacheWidth,
        height: cacheHeight,
      ),
      builder: (context, snapshot) {
        final resolvedUrl = snapshot.data;
        if (resolvedUrl == null || resolvedUrl.isEmpty) {
          return const SizedBox.shrink();
        }
        return AuthenticatedImageMessage(
          imageUrl: resolvedUrl,
          fit: fit,
          cacheWidth: cacheWidth,
          cacheHeight: cacheHeight,
        );
      },
    );
  }
}

class LinkPreviewData {
  final Uri uri;
  final String? title;
  final String? description;
  final String? siteName;
  final String? imageUrl;
  final String? faviconUrl;

  const LinkPreviewData({
    required this.uri,
    this.title,
    this.description,
    this.siteName,
    this.imageUrl,
    this.faviconUrl,
  });

  factory LinkPreviewData.fallback(Uri uri) => LinkPreviewData(uri: uri);

  String get hostLabel =>
      uri.host.replaceFirst(RegExp(r'^www\.', caseSensitive: false), '');

  String get sourceLabel => siteName ?? hostLabel;

  String get titleLabel => title ?? hostLabel;

  String? get descriptionLabel => description;

  String get displayUrl {
    final value = uri.toString();
    final scheme = '${uri.scheme}://';
    return value.startsWith(scheme) ? value.substring(scheme.length) : value;
  }
}

class LinkPreviewServerSource {
  final String homeserver;
  final String accessToken;

  const LinkPreviewServerSource({
    required this.homeserver,
    required this.accessToken,
  });

  String get cacheKey {
    final normalizedHomeserver = homeserver.trim().replaceFirst(
      RegExp(r'/+$'),
      '',
    );
    return 'server:$normalizedHomeserver:auth';
  }
}

class LinkPreviewRepository {
  static const int _maxPreviewBytes = 256 * 1024;
  static const Duration _timeout = Duration(seconds: 6);
  static final Map<String, Future<LinkPreviewData>> _cache = {};

  const LinkPreviewRepository._();

  static Future<LinkPreviewData> fetch(
    Uri uri, {
    LinkPreviewServerSource? serverSource,
  }) {
    final cacheKey = '${serverSource?.cacheKey ?? 'client'}:${uri.toString()}';
    return _cache.putIfAbsent(
      cacheKey,
      () => _fetch(uri, serverSource: serverSource),
    );
  }

  static Future<LinkPreviewData> _fetch(
    Uri uri, {
    LinkPreviewServerSource? serverSource,
  }) async {
    final serverPreview = await _fetchServerPreview(uri, serverSource);
    if (serverPreview != null) return serverPreview;
    return _fetchClientPreview(uri);
  }

  static Future<LinkPreviewData?> _fetchServerPreview(
    Uri uri,
    LinkPreviewServerSource? source,
  ) async {
    if (source == null) return null;
    final endpoint = serverPreviewEndpoint(source.homeserver, uri);
    if (endpoint == null) return null;

    final client = http.Client();
    try {
      final response = await client
          .get(
            endpoint,
            headers: {
              'accept': 'application/json',
              'authorization': 'Bearer ${source.accessToken}',
            },
          )
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return null;
      }
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) return null;
      return parseMatrixPreview(uri, decoded);
    } catch (_) {
      return null;
    } finally {
      client.close();
    }
  }

  static Future<LinkPreviewData> _fetchClientPreview(Uri uri) async {
    final fallback = LinkPreviewData.fallback(uri);
    final client = http.Client();
    try {
      final request = http.Request('GET', uri)
        ..followRedirects = true
        ..maxRedirects = 5
        ..headers.addAll({
          'accept': 'text/html,application/xhtml+xml',
          'user-agent': 'Matter link preview',
        });
      final response = await client.send(request).timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 400) {
        return fallback;
      }
      final contentType = response.headers['content-type']?.toLowerCase();
      if (contentType != null &&
          !contentType.contains('text/html') &&
          !contentType.contains('application/xhtml+xml')) {
        return fallback;
      }

      final bytes = <int>[];
      var total = 0;
      await for (final chunk in response.stream.timeout(_timeout)) {
        if (total >= _maxPreviewBytes) break;
        final remaining = _maxPreviewBytes - total;
        final capped = chunk.length > remaining
            ? chunk.sublist(0, remaining)
            : chunk;
        bytes.addAll(capped);
        total += capped.length;
      }
      if (bytes.isEmpty) return fallback;

      return _parsePreview(uri, utf8.decode(bytes, allowMalformed: true));
    } catch (_) {
      return fallback;
    } finally {
      client.close();
    }
  }

  @visibleForTesting
  static Uri? serverPreviewEndpoint(String homeserver, Uri previewUri) {
    final base = homeserver.trim().replaceFirst(RegExp(r'/+$'), '');
    if (base.isEmpty) return null;
    final uri = Uri.tryParse('$base/_matrix/client/v1/media/preview_url');
    if (uri == null || uri.host.isEmpty) return null;
    return uri.replace(queryParameters: {'url': previewUri.toString()});
  }

  @visibleForTesting
  static LinkPreviewData parseMatrixPreview(
    Uri uri,
    Map<String, dynamic> json,
  ) {
    final canonicalUrl = _stringValue(json['og:url']);
    final canonicalUri = canonicalUrl == null
        ? null
        : Uri.tryParse(canonicalUrl);
    final previewUri =
        canonicalUri != null &&
            canonicalUri.hasScheme &&
            canonicalUri.host.isNotEmpty
        ? canonicalUri
        : uri;
    return LinkPreviewData(
      uri: previewUri,
      title: _cleanText(_stringValue(json['og:title'])),
      description: _cleanText(_stringValue(json['og:description'])),
      siteName: _cleanText(_stringValue(json['og:site_name'])),
      imageUrl: _resolvePreviewUrl(uri, _stringValue(json['og:image'])),
      faviconUrl: _resolvePreviewUrl(
        uri,
        _stringValue(json['matrix:site_logo']),
      ),
    );
  }

  static LinkPreviewData _parsePreview(Uri uri, String body) {
    final document = html.parse(body);
    final titleElements = document.getElementsByTagName('title');
    final title =
        _metaContent(document, const ['og:title', 'twitter:title']) ??
        (titleElements.isEmpty ? null : _cleanText(titleElements.first.text));
    final description = _metaContent(document, const [
      'og:description',
      'twitter:description',
      'description',
    ]);
    final siteName = _metaContent(document, const [
      'og:site_name',
      'application-name',
      'apple-mobile-web-app-title',
    ]);
    final imageUrl = _resolvePreviewUrl(
      uri,
      _metaContent(document, const ['og:image', 'twitter:image']),
    );
    final faviconUrl = _resolvePreviewUrl(uri, _faviconHref(document));

    return LinkPreviewData(
      uri: uri,
      title: title,
      description: description,
      siteName: siteName,
      imageUrl: imageUrl,
      faviconUrl: faviconUrl,
    );
  }

  static String? _metaContent(dom.Document document, List<String> names) {
    final wanted = names.map((name) => name.toLowerCase()).toSet();
    for (final element in document.getElementsByTagName('meta')) {
      final key =
          element.attributes['property']?.toLowerCase() ??
          element.attributes['name']?.toLowerCase();
      if (key == null || !wanted.contains(key)) continue;
      final content = _cleanText(element.attributes['content']);
      if (content != null) return content;
    }
    return null;
  }

  static String? _faviconHref(dom.Document document) {
    String? fallback;
    for (final element in document.getElementsByTagName('link')) {
      final rel = element.attributes['rel']?.toLowerCase();
      final href = element.attributes['href'];
      if (rel == null || href == null || href.trim().isEmpty) continue;
      final rels = rel.split(RegExp(r'\s+')).toSet();
      if (rels.contains('icon') || rels.contains('shortcut')) return href;
      if (fallback == null && rels.contains('apple-touch-icon')) {
        fallback = href;
      }
    }
    return fallback;
  }

  static String? _resolvePreviewUrl(Uri pageUri, String? raw) {
    final value = raw?.trim();
    if (value == null || value.isEmpty) return null;
    final uri = Uri.tryParse(value);
    if (uri == null) return null;
    final resolved = pageUri.resolveUri(uri);
    final scheme = resolved.scheme.toLowerCase();
    if (scheme != 'http' && scheme != 'https' && scheme != 'mxc') return null;
    return resolved.toString();
  }

  static String? _stringValue(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value;
  }

  static String? _cleanText(String? value) {
    final cleaned = value?.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (cleaned == null || cleaned.isEmpty) return null;
    if (cleaned.length <= 240) return cleaned;
    return '${cleaned.substring(0, 237)}...';
  }
}
