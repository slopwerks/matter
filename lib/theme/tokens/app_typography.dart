import 'dart:ui' show lerpDouble;

import 'package:material_ui/material_ui.dart';

import 'app_design_tokens.dart';

/// 语义字阶槽位。字号字重由各皮肤的主题构建器决定，页面只按语义取槽，
/// 不再各自 copyWith 数字。
///
/// 三个基础槽位是跨皮肤契约（见 docs/ui-conventions.md）：
/// - [pageTitle] 页面标题（Material 24/w600，Neu 24/w700）；
/// - [listTitle] 列表行标题（未读时组件自行加粗）；
/// - [sectionTitle] 设置页分区标题；
/// - [chatBody] 聊天消息正文（支持独立字体、回退与缩放）；
/// - [monospace] 等宽代码/日志/密钥槽位（支持独立字体、回退与缩放）。
class AppTypography {
  const AppTypography({
    required this.pageTitle,
    required this.listTitle,
    required this.sectionTitle,
    this.chatBody = const TextStyle(fontSize: 15, height: 1.45),
    this.monospace = const TextStyle(fontFamily: 'monospace'),
    this.chatScale = 1.0,
    this.monoScale = 1.0,
  });

  final TextStyle pageTitle;
  final TextStyle listTitle;
  final TextStyle sectionTitle;
  final TextStyle chatBody;
  final TextStyle monospace;
  final double chatScale;
  final double monoScale;

  AppTypography copyWith({
    TextStyle? pageTitle,
    TextStyle? listTitle,
    TextStyle? sectionTitle,
    TextStyle? chatBody,
    TextStyle? monospace,
    double? chatScale,
    double? monoScale,
  }) => AppTypography(
    pageTitle: pageTitle ?? this.pageTitle,
    listTitle: listTitle ?? this.listTitle,
    sectionTitle: sectionTitle ?? this.sectionTitle,
    chatBody: chatBody ?? this.chatBody,
    monospace: monospace ?? this.monospace,
    chatScale: chatScale ?? this.chatScale,
    monoScale: monoScale ?? this.monoScale,
  );

  /// Applies the active monospace family, fallback and scale onto [base].
  TextStyle resolveMonospace(
    TextStyle? base, {
    double? baseFontSize,
    double? sourceScale,
    Color? color,
    double? height,
    FontWeight? fontWeight,
    Color? backgroundColor,
  }) {
    final effectiveBase = baseFontSize ?? base?.fontSize;
    final unscaled = effectiveBase == null
        ? null
        : (sourceScale != null && sourceScale > 0
              ? effectiveBase / sourceScale
              : effectiveBase);
    final scaledSize = unscaled == null ? null : unscaled * monoScale;
    return (base ?? const TextStyle()).copyWith(
      fontFamily: monospace.fontFamily ?? 'monospace',
      fontFamilyFallback: monospace.fontFamilyFallback,
      fontSize: scaledSize,
      color: color,
      height: height,
      fontWeight: fontWeight,
      backgroundColor: backgroundColor,
    );
  }

  /// Resolves a monospace style safely even in standalone widget tests that do
  /// not mount `AppDesignTokens`.
  static TextStyle monospaceOf(
    BuildContext context, {
    TextStyle? base,
    double? baseFontSize,
    double? sourceScale,
    Color? color,
    double? height,
    FontWeight? fontWeight,
    Color? backgroundColor,
  }) {
    final typography = maybeOf(context);
    if (typography != null) {
      return typography.resolveMonospace(
        base,
        baseFontSize: baseFontSize,
        sourceScale: sourceScale,
        color: color,
        height: height,
        fontWeight: fontWeight,
        backgroundColor: backgroundColor,
      );
    }
    return (base ?? const TextStyle()).copyWith(
      fontFamily: 'monospace',
      fontSize: baseFontSize ?? base?.fontSize,
      color: color,
      height: height,
      fontWeight: fontWeight,
      backgroundColor: backgroundColor,
    );
  }

  static AppTypography? maybeOf(BuildContext context) =>
      Theme.of(context).extension<AppDesignTokens>()?.typography;

  static AppTypography lerp(AppTypography a, AppTypography b, double t) =>
      AppTypography(
        pageTitle: TextStyle.lerp(a.pageTitle, b.pageTitle, t)!,
        listTitle: TextStyle.lerp(a.listTitle, b.listTitle, t)!,
        sectionTitle: TextStyle.lerp(a.sectionTitle, b.sectionTitle, t)!,
        chatBody: TextStyle.lerp(a.chatBody, b.chatBody, t)!,
        monospace: TextStyle.lerp(a.monospace, b.monospace, t)!,
        chatScale: lerpDouble(a.chatScale, b.chatScale, t) ?? a.chatScale,
        monoScale: lerpDouble(a.monoScale, b.monoScale, t) ?? a.monoScale,
      );
}
