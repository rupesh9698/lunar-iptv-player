import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';

/// Focus / hover / selected look for a poster tile in a grid.
///
/// The whole tile (image + ring) zooms together, and the ring is painted
/// on top of the clipped image without changing its size. The old tiles
/// thickened a layout border on focus, which shrank the image by 2 px —
/// that changed the image's decode width, so the poster re-loaded and
/// flickered every time focus moved onto or off it — and scaled only the
/// image inside the ring, so its corners poked out of the outline.
class PosterFocusFrame extends StatelessWidget {
  final bool focused;
  final bool pressed;
  final bool hovered;
  final bool selected;
  final double radius;
  final Widget child;

  const PosterFocusFrame({
    super.key,
    required this.focused,
    required this.child,
    this.pressed = false,
    this.hovered = false,
    this.selected = false,
    this.radius = 10,
  });

  /// Zoom of a focused tile. Grid spacing must leave room for it
  /// (a 160 px tile grows ~5 px per side).
  static const double focusScale = 1.06;

  @override
  Widget build(BuildContext context) {
    final r = BorderRadius.circular(radius);
    // Focus (white) wins over "last opened" (blue) and hover.
    final Color? ring = focused
        ? Colors.white
        : selected
        ? AppTheme.primary
        : hovered
        ? AppTheme.primary.withValues(alpha: 0.5)
        : null;
    return AnimatedScale(
      scale: pressed
          ? 0.97
          : (focused || hovered)
          ? focusScale
          : 1.0,
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOutCubic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        decoration: BoxDecoration(
          borderRadius: r,
          boxShadow: focused
              ? const [
                  BoxShadow(
                    color: Color(0x99000000),
                    blurRadius: 16,
                    offset: Offset(0, 6),
                  ),
                ]
              : const [],
        ),
        foregroundDecoration: ring == null
            ? null
            : BoxDecoration(
                borderRadius: r,
                border: Border.all(color: ring, width: focused ? 3 : 2),
              ),
        child: ClipRRect(borderRadius: r, child: child),
      ),
    );
  }
}
