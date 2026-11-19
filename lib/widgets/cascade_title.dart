import 'package:flutter/material.dart';

/// Animated title that cross-fades with a vertical slide when text changes.
/// Old text slides up and fades out, new text slides in from below and fades in.
class CascadeTitle extends StatefulWidget {
  final String text;
  final TextStyle style;

  const CascadeTitle({super.key, required this.text, required this.style});

  @override
  State<CascadeTitle> createState() => _CascadeTitleState();
}

class _CascadeTitleState extends State<CascadeTitle>
    with SingleTickerProviderStateMixin {
  String _oldText = '';
  bool _isTransitioning = false;

  late AnimationController _controller;
  late Animation<double> _oldOpacity;
  late Animation<double> _oldSlideY;
  late Animation<double> _newOpacity;
  late Animation<double> _newSlideY;

  @override
  void initState() {
    super.initState();
    _oldText = widget.text;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Old text: fade out + slide up
    _oldOpacity = Tween(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));
    _oldSlideY = Tween(
      begin: 0.0,
      end: -6.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeIn));

    // New text: fade in + slide up from below
    _newOpacity = Tween(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _newSlideY = Tween(
      begin: 6.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
  }

  @override
  void didUpdateWidget(CascadeTitle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.text != widget.text) {
      _oldText = oldWidget.text;
      _isTransitioning = true;
      _controller.forward(from: 0).then((_) {
        if (mounted) {
          setState(() {
            _isTransitioning = false;
            _oldText = widget.text;
          });
        }
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_isTransitioning) {
      return Text(
        widget.text,
        style: widget.style,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            Opacity(
              opacity: _oldOpacity.value,
              child: Transform.translate(
                offset: Offset(0, _oldSlideY.value),
                child: Text(
                  _oldText,
                  style: widget.style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
            Opacity(
              opacity: _newOpacity.value,
              child: Transform.translate(
                offset: Offset(0, _newSlideY.value),
                child: Text(
                  widget.text,
                  style: widget.style,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}
