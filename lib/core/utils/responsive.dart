import 'dart:math' as math;

import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// RESPONSIVE
// Single place for layout breakpoints so every screen adapts the same way on
// phones (landscape), tablets, desktop windows, web and Android TV
// (TV renders at ~960×540 logical px).
// ─────────────────────────────────────────────────────────────────────────────
class Responsive {
  final Size size;
  const Responsive(this.size);

  static Responsive of(BuildContext context) =>
      Responsive(MediaQuery.sizeOf(context));

  double get width => size.width;
  double get height => size.height;

  /// Phones in landscape / small windows.
  bool get isCompact => width < 840;

  /// Very narrow (split-screen, tiny web windows).
  bool get isNarrow => width < 640;

  /// Large desktop monitors.
  bool get isWide => width >= 1280;

  /// Short viewports — phone landscape (~360–430 px tall).
  bool get isShort => height < 480;

  /// Clamp a fraction of the width.
  double widthFrac(double fraction, double min, double max) =>
      (width * fraction).clamp(min, max);

  /// Clamp a fraction of the height.
  double heightFrac(double fraction, double min, double max) =>
      (height * fraction).clamp(min, max);

  /// Standard outer padding for page content.
  double get pagePadding => isNarrow
      ? 12
      : isCompact
      ? 16
      : isWide
      ? 28
      : 20;

  /// Category sidebars (Live / Movies / Series).
  double get sidebarWidth => widthFrac(0.21, 168, 260);

  /// Movie / series detail side-panel.
  double get detailPanelWidth => widthFrac(0.32, 250, 440);
}

// ─────────────────────────────────────────────────────────────────────────────
// ADAPTIVE VIEWPORT
// The whole UI is a landscape, multi-pane layout. Below a minimum logical
// canvas (tiny web windows, split-screen, very small phones) panes would
// overflow with yellow/black stripes. Instead we lay the app out at the
// minimum size and scale it down uniformly so it always fits.
// Also clamps the system text scale so huge accessibility font sizes don't
// break fixed-height rows (still honours moderate user preferences).
// ─────────────────────────────────────────────────────────────────────────────
class AdaptiveViewport extends StatelessWidget {
  final Widget child;
  static const double minWidth = 720;
  static const double minHeight = 360;

  const AdaptiveViewport({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final clamped = mq.copyWith(
      textScaler: mq.textScaler.clamp(
        minScaleFactor: 0.85,
        maxScaleFactor: 1.2,
      ),
    );
    final size = mq.size;
    if (size.isEmpty) {
      return MediaQuery(data: clamped, child: child);
    }

    final scale = math.min(
      1.0,
      math.min(size.width / minWidth, size.height / minHeight),
    );
    if (scale >= 0.999) {
      return MediaQuery(data: clamped, child: child);
    }

    final logical = Size(size.width / scale, size.height / scale);
    EdgeInsets s(EdgeInsets e) => e / scale;
    return ColoredBox(
      color: const Color(0xFF0A0C14),
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: logical.width,
          height: logical.height,
          child: MediaQuery(
            data: clamped.copyWith(
              size: logical,
              padding: s(mq.padding),
              viewPadding: s(mq.viewPadding),
              viewInsets: s(mq.viewInsets),
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
