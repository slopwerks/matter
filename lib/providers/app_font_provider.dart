import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/fonts/system_font_catalog.dart';

/// Family the picked font file is registered under.
const String kCustomFontFamily = 'MatterCustomFont';
const String kCjkFallbackFamily = 'MatterCjkFallback';

/// Family the user picked as a fallback for glyphs the main font lacks.
const String kFallbackFontFamily = 'MatterFallbackFont';

const String _kindKey = 'app_font_kind';
const String _familyKey = 'app_font_family';
const String _pathKey = 'app_font_path';
const String _labelKey = 'app_font_label';
const String _fallbackPathKey = 'app_font_fallback_path';
const String _fallbackLabelKey = 'app_font_fallback_label';
const String _fallbackFamilyKey = 'app_font_fallback_family';

/// Which font the app renders with.
sealed class FontChoice {
  const FontChoice();
}

/// A family the platform already knows, e.g. serif or sans-serif-condensed.
class SystemFontChoice extends FontChoice {
  const SystemFontChoice(this.family, [this.fallback]);

  final String family;

  /// Families tried before the platform fallback, e.g. a CJK serif.
  final List<String>? fallback;
}

/// Second font tried when the main one lacks a glyph.
sealed class FallbackChoice {
  const FallbackChoice();
}

/// A fallback family the platform already knows, e.g. monospace.
class FamilyFallback extends FallbackChoice {
  const FamilyFallback(this.family);

  final String family;
}

/// A fallback font file, registered under [kFallbackFontFamily].
class FileFallback extends FallbackChoice {
  const FileFallback({required this.path, required this.name});

  final String path;
  final String name;
}

/// A font file the user picked, registered under [kCustomFontFamily].
class PickedFontChoice extends FontChoice {
  const PickedFontChoice({required this.path, required this.name});

  final String path;
  final String name;
}

class AppFont extends Notifier<FontChoice?> {
  @override
  FontChoice? build() {
    unawaited(_restore());
    return null;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      switch (prefs.getString(_kindKey)) {
        case 'system':
          final family = prefs.getString(_familyKey);
          if (family == null) return;
          final fallback = await _registerCjkFallback(family);
          if (!ref.mounted) return;
          state = SystemFontChoice(family, fallback);
        case 'file':
          final path = prefs.getString(_pathKey);
          final label = prefs.getString(_labelKey);
          if (path == null || label == null) return;
          if (!await _register(path)) return;
          if (!ref.mounted) return;
          state = PickedFontChoice(path: path, name: label);
      }
    } catch (error) {
      debugPrint('restore app font failed: $error');
    }
  }

  /// Android's named families only carry Latin glyphs, so a serif choice would
  /// leave Chinese on the sans-serif fallback. Loading the platform CJK serif
  /// keeps the whole timeline serif.
  Future<List<String>?> _registerCjkFallback(String family) async {
    if (!family.contains('serif')) return null;
    const candidates = [
      '/system/fonts/NotoSerifCJK-Regular.ttc',
      '/system/fonts/SysSerifCJK-Regular.ttf',
    ];
    for (final path in candidates) {
      if (!await File(path).exists()) continue;
      try {
        final bytes = await File(path).readAsBytes();
        final loader = FontLoader(kCjkFallbackFamily)
          ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
        await loader.load();
        return const [kCjkFallbackFamily];
      } catch (error) {
        // A broken CJK font must not stop the family from being applied.
        debugPrint('cjk fallback failed: $error');
      }
    }
    return null;
  }

  Future<void> selectSystemFamily(String family) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kindKey, 'system');
    await prefs.setString(_familyKey, family);
    await prefs.remove(_pathKey);
    await prefs.remove(_labelKey);
    final fallback = await _registerCjkFallback(family);
    if (!ref.mounted) return;
    state = SystemFontChoice(family, fallback);
  }

  /// Lets the user pick a font file. Returns false when nothing was picked or
  /// the file could not be registered.
  Future<bool> pickFile() async {
    final stored = await _pickFontFile('custom_font');
    if (stored == null) return false;
    if (!await _registerFont(stored.path, kCustomFontFamily)) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kindKey, 'file');
    await prefs.setString(_pathKey, stored.path);
    await prefs.setString(_labelKey, stored.label);
    await prefs.remove(_familyKey);
    if (!ref.mounted) return false;
    state = PickedFontChoice(path: stored.path, name: stored.label);
    return true;
  }

  /// Falls back to the platform font.
  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kindKey);
    await prefs.remove(_familyKey);
    await prefs.remove(_pathKey);
    await prefs.remove(_labelKey);
    if (!ref.mounted) return;
    state = null;
  }

  Future<bool> _register(String path) => _registerFont(path, kCustomFontFamily);
}

class FallbackFont extends Notifier<FallbackChoice?> {
  @override
  FallbackChoice? build() {
    unawaited(_restore());
    return null;
  }

  Future<void> _restore() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final family = prefs.getString(_fallbackFamilyKey);
      if (family != null) {
        if (!ref.mounted) return;
        state = FamilyFallback(family);
        return;
      }
      final path = prefs.getString(_fallbackPathKey);
      final label = prefs.getString(_fallbackLabelKey);
      if (path == null || label == null) return;
      if (!await _registerFont(path, kFallbackFontFamily)) return;
      if (!ref.mounted) return;
      state = FileFallback(path: path, name: label);
    } catch (error) {
      debugPrint('restore fallback font failed: $error');
    }
  }

  Future<void> selectFamily(String family) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fallbackFamilyKey, family);
    await prefs.remove(_fallbackPathKey);
    await prefs.remove(_fallbackLabelKey);
    if (!ref.mounted) return;
    state = FamilyFallback(family);
  }

  Future<bool> pickFile() async {
    final stored = await _pickFontFile('fallback_font');
    if (stored == null) return false;
    if (!await _registerFont(stored.path, kFallbackFontFamily)) return false;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fallbackPathKey, stored.path);
    await prefs.setString(_fallbackLabelKey, stored.label);
    await prefs.remove(_fallbackFamilyKey);
    if (!ref.mounted) return false;
    state = FileFallback(path: stored.path, name: stored.label);
    return true;
  }

  Future<void> reset() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fallbackPathKey);
    await prefs.remove(_fallbackLabelKey);
    await prefs.remove(_fallbackFamilyKey);
    if (!ref.mounted) return;
    state = null;
  }
}

/// Registers [path] under [family]; false when the file cannot be loaded.
Future<bool> _registerFont(String path, String family) async {
  try {
    final bytes = await File(path).readAsBytes();
    if (bytes.isEmpty) return false;
    final loader = FontLoader(family)
      ..addFont(Future<ByteData>.value(ByteData.sublistView(bytes)));
    await loader.load();
    return true;
  } catch (error) {
    debugPrint('register font failed: $error');
    return false;
  }
}

/// Asks for a font file and copies it next to the app's own data.
Future<({String path, String label})?> _pickFontFile(String basename) async {
  final file = await openFile(
    acceptedTypeGroups: const [
      XTypeGroup(
        label: '字体',
        extensions: ['ttf', 'otf'],
        mimeTypes: ['font/ttf', 'font/otf', 'application/x-font-ttf'],
      ),
    ],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final dir = await getApplicationSupportDirectory();
  final target = File('${dir.path}/$basename${_extension(file.name)}');
  await target.writeAsBytes(bytes, flush: true);
  return (path: target.path, label: file.name);
}

String _extension(String name) {
  final index = name.lastIndexOf('.');
  return index < 0 ? '' : name.substring(index);
}

final appFontProvider = NotifierProvider<AppFont, FontChoice?>(AppFont.new);

/// Family names the platform declares, for the font picker.
final systemFontFamiliesProvider = FutureProvider<List<String>>(
  (ref) => loadSystemFontFamilies(),
);

final fallbackFontProvider = NotifierProvider<FallbackFont, FallbackChoice?>(
  FallbackFont.new,
);

/// Families tried before the platform fallback: the user's own fallback first,
/// then whatever the chosen system family brings along (a CJK serif).
final appFontFallbackProvider = Provider<List<String>?>((ref) {
  final choice = ref.watch(appFontProvider);
  final custom = ref.watch(fallbackFontProvider);
  final families = <String>[
    if (custom case FileFallback()) kFallbackFontFamily,
    if (custom case FamilyFallback(:final family)) family,
    if (choice is SystemFontChoice) ...?choice.fallback,
  ];
  return families.isEmpty ? null : families;
});

/// Family the app renders with: a chosen family wins, otherwise Android uses
/// the platform generic family (which follows the system font).
final appFontFamilyProvider = Provider<String?>((ref) {
  switch (ref.watch(appFontProvider)) {
    case PickedFontChoice():
      return kCustomFontFamily;
    case SystemFontChoice(:final family):
      return family;
    case null:
      if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
        return null;
      }
      return 'sans-serif';
  }
});
