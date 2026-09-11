import 'package:flutter/material.dart';

import '../theme/neu_colors.dart';
import 'neu_decoration.dart';
import 'neu_action.dart';

/// 凹陷轨道 + 凸起滑钮的新拟物开关。
class NeuSwitch extends StatelessWidget {
  const NeuSwitch({
    super.key,
    required this.value,
    required this.onChanged,
    this.width = 56,
  });

  final bool value;
  final ValueChanged<bool> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    final height = width * .55;
    final thumb = height - 8;

    return NeuAction(
      toggled: value,
      radius: height / 2,
      onTap: () => onChanged(!value),
      child: Center(
        widthFactor: 1,
        heightFactor: 1,
        child: Container(
          width: width,
          height: height,
          padding: const EdgeInsets.all(4),
          decoration: NeuDecoration(
            colors: colors,
            depth: NeuDepth.pressed,
            radius: height / 2,
            intensity: .8,
          ),
          child: AnimatedAlign(
            duration: const Duration(milliseconds: 160),
            curve: Curves.easeOutCubic,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              width: thumb,
              height: thumb,
              decoration: NeuDecoration(
                colors: colors,
                depth: NeuDepth.raised,
                radius: thumb / 2,
                accent: value,
                intensity: .7,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 凹陷轨道 + 凸起圆钮滑杆。
class NeuSlider extends StatelessWidget {
  const NeuSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.min = 0,
    this.max = 1,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final double min;
  final double max;

  @override
  Widget build(BuildContext context) {
    final colors = context.neu;
    // 保留凹陷轨道，交互交给 Slider 处理键盘、读屏和拖动坐标。
    return SizedBox(
      height: 44,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 10,
            margin: const EdgeInsets.symmetric(horizontal: 12),
            decoration: NeuDecoration(
              colors: colors,
              depth: NeuDepth.pressed,
              radius: 5,
              intensity: .8,
            ),
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 10,
              trackShape: const RoundedRectSliderTrackShape(),
              activeTrackColor: colors.accent,
              inactiveTrackColor: Colors.transparent,
              thumbColor: colors.surfaceStrong,
              overlayColor: colors.accent.withValues(alpha: .18),
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 12),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 20),
            ),
            child: Slider(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
              semanticFormatterCallback: (value) => value.toStringAsFixed(2),
            ),
          ),
        ],
      ),
    );
  }
}
