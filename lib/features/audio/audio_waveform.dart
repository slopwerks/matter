import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Bars are supplied by decoded PCM. Missing data renders a neutral seek line,
/// not a synthetic waveform. Drag cancellation never commits a position.
class AudioWaveform extends StatefulWidget {
  final List<double>? samples;
  final double progress;
  final Color color;
  final ValueChanged<double>? onSeek;

  const AudioWaveform({
    super.key,
    required this.samples,
    required this.progress,
    required this.color,
    this.onSeek,
  });

  @override
  State<AudioWaveform> createState() => _AudioWaveformState();
}

class _AudioWaveformState extends State<AudioWaveform> {
  double? _drag;

  double _fraction(double x, double width) =>
      width > 0 ? (x / width).clamp(0.0, 1.0) : 0;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fraction = (_drag ?? widget.progress).clamp(0.0, 1.0);
      final seek = widget.onSeek;
      return Semantics(
        label: '音频进度',
        value: '${(fraction * 100).round()}%',
        increasedValue: seek == null
            ? null
            : '${((fraction + 0.05).clamp(0.0, 1.0) * 100).round()}%',
        decreasedValue: seek == null
            ? null
            : '${((fraction - 0.05).clamp(0.0, 1.0) * 100).round()}%',
        onIncrease: seek == null
            ? null
            : () => seek((fraction + 0.05).clamp(0.0, 1.0)),
        onDecrease: seek == null
            ? null
            : () => seek((fraction - 0.05).clamp(0.0, 1.0)),
        child: Listener(
          onPointerCancel: (_) {
            if (mounted) setState(() => _drag = null);
          },
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: seek == null
                ? null
                : (details) => seek(
                    _fraction(details.localPosition.dx, constraints.maxWidth),
                  ),
            onHorizontalDragStart: seek == null
                ? null
                : (details) => setState(
                    () => _drag = _fraction(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    ),
                  ),
            onHorizontalDragUpdate: seek == null
                ? null
                : (details) => setState(
                    () => _drag = _fraction(
                      details.localPosition.dx,
                      constraints.maxWidth,
                    ),
                  ),
            onHorizontalDragEnd: seek == null
                ? null
                : (_) {
                    final value = _drag;
                    setState(() => _drag = null);
                    if (value != null) seek(value);
                  },
            onHorizontalDragCancel: () => setState(() => _drag = null),
            child: CustomPaint(
              key: const ValueKey('audio-waveform'),
              size: Size(constraints.maxWidth, 32),
              painter: AudioWaveformPainter(
                samples: widget.samples,
                progress: fraction,
                color: widget.color,
              ),
            ),
          ),
        ),
      );
    },
  );
}

class AudioWaveformPainter extends CustomPainter {
  final List<double>? samples;
  final double progress;
  final Color color;

  const AudioWaveformPainter({
    required this.samples,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final data = samples;
    final paint = Paint()
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    if (data == null || data.isEmpty) {
      paint.color = color.withValues(alpha: 0.25);
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        paint,
      );
      paint.color = color;
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width * progress, size.height / 2),
        paint,
      );
      return;
    }
    final count = math.max(1, math.min(data.length, (size.width / 4).floor()));
    final step = size.width / count;
    for (var bar = 0; bar < count; bar++) {
      final start = bar * data.length ~/ count;
      final end = math.max(start + 1, (bar + 1) * data.length ~/ count);
      var amplitude = 0.0;
      for (var index = start; index < end; index++) {
        final value = data[index];
        if (value.isFinite) {
          amplitude = math.max(amplitude, value.clamp(0.0, 1.0));
        }
      }
      paint.color = (bar + 0.5) / count <= progress
          ? color
          : color.withValues(alpha: 0.25);
      final height = math.max(1.0, amplitude * (size.height - 2));
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset((bar + 0.5) * step, size.height / 2),
            width: math.min(2, step),
            height: height,
          ),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant AudioWaveformPainter oldDelegate) =>
      oldDelegate.samples != samples ||
      oldDelegate.progress != progress ||
      oldDelegate.color != color;
}
