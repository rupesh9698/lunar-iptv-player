import 'package:flutter/material.dart';

/// Loading animation shown in the middle of the players while the stream
/// buffers (no "Buffering…" text). It is sized to sit around the centre
/// play / pause button ([playButtonSize]) when the controls are up, and on
/// its own at the same spot when they're hidden.
class PlayerLoadingRing extends StatelessWidget {
  /// Diameter of the centre play / pause button the ring goes around.
  static const double playButtonSize = 64;

  /// Ring diameter: a clear gap outside the play button's focus border.
  static const double ringSize = 92;

  final double size;
  final double strokeWidth;

  const PlayerLoadingRing({
    super.key,
    this.size = ringSize,
    this.strokeWidth = 4,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Semantics(
        label: 'Loading',
        child: SizedBox(
          width: size,
          height: size,
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: strokeWidth,
            strokeCap: StrokeCap.round,
            // Faint full track keeps the ring readable on bright video.
            backgroundColor: Colors.black.withValues(alpha: 0.35),
          ),
        ),
      ),
    );
  }
}
