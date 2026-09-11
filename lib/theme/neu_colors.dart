import 'package:flutter/material.dart';

/// 全局兜底变体:从 cmap 排除了 #/*/0-9,防止普通计数被空白占位字形接管。
/// emoji 的精确渲染由 theme/emoji.dart 的 run 拆分负责,这里只兜
/// 未经拆分的路径(输入框、toast 等)。
const kEmojiFallbackFontFamily = 'Twemoji Mozilla Fallback';
const kEmojiFontFallback = [kEmojiFallbackFontFamily];

/// 新拟物设计 tokens。所有页面统一从这里取色,保证明暗两套主题一致切换。
class NeuColors extends ThemeExtension<NeuColors> {
  const NeuColors({
    required this.base,
    required this.surface,
    required this.surfaceStrong,
    required this.shadowLight,
    required this.shadowDark,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.accent,
    required this.accentPressed,
    required this.onAccent,
    required this.accentSoft,
    required this.success,
    required this.warning,
    required this.error,
    required this.glassFill,
    required this.glassBorder,
    required this.hairline,
    required this.highlightAlpha,
    required this.card,
  });

  /// 页面基底(新拟物的"桌面")。
  final Color base;

  /// 凸起组件的填充基色(通常接近 base)。
  final Color surface;

  /// 需要与背景拉开层级时使用(卡片、弹层面板)。
  final Color surfaceStrong;

  /// 密集内容卡片的填充(会话/联系人/气泡等)——比 surface 更亮一档,
  /// 内容多的时候靠它和底色拉开对比,空阔页面不用它。
  final Color card;

  /// 高光阴影(左上,光源方向)。
  final Color shadowLight;

  /// 暗部阴影(右下)。
  final Color shadowDark;

  final Color text;
  final Color textSecondary;
  final Color textTertiary;

  /// 品牌主色(沿用 matter 的 #5B8DEF)。
  final Color accent;
  final Color accentPressed;
  final Color onAccent;

  /// 主色的低饱和铺色(选中态、徽标背景)。
  final Color accentSoft;

  final Color success;
  final Color warning;
  final Color error;

  /// 磨砂玻璃点缀:填充与高光描边。
  final Color glassFill;
  final Color glassBorder;

  /// 极细分隔线 / 描边。
  final Color hairline;

  /// 凸起受光面高光的整体不透明度。
  /// 深色下高光必须收敛,否则模糊开就是一圈辉光("散光感")。
  final double highlightAlpha;

  static const light = NeuColors(
    base: Color(0xFFE7EAF0),
    surface: Color(0xFFE9EDF3),
    surfaceStrong: Color(0xFFF0F3F8),
    shadowLight: Color(0xEFFFFFFF),
    shadowDark: Color(0xFF99A3BC),
    text: Color(0xFF2B3245),
    textSecondary: Color(0xFF55607A),
    textTertiary: Color(0xFF8B94AA),
    accent: Color(0xFF5B8DEF),
    accentPressed: Color(0xFF4A7BD9),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFFD6E1F9),
    success: Color(0xFF3DA56E),
    warning: Color(0xFFD9A13B),
    error: Color(0xFFE05656),
    glassFill: Color(0x99FFFFFF),
    glassBorder: Color(0xCFFFFFFF),
    hairline: Color(0x3355607A),
    highlightAlpha: 0.9,
    card: Color(0xFFF5F7FB),
  );

  static const dark = NeuColors(
    base: Color(0xFF222732),
    surface: Color(0xFF2A3040),
    surfaceStrong: Color(0xFF313949),
    shadowLight: Color(0xFF434D63),
    shadowDark: Color(0xFF101319),
    text: Color(0xFFECF0F7),
    textSecondary: Color(0xFFB1BACB),
    textTertiary: Color(0xFF767F92),
    accent: Color(0xFF6C9BF5),
    accentPressed: Color(0xFF5588E8),
    onAccent: Color(0xFFFFFFFF),
    accentSoft: Color(0xFF2F3C55),
    success: Color(0xFF4CBB83),
    warning: Color(0xFFE5B45A),
    error: Color(0xFFF07171),
    glassFill: Color(0x662E3543),
    glassBorder: Color(0x4DFFFFFF),
    hairline: Color(0x29FFFFFF),
    highlightAlpha: 0.32,
    card: Color(0xFF343D4E),
  );

  /// 以 [accent] 为基色派生一套主色 token(设置页主题色自定义用):
  /// 按压态向黑压深,soft 浅色向 card 淡化、深色向 base 收敛,
  /// 深色下基色再略微提亮,保证明暗两套观感都协调。
  NeuColors withAccent(Color accent) {
    final dark = base.computeLuminance() < 0.5;
    final a = dark ? Color.lerp(accent, Colors.white, .12)! : accent;
    return copyWith(
      accent: a,
      accentPressed: Color.lerp(a, Colors.black, dark ? .2 : .12),
      accentSoft: Color.lerp(a, dark ? base : card, .8),
    );
  }

  @override
  NeuColors copyWith({
    Color? accent,
    Color? accentPressed,
    Color? onAccent,
    Color? accentSoft,
  }) {
    return NeuColors(
      base: base,
      surface: surface,
      surfaceStrong: surfaceStrong,
      shadowLight: shadowLight,
      shadowDark: shadowDark,
      text: text,
      textSecondary: textSecondary,
      textTertiary: textTertiary,
      accent: accent ?? this.accent,
      accentPressed: accentPressed ?? this.accentPressed,
      onAccent: onAccent ?? this.onAccent,
      accentSoft: accentSoft ?? this.accentSoft,
      success: success,
      warning: warning,
      error: error,
      glassFill: glassFill,
      glassBorder: glassBorder,
      hairline: hairline,
      highlightAlpha: highlightAlpha,
      card: card,
    );
  }

  @override
  NeuColors lerp(ThemeExtension<NeuColors>? other, double t) =>
      t < 0.5 ? this : (other as NeuColors? ?? this);
}

/// 圆角档位(超椭圆应用这些半径,沿用 matter 的角标体系)。
class NeuRadius {
  static const double tag = 10; // 角标、小图标底
  static const double button = 14; // 按钮、小控件
  static const double content = 18; // 头像、消息气泡、输入框
  static const double surface = 22; // 卡片、面板
  static const double nav = 28; // 导航、浮层大圆角
}

/// 间距档位:页面节奏统一从这里取,不再散落魔数。
/// 列表页统一节奏:标题行(20,12,16,8) → 搜索框(上 4) → 筛选条(上 12)
/// → 列表(上 8),卡片间距 12,窄屏底部为玻璃导航留 104。
class NeuSpacing {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;

  /// 窄屏列表底部为玻璃导航预留的高度。
  static const double navClearance = 104;
}

extension NeuColorsX on BuildContext {
  NeuColors get neu => Theme.of(this).extension<NeuColors>()!;
}

/// 提亮 / 压暗(用于新拟物凸起渐变)。
Color neuShift(Color color, double amount) {
  final hsl = HSLColor.fromColor(color);
  final lightness = (hsl.lightness + amount).clamp(0.0, 1.0);
  return hsl.withLightness(lightness).toColor();
}
