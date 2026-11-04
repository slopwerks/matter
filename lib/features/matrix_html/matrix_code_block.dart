import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:re_highlight/languages/bash.dart';
import 'package:re_highlight/languages/c.dart';
import 'package:re_highlight/languages/cmake.dart';
import 'package:re_highlight/languages/cpp.dart';
import 'package:re_highlight/languages/csharp.dart';
import 'package:re_highlight/languages/css.dart';
import 'package:re_highlight/languages/dart.dart';
import 'package:re_highlight/languages/diff.dart';
import 'package:re_highlight/languages/dockerfile.dart';
import 'package:re_highlight/languages/go.dart';
import 'package:re_highlight/languages/graphql.dart';
import 'package:re_highlight/languages/ini.dart';
import 'package:re_highlight/languages/java.dart';
import 'package:re_highlight/languages/javascript.dart';
import 'package:re_highlight/languages/json.dart';
import 'package:re_highlight/languages/kotlin.dart';
import 'package:re_highlight/languages/latex.dart';
import 'package:re_highlight/languages/less.dart';
import 'package:re_highlight/languages/lua.dart';
import 'package:re_highlight/languages/makefile.dart';
import 'package:re_highlight/languages/markdown.dart';
import 'package:re_highlight/languages/php.dart';
import 'package:re_highlight/languages/powershell.dart';
import 'package:re_highlight/languages/python.dart';
import 'package:re_highlight/languages/ruby.dart';
import 'package:re_highlight/languages/rust.dart';
import 'package:re_highlight/languages/scss.dart';
import 'package:re_highlight/languages/shell.dart';
import 'package:re_highlight/languages/sql.dart';
import 'package:re_highlight/languages/swift.dart';
import 'package:re_highlight/languages/typescript.dart';
import 'package:re_highlight/languages/xml.dart';
import 'package:re_highlight/languages/yaml.dart';
import 'package:re_highlight/re_highlight.dart';
import 'package:re_highlight/styles/atom-one-dark.dart';
import 'package:re_highlight/styles/atom-one-light.dart';
import 'package:re_highlight/styles/github-dark.dart';
import 'package:re_highlight/styles/github.dart';
import 'package:re_highlight/styles/googlecode.dart';
import 'package:re_highlight/styles/monokai.dart';
import 'package:re_highlight/styles/stackoverflow-light.dart';
import 'package:re_highlight/styles/tokyo-night-dark.dart';
import 'package:re_highlight/styles/vs.dart';
import 'package:re_highlight/styles/vs2015.dart';

import '../../providers/code_block_settings_provider.dart';
import 'matrix_html_node.dart';

class CodeHighlightThemeInfo {
  final String id;
  final String name;
  final bool isDark;
  final Color backgroundColor;
  final Color headerColor;
  final Color dividerColor;
  final Color defaultTextColor;
  final Map<String, TextStyle> themeMap;

  const CodeHighlightThemeInfo({
    required this.id,
    required this.name,
    required this.isDark,
    required this.backgroundColor,
    required this.headerColor,
    required this.dividerColor,
    required this.defaultTextColor,
    required this.themeMap,
  });
}

const darkCodeThemes = <String, CodeHighlightThemeInfo>{
  'atom-one-dark': CodeHighlightThemeInfo(
    id: 'atom-one-dark',
    name: 'Atom One Dark',
    isDark: true,
    backgroundColor: Color(0xFF1E2227),
    headerColor: Color(0xFF262B34),
    dividerColor: Color(0xFF2F3542),
    defaultTextColor: Color(0xFFABB2BF),
    themeMap: atomOneDarkTheme,
  ),
  'github-dark': CodeHighlightThemeInfo(
    id: 'github-dark',
    name: 'GitHub Dark',
    isDark: true,
    backgroundColor: Color(0xFF0D1117),
    headerColor: Color(0xFF161B22),
    dividerColor: Color(0xFF30363D),
    defaultTextColor: Color(0xFFC9D1D9),
    themeMap: githubDarkTheme,
  ),
  'vs2015': CodeHighlightThemeInfo(
    id: 'vs2015',
    name: 'VS Code',
    isDark: true,
    backgroundColor: Color(0xFF1E1E1E),
    headerColor: Color(0xFF252526),
    dividerColor: Color(0xFF333333),
    defaultTextColor: Color(0xFFD4D4D4),
    themeMap: vs2015Theme,
  ),
  'monokai': CodeHighlightThemeInfo(
    id: 'monokai',
    name: 'Monokai',
    isDark: true,
    backgroundColor: Color(0xFF272822),
    headerColor: Color(0xFF1E1F1C),
    dividerColor: Color(0xFF3E3D32),
    defaultTextColor: Color(0xFFF8F8F2),
    themeMap: monokaiTheme,
  ),
  'tokyo-night-dark': CodeHighlightThemeInfo(
    id: 'tokyo-night-dark',
    name: 'Tokyo Night',
    isDark: true,
    backgroundColor: Color(0xFF1A1B26),
    headerColor: Color(0xFF16161E),
    dividerColor: Color(0xFF292E42),
    defaultTextColor: Color(0xFFA9B1D6),
    themeMap: tokyoNightDarkTheme,
  ),
};

const lightCodeThemes = <String, CodeHighlightThemeInfo>{
  'atom-one-light': CodeHighlightThemeInfo(
    id: 'atom-one-light',
    name: 'Atom One Light',
    isDark: false,
    backgroundColor: Color(0xFFFAFAFA),
    headerColor: Color(0xFFF0F0F0),
    dividerColor: Color(0xFFE0E0E0),
    defaultTextColor: Color(0xFF383A42),
    themeMap: atomOneLightTheme,
  ),
  'github': CodeHighlightThemeInfo(
    id: 'github',
    name: 'GitHub Light',
    isDark: false,
    backgroundColor: Color(0xFFF6F8FA),
    headerColor: Color(0xFFEAEEF2),
    dividerColor: Color(0xFFD0D7DE),
    defaultTextColor: Color(0xFF24292E),
    themeMap: githubTheme,
  ),
  'vs': CodeHighlightThemeInfo(
    id: 'vs',
    name: 'Visual Studio',
    isDark: false,
    backgroundColor: Color(0xFFFFFFFF),
    headerColor: Color(0xFFF3F3F3),
    dividerColor: Color(0xFFE5E5E5),
    defaultTextColor: Color(0xFF1E1E1E),
    themeMap: vsTheme,
  ),
  'stackoverflow-light': CodeHighlightThemeInfo(
    id: 'stackoverflow-light',
    name: 'Stack Overflow',
    isDark: false,
    backgroundColor: Color(0xFFF6F6F6),
    headerColor: Color(0xFFEBEBEB),
    dividerColor: Color(0xFFD6D9DC),
    defaultTextColor: Color(0xFF2F3337),
    themeMap: stackoverflowLightTheme,
  ),
  'googlecode': CodeHighlightThemeInfo(
    id: 'googlecode',
    name: 'Google Code',
    isDark: false,
    backgroundColor: Color(0xFFFFFFFF),
    headerColor: Color(0xFFF1F3F4),
    dividerColor: Color(0xFFDADCE0),
    defaultTextColor: Color(0xFF1E1E1E),
    themeMap: googlecodeTheme,
  ),
};

const codeLanguageAliases = <String, String>{
  'js': 'javascript',
  'jsx': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'ts': 'typescript',
  'tsx': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'py': 'python',
  'py3': 'python',
  'rb': 'ruby',
  'sh': 'bash',
  'zsh': 'bash',
  'c++': 'cpp',
  'cc': 'cpp',
  'cxx': 'cpp',
  'h': 'c',
  'hpp': 'cpp',
  'hxx': 'cpp',
  'cs': 'csharp',
  'c#': 'csharp',
  'dotnet': 'csharp',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'rs': 'rust',
  'golang': 'go',
  'yml': 'yaml',
  'html': 'xml',
  'htm': 'xml',
  'xhtml': 'xml',
  'svg': 'xml',
  'md': 'markdown',
  'docker': 'dockerfile',
  'gql': 'graphql',
  'ps': 'powershell',
  'ps1': 'powershell',
  'posh': 'powershell',
  'tex': 'latex',
  'make': 'makefile',
  'env': 'ini',
  'conf': 'ini',
  'properties': 'ini',
};

final codeLanguages = <String, Mode>{
  'bash': langBash,
  'c': langC,
  'cmake': langCmake,
  'cpp': langCpp,
  'csharp': langCsharp,
  'css': langCss,
  'dart': langDart,
  'diff': langDiff,
  'dockerfile': langDockerfile,
  'go': langGo,
  'graphql': langGraphql,
  'ini': langIni,
  'java': langJava,
  'javascript': langJavascript,
  'json': langJson,
  'kotlin': langKotlin,
  'latex': langLatex,
  'less': langLess,
  'lua': langLua,
  'makefile': langMakefile,
  'markdown': langMarkdown,
  'php': langPhp,
  'powershell': langPowershell,
  'python': langPython,
  'ruby': langRuby,
  'rust': langRust,
  'scss': langScss,
  'shell': langShell,
  'sql': langSql,
  'swift': langSwift,
  'typescript': langTypescript,
  'xml': langXml,
  'yaml': langYaml,
};

Highlight? _codeHighlighter;
final _highlightCache = <String, TextSpan>{};

/// Formats a language tag into a human-readable display label for code block headers.
String formatCodeLanguage(String? raw) {
  if (raw == null || raw.trim().isEmpty) {
    return 'Code';
  }
  final clean = raw.trim().toLowerCase();
  const displayNames = <String, String>{
    'dart': 'Dart',
    'python': 'Python',
    'py': 'Python',
    'javascript': 'JavaScript',
    'js': 'JavaScript',
    'mjs': 'JavaScript',
    'cjs': 'JavaScript',
    'typescript': 'TypeScript',
    'ts': 'TypeScript',
    'jsx': 'JSX',
    'tsx': 'TSX',
    'rust': 'Rust',
    'rs': 'Rust',
    'go': 'Go',
    'golang': 'Go',
    'c': 'C',
    'cpp': 'C++',
    'c++': 'C++',
    'csharp': 'C#',
    'cs': 'C#',
    'c#': 'C#',
    'java': 'Java',
    'kotlin': 'Kotlin',
    'kt': 'Kotlin',
    'swift': 'Swift',
    'php': 'PHP',
    'ruby': 'Ruby',
    'rb': 'Ruby',
    'bash': 'Bash',
    'sh': 'Shell',
    'shell': 'Shell',
    'zsh': 'Zsh',
    'sql': 'SQL',
    'html': 'HTML',
    'xml': 'XML',
    'json': 'JSON',
    'yaml': 'YAML',
    'yml': 'YAML',
    'css': 'CSS',
    'scss': 'SCSS',
    'less': 'Less',
    'markdown': 'Markdown',
    'md': 'Markdown',
    'diff': 'Diff',
    'lua': 'Lua',
    'dockerfile': 'Dockerfile',
    'docker': 'Dockerfile',
    'graphql': 'GraphQL',
    'gql': 'GraphQL',
    'powershell': 'PowerShell',
    'ps1': 'PowerShell',
    'latex': 'LaTeX',
    'tex': 'LaTeX',
    'makefile': 'Makefile',
    'make': 'Makefile',
    'cmake': 'CMake',
    'ini': 'INI',
  };
  return displayNames[clean] ?? clean;
}

/// Extracts language from pre/code element attributes.
String? extractCodeLanguage(MatrixElementNode pre) {
  for (final child in pre.children) {
    if (child is MatrixElementNode && child.tag == 'code') {
      final className = child.attributes['class'];
      if (className != null) {
        final match = RegExp(
          r'(?:^|\s)(?:language|lang)-([A-Za-z0-9_+-]{1,32})(?:\s|$)',
        ).firstMatch(className);
        if (match != null) return match.group(1);
      }
      final dataLang =
          child.attributes['data-language'] ?? child.attributes['data-lang'];
      if (dataLang != null && dataLang.trim().isNotEmpty) {
        return dataLang.trim();
      }
    }
  }
  return null;
}

/// Highlighted [code] as a span tree, or a plain span when the language is
/// unknown or highlighting fails.
TextSpan highlightedCodeSpan({
  required String code,
  required String? language,
  required TextStyle base,
  required Map<String, TextStyle> themeMap,
  bool isDark = true,
}) {
  if (language == null) return TextSpan(text: code, style: base);
  final normalized =
      codeLanguageAliases[language.toLowerCase()] ?? language.toLowerCase();
  if (!codeLanguages.containsKey(normalized)) {
    return TextSpan(text: code, style: base);
  }
  final themeKey = isDark
      ? 'dark_${themeMap.hashCode}'
      : 'light_${themeMap.hashCode}';
  final cacheKey =
      '$normalized\u0000${base.color?.toARGB32()}\u0000$themeKey\u0000$code';
  final cached = _highlightCache[cacheKey];
  if (cached != null) return cached;
  var span = TextSpan(text: code, style: base);
  try {
    final highlighter = _codeHighlighter ??= Highlight()
      ..registerLanguages(codeLanguages);
    final result = highlighter.highlight(code: code, language: normalized);
    final theme = <String, TextStyle>{
      for (final entry in themeMap.entries)
        entry.key: entry.key == 'root'
            ? base.merge(entry.value.copyWith(backgroundColor: null))
            : (entry.key == 'comment' || entry.key == 'quote')
            ? base.merge(
                entry.value.copyWith(
                  color: isDark
                      ? const Color(0xFF9DA5B4)
                      : const Color(0xFF6E7781),
                ),
              )
            : base.merge(entry.value),
    };
    final renderer = TextSpanRenderer(base, theme);
    result.render(renderer);
    span = renderer.span ?? span;
  } catch (_) {
    // Unknown or unparseable code: fall back to unhighlighted text.
  }
  if (_highlightCache.length > 200) _highlightCache.clear();
  _highlightCache[cacheKey] = span;
  return span;
}

/// A modern, fully-featured code block widget displaying:
/// - A header bar with a language badge and an instant copy button with visual feedback.
/// - Adaptive theme coloring with user-configurable dark/light theme and opacity.
/// - Horizontal scrolling with [Scrollbar] for desktop/mobile accessibility.
class MatrixCodeBlock extends ConsumerStatefulWidget {
  final String code;
  final String? language;
  final double width;
  final TextStyle baseStyle;
  final Color accentColor;
  final CodeBlockSettings? settingsOverride;

  const MatrixCodeBlock({
    super.key,
    required this.code,
    this.language,
    required this.width,
    required this.baseStyle,
    required this.accentColor,
    this.settingsOverride,
  });

  @override
  ConsumerState<MatrixCodeBlock> createState() => _MatrixCodeBlockState();
}

class _MatrixCodeBlockState extends ConsumerState<MatrixCodeBlock> {
  final ScrollController _scrollController = ScrollController();
  bool _copied = false;
  Timer? _copyTimer;

  @override
  void dispose() {
    _copyTimer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _handleCopy() async {
    await Clipboard.setData(ClipboardData(text: widget.code));
    if (!mounted) return;
    try {
      HapticFeedback.lightImpact();
    } catch (_) {}
    _copyTimer?.cancel();
    setState(() => _copied = true);
    _copyTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    CodeBlockSettings settings = const CodeBlockSettings();
    if (widget.settingsOverride != null) {
      settings = widget.settingsOverride!;
    } else {
      try {
        settings = ref.watch(codeBlockSettingsProvider);
      } catch (_) {
        // Fallback when built outside ProviderScope in standalone widget tests
      }
    }

    final isDark =
        (widget.baseStyle.color != null &&
            ThemeData.estimateBrightnessForColor(widget.baseStyle.color!) ==
                Brightness.light) ||
        Theme.of(context).brightness == Brightness.dark;

    final themeInfo = isDark
        ? (darkCodeThemes[settings.darkTheme] ??
              darkCodeThemes['atom-one-dark']!)
        : (lightCodeThemes[settings.lightTheme] ??
              lightCodeThemes['atom-one-light']!);

    final opacity = settings.opacity.clamp(0.1, 1.0);
    final blockBg = themeInfo.backgroundColor.withValues(alpha: opacity);
    final headerBg = themeInfo.headerColor.withValues(alpha: opacity);
    final dividerColor = themeInfo.dividerColor.withValues(alpha: opacity);
    final headerFg = isDark ? const Color(0xFFABB2BF) : const Color(0xFF57606A);
    final codeDefaultColor = isDark
        ? const Color(0xFFE5E9F0)
        : themeInfo.defaultTextColor;

    final codeStyle = widget.baseStyle.copyWith(
      fontFamily: 'monospace',
      fontSize: widget.baseStyle.fontSize == null
          ? 13
          : widget.baseStyle.fontSize! - 1,
      color: codeDefaultColor,
      height: 1.45,
    );

    final languageLabel = formatCodeLanguage(widget.language);
    final codeSpan = highlightedCodeSpan(
      code: widget.code,
      language: widget.language,
      base: codeStyle,
      themeMap: themeInfo.themeMap,
      isDark: isDark,
    );

    final lines = widget.code.split('\n');
    final showLineNumbers = settings.showLineNumbers && lines.length > 1;

    Widget codeContent = Text.rich(codeSpan, softWrap: false);
    if (showLineNumbers) {
      final lineNumbersText = List.generate(
        lines.length,
        (i) => '${i + 1}',
      ).join('\n');
      final lineNumbersStyle = codeStyle.copyWith(
        color: isDark ? const Color(0xFF5C6370) : const Color(0xFF8C959F),
      );
      codeContent = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            lineNumbersText,
            style: lineNumbersStyle,
            textAlign: TextAlign.right,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: SingleChildScrollView(
              controller: _scrollController,
              scrollDirection: Axis.horizontal,
              child: Text.rich(codeSpan, softWrap: false),
            ),
          ),
        ],
      );
    } else {
      codeContent = SingleChildScrollView(
        controller: _scrollController,
        scrollDirection: Axis.horizontal,
        child: Text.rich(codeSpan, softWrap: false),
      );
    }

    return Container(
      width: widget.width,
      decoration: BoxDecoration(
        color: blockBg,
        borderRadius: BorderRadius.circular(8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header Bar with Language label and Copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            color: headerBg,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.code_rounded, size: 14, color: headerFg),
                    const SizedBox(width: 6),
                    Text(
                      languageLabel,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: headerFg,
                        letterSpacing: 0.3,
                      ),
                    ),
                  ],
                ),
                Tooltip(
                  message: _copied ? '已复制' : '复制代码',
                  child: InkWell(
                    key: const ValueKey('code-block-copy-button'),
                    onTap: _handleCopy,
                    borderRadius: BorderRadius.circular(4),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 3,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          AnimatedSwitcher(
                            duration: const Duration(milliseconds: 200),
                            transitionBuilder: (child, animation) =>
                                ScaleTransition(scale: animation, child: child),
                            child: _copied
                                ? const Icon(
                                    Icons.check_rounded,
                                    key: ValueKey('copied-icon'),
                                    size: 14,
                                    color: Color(0xFF4CAF50),
                                  )
                                : Icon(
                                    Icons.copy_rounded,
                                    key: const ValueKey('copy-icon'),
                                    size: 14,
                                    color: headerFg,
                                  ),
                          ),
                          const SizedBox(width: 4),
                          Text(
                            _copied ? '已复制' : '复制',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: _copied
                                  ? const Color(0xFF4CAF50)
                                  : headerFg,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: dividerColor),
          // Code Area with Horizontal Scrollbar
          Container(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
            child: Scrollbar(controller: _scrollController, child: codeContent),
          ),
        ],
      ),
    );
  }
}
