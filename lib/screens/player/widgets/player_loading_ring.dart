import 'package:flutter/material.dart';

/// Loading animation shown in the middle of the players while the stream
/// buffers (no "Buffering…" text). It is sized to sit around the centre
/// play / pause button ([playButtonSize]) when the controls are up, and on
/// its own at the same spot when they're hidden.
///
/// With [percent] it shows how far the buffer has filled before playback
/// resumes (mpv's cache-buffering-state, 0–100) in the middle of the ring.
/// When the play button covers the middle ([percentBelow]) the number moves
/// just under the ring instead.
class PlayerLoadingRing extends StatelessWidget {
  /// Diameter of the centre play / pause button the ring goes around.
  static const double playButtonSize = 64;

  /// Ring diameter: a clear gap outside the play button's focus border.
  static const double ringSize = 92;

  final double size;
  final double strokeWidth;
  final Stream<double>? percent;
  final double? initialPercent;
  final bool percentBelow;

  const PlayerLoadingRing({
    super.key,
    this.size = ringSize,
    this.strokeWidth = 4,
    this.percent,
    this.initialPercent,
    this.percentBelow = false,
  });

  static String format(double v) => '${v.clamp(0, 100).floor()}%';

  @override
  Widget build(BuildContext context) {
    final ring = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        color: Colors.white,
        strokeWidth: strokeWidth,
        strokeCap: StrokeCap.round,
        // Faint full track keeps the ring readable on bright video.
        backgroundColor: Colors.black.withValues(alpha: 0.35),
      ),
    );
    final stream = percent;
    return IgnorePointer(
      child: Semantics(
        label: 'Loading',
        child: stream == null
            ? ring
            : StreamBuilder<double>(
                stream: stream,
                initialData: initialPercent,
                builder: (context, snap) {
                  final v = snap.data;
                  final label = v == null
                      ? null
                      : Text(
                          format(v),
                          maxLines: 1,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: percentBelow
                                ? 13
                                : (size * 0.2).clamp(10, 20).toDouble(),
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                            shadows: const [
                              Shadow(color: Colors.black, blurRadius: 6),
                            ],
                          ),
                        );
                  return SizedBox(
                    width: size,
                    height: size,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: [
                        ring,
                        if (label != null && !percentBelow) label,
                        if (label != null && percentBelow)
                          Positioned(
                            top: size + 6,
                            left: -20,
                            right: -20,
                            child: Center(child: label),
                          ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }
}
