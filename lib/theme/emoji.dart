import 'package:flutter/material.dart';

/// pubspec 内置的 COLR 彩色 emoji 字体(完整变体,含键帽基字符)。
/// 不要在调用点直接使用它;统一走 [emojiSpans] / [EmojiText] 拆分,
/// 只有 emoji run 会挂上这个字体,普通文本永远不经过它。
const kEmojiFontFamily = 'Twemoji Mozilla';

const _zwj = 0x200D;
const _vs16 = 0xFE0F;
const _keycap = 0x20E3;

/// 能单独构成 emoji 的核心字符(含区域指示符、标签符)。
bool _isCore(int r) =>
    (r >= 0x1F000 && r <= 0x1FAFF) || // 主 emoji 区段(含手势/肤色基字)
    (r >= 0x2600 && r <= 0x27BF) || // 杂项符号与装饰
    (r >= 0x2300 && r <= 0x23FF) || // ⌚⏰ 等
    (r >= 0x2194 && r <= 0x21AA) || // ↔️↩️ 等
    (r >= 0x2B00 && r <= 0x2BFF) || // ⭐⭕ 等
    (r >= 0x25A0 && r <= 0x25FF) || // ◾◻️ 等
    (r >= 0x1F1E6 && r <= 0x1F1FF) || // 区域指示符(国旗)
    (r >= 0xE0020 && r <= 0xE007F) || // 标签符(英格兰旗等)
    const {
      0x00A9,
      0x00AE,
      0x203C,
      0x2049,
      0x2122,
      0x2139,
      0x24C2,
      0x2934,
      0x2935,
      0x25FE,
      0x3030,
      0x303D,
      0x3297,
      0x3299,
    }.contains(r);

bool _isKeycapBase(int r) => r == 0x23 || r == 0x2A || (r >= 0x30 && r <= 0x39);

bool _isSkinTone(int r) => r >= 0x1F3FB && r <= 0x1F3FF;

/// [index] 处是否开始键帽组合(VS16 可省略)。
bool _keycapAt(List<int> runes, int index) {
  if (index >= runes.length) return false;
  if (runes[index] == _keycap) return true;
  return runes[index] == _vs16 &&
      index + 1 < runes.length &&
      runes[index + 1] == _keycap;
}

/// 把 [text] 拆成 emoji run 与普通 run:emoji run 挂 [kEmojiFontFamily],
/// 其余保持 [base] 原样。混排文本与纯 emoji 文本走同一条规则。
///
/// 覆盖键帽(`1️⃣`,裸数字不受影响)、国旗、肤色修饰与 ZWJ 家族序列;
/// 未识别的字符会落入普通 run,由全局 fallback 兜底。
List<TextSpan> emojiSpans(String text, [TextStyle? base]) {
  final runes = text.runes.toList();
  final spans = <TextSpan>[];
  final plain = StringBuffer();
  final emoji = StringBuffer();

  void flushPlain() {
    if (plain.isNotEmpty) {
      spans.add(TextSpan(text: plain.toString(), style: base));
      plain.clear();
    }
  }

  void flushEmoji() {
    if (emoji.isNotEmpty) {
      spans.add(
        TextSpan(
          text: emoji.toString(),
          style: (base ?? const TextStyle()).copyWith(
            fontFamily: kEmojiFontFamily,
          ),
        ),
      );
      emoji.clear();
    }
  }

  var i = 0;
  while (i < runes.length) {
    final r = runes[i];
    int? start;

    if (_isKeycapBase(r) && _keycapAt(runes, i + 1)) {
      // 键帽:基字符 + 可选 VS16 + U+20E3。
      start = i;
      i = runes[i + 1] == _keycap ? i + 2 : i + 3;
    } else if (_isCore(r)) {
      start = i;
      i++;
      // 国旗:区域指示符成对出现,孤立的不算。
      if (_isRegional(r) && i < runes.length && _isRegional(runes[i])) i++;
    } else {
      flushEmoji();
      plain.writeCharCode(r);
      i++;
      continue;
    }

    // 吸收修饰与 ZWJ 链(VS16 / 肤色 / 标签 / ZWJ + 下一核心字)。
    var absorbed = true;
    while (absorbed) {
      absorbed = false;
      if (i < runes.length &&
          (runes[i] == _vs16 || _isSkinTone(runes[i]) || _isTag(runes[i]))) {
        i++;
        absorbed = true;
      } else if (i + 1 < runes.length &&
          runes[i] == _zwj &&
          (_isCore(runes[i + 1]) || _isSkinTone(runes[i + 1]))) {
        i += 2;
        absorbed = true;
      }
    }
    flushPlain();
    for (var j = start; j < i; j++) {
      emoji.writeCharCode(runes[j]);
    }
  }
  flushPlain();
  flushEmoji();
  return spans;
}

bool _isRegional(int r) => r >= 0x1F1E6 && r <= 0x1F1FF;

bool _isTag(int r) => r >= 0xE0020 && r <= 0xE007F;

/// [Text] 的 emoji 感知版本:内部按 [emojiSpans] 拆分,
/// 纯 emoji 字符串(选择器、快捷回应、贴纸、SAS 验证等)统一用它。
class EmojiText extends StatelessWidget {
  const EmojiText(this.text, {super.key, this.style, this.textAlign});

  final String text;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Text.rich(
      TextSpan(children: emojiSpans(text, style)),
      textAlign: textAlign,
    );
  }
}
