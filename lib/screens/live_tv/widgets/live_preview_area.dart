import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../services/app_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/focus_utils.dart';
import '../../../core/utils/platform_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/live_player_provider.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/web_proxy_client.dart';
import '../../player/widgets/player_channel_guide.dart';

/// Inline player for Live TV.
/// Compact mode: video (16:9) + info pane.
/// Maximized mode: full-screen with controls + channel guide.
class LiveInlinePlayer extends ConsumerStatefulWidget {
  final bool isMaximized;
  final VoidCallback onMaximize;
  final VoidCallback onMinimize;
  final FocusNode? watchNowFocusNode;
  final FocusNode? playPauseFocusNode;
  final FocusNode? Function()? categoryEntryFocus;
  final FocusNode? channelSearchFocus;
  final FocusNode? backFocusNode;

  const LiveInlinePlayer({
    super.key,
    required this.isMaximized,
    required this.onMaximize,
    required this.onMinimize,
    this.watchNowFocusNode,
    this.playPauseFocusNode,
    this.categoryEntryFocus,
    this.channelSearchFocus,
    this.backFocusNode,
  });

  @override
  ConsumerState<LiveInlinePlayer> createState() => _LiveInlinePlayerState();
}

class _LiveInlinePlayerState extends ConsumerState<LiveInlinePlayer> {
  bool _ctrlVisible = true;
  Timer? _hideTimer;
  bool _locked = false;
  // Video is always "fit to screen" (BoxFit.contain); the fill/fit toggle
  // was removed.
  static const bool _videoFill = false;
  bool _showChannelGuide = false;

  /// Android TV: lean, remote-first full-screen UI (see _onMaxKey).
  static bool get _tv => PlatformUtils.isTV;

  // Gesture
  bool _isDragging = false;
  bool _dragIsLeft = false;
  bool _showVol = false;
  bool _showBright = false;
  double _brightness = 0.5;
  final Offset _lastTap = Offset.zero;
  bool _showSkipLeft = false;
  bool _showSkipRight = false;

  // Channel switching
  LiveStream? _switchingChannel;
  int _switchCurrentIndex = -1;
  int _switchTotalChannels = 0;
  Timer? _channelSwitchTimer;

  // ── TV remote focus (maximized mode) ─────────────────────────────────────
  // Root node holds focus while the OSD is hidden so that D-pad keys reach
  // the player (channel up/down, guide) instead of invisible buttons.
  final FocusNode _maxRootFocus = FocusNode(debugLabel: 'liveMaxRoot');
  final FocusNode _maxPlayFocus = FocusNode(debugLabel: 'liveMaxPlay');
  // TV info bar buttons (top-left minimize, top-right favourite).
  final FocusNode _maxMinimizeFocus = FocusNode(debugLabel: 'liveMaxMin');
  final FocusNode _maxFavFocus = FocusNode(debugLabel: 'liveMaxFav');

  /// Where remote focus goes when the full-screen player opens: on TV the
  /// player itself (so OK opens the guide and Left/Right zap), elsewhere
  /// the play/pause button.
  FocusNode get _maxEntryFocus => _tv ? _maxRootFocus : _maxPlayFocus;

  @override
  void initState() {
    super.initState();
    widget.playPauseFocusNode?.addListener(_onMiniPlayFocus);
    _resetHideTimer();
    if (widget.isMaximized) _focusAfterFrame(_maxEntryFocus);
  }

  @override
  void didUpdateWidget(LiveInlinePlayer old) {
    super.didUpdateWidget(old);
    if (old.playPauseFocusNode != widget.playPauseFocusNode) {
      old.playPauseFocusNode?.removeListener(_onMiniPlayFocus);
      widget.playPauseFocusNode?.addListener(_onMiniPlayFocus);
    }
    if (old.isMaximized != widget.isMaximized) {
      // Windows/macOS/Linux: real full screen (covers title bar + taskbar).
      PlatformUtils.setDesktopFullScreen(widget.isMaximized);
      setState(() {
        _ctrlVisible = true;
        _showChannelGuide = false;
      });
      _resetHideTimer();
      // Move remote focus into the new layout — the previously focused
      // button no longer exists.
      _focusAfterFrame(
        widget.isMaximized ? _maxEntryFocus : widget.watchNowFocusNode,
      );
    }
  }

  @override
  void dispose() {
    widget.playPauseFocusNode?.removeListener(_onMiniPlayFocus);
    _hideTimer?.cancel();
    _channelSwitchTimer?.cancel();
    _maxRootFocus.dispose();
    _maxPlayFocus.dispose();
    _maxMinimizeFocus.dispose();
    if (widget.isMaximized) PlatformUtils.setDesktopFullScreen(false);
    _maxFavFocus.dispose();
    super.dispose();
  }

  void _focusAfterFrame(FocusNode? node) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node != null && node.context != null) {
        node.requestFocus();
      }
    });
  }

  /// Keep the compact overlay visible while its play/pause has remote focus
  /// (otherwise the focused button fades out and the user loses track).
  void _onMiniPlayFocus() {
    if (widget.playPauseFocusNode?.hasFocus ?? false) _resetHideTimer();
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_ctrlVisible && mounted) setState(() => _ctrlVisible = true);
    _hideTimer = Timer(Duration(seconds: _tv ? 6 : 4), () {
      if (!mounted || _locked) return;
      if (!widget.isMaximized &&
          (widget.playPauseFocusNode?.hasFocus ?? false)) {
        _resetHideTimer();
        return;
      }
      _hideControls();
    });
  }

  void _hideControls() {
    setState(() => _ctrlVisible = false);
    // Park focus on the player root so keys aren't sent to hidden buttons.
    // Only when focus is inside the player — never steal it from a dialog.
    if (widget.isMaximized && !_showChannelGuide && _maxRootFocus.hasFocus) {
      _maxRootFocus.requestFocus();
    }
  }

  void _showControls({bool focusPlay = false}) {
    _resetHideTimer();
    if (focusPlay) _focusAfterFrame(_tv ? _maxMinimizeFocus : _maxPlayFocus);
  }

  void _openGuide() {
    _hideTimer?.cancel();
    setState(() {
      _showChannelGuide = true;
      _ctrlVisible = false;
    });
  }

  void _closeGuide() {
    setState(() => _showChannelGuide = false);
    _maxRootFocus.requestFocus();
  }

  void _toggleControls() {
    if (_locked) return;
    if (_ctrlVisible) {
      _hideTimer?.cancel();
      _hideControls();
    } else {
      _resetHideTimer();
    }
  }

  static bool _isOk(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.space ||
      k == LogicalKeyboardKey.gameButtonA;

  static bool _isArrow(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.arrowUp ||
      k == LogicalKeyboardKey.arrowDown ||
      k == LogicalKeyboardKey.arrowLeft ||
      k == LogicalKeyboardKey.arrowRight;

  /// Maximized-player key handling (TV remote / keyboard).
  ///
  ///  Focus on the player (normal state):
  ///    Left / Right  → previous / next channel
  ///    OK            → TV Guide (TV) · show controls (touch/desktop)
  ///    Up / Down     → show the info bar / controls
  ///  Focus on an info-bar button (TV): Left/Right move between Minimize and
  ///    Favourite, Up/Down return to the player, OK activates.
  ///  Always: CH+/CH−/PgUp/PgDn zap, Play/Pause media key, G = guide,
  ///    Back/Esc = minimize to the Live TV screen (never straight to Home).
  KeyEventResult _onMaxKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final k = event.logicalKey;
    final isDown = event is KeyDownEvent;

    if (k == LogicalKeyboardKey.keyG) {
      if (isDown) _showChannelGuide ? _closeGuide() : _openGuide();
      return KeyEventResult.handled;
    }
    if (_showChannelGuide) return KeyEventResult.ignored;

    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (isDown) widget.onMinimize();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.channelUp) {
      if (isDown) _switchChannel(-1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.pageDown ||
        k == LogicalKeyboardKey.channelDown) {
      if (isDown) _switchChannel(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.mediaPlayPause ||
        k == LogicalKeyboardKey.mediaPlay ||
        k == LogicalKeyboardKey.mediaPause) {
      if (isDown) ref.read(livePlayerProvider.notifier).togglePlayPause();
      return KeyEventResult.handled;
    }

    if (_locked) {
      // Lock is a touch feature — OK on the remote unlocks.
      if (_isOk(k)) {
        if (isDown) {
          setState(() => _locked = false);
          _showControls(focusPlay: true);
        }
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    final onPlayer = node.hasPrimaryFocus || !_ctrlVisible;
    if (onPlayer) {
      if (k == LogicalKeyboardKey.arrowLeft ||
          k == LogicalKeyboardKey.arrowRight) {
        if (isDown) _switchChannel(k == LogicalKeyboardKey.arrowLeft ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (_isOk(k)) {
        if (isDown) _tv ? _openGuide() : _showControls(focusPlay: true);
        return KeyEventResult.handled;
      }
      if (k == LogicalKeyboardKey.arrowUp ||
          k == LogicalKeyboardKey.arrowDown) {
        if (isDown) _showControls(focusPlay: true);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // Focus is on a visible control: keep the overlay alive while navigating.
    _resetHideTimer();
    if (_tv &&
        (k == LogicalKeyboardKey.arrowLeft ||
            k == LogicalKeyboardKey.arrowRight)) {
      // Info bar has exactly two buttons: Minimize (left) ↔ Favourite.
      if (isDown) {
        final target = k == LogicalKeyboardKey.arrowLeft
            ? _maxMinimizeFocus
            : _maxFavFocus;
        if (target.context != null) target.requestFocus();
      }
      return KeyEventResult.handled;
    }
    if (_tv &&
        (k == LogicalKeyboardKey.arrowUp ||
            k == LogicalKeyboardKey.arrowDown)) {
      // Leave the info bar → back to the player.
      if (isDown) {
        _maxRootFocus.requestFocus();
        _hideTimer?.cancel();
        _hideControls();
      }
      return KeyEventResult.handled;
    }
    // Contain D-pad traversal inside the full-screen player: an unhandled
    // arrow must never escape to the (covered) sidebar / EPG panels.
    if (_isArrow(k)) {
      final dir = switch (k) {
        LogicalKeyboardKey.arrowUp => TraversalDirection.up,
        LogicalKeyboardKey.arrowDown => TraversalDirection.down,
        LogicalKeyboardKey.arrowLeft => TraversalDirection.left,
        _ => TraversalDirection.right,
      };
      FocusManager.instance.primaryFocus?.focusInDirection(dir);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  void _switchChannel(int delta) {
    final streams = ref.read(filteredLiveStreamsProvider).value;
    if (streams == null || streams.isEmpty) return;
    final current = ref.read(selectedChannelProvider);
    if (current == null) return;
    final idx = streams.indexWhere((s) => s.streamId == current.streamId);
    final base = idx < 0 ? 0 : idx;
    final newIdx = (base + delta).clamp(0, streams.length - 1);
    if (newIdx == base) return;
    final newChannel = streams[newIdx];

    ref.read(selectedChannelProvider.notifier).state = newChannel;
    ref.read(epgCacheProvider.notifier).loadEpg(newChannel.streamId);
    ref.read(recentlyViewedLiveProvider.notifier).add(newChannel.streamId);

    _channelSwitchTimer?.cancel();
    if (mounted) {
      setState(() {
        _switchingChannel = newChannel;
        _switchCurrentIndex = newIdx;
        _switchTotalChannels = streams.length;
      });
      // Keep the banner until the new stream is actually playing (the
      // picture is black while it connects) — min 2 s, max 8 s.
      final shownAt = DateTime.now();
      _channelSwitchTimer = Timer.periodic(
        const Duration(milliseconds: 400),
        (t) {
          if (!mounted) {
            t.cancel();
            return;
          }
          final elapsed = DateTime.now().difference(shownAt);
          final ps = ref.read(livePlayerProvider);
          final started = ps.isPlaying && !ps.isBuffering;
          if ((elapsed >= const Duration(seconds: 2) && started) ||
              elapsed >= const Duration(seconds: 8) ||
              ps.error.isNotEmpty) {
            t.cancel();
            setState(() => _switchingChannel = null);
          }
        },
      );
    }
  }

  void _onDoubleTap() {
    if (_locked) return;
    final w = MediaQuery.of(context).size.width;
    if (_lastTap.dx < w / 3) {
      setState(() => _showSkipLeft = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showSkipLeft = false);
      });
    } else if (_lastTap.dx > w * 2 / 3) {
      setState(() => _showSkipRight = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showSkipRight = false);
      });
    } else {
      ref.read(livePlayerProvider.notifier).togglePlayPause();
    }
  }

  void _onDragStart(DragStartDetails d) {
    _isDragging = true;
    _dragIsLeft = d.localPosition.dx < MediaQuery.of(context).size.width / 2;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (!_isDragging || _locked) return;
    final delta = -d.delta.dy / (MediaQuery.of(context).size.height * 0.5);
    if (_dragIsLeft) {
      if (PlatformUtils.isMobile) {
        setState(() {
          _brightness = (_brightness + delta).clamp(0.0, 1.0);
          _showBright = true;
        });
        PlatformUtils.setBrightness(_brightness);
      }
    } else {
      final nv = (ref.read(livePlayerProvider).volume + delta).clamp(0.0, 1.0);
      ref.read(livePlayerProvider.notifier).setVolume(nv);
      setState(() => _showVol = true);
    }
  }

  void _onDragEnd(DragEndDetails _) {
    _isDragging = false;
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showVol = false;
          _showBright = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ps = ref.watch(livePlayerProvider);
    final channel = ref.watch(selectedChannelProvider);
    final epgCache = ref.watch(epgCacheProvider);
    final ctrl = ref.read(livePlayerProvider.notifier).videoController;
    final epg = channel != null
        ? (epgCache[channel.streamId] ?? [])
        : <EpgListing>[];
    // By the clock — never "the first listing" (which was days old).
    final current = epg.currentAt();
    final next = epg.nextAt();

    return widget.isMaximized
        ? _buildMaximized(context, ps, channel, current, next, ctrl)
        : _buildCompact(context, ps, channel, current, next, ctrl);
  }

  // ── COMPACT MODE ──────────────────────────────────────────────────────────
  Widget _buildCompact(
    BuildContext context,
    LivePlayerState ps,
    LiveStream? channel,
    EpgListing? current,
    EpgListing? next,
    VideoController? ctrl,
  ) {
    if (channel == null) {
      return Container(
        color: AppTheme.surface,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.tv_outlined, color: AppTheme.textMuted, size: 36),
              SizedBox(height: 8),
              Text(
                'Select a channel from the EPG to preview',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    return Focus(
      // Intercept Select/OK in compact mode → maximize player
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter)) {
          widget.onMaximize();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Container(
        color: AppTheme.surface,
        child: Row(
          children: [
            // Video (16:9)
            AspectRatio(
              aspectRatio: 16 / 9,
              child: _VideoArea(
                ctrl: ctrl,
                ps: ps,
                videoFill: _videoFill,
                ctrlVisible: _ctrlVisible,
                onTap: _toggleControls,
                onDoubleTap: widget.onMaximize,
                overlay: _compactOverlay(ps),
              ),
            ),
            // Info pane
            Expanded(
              child: _InfoPane(
                channel: channel,
                current: current,
                next: next,
                ps: ps,
                onWatchNow: widget.onMaximize,
                watchNowFocusNode: widget.watchNowFocusNode,
                onTogglePlay: () =>
                    ref.read(livePlayerProvider.notifier).togglePlayPause(),
                onVolumeChange: (v) =>
                    ref.read(livePlayerProvider.notifier).setVolume(v),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _compactOverlay(LivePlayerState ps) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 0),
          child: Row(
            children: [
              if (ps.quality.isNotEmpty) _QualityBadge(ps.quality),
              const Spacer(),
              _OverlayBtn(
                icon: Icons.fullscreen_rounded,
                tooltip: 'Maximize',
                onTap: widget.onMaximize,
              ),
            ],
          ),
        ),
        const Spacer(),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            children: [
              _PlayPauseFocusBtn(
                focusNode: widget.playPauseFocusNode,
                isPlaying: ps.isPlaying,
                onTap: () =>
                    ref.read(livePlayerProvider.notifier).togglePlayPause(),
                onUp: () => widget.backFocusNode?.requestFocus(),
                onDown: () => widget.channelSearchFocus?.requestFocus(),
                onLeft: () => widget.categoryEntryFocus?.call()?.requestFocus(),
                onRight: () => widget.watchNowFocusNode?.requestFocus(),
              ),
              // TV: volume belongs to the remote's volume keys.
              if (!_tv) ...[
              const SizedBox(width: 4),
              Icon(
                ps.volume > 0.5
                    ? Icons.volume_up
                    : ps.volume > 0
                    ? Icons.volume_down
                    : Icons.volume_off,
                color: Colors.white70,
                size: 14,
              ),
              SizedBox(
                width: 52,
                // Not reachable by D-pad (would trap focus) — remote users
                // have hardware volume keys.
                child: ExcludeFocus(
                child: SliderTheme(
                  data: SliderThemeData(
                    trackHeight: 1.5,
                    thumbShape: const RoundSliderThumbShape(
                      enabledThumbRadius: 4,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 8,
                    ),
                    activeTrackColor: Colors.white,
                    inactiveTrackColor: Colors.white30,
                    thumbColor: Colors.white,
                    overlayColor: Colors.white24,
                  ),
                  child: Slider(
                    value: ps.volume,
                    onChanged: (v) =>
                        ref.read(livePlayerProvider.notifier).setVolume(v),
                  ),
                ),
                ),
              ),
              ],
              const Spacer(),
              _LiveBadge(),
            ],
          ),
        ),
      ],
    );
  }

  // ── MAXIMIZED MODE ────────────────────────────────────────────────────────
  Widget _buildMaximized(
    BuildContext context,
    LivePlayerState ps,
    LiveStream? channel,
    EpgListing? current,
    EpgListing? next,
    VideoController? ctrl,
  ) {
    return Focus(
      focusNode: _maxRootFocus,
      autofocus: !_showChannelGuide,
      onKeyEvent: _onMaxKey,
      child: Material(
        color: Colors.black,
        child: Stack(
          children: [
            // Video
            Positioned.fill(
              child: ps.error == WebProxyClient.webHttpStreamError
                  ? _WebStreamError(channel: channel)
                  : _VideoArea(
                      ctrl: ctrl,
                      ps: ps,
                      videoFill: _videoFill,
                      ctrlVisible: _ctrlVisible,
                      onTap: _showChannelGuide ? _closeGuide : _toggleControls,
                      onDoubleTap: _showChannelGuide ? null : _onDoubleTap,
                      onDragStart: _onDragStart,
                      onDragUpdate: _onDragUpdate,
                      onDragEnd: _onDragEnd,
                    ),
            ),

            // Buffering
            if (ps.isBuffering && ps.error.isEmpty && !ps.isReconnecting)
              const Positioned(bottom: 80, right: 20, child: _BufferingBadge()),

            // Reconnect
            if (ps.isReconnecting)
              Center(
                child: _ReconnectOverlay(
                  attempt: ps.reconnectAttempt,
                  onCancel: () =>
                      ref.read(livePlayerProvider.notifier).clearError(),
                ),
              ),

            // Controls overlay
            if (!_locked &&
                ps.error.isEmpty &&
                !ps.isReconnecting &&
                !_showChannelGuide)
              AnimatedOpacity(
                opacity: _ctrlVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                // Hidden controls must not hold remote focus.
                child: ExcludeFocus(
                  excluding: !_ctrlVisible,
                  child: IgnorePointer(
                  ignoring: !_ctrlVisible,
                  child: _tv
                      ? _TvInfoBar(
                          channel: channel,
                          ps: ps,
                          current: current,
                          next: next,
                          isFavorite: ref
                              .watch(liveFavoritesNotifierProvider)
                              .contains(channel?.streamId ?? ''),
                          minimizeFocus: _maxMinimizeFocus,
                          favoriteFocus: _maxFavFocus,
                          onMinimize: widget.onMinimize,
                          onToggleFav: channel != null
                              ? () => ref
                                    .read(
                                      liveFavoritesNotifierProvider.notifier,
                                    )
                                    .toggle(channel.streamId)
                              : null,
                        )
                      : _MaximizedControls(
                    playFocusNode: _maxPlayFocus,
                    channel: channel,
                    ps: ps,
                    isVideoFill: _videoFill,
                    isFavorite: ref
                        .watch(liveFavoritesNotifierProvider)
                        .contains(channel?.streamId ?? ''),
                    onMinimize: widget.onMinimize,
                    onLock: () => setState(() => _locked = true),
                    onTogglePlay: () =>
                        ref.read(livePlayerProvider.notifier).togglePlayPause(),
                    onVolumeChange: (v) =>
                        ref.read(livePlayerProvider.notifier).setVolume(v),
                    onToggleFav: channel != null
                        ? () => ref
                              .read(liveFavoritesNotifierProvider.notifier)
                              .toggle(channel.streamId)
                        : null,
                    onPrevChannel: () => _switchChannel(-1),
                    onNextChannel: () => _switchChannel(1),
                    onToggleGuide: () =>
                        setState(() => _showChannelGuide = true),
                  ),
                ),
                ),
              ),

            // Lock overlay
            if (_locked)
              _LockOverlay(onUnlock: () => setState(() => _locked = false)),

            // Skip indicators
            if (_showSkipLeft)
              const Positioned(
                left: 32,
                top: 0,
                bottom: 0,
                child: Center(child: _SkipIndicator(forward: false)),
              ),
            if (_showSkipRight)
              const Positioned(
                right: 32,
                top: 0,
                bottom: 0,
                child: Center(child: _SkipIndicator(forward: true)),
              ),

            // Volume / Brightness
            if (_showVol)
              Center(
                child: _GestureOverlay(
                  icon: ref.read(livePlayerProvider).volume > 0.5
                      ? Icons.volume_up_rounded
                      : ref.read(livePlayerProvider).volume > 0
                      ? Icons.volume_down_rounded
                      : Icons.volume_off_rounded,
                  value: ref.read(livePlayerProvider).volume,
                  color: Colors.white,
                ),
              ),
            if (_showBright)
              Center(
                child: _GestureOverlay(
                  icon: _brightness > 0.5
                      ? Icons.brightness_high_rounded
                      : Icons.brightness_low_rounded,
                  value: _brightness,
                  color: Colors.amber,
                ),
              ),

            // Channel switch overlay
            if (_switchingChannel != null)
              _ChannelSwitchOverlay(
                channel: _switchingChannel!,
                currentIndex: _switchCurrentIndex,
                totalChannels: _switchTotalChannels,
              ),

            // Channel Guide panel
            if (_showChannelGuide)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: PlayerChannelGuide(
                  onMinimize: () {
                    setState(() => _showChannelGuide = false);
                    widget.onMinimize();
                  },
                  onClose: _closeGuide,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VIDEO AREA
// ─────────────────────────────────────────────────────────────────────────────
class _VideoArea extends StatelessWidget {
  final VideoController? ctrl;
  final LivePlayerState ps;
  final bool videoFill;
  final bool ctrlVisible;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;
  final GestureDragStartCallback? onDragStart;
  final GestureDragUpdateCallback? onDragUpdate;
  final GestureDragEndCallback? onDragEnd;
  final Widget? overlay;

  const _VideoArea({
    required this.ctrl,
    required this.ps,
    required this.videoFill,
    required this.ctrlVisible,
    required this.onTap,
    this.onDoubleTap,
    this.onDragStart,
    this.onDragUpdate,
    this.onDragEnd,
    this.overlay,
  });

  @override
  Widget build(BuildContext context) {
    if (ps.error.isNotEmpty && ps.error != WebProxyClient.webHttpStreamError) {
      return Container(
        color: Colors.black,
        child: const Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, color: Colors.white54, size: 32),
            SizedBox(height: 8),
            Text(
              'Stream unavailable',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      );
    }

    if (ctrl == null) {
      return Container(
        color: Colors.black,
        child: const Center(
          child: CircularProgressIndicator(
            color: AppTheme.primary,
            strokeWidth: 2,
          ),
        ),
      );
    }

    return ClipRect(
      child: Stack(
        fit: StackFit.expand,
        children: [
          Video(
            controller: ctrl!,
            fit: videoFill ? BoxFit.cover : BoxFit.contain,
            controls: NoVideoControls,
          ),
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: onTap,
              onDoubleTap: onDoubleTap,
              onVerticalDragStart: onDragStart,
              onVerticalDragUpdate: onDragUpdate,
              onVerticalDragEnd: onDragEnd,
            ),
          ),
          if (overlay != null)
            Positioned.fill(
              child: AnimatedOpacity(
                opacity: ctrlVisible ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 200),
                child: IgnorePointer(
                  ignoring: !ctrlVisible,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.black.withValues(alpha: 0.65),
                          Colors.transparent,
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.75),
                        ],
                        stops: const [0.0, 0.3, 0.7, 1.0],
                      ),
                    ),
                    child: overlay,
                  ),
                ),
              ),
            ),
          if (ps.isBuffering && overlay != null)
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 1.5,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MAXIMIZED CONTROLS
// ─────────────────────────────────────────────────────────────────────────────
class _MaximizedControls extends StatelessWidget {
  final FocusNode? playFocusNode;
  final LiveStream? channel;
  final LivePlayerState ps;
  final bool isVideoFill;
  final bool isFavorite;
  final VoidCallback onMinimize;
  final VoidCallback onLock;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChange;
  final VoidCallback? onToggleFav;
  final VoidCallback onPrevChannel;
  final VoidCallback onNextChannel;
  final VoidCallback onToggleGuide;

  const _MaximizedControls({
    this.playFocusNode,
    required this.channel,
    required this.ps,
    required this.isVideoFill,
    required this.isFavorite,
    required this.onMinimize,
    required this.onLock,
    required this.onTogglePlay,
    required this.onVolumeChange,
    required this.onToggleFav,
    required this.onPrevChannel,
    required this.onNextChannel,
    required this.onToggleGuide,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.black.withValues(alpha: 0.80),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.85),
          ],
          stops: const [0.0, 0.18, 0.78, 1.0],
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onMinimize,
                    icon: const Icon(
                      Icons.fullscreen_exit_rounded,
                      color: Colors.white,
                      size: 24,
                    ),
                    tooltip: 'Minimize',
                  ),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          channel?.name ?? '',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(color: Colors.black, blurRadius: 6),
                            ],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const Row(
                          children: [
                            _LiveDot(),
                            SizedBox(width: 4),
                            Text(
                              'LIVE',
                              style: TextStyle(
                                color: AppTheme.error,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (ps.quality.isNotEmpty) ...[
                    _QualityBadge(ps.quality),
                    const SizedBox(width: 6),
                  ],
                  if (onToggleFav != null)
                    IconButton(
                      onPressed: onToggleFav,
                      icon: Icon(
                        isFavorite ? Icons.favorite : Icons.favorite_border,
                        color: isFavorite ? AppTheme.error : Colors.white,
                        size: 22,
                      ),
                    ),
                  IconButton(
                    onPressed: onLock,
                    icon: const Icon(
                      Icons.lock_outline,
                      color: Colors.white,
                      size: 22,
                    ),
                    tooltip: 'Lock',
                  ),
                ],
              ),
            ),

            const Spacer(),

            // Center play — focusable so the remote has an anchor
            TvFocusable(
              focusNode: playFocusNode,
              autoScroll: false,
              onActivate: onTogglePlay,
              builder: (focused, _) => AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: focused ? 0.28 : 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: focused
                        ? AppTheme.primary
                        : Colors.white.withValues(alpha: 0.35),
                    width: focused ? 3 : 1.5,
                  ),
                ),
                child: Icon(
                  ps.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 34,
                ),
              ),
            ),

            const Spacer(),

            // Bottom bar
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Row(
                children: [
                  IconButton(
                    onPressed: onTogglePlay,
                    padding: const EdgeInsets.all(8),
                    icon: Icon(
                      ps.isPlaying
                          ? Icons.pause_rounded
                          : Icons.play_arrow_rounded,
                      color: Colors.white,
                      size: 30,
                    ),
                  ),
                  _ChannelBtn(
                    icon: Icons.skip_previous_rounded,
                    tooltip: 'Previous Channel',
                    onTap: onPrevChannel,
                  ),
                  _ChannelBtn(
                    icon: Icons.skip_next_rounded,
                    tooltip: 'Next Channel',
                    onTap: onNextChannel,
                  ),
                  _ChannelBtn(
                    icon: Icons.video_library_outlined,
                    tooltip: 'Channel Guide (G)',
                    onTap: onToggleGuide,
                  ),
                  const Spacer(),
                  Icon(
                    ps.volume > 0.5 ? Icons.volume_up : Icons.volume_off,
                    color: Colors.white,
                    size: 20,
                  ),
                  SizedBox(
                    width: 96,
                    child: TvSlider(
                      value: ps.volume,
                      onChanged: onVolumeChange,
                      theme: const SliderThemeData(
                        trackHeight: 2,
                        thumbShape: RoundSliderThumbShape(
                          enabledThumbRadius: 5,
                        ),
                        overlayShape: RoundSliderOverlayShape(
                          overlayRadius: 10,
                        ),
                        activeTrackColor: Colors.white,
                        inactiveTrackColor: Colors.white30,
                        thumbColor: Colors.white,
                      ),
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
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _ChannelBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_ChannelBtn> createState() => _ChannelBtnState();
}

class _ChannelBtnState extends State<_ChannelBtn> {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onActivate: widget.onTap,
      builder: (focused, _) => Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: focused
                ? Colors.white.withValues(alpha: 0.2)
                : Colors.transparent,
            border: focused
                ? Border.all(color: Colors.white.withValues(alpha: 0.55))
                : null,
          ),
          child: Icon(widget.icon, color: Colors.white, size: 24),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// INFO PANE (compact right side)
// ─────────────────────────────────────────────────────────────────────────────
class _InfoPane extends StatelessWidget {
  final LiveStream channel;
  final EpgListing? current;
  final EpgListing? next;
  final LivePlayerState ps;
  final VoidCallback onWatchNow;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChange;
  final FocusNode? watchNowFocusNode;

  const _InfoPane({
    required this.channel,
    required this.current,
    required this.next,
    required this.ps,
    required this.onWatchNow,
    required this.onTogglePlay,
    required this.onVolumeChange,
    this.watchNowFocusNode,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 6, 14, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  channel.name,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              _LiveBadge(),
              if (ps.quality.isNotEmpty) ...[
                const SizedBox(width: 6),
                _QualityBadge(ps.quality),
              ],
            ],
          ),

          const SizedBox(height: 4),

          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (current != null) ...[
                    const _Label('NOW PLAYING'),
                    const SizedBox(height: 4),
                    Text(
                      current!.decodedTitle,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 5),
                    Row(
                      children: [
                        Text(
                          '${DateFormat('HH:mm').format(current!.startTime)} – '
                          '${DateFormat('HH:mm').format(current!.endTime)}',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${current!.endTime.difference(DateTime.now()).inMinutes.clamp(0, 9999)} min',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(3),
                      child: LinearProgressIndicator(
                        value: current!.progress,
                        minHeight: 3,
                        backgroundColor: AppTheme.primary.withValues(
                          alpha: 0.15,
                        ),
                        valueColor: const AlwaysStoppedAnimation<Color>(
                          AppTheme.primary,
                        ),
                      ),
                    ),
                    if (current!.decodedDescription.isNotEmpty) ...[
                      const SizedBox(height: 5),
                      Text(
                        current!.decodedDescription,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 11,
                          height: 1.4,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ] else
                    const Text(
                      'No EPG data available',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  if (next != null) ...[
                    const SizedBox(height: 8),
                    const _Label('UP NEXT'),
                    const SizedBox(height: 3),
                    Text(
                      next!.decodedTitle,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '${DateFormat('HH:mm').format(next!.startTime)} – '
                      '${DateFormat('HH:mm').format(next!.endTime)}',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 11,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),

          const SizedBox(height: 8),

          SizedBox(
            width: double.infinity,
            child: _FocusableElevatedButton(
              focusNode: watchNowFocusNode,
              label: 'Watch Now',
              icon: Icons.fullscreen_rounded,
              onTap: onWatchNow,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FOCUSABLE ELEVATED BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _FocusableElevatedButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const _FocusableElevatedButton({
    required this.label,
    required this.icon,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_FocusableElevatedButton> createState() =>
      _FocusableElevatedButtonState();
}

class _FocusableElevatedButtonState extends State<_FocusableElevatedButton> {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      autoScroll: false,
      onActivate: widget.onTap,
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: focused
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.70),
                  width: 2,
                )
              : null,
        ),
        // ExcludeFocus: the outer TvFocusable is the one D-pad stop (the
        // inner Material button was a second, un-wired focus target).
        child: ExcludeFocus(
          child: ElevatedButton.icon(
          onPressed: widget.onTap,
          icon: Icon(widget.icon, size: 18),
          label: Text(widget.label),
          style: ElevatedButton.styleFrom(
            backgroundColor: focused
                ? AppTheme.primary.withValues(alpha: 0.9)
                : AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 8),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WEB HTTP STREAM ERROR
// ─────────────────────────────────────────────────────────────────────────────
class _WebStreamError extends StatelessWidget {
  final LiveStream? channel;
  const _WebStreamError({this.channel});

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Center(
        child: Container(
          padding: const EdgeInsets.all(28),
          constraints: const BoxConstraints(maxWidth: 420),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.divider),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.signal_wifi_off_rounded,
                color: AppTheme.warning,
                size: 40,
              ),
              const SizedBox(height: 16),
              Text(
                channel?.name ?? 'Stream',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              const Text(
                'This channel uses an HTTP stream which browsers\n'
                'block on HTTPS pages. Use our Android or Windows\n'
                'app for full streaming support.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/live-tv'),
                      icon: const Icon(Icons.arrow_back, size: 16),
                      label: const Text('Back to Guide'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.textSecondary,
                        side: const BorderSide(color: AppTheme.divider),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SMALL REUSABLE WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: AppTheme.error,
      borderRadius: BorderRadius.circular(5),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _LiveDot(),
        SizedBox(width: 4),
        Text(
          'LIVE',
          style: TextStyle(
            color: Colors.white,
            fontSize: 9,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();

  @override
  Widget build(BuildContext context) => Container(
    width: 5,
    height: 5,
    decoration: const BoxDecoration(
      color: Colors.white,
      shape: BoxShape.circle,
    ),
  );
}

class _QualityBadge extends StatelessWidget {
  final String quality;
  const _QualityBadge(this.quality);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
    ),
    child: Text(
      quality,
      style: const TextStyle(
        color: Colors.white,
        fontSize: 9,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _OverlayBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;
  const _OverlayBtn({required this.icon, required this.onTap, this.tooltip});
  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Tooltip(
      message: tooltip ?? '',
      child: Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Icon(icon, color: Colors.white, size: 16),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PLAY/PAUSE BUTTON — mini-player, fully focusable with explicit nav graph.
// ─────────────────────────────────────────────────────────────────────────────
class _PlayPauseFocusBtn extends StatelessWidget {
  final FocusNode? focusNode;
  final bool isPlaying;
  final VoidCallback onTap;
  final VoidCallback? onUp;
  final VoidCallback? onDown;
  final VoidCallback? onLeft;
  final VoidCallback? onRight;

  const _PlayPauseFocusBtn({
    required this.focusNode,
    required this.isPlaying,
    required this.onTap,
    this.onUp,
    this.onDown,
    this.onLeft,
    this.onRight,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: focusNode,
      autoScroll: false,
      onActivate: onTap,
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          (onUp ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          (onDown ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          (onLeft ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          (onRight ?? () {})();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (focused, _) => Container(
        padding: const EdgeInsets.all(5),
        decoration: BoxDecoration(
          color: focused
              ? AppTheme.primary.withValues(alpha: 0.85)
              : Colors.black.withValues(alpha: 0.6),
          borderRadius: BorderRadius.circular(6),
          border: focused
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.7),
                  width: 1.5,
                )
              : null,
        ),
        child: Icon(
          isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 16,
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: const TextStyle(
      color: AppTheme.textMuted,
      fontSize: 9,
      fontWeight: FontWeight.w700,
      letterSpacing: 1,
    ),
  );
}

class _BufferingBadge extends StatelessWidget {
  const _BufferingBadge();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(8),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 14,
          height: 14,
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 1.5,
          ),
        ),
        SizedBox(width: 8),
        Text(
          'Buffering...',
          style: TextStyle(color: Colors.white, fontSize: 12),
        ),
      ],
    ),
  );
}

class _ReconnectOverlay extends StatelessWidget {
  final int attempt;
  final VoidCallback onCancel;
  const _ReconnectOverlay({required this.attempt, required this.onCancel});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(
          width: 32,
          height: 32,
          child: CircularProgressIndicator(
            color: Colors.white,
            strokeWidth: 2.5,
          ),
        ),
        const SizedBox(height: 16),
        Text(
          'Reconnecting ($attempt/3)',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Stream interrupted — retrying...',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: onCancel,
          child: const Text('Cancel', style: TextStyle(color: Colors.white70)),
        ),
      ],
    ),
  );
}

class _LockOverlay extends StatelessWidget {
  final VoidCallback onUnlock;
  const _LockOverlay({required this.onUnlock});

  @override
  Widget build(BuildContext context) => SafeArea(
    child: Align(
      alignment: Alignment.centerRight,
      child: TvFocusable(
        autofocus: true,
        autoScroll: false,
        onActivate: onUnlock,
        builder: (focused, _) => Container(
          margin: const EdgeInsets.only(right: 16),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.55),
            shape: BoxShape.circle,
            border: Border.all(
              color: focused ? Colors.white : Colors.white30,
              width: focused ? 2.5 : 1.5,
            ),
          ),
          child: const Icon(Icons.lock_rounded, color: Colors.white, size: 22),
        ),
      ),
    ),
  );
}

class _SkipIndicator extends StatelessWidget {
  final bool forward;
  const _SkipIndicator({required this.forward});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(40),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
          color: Colors.white,
          size: 28,
        ),
        const SizedBox(height: 4),
        Text(
          forward ? '+10s' : '-10s',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

class _GestureOverlay extends StatelessWidget {
  final IconData icon;
  final double value;
  final Color color;
  const _GestureOverlay({
    required this.icon,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.6),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 30),
        const SizedBox(height: 10),
        SizedBox(
          width: 120,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: value,
              minHeight: 6,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(color),
            ),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '${(value * 100).round()}%',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL SWITCH OVERLAY
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelSwitchOverlay extends StatelessWidget {
  final LiveStream channel;
  final int currentIndex;
  final int totalChannels;
  const _ChannelSwitchOverlay({
    required this.channel,
    required this.currentIndex,
    required this.totalChannels,
  });

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: 20,
      top: 0,
      bottom: 0,
      child: Center(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          constraints: const BoxConstraints(maxWidth: 180),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.82),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.5),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.15),
                blurRadius: 20,
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (channel.streamIcon?.isNotEmpty == true)
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: CachedNetworkImage(
                    imageUrl: channel.streamIcon!,
                    cacheManager: AppCacheManager.instance,
                    width: 80,
                    height: 54,
                    memCacheWidth: 160,
                    fit: BoxFit.contain,
                    placeholder: (_, _) =>
                        const Icon(Icons.tv, color: Colors.white54, size: 32),
                    errorWidget: (_, _, _) =>
                        const Icon(Icons.tv, color: Colors.white54, size: 32),
                  ),
                )
              else
                const Icon(Icons.tv, color: Colors.white54, size: 36),
              const SizedBox(height: 10),
              if (channel.num.isNotEmpty && channel.num != '0')
                Text(
                  'CH ${channel.num}',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              Text(
                channel.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 6),
              Container(
                height: 2,
                width: 80,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(1),
                  color: Colors.white.withValues(alpha: 0.15),
                ),
                child: FractionallySizedBox(
                  alignment: Alignment.centerLeft,
                  widthFactor: totalChannels > 1
                      ? currentIndex / (totalChannels - 1)
                      : 1.0,
                  child: Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1),
                      color: AppTheme.primary,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '${currentIndex + 1} / $totalChannels',
                style: const TextStyle(color: Colors.white38, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TV INFO BAR — the only overlay on Android TV in full screen.
// Top-left: Minimize · title / LIVE / now & next · top-right: Favourite.
// No play/pause, prev/next, guide, volume or fit buttons: the remote has
// dedicated keys (◀ ▶ channels, OK guide, volume keys).
// ─────────────────────────────────────────────────────────────────────────────
class _TvInfoBar extends StatelessWidget {
  final LiveStream? channel;
  final LivePlayerState ps;
  final EpgListing? current;
  final EpgListing? next;
  final bool isFavorite;
  final FocusNode minimizeFocus;
  final FocusNode favoriteFocus;
  final VoidCallback onMinimize;
  final VoidCallback? onToggleFav;

  const _TvInfoBar({
    required this.channel,
    required this.ps,
    required this.current,
    required this.next,
    required this.isFavorite,
    required this.minimizeFocus,
    required this.favoriteFocus,
    required this.onMinimize,
    required this.onToggleFav,
  });

  static String _hm(DateTime t) => DateFormat('HH:mm').format(t);

  @override
  Widget build(BuildContext context) {
    final cur = current;
    final nxt = next;
    return Stack(
      children: [
        // Top gradient + bar
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withValues(alpha: 0.85),
                  Colors.transparent,
                ],
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 36),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  TvIconButton(
                    focusNode: minimizeFocus,
                    icon: Icons.fullscreen_exit_rounded,
                    color: Colors.white,
                    size: 26,
                    circle: true,
                    tooltip: 'Minimize',
                    onTap: onMinimize,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                channel?.name ?? '',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 17,
                                  fontWeight: FontWeight.w700,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 8),
                            _LiveBadge(),
                            if (ps.quality.isNotEmpty) ...[
                              const SizedBox(width: 6),
                              _QualityBadge(ps.quality),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (cur != null)
                          Text(
                            'Now  ${_hm(cur.startTime)}–${_hm(cur.endTime)}  '
                            '${cur.decodedTitle}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          )
                        else
                          const Text(
                            'No programme information',
                            style: TextStyle(
                              color: Colors.white60,
                              fontSize: 13,
                            ),
                          ),
                        if (nxt != null)
                          Text(
                            'Next  ${_hm(nxt.startTime)}  ${nxt.decodedTitle}',
                            style: const TextStyle(
                              color: Colors.white60,
                              fontSize: 12,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  if (onToggleFav != null)
                    TvIconButton(
                      focusNode: favoriteFocus,
                      icon: isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: isFavorite ? AppTheme.error : Colors.white,
                      size: 24,
                      circle: true,
                      tooltip: isFavorite
                          ? 'Remove from Favorites'
                          : 'Add to Favorites',
                      onTap: onToggleFav,
                    ),
                ],
              ),
            ),
          ),
        ),
        // Remote hint
        Positioned(
          left: 20,
          bottom: 18,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Text(
              '◀ ▶  Change channel     OK  TV Guide     BACK  Minimize',
              style: TextStyle(color: Colors.white70, fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}
