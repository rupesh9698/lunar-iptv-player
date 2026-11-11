import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/utils/platform_utils.dart';

/// How a locked player is unlocked on this device.
enum LockUnlockStyle {
  /// Android TV: the remote's Back button.
  tv,

  /// Desktop / web: Esc, or a click on the lock button.
  desktop,

  /// Phones / tablets: a tap on the lock button.
  touch,
}

/// What a key press does while a player is locked.
enum LockedKeyAction { unlock, hint, pass }

/// Screen lock shared by the Live TV and Movies / Series players.
///
/// While locked the player ignores every touch and key. The way out
/// depends on the device:
///  * TV      — Back on the remote (the lock can't take remote focus).
///  * Desktop — Esc, or a click on the lock button.
///  * Phone   — a tap on the lock button.
/// Anything else flashes a hint that says how to unlock. Bump [nudge] to
/// flash it from outside (key presses are handled by the player).
class PlayerLockOverlay extends StatefulWidget {
  final VoidCallback onUnlock;

  /// Change this to show the hint again.
  final int nudge;

  /// Defaults to the current device ([platformStyle]).
  final LockUnlockStyle? style;

  const PlayerLockOverlay({
    super.key,
    required this.onUnlock,
    this.nudge = 0,
    this.style,
  });

  static LockUnlockStyle get platformStyle => PlatformUtils.isTV
      ? LockUnlockStyle.tv
      : PlatformUtils.isMobile
      ? LockUnlockStyle.touch
      : LockUnlockStyle.desktop;

  static String hintText(LockUnlockStyle s) => switch (s) {
    LockUnlockStyle.tv => 'Screen locked · press BACK to unlock',
    LockUnlockStyle.desktop =>
      'Screen locked · press Esc or click the lock to unlock',
    LockUnlockStyle.touch => 'Screen locked · tap the lock to unlock',
  };

  static bool _isBack(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.escape ||
      k == LogicalKeyboardKey.goBack ||
      k == LogicalKeyboardKey.browserBack;

  /// What [event] should do while the player is locked. Volume keys keep
  /// working; Back / Esc unlocks (except on phones, where only the lock
  /// button does); every other key just shows the hint.
  static LockedKeyAction keyAction(KeyEvent event, [LockUnlockStyle? style]) {
    if (event is KeyUpEvent) return LockedKeyAction.pass;
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.audioVolumeUp ||
        k == LogicalKeyboardKey.audioVolumeDown ||
        k == LogicalKeyboardKey.audioVolumeMute) {
      return LockedKeyAction.pass;
    }
    final s = style ?? platformStyle;
    if (_isBack(k) && s != LockUnlockStyle.touch) {
      // A held Back must not unlock and then leave the player.
      return event is KeyDownEvent
          ? LockedKeyAction.unlock
          : LockedKeyAction.hint;
    }
    return LockedKeyAction.hint;
  }

  /// System back (gesture / Back button routed as a pop) while locked:
  /// unlocks on TV and desktop; on phones it only shows the hint.
  static bool backUnlocks([LockUnlockStyle? style]) =>
      (style ?? platformStyle) != LockUnlockStyle.touch;

  @override
  State<PlayerLockOverlay> createState() => _PlayerLockOverlayState();
}

class _PlayerLockOverlayState extends State<PlayerLockOverlay> {
  bool _hint = true;
  Timer? _hideTimer;

  LockUnlockStyle get _style => widget.style ?? PlayerLockOverlay.platformStyle;

  @override
  void initState() {
    super.initState();
    _armHide();
  }

  @override
  void didUpdateWidget(PlayerLockOverlay old) {
    super.didUpdateWidget(old);
    if (old.nudge != widget.nudge) _flash();
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  void _armHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(milliseconds: 2800), () {
      if (mounted) setState(() => _hint = false);
    });
  }

  void _flash() {
    if (!_hint) setState(() => _hint = true);
    _armHide();
  }

  @override
  Widget build(BuildContext context) {
    final tv = _style == LockUnlockStyle.tv;
    // Nothing here takes remote focus: on TV Back unlocks, and the player
    // keeps focus so it sees that key.
    return ExcludeFocus(
      child: Stack(
        fit: StackFit.expand,
        children: [
          // Swallows every touch / click on the picture.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            // (No double-tap: it would delay every single tap.)
            onTap: _flash,
            onLongPress: _flash,
            onVerticalDragStart: (_) => _flash(),
            onHorizontalDragStart: (_) => _flash(),
          ),
          // Lock button (right, centred). TV: only an indicator, shown
          // with the hint.
          SafeArea(
            child: Align(
              alignment: Alignment.centerRight,
              child: Padding(
                padding: const EdgeInsets.only(right: 16),
                child: AnimatedOpacity(
                  opacity: tv && !_hint ? 0 : 1,
                  duration: const Duration(milliseconds: 200),
                  child: _LockButton(
                    emphasised: _hint,
                    onTap: tv ? _flash : widget.onUnlock,
                  ),
                ),
              ),
            ),
          ),
          // How to unlock.
          SafeArea(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 36),
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _hint ? 1 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: _HintPill(text: PlayerLockOverlay.hintText(_style)),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LockButton extends StatefulWidget {
  final bool emphasised;
  final VoidCallback onTap;
  const _LockButton({required this.emphasised, required this.onTap});

  @override
  State<_LockButton> createState() => _LockButtonState();
}

class _LockButtonState extends State<_LockButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.emphasised || _hover;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: Semantics(
          button: true,
          label: 'Unlock screen',
          child: AnimatedScale(
            scale: lit ? 1.12 : 1.0,
            duration: const Duration(milliseconds: 180),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 180),
              // Generous target for thumbs.
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: lit ? 0.7 : 0.45),
                shape: BoxShape.circle,
                border: Border.all(
                  color: lit ? Colors.white : Colors.white38,
                  width: lit ? 2.5 : 1.5,
                ),
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: Colors.white,
                size: 24,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HintPill extends StatelessWidget {
  final String text;
  const _HintPill({required this.text});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(24),
      border: Border.all(color: Colors.white24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.lock_rounded, color: Colors.white, size: 18),
        const SizedBox(width: 10),
        Flexible(
          child: Text(
            text,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    ),
  );
}
