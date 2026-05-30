import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Wraps any widget with full TV remote + keyboard + touch + cursor support.
/// - Shows visible focus ring
/// - Handles Select/Enter/Space as activation
/// - Handles optional arrow-key delegation
class TvFocusable extends StatefulWidget {
  final Widget Function(bool focused, bool pressed) builder;
  final VoidCallback? onActivate;
  final FocusNode? focusNode;
  final bool autofocus;
  final ValueChanged<bool>? onFocusChange;
  final KeyEventResult Function(LogicalKeyboardKey key)? onArrowKey;

  const TvFocusable({
    super.key,
    required this.builder,
    this.onActivate,
    this.focusNode,
    this.autofocus = false,
    this.onFocusChange,
    this.onArrowKey,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> {
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (f) {
        setState(() => _focused = f);
        widget.onFocusChange?.call(f);
      },
      onKeyEvent: (_, event) {
        final isDown = event is KeyDownEvent;
        final isUp = event is KeyUpEvent;

        // Activation keys
        if (isDown &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          setState(() => _pressed = true);
          widget.onActivate?.call();
          return KeyEventResult.handled;
        }
        if (isUp) {
          setState(() => _pressed = false);
          return KeyEventResult.ignored;
        }

        // Arrow keys — delegate to caller
        if (isDown && widget.onArrowKey != null) {
          final arrowKeys = [
            LogicalKeyboardKey.arrowUp,
            LogicalKeyboardKey.arrowDown,
            LogicalKeyboardKey.arrowLeft,
            LogicalKeyboardKey.arrowRight,
          ];
          if (arrowKeys.contains(event.logicalKey)) {
            return widget.onArrowKey!(event.logicalKey);
          }
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.onActivate != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: widget.onActivate,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: widget.builder(_focused, _pressed),
        ),
      ),
    );
  }
}

/// Wraps a screen's root with a FocusScopeNode so that
/// navigating back restores focus to where the user left off.
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
