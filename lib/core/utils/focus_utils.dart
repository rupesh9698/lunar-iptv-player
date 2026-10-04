import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// FOCUS HIGHLIGHT MODE MIXIN
// Automatically listens to FocusManager highlight mode changes.
// Mix into any StatefulWidget that needs to distinguish keyboard vs pointer.
// ─────────────────────────────────────────────────────────────────────────────
mixin TvFocusMixin<T extends StatefulWidget> on State<T> {
  bool _tvFocused = false; // has keyboard/remote focus
  bool _tvPressed = false; // currently pressed via keyboard
  bool _tvHovered = false; // mouse hover

  /// True only when focused via keyboard / TV remote — not mouse or touch.
  bool get isTvFocused => _tvFocused;
  bool get isTvPressed => _tvPressed;
  bool get isTvHovered => _tvHovered;

  /// True when a visible focus ring should be shown.
  bool get showFocusRing =>
      _tvFocused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightChanged);
  }

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightChanged);
    super.dispose();
  }

  void _onHighlightChanged(FocusHighlightMode _) {
    if (mounted) setState(() {});
  }

  void setTvFocused(bool v) {
    if (_tvFocused == v) return;
    setState(() => _tvFocused = v);
  }

  void setTvPressed(bool v) {
    if (_tvPressed == v) return;
    setState(() => _tvPressed = v);
  }

  void setTvHovered(bool v) {
    if (_tvHovered == v) return;
    setState(() => _tvHovered = v);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TV FOCUS RING DECORATION
// Single source of truth for the focus ring style.
// ─────────────────────────────────────────────────────────────────────────────
class TvFocusRing {
  TvFocusRing._();

  static const Color defaultColor = Colors.white;
  static const double defaultWidth = 2.5;
  static const double defaultRadius = 12.0;

  static BoxDecoration decoration({
    bool focused = false,
    double radius = defaultRadius,
    Color color = defaultColor,
    double width = defaultWidth,
    Color? backgroundColor,
    BoxDecoration? base,
  }) {
    if (!focused) {
      return base ??
          BoxDecoration(
            borderRadius: BorderRadius.circular(radius),
            color: backgroundColor,
          );
    }
    return (base ?? BoxDecoration()).copyWith(
      borderRadius: BorderRadius.circular(radius),
      border: Border.all(color: color.withValues(alpha: 0.80), width: width),
      color: backgroundColor,
    );
  }

  static Border border({
    bool focused = false,
    Color color = defaultColor,
    double width = defaultWidth,
  }) => focused
      ? Border.all(color: color.withValues(alpha: 0.80), width: width)
      : Border.all(color: Colors.transparent, width: width);
}

// ─────────────────────────────────────────────────────────────────────────────
// TV FOCUSABLE
// Core focusable widget. Replaces every raw Focus + onKeyEvent pattern.
//
// Features:
//  • Shows focus ring only on keyboard/TV-remote (FocusHighlightMode.traditional)
//  • Auto-scrolls itself into view when focused via remote
//  • Handles Select / Enter / Space / GameButtonA as activation
//  • Handles arrow keys via optional onArrowKey callback
//  • Supports long-press via onLongPress
//  • MouseRegion + GestureDetector built-in
//  • builder(isFocused, isPressed) — isFocused = TV-remote focus only
// ─────────────────────────────────────────────────────────────────────────────
class TvFocusable extends StatefulWidget {
  final Widget Function(bool isFocused, bool isPressed) builder;
  final VoidCallback? onActivate;
  final VoidCallback? onLongPress;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final KeyEventResult Function(LogicalKeyboardKey key)? onArrowKey;

  /// Whether to auto-scroll this widget into the center of its scrollable
  /// when it receives TV/keyboard focus.
  final bool autoScroll;
  final double scrollAlignment;

  const TvFocusable({
    super.key,
    required this.builder,
    this.onActivate,
    this.onLongPress,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.onArrowKey,
    this.autoScroll = true,
    this.scrollAlignment = 0.5,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> with TvFocusMixin {
  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setTvFocused(focused);
        widget.onFocusChange?.call(focused);
        // Auto-scroll only when receiving focus via keyboard/remote
        if (focused && widget.autoScroll) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            final ctx = context;
            Scrollable.maybeOf(ctx)?.position; // ensure scrollable exists
            Scrollable.ensureVisible(
              ctx,
              alignment: widget.scrollAlignment,
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
            );
          });
        }
      },
      onKeyEvent: (node, event) {
        final isDown = event is KeyDownEvent;
        final isUp   = event is KeyUpEvent;

        if (isDown) {
          // Activation keys — always handled here, never bubble
          if (_isActivationKey(event.logicalKey)) {
            setTvPressed(true);
            widget.onActivate?.call();
            return KeyEventResult.handled;
          }
          // Arrow keys — delegate to widget's onArrowKey only.
          // Never call node.onKeyEvent here — that causes infinite recursion
          // because Focus.onKeyEvent and FocusNode.onKeyEvent share the same
          // dispatch chain in Flutter's focus system.
          if (_isArrowKey(event.logicalKey) && widget.onArrowKey != null) {
            return widget.onArrowKey!(event.logicalKey);
          }
        }
        if (isUp && _isActivationKey(event.logicalKey)) {
          setTvPressed(false);
          return KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.onActivate != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        onEnter: (_) => setTvHovered(true),
        onExit: (_) {
          setTvHovered(false);
          setTvPressed(false);
        },
        child: GestureDetector(
          onTap: widget.onActivate,
          onLongPress: widget.onLongPress,
          onTapDown: (_) => setTvPressed(true),
          onTapUp: (_) => setTvPressed(false),
          onTapCancel: () => setTvPressed(false),
          child: widget.builder(showFocusRing, isTvPressed),
        ),
      ),
    );
  }

  static bool _isActivationKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.space ||
      k == LogicalKeyboardKey.gameButtonA;

  static bool _isArrowKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.arrowUp ||
      k == LogicalKeyboardKey.arrowDown ||
      k == LogicalKeyboardKey.arrowLeft ||
      k == LogicalKeyboardKey.arrowRight;
}

// ─────────────────────────────────────────────────────────────────────────────
// TV ICON BUTTON
// Drop-in replacement for IconButton everywhere in the app.
// Shows focus ring only on TV/keyboard navigation.
// ─────────────────────────────────────────────────────────────────────────────
class TvIconButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  final Color? color;
  final double size;
  final String? tooltip;
  final double ringRadius;
  final bool autofocus;

  const TvIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.color,
    this.size = 20,
    this.tooltip,
    this.ringRadius = 8,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? Theme.of(context).iconTheme.color;
    Widget child = TvFocusable(
      autofocus: autofocus,
      onActivate: onTap,
      builder: (focused, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(ringRadius),
          color: focused
              ? Colors.white.withValues(alpha: 0.10)
              : pressed
              ? Colors.white.withValues(alpha: 0.06)
              : Colors.transparent,
          border: focused
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.55),
                  width: 2,
                )
              : null,
        ),
        child: Icon(icon, size: size, color: iconColor),
      ),
    );
    if (tooltip != null) {
      child = Tooltip(message: tooltip!, child: child);
    }
    return child;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN FOCUS SCOPE
// Wraps a screen's root so focus is restored correctly on back-navigation.
// ─────────────────────────────────────────────────────────────────────────────
class ScreenFocusScope extends StatefulWidget {
  final Widget child;
  final String debugLabel;

  const ScreenFocusScope({
    super.key,
    required this.child,
    this.debugLabel = 'Screen',
  });

  @override
  State<ScreenFocusScope> createState() => _ScreenFocusScopeState();
}

class _ScreenFocusScopeState extends State<ScreenFocusScope> {
  late final FocusScopeNode _node;

  @override
  void initState() {
    super.initState();
    _node = FocusScopeNode(debugLabel: widget.debugLabel);
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      FocusScope(node: _node, child: widget.child);
}

// ─────────────────────────────────────────────────────────────────────────────
// TV NAV — directional focus-jump helper.
// Wraps a FocusNode's onKeyEvent so each arrow direction can jump straight
// to another FocusNode, independent of FocusScope boundaries. Used to wire
// fixed navigation graphs (e.g. Live TV screen) where default traversal
// across separate FocusScopes is unreliable.
// ─────────────────────────────────────────────────────────────────────────────
class TvNav {
  TvNav._();

  /// Builds an onKeyEvent handler that jumps focus on arrow keys.
  /// Pass null for a direction with "No Action".
  /// Pass a callback (instead of a FocusNode) for dynamic targets
  /// (e.g. "first item in a list that may not exist yet").
  static KeyEventResult Function(FocusNode, KeyEvent) handler({
    FocusNode? up,
    FocusNode? down,
    FocusNode? left,
    FocusNode? right,
    VoidCallback? onUp,
    VoidCallback? onDown,
    VoidCallback? onLeft,
    VoidCallback? onRight,
  }) {
    return (node, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowUp) {
        if (onUp != null) {
          onUp();
          return KeyEventResult.handled;
        }
        if (up != null) {
          up.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        if (onDown != null) {
          onDown();
          return KeyEventResult.handled;
        }
        if (down != null) {
          down.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (onLeft != null) {
          onLeft();
          return KeyEventResult.handled;
        }
        if (left != null) {
          left.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        if (onRight != null) {
          onRight();
          return KeyEventResult.handled;
        }
        if (right != null) {
          right.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      }
      return KeyEventResult.ignored;
    };
  }
}
