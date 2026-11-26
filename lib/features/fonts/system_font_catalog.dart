import 'dart:convert';
import 'dart:io';

/// Candidates Android uses to declare its font families, in priority order.
const List<String> systemFontConfigPaths = [
  '/system/etc/fonts.xml',
  '/product/etc/fonts.xml',
];

final RegExp _namedFamily = RegExp(r'<family\s+name="([^"]+)"');

/// Discovered platform font families, with an optional monospace subset.
class SystemFontCatalog {
  const SystemFontCatalog({
    required this.families,
    this.monospaceFamilies = const {},
  });

  static const empty = SystemFontCatalog(families: []);

  final List<String> families;
  final Set<String> monospaceFamilies;
}

/// Family names declared in [path] (or all [systemFontConfigPaths] / desktop
/// platform font registries when [path] is omitted), in order without
/// duplicates.
Future<List<String>> loadSystemFontFamilies({String? path}) async {
  if (path != null) {
    try {
      final xml = await File(path).readAsString();
      return parseAndroidFontsXml(xml);
    } catch (_) {
      return const [];
    }
  }
  return (await loadSystemFontCatalog()).families;
}

/// Discovers installed system font families on Android, Linux, macOS and
/// Windows.
Future<SystemFontCatalog> loadSystemFontCatalog() async {
  if (Platform.isAndroid) {
    return _loadAndroidFontCatalog();
  }
  if (Platform.isLinux) {
    return _loadLinuxFontCatalog();
  }
  if (Platform.isMacOS) {
    return _loadMacOsFontCatalog();
  }
  if (Platform.isWindows) {
    return _loadWindowsFontCatalog();
  }
  return SystemFontCatalog.empty;
}

Future<SystemFontCatalog> _loadAndroidFontCatalog() async {
  final names = <String>[];
  final seen = <String>{};
  for (final path in systemFontConfigPaths) {
    try {
      final xml = await File(path).readAsString();
      for (final name in parseAndroidFontsXml(xml)) {
        if (seen.add(name)) names.add(name);
      }
    } catch (_) {
      // Missing or unreadable config candidate: continue to the next path.
    }
  }
  final mono = {
    for (final name in names)
      if (isLikelyMonospaceFamily(name)) name,
  };
  return SystemFontCatalog(families: names, monospaceFamilies: mono);
}

Future<SystemFontCatalog> _loadLinuxFontCatalog() async {
  try {
    final allResult = await Process.run('fc-list', ['--format=%{family[0]}\n']);
    if (allResult.exitCode == 0) {
      final families = parseFcListOutput(allResult.stdout.toString());
      final monoSet = <String>{};
      try {
        final monoResult = await Process.run('fc-list', [
          ':spacing=100',
          '--format=%{family[0]}\n',
        ]);
        if (monoResult.exitCode == 0) {
          monoSet.addAll(parseFcListOutput(monoResult.stdout.toString()));
        }
      } catch (_) {}
      for (final name in families) {
        if (isLikelyMonospaceFamily(name)) monoSet.add(name);
      }
      if (families.isNotEmpty) {
        return SystemFontCatalog(
          families: families,
          monospaceFamilies: monoSet,
        );
      }
    }
  } catch (_) {}

  final home = Platform.environment['HOME'];
  return _scanFontDirectories([
    '/usr/share/fonts',
    '/usr/local/share/fonts',
    if (home != null && home.isNotEmpty) '$home/.local/share/fonts',
    if (home != null && home.isNotEmpty) '$home/.fonts',
  ]);
}

Future<SystemFontCatalog> _loadMacOsFontCatalog() async {
  try {
    final result = await Process.run('system_profiler', [
      'SPFontsDataType',
      '-json',
    ]);
    if (result.exitCode == 0) {
      final catalog = parseMacOsProfilerJson(result.stdout.toString());
      if (catalog.families.isNotEmpty) return catalog;
    }
  } catch (_) {}

  final home = Platform.environment['HOME'];
  return _scanFontDirectories([
    '/System/Library/Fonts',
    '/Library/Fonts',
    if (home != null && home.isNotEmpty) '$home/Library/Fonts',
  ]);
}

Future<SystemFontCatalog> _loadWindowsFontCatalog() async {
  final names = <String>[];
  final seen = <String>{};
  const keys = [
    r'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
    r'HKCU\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Fonts',
  ];
  for (final key in keys) {
    try {
      final result = await Process.run('reg', ['query', key]);
      if (result.exitCode == 0) {
        for (final name in parseWindowsFontRegistryOutput(
          result.stdout.toString(),
        )) {
          if (seen.add(name.toLowerCase())) names.add(name);
        }
      }
    } catch (_) {}
  }
  if (names.isNotEmpty) {
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return SystemFontCatalog(
      families: names,
      monospaceFamilies: {
        for (final name in names)
          if (isLikelyMonospaceFamily(name)) name,
      },
    );
  }
  final winDir = Platform.environment['WINDIR'] ?? r'C:\Windows';
  return _scanFontDirectories(['$winDir\\Fonts']);
}

/// Parses `<family name="...">` entries from an Android `fonts.xml` string.
List<String> parseAndroidFontsXml(String xml) {
  final names = <String>[];
  for (final match in _namedFamily.allMatches(xml)) {
    final name = match.group(1)!;
    if (!names.contains(name)) names.add(name);
  }
  return names;
}

/// Parses `fc-list --format=%{family[0]}\n` output into sorted unique families.
List<String> parseFcListOutput(String output) {
  final seen = <String>{};
  final names = <String>[];
  for (final rawLine in LineSplitter.split(output)) {
    final cleaned = rawLine.trim().replaceAll(r'\-', '-');
    if (cleaned.isEmpty) continue;
    if (seen.add(cleaned)) names.add(cleaned);
  }
  names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return names;
}

/// Parses `system_profiler SPFontsDataType -json` output into a catalog.
SystemFontCatalog parseMacOsProfilerJson(String rawJson) {
  try {
    final decoded = jsonDecode(rawJson);
    if (decoded is! Map<String, dynamic>) return SystemFontCatalog.empty;
    final entries = decoded['SPFontsDataType'];
    if (entries is! List) return SystemFontCatalog.empty;
    final seen = <String>{};
    final names = <String>[];
    final mono = <String>{};
    for (final font in entries) {
      if (font is! Map) continue;
      if (font['enabled'] == 'no') continue;
      final typefaces = font['typefaces'];
      if (typefaces is List) {
        for (final face in typefaces) {
          if (face is! Map) continue;
          final family = (face['family'] as String?)?.trim();
          if (family == null || family.isEmpty) continue;
          if (seen.add(family)) names.add(family);
          if (isLikelyMonospaceFamily(family)) mono.add(family);
        }
      }
      final fallbackName = (font['_name'] as String?)?.trim();
      if ((typefaces is! List || typefaces.isEmpty) &&
          fallbackName != null &&
          fallbackName.isNotEmpty) {
        final normalized = _normalizeFontFileStem(fallbackName);
        if (normalized.isNotEmpty && seen.add(normalized)) {
          names.add(normalized);
          if (isLikelyMonospaceFamily(normalized)) mono.add(normalized);
        }
      }
    }
    names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return SystemFontCatalog(families: names, monospaceFamilies: mono);
  } catch (_) {
    return SystemFontCatalog.empty;
  }
}

final RegExp _windowsRegLine = RegExp(r'^\s+(.+?)\s{2,}REG_\w+\s+');
final RegExp _windowsFontSuffix = RegExp(
  r'\s*\((?:TrueType|OpenType|All res|Type 1|Bitmap|VGA.*)\)\s*$',
  caseSensitive: false,
);

/// Parses `reg query ...\Fonts` output into clean font family names.
List<String> parseWindowsFontRegistryOutput(String output) {
  final seen = <String>{};
  final names = <String>[];
  for (final line in LineSplitter.split(output)) {
    final match = _windowsRegLine.firstMatch(line);
    if (match == null) continue;
    final rawValue = match.group(1)!.replaceAll(_windowsFontSuffix, '').trim();
    if (rawValue.isEmpty) continue;
    for (final part in rawValue.split('&')) {
      final family = part.trim();
      if (family.isEmpty) continue;
      if (seen.add(family.toLowerCase())) names.add(family);
    }
  }
  names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return names;
}

Future<SystemFontCatalog> _scanFontDirectories(List<String> directories) async {
  final seen = <String>{};
  final names = <String>[];
  for (final path in directories) {
    final dir = Directory(path);
    try {
      if (!await dir.exists()) continue;
      await for (final entity in dir.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        final lower = entity.path.toLowerCase();
        if (!lower.endsWith('.ttf') &&
            !lower.endsWith('.otf') &&
            !lower.endsWith('.ttc')) {
          continue;
        }
        final filename = entity.uri.pathSegments.isEmpty
            ? ''
            : entity.uri.pathSegments.last;
        final family = _normalizeFontFileStem(filename);
        if (family.isNotEmpty && seen.add(family.toLowerCase())) {
          names.add(family);
        }
      }
    } catch (_) {}
  }
  names.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return SystemFontCatalog(
    families: names,
    monospaceFamilies: {
      for (final name in names)
        if (isLikelyMonospaceFamily(name)) name,
    },
  );
}

String _normalizeFontFileStem(String name) {
  var stem = name.replaceFirst(
    RegExp(r'\.(ttf|otf|ttc)$', caseSensitive: false),
    '',
  );
  stem = stem.replaceFirst(
    RegExp(
      r'[-_](?:Regular|Bold|Italic|BoldItalic|Medium|SemiBold|Light|Thin|Black)$',
      caseSensitive: false,
    ),
    '',
  );
  return stem.replaceAll('-', ' ').replaceAll('_', ' ').trim();
}

final RegExp _monoNamePattern = RegExp(
  r'(?:mono|courier|consolas|menlo|monaco|iosevka|ioskeley|hack\b|fira\s*code|jetbrains|cascadia|source\s*code|inconsolata|victor|meslo|等距|termin|fixed|profont|anonymous)',
  caseSensitive: false,
);

/// Heuristic check for monospace family names when platform metadata lacks
/// spacing flags.
bool isLikelyMonospaceFamily(String family) =>
    _monoNamePattern.hasMatch(family);
