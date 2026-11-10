import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TV KEY TRACKER
// Global, passive key listener (never consumes events). Lets focus widgets
// know whether the current focus change was caused by a held-down D-pad key
// (KeyRepeatEvent) so they can jump-scroll instead of animating — animated
// scrolling can't keep up with remote auto-repeat and focus gets "lost"
// off-screen in long lists.
// ─────────────────────────────────────────────────────────────────────────────
class TvKeyTracker {
  TvKeyTracker._();

  static bool _installed = false;

  /// True while the most recent key event was an auto-repeat.
  static bool isRepeating = false;

  static void install() {
    if (_installed) return;
    _installed = true;
    HardwareKeyboard.instance.addHandler(_handle);
  }

  static bool _handle(KeyEvent event) {
    if (event is KeyRepeatEvent) {
      isRepeating = true;
    } else {
      isRepeating = false;
    }
    // A new Back press starts: nobody has seen it reach the root yet.
    if (event is KeyDownEvent && TvBackKeyGuard.isBackKey(event.logicalKey)) {
      TvBackKeyGuard._downReachedRoot = false;
    }
    return false; // never consume
  }

  /// Scroll duration to use when bringing a newly focused widget into view.
  static Duration get scrollDuration =>
      isRepeating ? Duration.zero : const Duration(milliseconds: 220);
}

// ─────────────────────────────────────────────────────────────────────────────
// TV BACK KEY GUARD
// On Android a Back press arrives twice: as a key event (down + up) and —
// if the framework does not consume the *up* — as a system "back" that pops
// the route. Screens that handle Back themselves (full-screen player,
// channel guide…) consumed only the key-DOWN, so the key-UP still triggered
// a system back a moment later. If the screen had already changed state
// (e.g. minimised the player) that second back went one level further —
// straight to Home.
// This guard sits above the Navigator: if a Back key-DOWN was consumed
// somewhere below (it never reached the root), the matching key-UP is
// consumed here too. Unhandled Back presses pass through untouched.
// ─────────────────────────────────────────────────────────────────────────────
class TvBackKeyGuard extends StatelessWidget {
  final Widget child;
  const TvBackKeyGuard({super.key, required this.child});

  static bool _downReachedRoot = true;

  /// Set when a held OK fired a long-press: the rest of that press (its
  /// auto-repeats and the key-up) must not reach whatever the long-press
  /// opened. Otherwise the repeats "click" the dialog's focused button —
  /// the Hide Category dialog flashed up and closed straight away on TV.
  static bool _swallowActivation = false;

  static void swallowRestOfActivation() => _swallowActivation = true;

  static bool isBackKey(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.goBack ||
      k == LogicalKeyboardKey.escape ||
      k == LogicalKeyboardKey.browserBack;

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (_isActivationKey(event.logicalKey) && _swallowActivation) {
          if (event is KeyDownEvent) {
            _swallowActivation = false; // a new press: deliver normally
            return KeyEventResult.ignored;
          }
          if (event is KeyUpEvent) _swallowActivation = false;
          return KeyEventResult.handled;
        }
        if (!isBackKey(event.logicalKey)) return KeyEventResult.ignored;
        if (event is KeyDownEvent) {
          _downReachedRoot = true; // nobody below handled it → system back
          return KeyEventResult.ignored;
        }
        // Up / repeat of a press that was handled below → swallow.
        return _downReachedRoot
            ? KeyEventResult.ignored
            : KeyEventResult.handled;
      },
      child: child,
    );
  }
}

bool _isActivationKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.select ||
    k == LogicalKeyboardKey.enter ||
    k == LogicalKeyboardKey.numpadEnter ||
    k == LogicalKeyboardKey.space ||
    k == LogicalKeyboardKey.gameButtonA;

bool _isArrowKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.arrowUp ||
    k == LogicalKeyboardKey.arrowDown ||
    k == LogicalKeyboardKey.arrowLeft ||
    k == LogicalKeyboardKey.arrowRight;

/// Keys that open a context / options menu on TV remotes & keyboards.
bool _isMenuKey(LogicalKeyboardKey k) =>
    k == LogicalKeyboardKey.contextMenu || k == LogicalKeyboardKey.gameButtonY;

/// How long OK/Select must be held before [TvFocusable.onLongPress] fires.
/// Slightly under Android's standard long-press timeout (500 ms) so a
/// system long-press always registers before the key is released.
const Duration kTvLongPressDuration = Duration(milliseconds: 450);

/// Fallback when key events carry no usable timestamps.
/// Android only starts auto-repeat after the long-press timeout, so the
/// first repeat already means "held".
const int kTvLongPressRepeats = 1;

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
    if (_tvFocused == v || !mounted) return;
    setState(() => _tvFocused = v);
  }

  void setTvPressed(bool v) {
    if (_tvPressed == v || !mounted) return;
    setState(() => _tvPressed = v);
  }

  void setTvHovered(bool v) {
    if (_tvHovered == v || !mounted) return;
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
    return (base ?? const BoxDecoration()).copyWith(
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
//  • Auto-scrolls itself into view when focused (jump-scrolls while a D-pad
//    key is held down so focus never runs off-screen)
//  • Handles Select / Enter / Space / GameButtonA as activation
//  • Long-press OK (or the Menu key) triggers [onLongPress] — when a
//    long-press handler exists, activation fires on key-up so the two never
//    collide
//  • Handles arrow keys (including auto-repeat) via optional onArrowKey
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

  /// When true (default) everything built by [builder] is removed from the
  /// focus tree, so a TvFocusable wrapping a Material button (IconButton,
  /// OutlinedButton, ListTile...) is ONE D-pad stop instead of two (the
  /// inner, un-wired stop made users press twice and broke nav graphs).
  /// Set false only when the child hosts its own focus target (e.g. a
  /// TextField that opens inside a search toggle).
  final bool excludeChildFocus;

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
    this.excludeChildFocus = true,
  });

  @override
  State<TvFocusable> createState() => _TvFocusableState();
}

class _TvFocusableState extends State<TvFocusable> with TvFocusMixin {
  bool _activationDown = false;
  bool _longPressFired = false;
  int _repeatCount = 0;
  Timer? _longPressTimer;

  @override
  void dispose() {
    _longPressTimer?.cancel();
    super.dispose();
  }

  void _fireLongPress() {
    _longPressTimer?.cancel();
    if (!mounted || !_activationDown || _longPressFired) return;
    if (widget.onLongPress == null) return;
    _longPressFired = true;
    setTvPressed(false);
    TvBackKeyGuard.swallowRestOfActivation();
    widget.onLongPress!();
  }

  void _ensureVisible() {
    if (!mounted) return;
    final duration = TvKeyTracker.scrollDuration;
    Scrollable.ensureVisible(
      context,
      alignment: widget.scrollAlignment,
      duration: duration,
      curve: Curves.easeOutCubic,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final key = event.logicalKey;

    // ── Activation (OK / Enter / Space / A) ─────────────────────────────
    if (_isActivationKey(key)) {
      final hasLong = widget.onLongPress != null;
      if (event is KeyDownEvent) {
        _activationDown = true;
        _longPressFired = false;
        _repeatCount = 0;
        setTvPressed(true);
        // Without a long-press handler, activate immediately (snappier).
        if (!hasLong) widget.onActivate?.call();
        // Primary long-press signal: a timer. Many TV remotes / Android
        // builds never deliver key-repeat events for OK, so relying on
        // repeats alone made "hold OK" do nothing on real TVs.
        _longPressTimer?.cancel();
        if (hasLong) {
          _longPressTimer = Timer(kTvLongPressDuration, _fireLongPress);
        }
        return KeyEventResult.handled;
      }
      if (event is KeyRepeatEvent) {
        _repeatCount++;
        // Android (and desktop OSes) only begin auto-repeat once the system
        // long-press timeout (400–500 ms) has passed, so the first repeat
        // already means "held". Remotes that never send repeats are covered
        // by the timer started on key-down.
        final held = _repeatCount >= kTvLongPressRepeats;
        if (hasLong && _activationDown && !_longPressFired && held) {
          _fireLongPress();
        }
        // Swallow repeats so held OK never re-triggers anything.
        return KeyEventResult.handled;
      }
      if (event is KeyUpEvent) {
        _longPressTimer?.cancel();
        final wasDown = _activationDown;
        _activationDown = false;
        setTvPressed(false);
        if (!wasDown) return KeyEventResult.ignored;
        if (hasLong && !_longPressFired) widget.onActivate?.call();
        return KeyEventResult.handled;
      }
    }

    // ── Menu key → long-press action ────────────────────────────────────
    if (event is KeyDownEvent &&
        _isMenuKey(key) &&
        widget.onLongPress != null) {
      widget.onLongPress!();
      return KeyEventResult.handled;
    }

    // ── Arrows (down + auto-repeat) ─────────────────────────────────────
    // Never call node.onKeyEvent here — Focus.onKeyEvent and
    // FocusNode.onKeyEvent share the same dispatch chain.
    if ((event is KeyDownEvent || event is KeyRepeatEvent) &&
        _isArrowKey(key)) {
      // Screen-level navigation graph (see TvNav.wire) wins over the
      // widget's own defaults.
      final graph = TvNav.graphFor(node);
      if (graph != null) {
        final r = graph(node, event);
        if (r != KeyEventResult.ignored) return r;
      }
      if (widget.onArrowKey != null) return widget.onArrowKey!(key);
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      autofocus: widget.autofocus,
      onFocusChange: (focused) {
        setTvFocused(focused);
        if (!focused) {
          _activationDown = false;
          _longPressTimer?.cancel();
          setTvPressed(false);
        }
        widget.onFocusChange?.call(focused);
        if (focused && widget.autoScroll) {
          WidgetsBinding.instance.addPostFrameCallback((_) => _ensureVisible());
        }
      },
      onKeyEvent: _onKey,
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
          onSecondaryTap: widget.onLongPress,
          onTapDown: (_) => setTvPressed(true),
          onTapUp: (_) => setTvPressed(false),
          onTapCancel: () => setTvPressed(false),
          child: widget.excludeChildFocus
              ? ExcludeFocus(child: widget.builder(showFocusRing, isTvPressed))
              : widget.builder(showFocusRing, isTvPressed),
        ),
      ),
    );
  }
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
  final FocusNode? focusNode;
  final EdgeInsets padding;
  final bool circle;

  const TvIconButton({
    super.key,
    required this.icon,
    this.onTap,
    this.color,
    this.size = 20,
    this.tooltip,
    this.ringRadius = 8,
    this.autofocus = false,
    this.focusNode,
    this.padding = const EdgeInsets.all(8),
    this.circle = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = color ?? Theme.of(context).iconTheme.color;
    Widget child = TvFocusable(
      autofocus: autofocus,
      focusNode: focusNode,
      autoScroll: false,
      onActivate: onTap,
      builder: (focused, pressed) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: padding,
        decoration: BoxDecoration(
          shape: circle ? BoxShape.circle : BoxShape.rectangle,
          borderRadius: circle ? null : BorderRadius.circular(ringRadius),
          color: focused
              ? Colors.white.withValues(alpha: 0.16)
              : pressed
              ? Colors.white.withValues(alpha: 0.08)
              : Colors.transparent,
          border: Border.all(
            color: focused
                ? Colors.white.withValues(alpha: 0.75)
                : Colors.transparent,
            width: 2,
          ),
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
// TV TEXT FIELD NAV
// Single-line TextFields swallow every arrow key (DefaultTextEditingShortcuts
// maps Up/Down to "move caret to start/end"), so a D-pad user who lands in a
// search box can never leave it. Wrap any TextField with this to let
// Up/Down — and Left/Right when the caret is already at the edge — move
// focus out again. Sits *above* the TextField so it sees keys first.
// ─────────────────────────────────────────────────────────────────────────────
class TvTextFieldNav extends StatelessWidget {
  final Widget child;
  final TextEditingController? controller;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  const TvTextFieldNav({
    super.key,
    required this.child,
    this.controller,
    this.onUp,
    this.onDown,
    this.onLeft,
    this.onRight,
  });

  static bool _move(TraversalDirection dir) =>
      FocusManager.instance.primaryFocus?.focusInDirection(dir) ?? false;

  KeyEventResult _go(VoidCallback? custom, TraversalDirection dir) {
    if (custom != null) {
      custom();
      return KeyEventResult.handled;
    }
    return _move(dir) ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: (node, event) {
        if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
          return KeyEventResult.ignored;
        }
        final k = event.logicalKey;
        if (k == LogicalKeyboardKey.arrowUp) {
          return _go(onUp, TraversalDirection.up);
        }
        if (k == LogicalKeyboardKey.arrowDown) {
          return _go(onDown, TraversalDirection.down);
        }
        final sel = controller?.selection;
        final len = controller?.text.length ?? 0;
        final collapsed = sel != null && sel.isValid && sel.isCollapsed;
        if (k == LogicalKeyboardKey.arrowLeft &&
            (controller == null || (collapsed && sel.baseOffset <= 0))) {
          return _go(onLeft, TraversalDirection.left);
        }
        if (k == LogicalKeyboardKey.arrowRight &&
            (controller == null || (collapsed && sel.baseOffset >= len))) {
          return _go(onRight, TraversalDirection.right);
        }
        return KeyEventResult.ignored;
      },
      child: child,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TV SLIDER
// Material Slider captures all four arrow keys in "traditional" navigation
// mode, trapping D-pad focus forever. This wrapper removes the Slider from
// the focus tree and drives it itself: Left/Right adjust, Up/Down leave.
// A visible focus ring is drawn around the track when focused by remote.
// ─────────────────────────────────────────────────────────────────────────────
class TvSlider extends StatelessWidget {
  final double value;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;
  final double min;
  final double max;

  /// Amount Left/Right moves the value (in the slider's own units).
  final double step;

  /// Optional override for D-pad Left/Right (e.g. "seek ±10s" on a seek bar).
  /// When provided, [step] is ignored.
  final VoidCallback? onStepDown;
  final VoidCallback? onStepUp;

  final SliderThemeData? theme;
  final FocusNode? focusNode;

  const TvSlider({
    super.key,
    required this.value,
    required this.onChanged,
    this.onChangeStart,
    this.onChangeEnd,
    this.min = 0.0,
    this.max = 1.0,
    this.step = 0.05,
    this.onStepDown,
    this.onStepUp,
    this.theme,
    this.focusNode,
  });

  void _nudge(double delta) {
    final v = (value + delta).clamp(min, max);
    onChangeStart?.call(value);
    onChanged?.call(v);
    onChangeEnd?.call(v);
  }

  @override
  Widget build(BuildContext context) {
    final slider = ExcludeFocus(
      child: Slider(
        value: value.clamp(min, max),
        min: min,
        max: max,
        onChanged: onChanged,
        onChangeStart: onChangeStart,
        onChangeEnd: onChangeEnd,
      ),
    );
    return TvFocusable(
      focusNode: focusNode,
      autoScroll: false,
      onArrowKey: (key) {
        if (onChanged == null) return KeyEventResult.ignored;
        if (key == LogicalKeyboardKey.arrowLeft) {
          onStepDown != null ? onStepDown!() : _nudge(-step);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          onStepUp != null ? onStepUp!() : _nudge(step);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored; // Up/Down → normal traversal
      },
      builder: (focused, _) => DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: focused
                ? Colors.white.withValues(alpha: 0.7)
                : Colors.transparent,
            width: 1.5,
          ),
          color: focused ? Colors.white.withValues(alpha: 0.08) : null,
        ),
        child: theme != null
            ? SliderTheme(data: theme!, child: slider)
            : slider,
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TV SCROLL VIEW
// A SingleChildScrollView that a D-pad can scroll. Pages that are mostly
// read-only (stats, info) have no focusable children, so a TV remote could
// never scroll them. This view is itself a focus stop: Up/Down (and
// Page Up/Down) scroll; Up at the very top lets focus leave normally.
// ─────────────────────────────────────────────────────────────────────────────
class TvScrollView extends StatefulWidget {
  final Widget child;
  final EdgeInsetsGeometry? padding;
  final ScrollController? controller;
  final double step;

  const TvScrollView({
    super.key,
    required this.child,
    this.padding,
    this.controller,
    this.step = 140,
  });

  @override
  State<TvScrollView> createState() => _TvScrollViewState();
}

class _TvScrollViewState extends State<TvScrollView> {
  ScrollController? _own;
  ScrollController get _ctrl =>
      widget.controller ?? (_own ??= ScrollController());
  final FocusNode _node = FocusNode(debugLabel: 'tvScrollView');
  bool _focused = false;

  @override
  void dispose() {
    _own?.dispose();
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent || !_ctrl.hasClients) return KeyEventResult.ignored;
    final pos = _ctrl.position;
    final k = event.logicalKey;
    double? delta;
    if (k == LogicalKeyboardKey.arrowDown) delta = widget.step;
    if (k == LogicalKeyboardKey.arrowUp) delta = -widget.step;
    if (k == LogicalKeyboardKey.pageDown) delta = pos.viewportDimension * 0.9;
    if (k == LogicalKeyboardKey.pageUp) delta = -pos.viewportDimension * 0.9;
    if (delta == null) return KeyEventResult.ignored;
    // At the edge → let focus traverse out (e.g. Up to the top bar).
    if (delta < 0 && pos.pixels <= pos.minScrollExtent) {
      return KeyEventResult.ignored;
    }
    if (delta > 0 && pos.pixels >= pos.maxScrollExtent) {
      return KeyEventResult.handled;
    }
    final target = (pos.pixels + delta).clamp(
      pos.minScrollExtent,
      pos.maxScrollExtent,
    );
    if (TvKeyTracker.isRepeating) {
      _ctrl.jumpTo(target);
    } else {
      _ctrl.animateTo(
        target,
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
      );
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _node,
      onKeyEvent: _onKey,
      onFocusChange: (f) => setState(() => _focused = f),
      child: Scrollbar(
        controller: _ctrl,
        thumbVisibility: _focused,
        child: SingleChildScrollView(
          controller: _ctrl,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
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

  static final Expando<FocusOnKeyEventCallback> _graph = Expando('tvNavGraph');

  /// Attaches an arrow-key navigation [handler] to [node] WITHOUT replacing
  /// `node.onKeyEvent`. (Assigning onKeyEvent directly would overwrite the
  /// TvFocusable handler on the same node and break OK/Select activation.)
  /// Consulted by [TvFocusable] before its own `onArrowKey`.
  static void wire(FocusNode node, FocusOnKeyEventCallback handler) {
    _graph[node] = handler;
  }

  static FocusOnKeyEventCallback? graphFor(FocusNode node) => _graph[node];

  /// Requests focus on [node] if it is attached to the tree; otherwise
  /// (e.g. the target list item hasn't been built yet because it is
  /// off-screen) falls back to geometric traversal in [fallback] direction
  /// from the current focus. Returns true when focus moved.
  static bool focus(FocusNode? node, {TraversalDirection? fallback}) {
    if (node != null && node.context != null && node.canRequestFocus) {
      node.requestFocus();
      return true;
    }
    if (fallback != null) {
      return FocusManager.instance.primaryFocus?.focusInDirection(fallback) ??
          false;
    }
    return false;
  }

  /// Moves focus to [target] as soon as it is attached (e.g. a button that
  /// appears once async data loads), retrying for ~2 s. Gives up silently
  /// if the user has moved focus elsewhere in the meantime.
  static void focusSoon(
    FocusNode target, {
    int tries = 14,
    Duration interval = const Duration(milliseconds: 150),
  }) {
    final origin = FocusManager.instance.primaryFocus;
    void attempt(int left) {
      if (FocusManager.instance.primaryFocus != origin) return;
      if (target.context != null && target.canRequestFocus) {
        target.requestFocus();
        return;
      }
      if (left <= 0) return;
      Future.delayed(interval, () => attempt(left - 1));
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt(tries));
  }

  /// Requests initial focus on the first attached node in [candidates]
  /// after the current frame — used to give every screen a visible starting
  /// point for remote users.
  static void focusFirstAttached(List<FocusNode? Function()> candidates) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final c in candidates) {
        final n = c();
        if (n != null && n.context != null && n.canRequestFocus) {
          n.requestFocus();
          return;
        }
      }
    });
  }

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
    KeyEventResult go(VoidCallback? cb, FocusNode? target) {
      if (cb != null) {
        cb();
        return KeyEventResult.handled;
      }
      if (target != null) {
        target.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    return (node, event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final key = event.logicalKey;
      if (key == LogicalKeyboardKey.arrowUp) return go(onUp, up);
      if (key == LogicalKeyboardKey.arrowDown) return go(onDown, down);
      if (key == LogicalKeyboardKey.arrowLeft) return go(onLeft, left);
      if (key == LogicalKeyboardKey.arrowRight) return go(onRight, right);
      return KeyEventResult.ignored;
    };
  }
}
