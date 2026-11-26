import 'dart:async';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../features/fonts/system_font_catalog.dart';
import '../theme/system_font.dart';

/// Family the picked UI font file is registered under.
const String kCustomFontFamily = 'MatterCustomFont';

/// Family the picked chat-body font file is registered under.
const String kChatFontFamily = 'MatterChatFont';

/// Family the picked monospace font file is registered under.
const String kMonospaceFontFamily = 'MatterMonospaceFont';

/// Family the platform CJK serif fallback is registered under.
const String kCjkFallbackFamily = 'MatterCjkFallback';

/// Family the user picked as a fallback for glyphs the main font lacks.
const String kFallbackFontFamily = 'MatterFallbackFont';

const String _kindKey = 'app_font_kind';
const String _familyKey = 'app_font_family';
const String _pathKey = 'app_font_path';
const String _labelKey = 'app_font_label';

const String _chatKindKey = 'chat_font_kind';
const String _chatFamilyKey = 'chat_font_family';
const String _chatPathKey = 'chat_font_path';
const String _chatLabelKey = 'chat_font_label';

const String _monoKindKey = 'mono_font_kind';
const String _monoFamilyKey = 'mono_font_family';
const String _monoPathKey = 'mono_font_path';
const String _monoLabelKey = 'mono_font_label';

const String _fallbackPathKey = 'app_font_fallback_path';
const String _fallbackLabelKey = 'app_font_fallback_label';
const String _fallbackFamilyKey = 'app_font_fallback_family';

const String _uiScaleKey = 'ui_font_scale';
const String _chatScaleKey = 'chat_font_scale';
const String _monoScaleKey = 'mono_font_scale';

const double kMinUiFontScale = 0.85;
const double kMaxUiFontScale = 1.30;
const double kMinContentFontScale = 0.85;
const double kMaxContentFontScale = 1.40;

const _customFontExtensions = ['.ttf', '.otf', '.ttc'];

/// Which font a typography role renders with.
sealed class FontChoice {
  const FontChoice();
}

/// Explicitly follow the platform default font (e.g. opt chat body out of a
/// custom UI font, or use platform `monospace` instead of the bundled font).
class PlatformDefaultFontChoice extends FontChoice {
  const PlatformDefaultFontChoice();
}

/// A font bundled inside the app assets (e.g. `Ioskeley Mono`).
class BundledFontChoice extends FontChoice {
  const BundledFontChoice({required this.family, required this.name});

  final String family;
  final String name;
}

/// A family the platform already knows, e.g. serif or sans-serif-condensed.
class SystemFontChoice extends FontChoice {
  const SystemFontChoice(this.family, [this.fallback]);

  final String family;

  /// Families tried before the platform fallback, e.g. a CJK serif.
  final List<String>? fallback;
}

/// A font file the user picked, registered under the slot's runtime family.
class PickedFontChoice extends FontChoice {
  const PickedFontChoice({required this.path, required this.name});

  final String path;
  final String name;
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

@immutable
class FontScaleSettings {
  const FontScaleSettings({
    this.uiScale = 1.0,
    this.chatScale = 1.0,
    this.monoScale = 1.0,
  });

  final double uiScale;
  final double chatScale;
  final double monoScale;

  bool get isDefault =>
      (uiScale - 1.0).abs() < 0.001 &&
      (chatScale - 1.0).abs() < 0.001 &&
      (monoScale - 1.0).abs() < 0.001;

  FontScaleSettings copyWith({
    double? uiScale,
    double? chatScale,
    double? monoScale,
  }) => FontScaleSettings(
    uiScale: (uiScale ?? this.uiScale).clamp(kMinUiFontScale, kMaxUiFontScale),
    chatScale: (chatScale ?? this.chatScale).clamp(
      kMinContentFontScale,
      kMaxContentFontScale,
    ),
    monoScale: (monoScale ?? this.monoScale).clamp(
      kMinContentFontScale,
      kMaxContentFontScale,
    ),
  );

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is FontScaleSettings &&
        other.uiScale == uiScale &&
        other.chatScale == chatScale &&
        other.monoScale == monoScale;
  }

  @override
  int get hashCode => Object.hash(uiScale, chatScale, monoScale);
}

class _FontSlotConfig {
  const _FontSlotConfig({
    required this.kindKey,
    required this.familyKey,
    required this.pathKey,
    required this.labelKey,
    required this.runtimeFamily,
    required this.fileBasename,
    this.defaultChoice,
    this.bundledFamily,
    this.bundledName,
  });

  final String kindKey;
  final String familyKey;
  final String pathKey;
  final String labelKey;
  final String runtimeFamily;
  final String fileBasename;
  final FontChoice? defaultChoice;
  final String? bundledFamily;
  final String? bundledName;
}

abstract class _FontChoiceNotifier extends Notifier<FontChoice?> {
  _FontSlotConfig get _config;

  int _epoch = 0;

  @override
  FontChoice? build() {
    unawaited(_restore());
    return _config.defaultChoice;
  }

  Future<void> _restore() async {
    final restoreEpoch = _epoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _epoch != restoreEpoch) return;
      final kind = prefs.getString(_config.kindKey);
      switch (kind) {
        case 'bundled':
          if (_config.bundledFamily != null && _config.bundledName != null) {
            state = BundledFontChoice(
              family: _config.bundledFamily!,
              name: _config.bundledName!,
            );
          }
        case 'system_default':
          state = const PlatformDefaultFontChoice();
        case 'system':
          final family = prefs.getString(_config.familyKey);
          if (family == null) return;
          final fallback = await _registerCjkFallback(family);
          if (!ref.mounted || _epoch != restoreEpoch) return;
          state = SystemFontChoice(family, fallback);
        case 'file':
          final path = prefs.getString(_config.pathKey);
          final label = prefs.getString(_config.labelKey);
          if (path == null || label == null) return;
          if (!await _registerFont(path, _config.runtimeFamily)) return;
          if (!ref.mounted || _epoch != restoreEpoch) return;
          state = PickedFontChoice(path: path, name: label);
      }
    } catch (error) {
      debugPrint('restore font (${_config.kindKey}) failed: $error');
    }
  }

  Future<void> selectBundled() async {
    if (_config.bundledFamily == null || _config.bundledName == null) return;
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_config.kindKey, 'bundled');
    await _clearNonKindKeys(prefs);
    await _cleanupFontFiles(_config.fileBasename);
    if (!ref.mounted) return;
    state = BundledFontChoice(
      family: _config.bundledFamily!,
      name: _config.bundledName!,
    );
  }

  Future<void> selectPlatformDefault() async {
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_config.kindKey, 'system_default');
    await _clearNonKindKeys(prefs);
    await _cleanupFontFiles(_config.fileBasename);
    if (!ref.mounted) return;
    state = const PlatformDefaultFontChoice();
  }

  Future<void> selectSystemFamily(String family) async {
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_config.kindKey, 'system');
    await prefs.setString(_config.familyKey, family);
    await prefs.remove(_config.pathKey);
    await prefs.remove(_config.labelKey);
    await _cleanupFontFiles(_config.fileBasename);
    final fallback = await _registerCjkFallback(family);
    if (!ref.mounted) return;
    state = SystemFontChoice(family, fallback);
  }

  /// Lets the user pick a font file. Returns false when nothing was picked or
  /// the file could not be registered.
  Future<bool> pickFile() async {
    final stored = await _pickFontFile(_config.fileBasename);
    if (stored == null) return false;
    if (!await _registerFont(stored.path, _config.runtimeFamily)) return false;
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_config.kindKey, 'file');
    await prefs.setString(_config.pathKey, stored.path);
    await prefs.setString(_config.labelKey, stored.label);
    await prefs.remove(_config.familyKey);
    if (!ref.mounted) return false;
    state = PickedFontChoice(path: stored.path, name: stored.label);
    return true;
  }

  Future<void> reset() async {
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_config.kindKey);
    await _clearNonKindKeys(prefs);
    await _cleanupFontFiles(_config.fileBasename);
    if (!ref.mounted) return;
    state = _config.defaultChoice;
  }

  Future<void> _clearNonKindKeys(SharedPreferences prefs) async {
    await prefs.remove(_config.familyKey);
    await prefs.remove(_config.pathKey);
    await prefs.remove(_config.labelKey);
  }
}

class AppFont extends _FontChoiceNotifier {
  @override
  _FontSlotConfig get _config => const _FontSlotConfig(
    kindKey: _kindKey,
    familyKey: _familyKey,
    pathKey: _pathKey,
    labelKey: _labelKey,
    runtimeFamily: kCustomFontFamily,
    fileBasename: 'custom_font',
  );
}

class ChatFont extends _FontChoiceNotifier {
  @override
  _FontSlotConfig get _config => const _FontSlotConfig(
    kindKey: _chatKindKey,
    familyKey: _chatFamilyKey,
    pathKey: _chatPathKey,
    labelKey: _chatLabelKey,
    runtimeFamily: kChatFontFamily,
    fileBasename: 'chat_font',
  );
}

class MonospaceFont extends _FontChoiceNotifier {
  @override
  _FontSlotConfig get _config => const _FontSlotConfig(
    kindKey: _monoKindKey,
    familyKey: _monoFamilyKey,
    pathKey: _monoPathKey,
    labelKey: _monoLabelKey,
    runtimeFamily: kMonospaceFontFamily,
    fileBasename: 'mono_font',
    defaultChoice: BundledFontChoice(
      family: kBundledMonospaceFamily,
      name: 'Ioskeley Mono',
    ),
    bundledFamily: kBundledMonospaceFamily,
    bundledName: 'Ioskeley Mono',
  );
}

class FallbackFont extends Notifier<FallbackChoice?> {
  int _epoch = 0;

  @override
  FallbackChoice? build() {
    unawaited(_restore());
    return null;
  }

  Future<void> _restore() async {
    final restoreEpoch = _epoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _epoch != restoreEpoch) return;
      final family = prefs.getString(_fallbackFamilyKey);
      if (family != null) {
        state = FamilyFallback(family);
        return;
      }
      final path = prefs.getString(_fallbackPathKey);
      final label = prefs.getString(_fallbackLabelKey);
      if (path == null || label == null) return;
      if (!await _registerFont(path, kFallbackFontFamily)) return;
      if (!ref.mounted || _epoch != restoreEpoch) return;
      state = FileFallback(path: path, name: label);
    } catch (error) {
      debugPrint('restore fallback font failed: $error');
    }
  }

  Future<void> selectFamily(String family) async {
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fallbackFamilyKey, family);
    await prefs.remove(_fallbackPathKey);
    await prefs.remove(_fallbackLabelKey);
    await _cleanupFontFiles('fallback_font');
    if (!ref.mounted) return;
    state = FamilyFallback(family);
  }

  Future<bool> pickFile() async {
    final stored = await _pickFontFile('fallback_font');
    if (stored == null) return false;
    if (!await _registerFont(stored.path, kFallbackFontFamily)) return false;
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fallbackPathKey, stored.path);
    await prefs.setString(_fallbackLabelKey, stored.label);
    await prefs.remove(_fallbackFamilyKey);
    if (!ref.mounted) return false;
    state = FileFallback(path: stored.path, name: stored.label);
    return true;
  }

  Future<void> reset() async {
    _epoch++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_fallbackPathKey);
    await prefs.remove(_fallbackLabelKey);
    await prefs.remove(_fallbackFamilyKey);
    await _cleanupFontFiles('fallback_font');
    if (!ref.mounted) return;
    state = null;
  }
}

class FontScaleSettingsNotifier extends Notifier<FontScaleSettings> {
  int _epoch = 0;

  @override
  FontScaleSettings build() {
    unawaited(_restore());
    return const FontScaleSettings();
  }

  Future<void> _restore() async {
    final restoreEpoch = _epoch;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!ref.mounted || _epoch != restoreEpoch) return;
      final ui = prefs.getDouble(_uiScaleKey) ?? 1.0;
      final chat = prefs.getDouble(_chatScaleKey) ?? 1.0;
      final mono = prefs.getDouble(_monoScaleKey) ?? 1.0;
      state = const FontScaleSettings().copyWith(
        uiScale: ui,
        chatScale: chat,
        monoScale: mono,
      );
    } catch (error) {
      debugPrint('restore font scales failed: $error');
    }
  }

  Future<void> setUiScale(double scale) => _update(
    (s) => s.copyWith(uiScale: scale),
    _uiScaleKey,
    scale.clamp(kMinUiFontScale, kMaxUiFontScale),
  );

  Future<void> setChatScale(double scale) => _update(
    (s) => s.copyWith(chatScale: scale),
    _chatScaleKey,
    scale.clamp(kMinContentFontScale, kMaxContentFontScale),
  );

  Future<void> setMonoScale(double scale) => _update(
    (s) => s.copyWith(monoScale: scale),
    _monoScaleKey,
    scale.clamp(kMinContentFontScale, kMaxContentFontScale),
  );

  Future<void> reset() async {
    _epoch++;
    state = const FontScaleSettings();
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_uiScaleKey);
    await prefs.remove(_chatScaleKey);
    await prefs.remove(_monoScaleKey);
  }

  Future<void> _update(
    FontScaleSettings Function(FontScaleSettings) transform,
    String key,
    double clamped,
  ) async {
    _epoch++;
    state = transform(state);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(key, clamped);
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
        extensions: ['ttf', 'otf', 'ttc'],
        mimeTypes: [
          'font/ttf',
          'font/otf',
          'font/collection',
          'application/x-font-ttf',
        ],
      ),
    ],
  );
  if (file == null) return null;
  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) return null;
  final dir = await getApplicationSupportDirectory();
  final target = File('${dir.path}/$basename${_extension(file.name)}');
  await _cleanupFontFiles(basename, keepPath: target.path);
  await target.writeAsBytes(bytes, flush: true);
  return (path: target.path, label: file.name);
}

Future<void> _cleanupFontFiles(String basename, {String? keepPath}) async {
  try {
    final dir = await getApplicationSupportDirectory();
    for (final ext in _customFontExtensions) {
      final candidate = File('${dir.path}/$basename$ext');
      if (keepPath != null && candidate.path == keepPath) continue;
      if (await candidate.exists()) {
        await candidate.delete();
      }
    }
  } catch (_) {}
}

String _extension(String name) {
  final index = name.lastIndexOf('.');
  return index < 0 ? '' : name.substring(index).toLowerCase();
}

String? _platformDefaultUiFamily() {
  if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
    return null;
  }
  return kSystemFontFamily;
}

List<String>? _mergeFallbacks(Iterable<String> primary) {
  final seen = <String>{};
  final merged = <String>[];
  void addAll(Iterable<String>? items) {
    if (items == null) return;
    for (final item in items) {
      if (item.isNotEmpty && seen.add(item)) merged.add(item);
    }
  }

  addAll(primary);
  return merged.isEmpty ? null : merged;
}

String? _resolveFamily(FontChoice? choice, String customFamily) =>
    switch (choice) {
      PickedFontChoice() => customFamily,
      BundledFontChoice(:final family) => family,
      SystemFontChoice(:final family) => family,
      PlatformDefaultFontChoice() || null => _platformDefaultUiFamily(),
    };

final appFontProvider = NotifierProvider<AppFont, FontChoice?>(AppFont.new);
final chatFontProvider = NotifierProvider<ChatFont, FontChoice?>(ChatFont.new);
final monospaceFontProvider = NotifierProvider<MonospaceFont, FontChoice?>(
  MonospaceFont.new,
);
final fallbackFontProvider = NotifierProvider<FallbackFont, FallbackChoice?>(
  FallbackFont.new,
);
final fontScaleSettingsProvider =
    NotifierProvider<FontScaleSettingsNotifier, FontScaleSettings>(
      FontScaleSettingsNotifier.new,
    );

/// Discovered platform font catalog (all families + monospace subset).
final systemFontCatalogProvider = FutureProvider<SystemFontCatalog>(
  (ref) => loadSystemFontCatalog(),
);

/// Family names the platform declares, for the font picker.
final systemFontFamiliesProvider = FutureProvider<List<String>>(
  (ref) async => (await ref.watch(systemFontCatalogProvider.future)).families,
);

/// Families tried before the platform fallback: the user's own fallback first,
/// then whatever the chosen system family brings along (a CJK serif).
final appFontFallbackProvider = Provider<List<String>?>((ref) {
  final choice = ref.watch(appFontProvider);
  final custom = ref.watch(fallbackFontProvider);
  return _mergeFallbacks([
    if (custom case FileFallback()) kFallbackFontFamily,
    if (custom case FamilyFallback(:final family)) family,
    if (choice is SystemFontChoice) ...?choice.fallback,
  ]);
});

/// Family the UI renders with: a chosen family wins, otherwise Android uses
/// the platform generic family (which follows the system font).
final appFontFamilyProvider = Provider<String?>(
  (ref) => _resolveFamily(ref.watch(appFontProvider), kCustomFontFamily),
);

/// Family chat message bodies render with; null chat choice follows UI font.
final chatFontFamilyProvider = Provider<String?>((ref) {
  final choice = ref.watch(chatFontProvider);
  if (choice == null) return ref.watch(appFontFamilyProvider);
  return _resolveFamily(choice, kChatFontFamily);
});

/// Fallback list for chat message bodies; null chat choice follows UI fallback.
final chatFontFallbackProvider = Provider<List<String>?>((ref) {
  final choice = ref.watch(chatFontProvider);
  if (choice == null) return ref.watch(appFontFallbackProvider);
  final custom = ref.watch(fallbackFontProvider);
  return _mergeFallbacks([
    if (custom case FileFallback()) kFallbackFontFamily,
    if (custom case FamilyFallback(:final family)) family,
    if (choice is SystemFontChoice) ...?choice.fallback,
  ]);
});

/// Family monospace text (code blocks, inline code, logs, recovery keys) uses.
final monospaceFontFamilyProvider = Provider<String>((ref) {
  switch (ref.watch(monospaceFontProvider)) {
    case BundledFontChoice(:final family):
      return family;
    case PickedFontChoice():
      return kMonospaceFontFamily;
    case SystemFontChoice(:final family):
      return family;
    case PlatformDefaultFontChoice() || null:
      return kSystemMonospaceFamily;
  }
});

/// Fallback chain for monospace text: user fallback, then chat/UI font so CJK
/// comments in code use the user's chosen text font.
final monospaceFontFallbackProvider = Provider<List<String>?>((ref) {
  final custom = ref.watch(fallbackFontProvider);
  final chatFamily = ref.watch(chatFontFamilyProvider);
  final chatFallback = ref.watch(chatFontFallbackProvider);
  final seen = <String>{};
  final merged = <String>[];
  void add(String? family) {
    if (family != null && family.isNotEmpty && seen.add(family)) {
      merged.add(family);
    }
  }

  if (custom case FileFallback()) add(kFallbackFontFamily);
  if (custom case FamilyFallback(:final family)) add(family);
  add(chatFamily);
  if (chatFallback != null) {
    for (final f in chatFallback) {
      add(f);
    }
  }
  return merged.isEmpty ? null : merged;
});
