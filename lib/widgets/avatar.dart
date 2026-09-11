import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'neu_decoration.dart';

enum Presence { online, away, busy, offline }

/// 新拟物圆形头像:离线环境不用网络图,用 seed 派生的双色渐变 + 首字符。
class NeuAvatar extends StatelessWidget {
  const NeuAvatar({
    super.key,
    required this.seed,
    required this.label,
    this.size = 48,
    this.presence,
  });

  final String seed;
  final String label;
  final double size;
  final Presence? presence;

  /// 派生头像渐变的调色板(图片占位等复用)。
  static const palettesStatic = _palettes;

  static const _palettes = [
    [Color(0xFF5B8DEF), Color(0xFF9B7BFF)],
    [Color(0xFF3FA7A0), Color(0xFF5B8DEF)],
    [Color(0xFFE58E6D), Color(0xFFD9668E)],
    [Color(0xFF6FBF73), Color(0xFF3FA7A0)],
    [Color(0xFF9B7BFF), Color(0xFFD9668E)],
    [Color(0xFFE0B34B), Color(0xFFE58E6D)],
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final idx = seed.hashCode.abs() % _palettes.length;
    final pair = _palettes[idx];
    final initial = label.isEmpty
        ? '?'
        : String.fromCharCode(label.runes.first);

    Widget avatar = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * .07),
      decoration: NeuDecoration(
        colors: colors,
        depth: NeuDepth.raised,
        radius: size / 2,
        intensity: .6,
      ),
      child: Container(
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: pair,
          ),
        ),
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * .4,
            fontWeight: FontWeight.w700,
            height: 1,
          ),
        ),
      ),
    );

    if (presence != null && presence != Presence.offline) {
      final dotColor = switch (presence!) {
        Presence.online => colors.success,
        Presence.away => colors.warning,
        Presence.busy => colors.error,
        Presence.offline => colors.textTertiary,
      };
      avatar = Stack(
        clipBehavior: Clip.none,
        children: [
          avatar,
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: size * .28,
              height: size * .28,
              decoration: BoxDecoration(
                color: dotColor,
                shape: BoxShape.circle,
                border: Border.all(color: colors.base, width: 2),
              ),
            ),
          ),
        ],
      );
    }
    return avatar;
  }
}

/// 未读数徽标。
class NeuBadge extends StatelessWidget {
  const NeuBadge({super.key, required this.count, this.muted = false});

  final int count;
  final bool muted;

  @override
  Widget build(BuildContext context) {
    if (count <= 0) return const SizedBox.shrink();
    final colors = context.neu;
    final text = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: NeuDecoration(
        colors: colors,
        depth: NeuDepth.raised,
        radius: NeuRadius.tag,
        color: muted ? colors.surfaceStrong : null,
        accent: !muted,
        intensity: .6,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
          fontWeight: FontWeight.w700,
          color: muted ? colors.textSecondary : colors.onAccent,
        ),
      ),
    );
  }
}

/// 叠放头像(已读回执、群成员预览)。
class AvatarStack extends StatelessWidget {
  const AvatarStack({super.key, required this.avatars, this.size = 18});

  final List<NeuAvatar> avatars;
  final double size;

  @override
  Widget build(BuildContext context) {
    if (avatars.isEmpty) return const SizedBox.shrink();
    final shown = avatars.take(3).toList();
    return SizedBox(
      width: size + (shown.length - 1) * size * .62,
      height: size,
      child: Stack(
        children: [
          for (var i = 0; i < shown.length; i++)
            Positioned(
              left: i * size * .62,
              child: Container(
                width: size,
                height: size,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: context.neu.surfaceStrong,
                  border: Border.all(color: context.neu.base, width: 1.4),
                ),
                child: Text(
                  String.fromCharCode(shown[i].label.runes.first),
                  style: TextStyle(
                    fontSize: size * .52,
                    fontWeight: FontWeight.w700,
                    color: context.neu.textSecondary,
                    height: 1,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
