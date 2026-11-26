import 'dart:io';

/// Candidates Android uses to declare its font families, in priority order.
const List<String> systemFontConfigPaths = [
  '/system/etc/fonts.xml',
  '/product/etc/fonts.xml',
];

final RegExp _namedFamily = RegExp(r'<family\s+name="([^"]+)"');

/// Family names declared in [path], in file order and without duplicates.
///
/// Only the family entries that carry a name matter: the unnamed ones are
/// fallback chains that cannot be requested by name.
Future<List<String>> loadSystemFontFamilies({
  String path = '/system/etc/fonts.xml',
}) async {
  try {
    final xml = await File(path).readAsString();
    final names = <String>[];
    for (final match in _namedFamily.allMatches(xml)) {
      final name = match.group(1)!;
      if (!names.contains(name)) names.add(name);
    }
    return names;
  } catch (_) {
    return const [];
  }
}
