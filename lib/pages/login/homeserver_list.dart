import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

const _kHomeserversAssetPath = 'assets/homeservers.json';

/// A preset homeserver entry loaded from `assets/homeservers.json`.
class HomeserverEntry {
  final String domain;
  final String label;

  const HomeserverEntry({required this.domain, required this.label});

  factory HomeserverEntry.fromJson(Map<String, dynamic> json) {
    final domain = (json['domain'] as String?)?.trim() ?? '';
    final label = (json['label'] as String?)?.trim() ?? domain;
    return HomeserverEntry(domain: domain, label: label);
  }
}

/// Parse the bundled homeserver list from its raw JSON. Returns an empty list
/// (rather than throwing) if the content is missing or malformed, so the login
/// page can always fall back to a plain input field.
List<HomeserverEntry> parseHomeservers(String raw) {
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! List) return const [];
    return decoded
        .whereType<Map<String, dynamic>>()
        .map(HomeserverEntry.fromJson)
        .where((e) => e.domain.isNotEmpty)
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Load the bundled preset homeserver list.
Future<List<HomeserverEntry>> loadHomeservers({
  String assetPath = _kHomeserversAssetPath,
}) async {
  try {
    final raw = await rootBundle.loadString(assetPath);
    return parseHomeservers(raw);
  } catch (_) {
    return const [];
  }
}
