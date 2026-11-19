import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'blurhash_codec.dart';

final _decodedHashes = <String, Future<Uint8List?>>{};

class BlurhashPlaceholder extends StatelessWidget {
  final String? hash;
  final Color color;
  const BlurhashPlaceholder({
    super.key,
    required this.hash,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final value = hash;
    if (value == null || value.length > 166 || value.length < 6) {
      return ColoredBox(color: color);
    }
    final future = _decodedHashes.putIfAbsent(
      value,
      () => compute(decodeBlurhash, value),
    );
    while (_decodedHashes.length > 100) {
      _decodedHashes.remove(_decodedHashes.keys.first);
    }
    return FutureBuilder<Uint8List?>(
      future: future,
      builder: (context, snapshot) => snapshot.data == null
          ? ColoredBox(color: color)
          : Image.memory(
              snapshot.data!,
              fit: BoxFit.fill,
              gaplessPlayback: true,
              excludeFromSemantics: true,
            ),
    );
  }
}

/// Spoilers use the low-detail placeholder only; the original image is not
/// rendered or fetched until the user explicitly reveals it.
class SpoilerImageCover extends StatelessWidget {
  final String? hash;
  final String? reason;
  final Color color;
  final VoidCallback onReveal;
  const SpoilerImageCover({
    super.key,
    required this.hash,
    this.reason,
    required this.color,
    required this.onReveal,
  });

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: reason?.isNotEmpty == true ? '显示隐藏图片：$reason' : '显示隐藏图片',
    child: GestureDetector(
      key: const ValueKey('spoiler-image-cover'),
      onTap: onReveal,
      behavior: HitTestBehavior.opaque,
      child: Stack(
        fit: StackFit.expand,
        children: [
          BlurhashPlaceholder(hash: hash, color: color),
          ColoredBox(color: Colors.black.withValues(alpha: .35)),
          Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: .45),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    CupertinoIcons.eye_slash,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
                if (reason?.trim().isNotEmpty == true)
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: Text(
                      reason!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
