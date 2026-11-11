import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:media_kit_video/media_kit_video_controls/src/controls/extensions/duration.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/focus_utils.dart';
import '../../core/utils/platform_utils.dart';
import '../../core/utils/player_tuning.dart';
import '../../providers/app_providers.dart';
import '../../providers/behavior_providers.dart';
import '../../providers/live_tv_provider.dart';
import '../../services/web_proxy_client.dart';

class PlayerScreen extends ConsumerStatefulWidget {
  final String title;
  final String url;
  final String? imageUrl;
  final String type; // 'live' | 'movie' | 'series'
  final String id;
  final double startPosition;

  const PlayerScreen({
    super.key,
    required this.title,
    required this.url,
    this.imageUrl,
    required this.type,
    required this.id,
    this.startPosition = 0.0,
  });

  @override
  ConsumerState<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends ConsumerState<PlayerScreen>
    with TickerProviderStateMixin {
  // ── Media Kit ──────────────────────────────────────────────────────
  late final Player _player;
  late final VideoController _ctrl;
  final _subs = <StreamSubscription>[];

  // ── Playback state ──────────────────────────────────────────────────
  bool _playing = false;
  bool _buffering = true;
  String _error = '';
  Duration _pos = Duration.zero;
  Duration _dur = Duration.zero;
  Duration _buf = Duration.zero;
  String _quality = '';

  // ── Reconnect (live streams) ────────────────────────────────────────
  int _reconnectAttempt = 0;
  bool _isReconnecting = false;
  Timer? _reconnectTimer;
  static const _maxReconnects = 3;

  // ── Controls UI ─────────────────────────────────────────────────────
  bool _ctrlVisible = true;
  bool _locked = false;
  Timer? _hideTimer;

  // ── TV remote focus ─────────────────────────────────────────────────
  // While the OSD is hidden, focus is parked on the root so D-pad keys
  // drive the player (seek / zap / show OSD) instead of invisible buttons.
  final FocusNode _rootFocus = FocusNode(debugLabel: 'playerRoot');
  final FocusNode _playFocus = FocusNode(debugLabel: 'playerPlay');

  // ── Seek ────────────────────────────────────────────────────────────
  bool _isSeeking = false;
  double _seekVal = 0.0;

  // ── Double-tap ──────────────────────────────────────────────────────
  Offset _lastTap = Offset.zero;
  bool _showSkipLeft = false;
  bool _showSkipRight = false;
  Timer? _skipHideTimer;

  // ── Accelerating seek (remote / keyboard / seek bar / double-tap) ───
  // Like Prime Video: the first steps are 10 s, keep pressing (or hold)
  // in the same direction and the step grows to 30 s, 1 min, 2 min. The
  // target is shown at once; the real seek runs once the presses pause,
  // so a held key doesn't fire dozens of network seeks.
  int _seekDir = 0;
  int _seekChain = 0;
  DateTime _lastSeekStep = DateTime(0);
  Duration? _pendingSeek;
  Duration _chainBase = Duration.zero;
  int _skipAmount = 10; // signed seconds shown in the skip bubble
  Timer? _seekCommitTimer;

  // Touch: press and hold the left / right third to rewind / fast-forward
  // in growing steps (like holding the remote's Left / Right).
  Timer? _holdSeekTimer;

  // ── Gesture (volume / brightness) ───────────────────────────────────
  double _volume = 1.0;
  double _brightness = 0.5;
  bool _showVol = false;
  Timer? _volHideTimer;
  bool _showBright = false;
  bool _dragIsLeft = false;
  bool _playerDisposed = false;
  Timer? _positionTimer;
  static const int _kPosSaveInterval = 10;

  bool get _isLive => widget.type == 'live';

  bool _videoFill = false; // false=contain, true=fill/cover

  // ─────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();
    _initPlayer();
    _enterImmersive();
  }

  @override
  void dispose() {
    _holdSeekTimer?.cancel();
    _seekCommitTimer?.cancel();
    _skipHideTimer?.cancel();
    _finalSaveAndRefresh(); // any other exit path (e.g. route replaced)
    _playerDisposed = true;
    _hideTimer?.cancel();
    _volHideTimer?.cancel();
    _rootFocus.dispose();
    _playFocus.dispose();
    _reconnectTimer?.cancel();
    // ── Save final position + stop behavior timer ─────────────────────────────
    _positionTimer?.cancel();
    try {
      BehaviorService.instance.stopWatchTimer(widget.id);
    } catch (_) {}
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    try {
      _player.stop(); // Stop before dispose → releases video texture
      _player.dispose();
    } catch (_) {}
    _exitImmersive();
    try {
      PlatformUtils.disableWakelock();
    } catch (_) {}
    super.dispose();
  }

  // ── Player init with IPTV optimizations ──────────────────────────────
  Future<void> _initPlayer() async {
    // Web: HTTP stream blocked by browser Mixed Content policy
    if (WebProxyClient.isWebHttpStream(widget.url)) {
      if (mounted) {
        setState(() {
          _error = WebProxyClient.webHttpStreamError;
          _buffering = false;
        });
      }
      return;
    }

    // Shared, device-aware tuning (see PlayerTuning for the rationale —
    // the previous hand-rolled mpv option list never actually applied).
    _player = Player(configuration: PlayerTuning.playerConfig());
    _ctrl = VideoController(_player, configuration: PlayerTuning.videoConfig());
    await PlayerTuning.apply(_player, live: _isLive);

    // ── Subscriptions ─────────────────────────────────────────────────────────
    _subs.addAll([
      _player.stream.playing.listen((v) {
        if (!mounted) return;
        setState(() => _playing = v);
        if (v) {
          _reconnectAttempt = 0;
          _isReconnecting = false;
        }
      }),
      _player.stream.buffering.listen((v) {
        if (mounted) setState(() => _buffering = v);
      }),
      _player.stream.position.listen((v) {
        if (_isSeeking || !mounted) return;
        final secondChanged = v.inSeconds != _pos.inSeconds;
        _pos = v; // always keep the latest value (used for saving)
        // Rebuild only when the on-screen time changes and the OSD shows it.
        if (secondChanged && _ctrlVisible && !_isLive) setState(() {});
      }),
      _player.stream.duration.listen((v) {
        if (mounted) setState(() => _dur = v);
      }),
      _player.stream.buffer.listen((v) {
        final changed = v.inSeconds != _buf.inSeconds;
        _buf = v;
        // Only the buffering badge shows this value.
        if (changed && _buffering && mounted) setState(() {});
      }),
      _player.stream.videoParams.listen((v) {
        if (!mounted) return;
        final w = (v.dw ?? 0).round();
        final q = w >= 3840
            ? '4K'
            : w >= 1920
            ? 'FHD'
            : w >= 1280
            ? 'HD'
            : w > 0
            ? 'SD'
            : '';
        if (q.isNotEmpty) setState(() => _quality = q);
      }),
      // Live channels opened in this player: an end-of-stream means the
      // server closed the connection → reconnect at the live edge instead of
      // pausing (Play would make media_kit rewind to the start).
      _player.stream.completed.listen((done) {
        if (!done || !_isLive || !mounted || _playerDisposed) return;
        _player.open(Media(widget.url));
      }),
      _player.stream.error.listen((e) {
        if (e.isEmpty || !mounted) return;
        _handleStreamError(e);
      }),
    ]);

    await _player.setVolume(100);

    // Open media — VOD: seek to saved position after open completes
    if (!_isLive && widget.startPosition > 3.0) {
      // Listen for first duration event which confirms media is loaded
      late StreamSubscription<Duration> durSub;
      durSub = _player.stream.duration.listen((dur) async {
        if (dur.inSeconds > 0) {
          durSub.cancel();
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted && !_playerDisposed) {
            final seekTo = Duration(seconds: widget.startPosition.round());
            await _player.seek(seekTo.clamp(Duration.zero, dur));
          }
        }
      });
      _subs.add(durSub);
    }

    await _player.open(Media(widget.url));
    await PlatformUtils.enableWakelock();

    // ── Behavior tracking ─────────────────────────────────────────────────────
    BehaviorService.instance.startWatchTimer(widget.id, name: widget.title);

    // ── Periodic position save (VOD only, every 10s) ─────────────────────────
    if (!_isLive) {
      _positionTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!_playerDisposed && mounted) _saveCurrentPosition().ignore();
      });
    }

    _resetHideTimer();
  }

  // ── Auto-reconnect for live streams ──────────────────────────────────
  void _handleStreamError(String error) {
    if (!mounted) return;

    if (_isLive && _reconnectAttempt < _maxReconnects) {
      _reconnectAttempt++;
      final delay = Duration(seconds: _reconnectAttempt * 3);
      setState(() {
        _isReconnecting = true;
        _error = '';
      });

      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(delay, () {
        if (!mounted) return;
        setState(() => _isReconnecting = false);
        _player.open(Media(widget.url));
      });
    } else {
      setState(() {
        _error = 'Stream unavailable';
        _isReconnecting = false;
      });
    }
  }

  // ── Retry (user-triggered) ────────────────────────────────────────────
  void _retry() {
    setState(() {
      _error = '';
      _reconnectAttempt = 0;
      _isReconnecting = false;
    });
    _player.open(Media(widget.url));
  }

  // ── System UI ─────────────────────────────────────────────────────────
  void _enterImmersive() {
    if (kIsWeb) return;
    PlatformUtils.setDesktopFullScreen(true);
    try {
      // SystemUiMode.immersiveSticky hides taskbar on ALL native platforms
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } catch (_) {}
  }

  bool _immersiveExited = false;

  void _exitImmersive() {
    if (_immersiveExited) return;
    _immersiveExited = true;
    if (kIsWeb) return;
    PlatformUtils.setDesktopFullScreen(false);
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } catch (_) {}
  }

  // ── Controls ──────────────────────────────────────────────────────────
  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_ctrlVisible) setState(() => _ctrlVisible = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing && !_isSeeking) _hideControls();
    });
  }

  void _hideControls() {
    setState(() => _ctrlVisible = false);
    // Only reclaim focus if it is inside the player (never steal it from a
    // dialog / bottom sheet opened on top, e.g. the audio & subtitle sheet).
    if (_rootFocus.hasFocus || FocusManager.instance.primaryFocus == null) {
      _rootFocus.requestFocus();
    }
  }

  void _showControls({bool focusPlay = false}) {
    _resetHideTimer();
    if (focusPlay) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _playFocus.context != null) _playFocus.requestFocus();
      });
    }
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

  void _flashSkip(bool forward) {
    _skipHideTimer?.cancel();
    setState(() {
      _showSkipRight = forward;
      _showSkipLeft = !forward;
    });
    _skipHideTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) {
        setState(() {
          _showSkipLeft = false;
          _showSkipRight = false;
        });
      }
    });
  }

  /// Seek step for the [n]th press of a continuous run.
  static int _stepFor(int n) => n <= 3
      ? 10
      : n <= 8
      ? 30
      : n <= 14
      ? 60
      : 120;

  /// One seek step forward/back. Presses (or key repeats) in the same
  /// direction less than ~1 s apart form a run whose step accelerates.
  void _stepSeek(bool forward, {bool fixed = false}) {
    if (_isLive || _playerDisposed) return;
    final now = DateTime.now();
    final gap = now.difference(_lastSeekStep);
    // Remote auto-repeat fires every ~50 ms: take one step per 150 ms.
    if (gap < const Duration(milliseconds: 150) &&
        _seekDir == (forward ? 1 : -1)) {
      return;
    }
    final dir = forward ? 1 : -1;
    if (dir != _seekDir || gap > const Duration(milliseconds: 1000)) {
      _seekDir = dir;
      _seekChain = 0;
      _chainBase = _pendingSeek ?? _pos;
    }
    _seekChain++;
    _lastSeekStep = now;
    final base = _pendingSeek ?? _pos;
    // [fixed]: double-tap is always 10 s a time; holding accelerates.
    final step = fixed ? 10 : _stepFor(_seekChain);
    var target = base + Duration(seconds: dir * step);
    if (target < Duration.zero) target = Duration.zero;
    if (_dur > Duration.zero && target > _dur) target = _dur;
    _pendingSeek = target;
    _skipAmount = (target - _chainBase).inSeconds;
    if (_skipAmount == 0) _skipAmount = dir * 10;
    _flashSkip(forward);
    _resetHideTimer();
    _seekCommitTimer?.cancel();
    _seekCommitTimer = Timer(const Duration(milliseconds: 450), _commitSeek);
  }

  void _commitSeek() {
    _seekCommitTimer?.cancel();
    final t = _pendingSeek;
    if (t == null || _playerDisposed) return;
    _player.seek(t).whenComplete(() {
      if (!mounted) return;
      // Keep showing the target until the player reports it (no jump
      // back to the old position on the bar).
      setState(() => _pendingSeek = null);
    });
  }

  void _togglePlay() {
    _player.playOrPause();
    _resetHideTimer();
  }

  void _seekTo(double frac) {
    if (_isLive) return;
    _player.seek(_dur * frac.clamp(0, 1));
  }

  // ── Double tap ───────────────────────────────────────────────────────
  void _onDoubleTap() {
    if (_locked) return;
    final w = MediaQuery.of(context).size.width;
    // Live streams can't seek: no skip bubbles, only the centre (pause).
    if (!_isLive && _lastTap.dx < w / 3) {
      _stepSeek(false, fixed: true);
    } else if (!_isLive && _lastTap.dx > w * 2 / 3) {
      _stepSeek(true, fixed: true);
    } else if (_isLive && (_lastTap.dx < w / 3 || _lastTap.dx > w * 2 / 3)) {
      return;
    } else {
      _togglePlay();
    }
  }

  // ── Touch: hold a side to seek continuously ─────────────────────────
  void _onHoldStart(LongPressStartDetails d) {
    if (_locked || _isLive) return;
    final w = MediaQuery.sizeOf(context).width;
    final x = d.localPosition.dx;
    if (x > w / 3 && x < w * 2 / 3) return; // centre: nothing
    final fwd = x >= w * 2 / 3;
    _stepSeek(fwd);
    _holdSeekTimer?.cancel();
    _holdSeekTimer = Timer.periodic(
      const Duration(milliseconds: 220),
      (_) => _stepSeek(fwd),
    );
  }

  void _onHoldEnd() {
    if (_holdSeekTimer == null) return;
    _holdSeekTimer?.cancel();
    _holdSeekTimer = null;
    _commitSeek(); // seek as soon as the finger lifts
  }

  // ── Volume / Brightness gestures ──────────────────────────────────────
  void _onDragStart(DragStartDetails d) {
    _dragIsLeft = d.localPosition.dx < MediaQuery.of(context).size.width / 2;
  }

  void _onDragUpdate(DragUpdateDetails d) {
    if (_locked || _playerDisposed) return;
    final delta = -d.delta.dy / (MediaQuery.of(context).size.height * 0.5);
    if (_dragIsLeft) {
      // Brightness only works on mobile (ScreenBrightness plugin limitation)
      if (PlatformUtils.isMobile) {
        final nb = (_brightness + delta).clamp(0.0, 1.0);
        setState(() {
          _brightness = nb;
          _showBright = true;
        });
        _setBrightnessAsync(nb);
      }
    } else {
      // Volume via MPV — works on all platforms
      final nv = (_volume + delta).clamp(0.0, 1.0);
      setState(() {
        _volume = nv;
        _showVol = true;
      });
      _player.setVolume(nv * 100);
    }
  }

  void _onDragEnd(DragEndDetails _) {
    Future.delayed(const Duration(seconds: 1), () {
      if (mounted) {
        setState(() {
          _showVol = false;
          _showBright = false;
        });
      }
    });
  }

  void _setBrightnessAsync(double value) {
    try {
      PlatformUtils.setBrightness(value);
    } catch (_) {}
  }

  void _showTracks() {
    showModalBottomSheet(
      context: context,
      backgroundColor: AppTheme.surface,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(ctx).size.height * 0.55,
          ),
          child: _TrackSheet(player: _player),
        ),
      ),
    );
  }

  /// Saves position for Continue Watching. Skips very short content
  /// and near-complete content (handled by BehaviorService internally).
  Future<void> _saveCurrentPosition() async {
    if (_isLive || _dur.inSeconds < 30 || _pos == Duration.zero) return;
    try {
      await BehaviorService.instance.savePosition(
        id: widget.id,
        url: widget.url,
        positionSeconds: _pos.inSeconds.toDouble(),
        durationSeconds: _dur.inSeconds.toDouble(),
        type: widget.type,
        title: widget.title,
        imageUrl: widget.imageUrl,
      );
    } catch (_) {}
  }

  bool _finalSaveDone = false;

  /// Saves the final position once and refreshes Home's "Continue Watching"
  /// so the item appears immediately (it used to need an app restart: the
  /// list was loaded once, and the final save was skipped because
  /// `_playerDisposed` was set before the save check).
  void _finalSaveAndRefresh() {
    if (_finalSaveDone) return;
    _finalSaveDone = true;
    final cw = ref.read(continueWatchingProvider.notifier);
    _saveCurrentPosition().whenComplete(() {
      try {
        cw.refresh();
      } catch (_) {}
    });
  }

  // ── Buffer percentage (VOD only) ──────────────────────────────────────
  String _bufferPct() {
    if (_dur.inMilliseconds <= 0) return '';
    return '${(_buf.inMilliseconds / _dur.inMilliseconds * 100).round()}%';
  }

  // ── Favorites (live channels) ─────────────────────────────────────────
  bool get _isFavorite =>
      ref.watch(liveFavoritesNotifierProvider).contains(widget.id);

  void _toggleFavorite() {
    ref.read(liveFavoritesNotifierProvider.notifier).toggle(widget.id);
  }

  void _exitPlayer() {
    _finalSaveAndRefresh();
    if (mounted) setState(() => _playerDisposed = true);
    _exitImmersive();
    try {
      _player.stop();
    } catch (_) {}
    if (context.canPop()) {
      Navigator.of(context).pop();
    } else {
      context.go('/home');
    }
  }

  /// Handles hardware TV-remote / keyboard keys that aren't tied to a
  /// specific focusable widget: media transport keys, channel up/down
  /// (live only), and Escape/Back to exit the player.
  KeyEventResult _handleGlobalKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    final isDown = event is KeyDownEvent;

    // Desktop / web: Up / Down = volume (no on-screen volume slider; TV uses
    // the remote's volume keys, phones the swipe gesture).
    if (!_locked &&
        !PlatformUtils.isTV &&
        !PlatformUtils.isMobile &&
        (key == LogicalKeyboardKey.arrowUp ||
            key == LogicalKeyboardKey.arrowDown)) {
      final nv = (_volume + (key == LogicalKeyboardKey.arrowUp ? 0.05 : -0.05))
          .clamp(0.0, 1.0);
      setState(() {
        _volume = nv;
        _showVol = true;
      });
      _player.setVolume(nv * 100);
      _volHideTimer?.cancel();
      _volHideTimer = Timer(const Duration(milliseconds: 900), () {
        if (mounted) setState(() => _showVol = false);
      });
      return KeyEventResult.handled;
    }

    // ── D-pad while the OSD is hidden ──────────────────────────────────
    //  VOD : Left/Right = seek ∓/±10s, Up/Down/OK = show controls
    //  Live: Up/Down = channel −/+,     Left/Right/OK = show controls
    final isOk =
        key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.gameButtonA;
    final isArrow =
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowRight;
    // VOD: Left/Right seek whenever focus is parked on the player itself
    // (OSD hidden, or just revealed by a previous seek) — hold to scrub.
    if (!_locked &&
        _error.isEmpty &&
        !_isLive &&
        node.hasPrimaryFocus &&
        (key == LogicalKeyboardKey.arrowLeft ||
            key == LogicalKeyboardKey.arrowRight)) {
      _stepSeek(key == LogicalKeyboardKey.arrowRight);
      return KeyEventResult.handled;
    }
    if (!_locked && !_ctrlVisible && _error.isEmpty) {
      if (_isLive &&
          (key == LogicalKeyboardKey.arrowUp ||
              key == LogicalKeyboardKey.arrowDown)) {
        if (isDown) _switchChannel(key == LogicalKeyboardKey.arrowUp ? -1 : 1);
        return KeyEventResult.handled;
      }
      if (isOk || isArrow) {
        if (isDown) _showControls(focusPlay: true);
        return KeyEventResult.handled;
      }
    }
    // OSD shown but focus parked on the root (e.g. after seeking) → jump
    // into the controls.
    if (!_locked &&
        _ctrlVisible &&
        node.hasPrimaryFocus &&
        _playFocus.context != null &&
        (isArrow || isOk)) {
      if (isDown) _showControls(focusPlay: true);
      return KeyEventResult.handled;
    }

    if (!isDown) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.escape ||
        key == LogicalKeyboardKey.goBack ||
        key == LogicalKeyboardKey.browserBack) {
      if (_locked) return KeyEventResult.ignored; // let lock UI handle it
      // Controls showing → Back just hides them; next Back leaves.
      if (_ctrlVisible && _error.isEmpty) {
        _hideTimer?.cancel();
        _hideControls();
        return KeyEventResult.handled;
      }
      _exitPlayer();
      return KeyEventResult.handled;
    }

    if (_locked) return KeyEventResult.ignored;

    if (key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.mediaPlay ||
        key == LogicalKeyboardKey.mediaPause) {
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (!_isLive) {
      if (key == LogicalKeyboardKey.mediaRewind ||
          key == LogicalKeyboardKey.mediaStepBackward) {
        _stepSeek(false);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.mediaFastForward ||
          key == LogicalKeyboardKey.mediaStepForward) {
        _stepSeek(true);
        return KeyEventResult.handled;
      }
    }
    if (_isLive) {
      if (key == LogicalKeyboardKey.channelUp ||
          key == LogicalKeyboardKey.pageUp) {
        _switchChannel(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.channelDown ||
          key == LogicalKeyboardKey.pageDown) {
        _switchChannel(1);
        return KeyEventResult.handled;
      }
    }
    // Any other key press keeps the overlay alive / wakes it.
    _resetHideTimer();
    return KeyEventResult.ignored;
  }

  /// Switches to the next/previous channel in the currently active Live TV
  /// filter list. Only meaningful when opened directly for a live channel.
  void _switchChannel(int delta) {
    final streams = ref.read(filteredLiveStreamsProvider).value;
    if (streams == null || streams.isEmpty) return;
    final idx = streams.indexWhere((s) => s.streamId == widget.id);
    if (idx < 0) return;
    final newIdx = (idx + delta).clamp(0, streams.length - 1);
    if (newIdx == idx) return;
    final next = streams[newIdx];
    final service = ref.read(xtreamServiceProvider);
    if (service == null) return;
    final url = service.getLiveUrl(next.streamId);
    ref.read(recentlyViewedLiveProvider.notifier).add(next.streamId);
    context.pushReplacement(
      '/player',
      extra: {
        'title': next.name,
        'url': url,
        'imageUrl': next.streamIcon,
        'type': 'live',
        'id': next.streamId,
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // System back (gesture / back button): dismiss controls first.
        if (_ctrlVisible && !_locked && _error.isEmpty) {
          _hideTimer?.cancel();
          _hideControls();
          return;
        }
        _exitPlayer();
      },
      child: Focus(
        focusNode: _rootFocus,
        autofocus: true,
        onKeyEvent: _handleGlobalKey,
        child: Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              // ── Video ────────────────────────────────────────────────
              _error.isNotEmpty
                  ? _ErrorView(
                      title: widget.title,
                      url: widget.url,
                      errorMsg: _error,
                      isLive: _isLive,
                      onRetry: _retry,
                    )
                  : Video(
                      controller: _ctrl,
                      fit: _videoFill ? BoxFit.cover : BoxFit.contain,
                      controls: NoVideoControls,
                    ),

              // ── Buffering indicator (subtle — over video) ────────────
              if (_buffering && _error.isEmpty && !_isReconnecting)
                Positioned(
                  bottom: _isLive ? 20 : 90,
                  right: 20,
                  child: _BufferingBadge(
                    isLive: _isLive,
                    bufPct: _isLive ? null : _bufferPct(),
                  ),
                ),

              // ── Reconnecting overlay ──────────────────────────────────
              if (_isReconnecting)
                Center(
                  child: _ReconnectOverlay(
                    attempt: _reconnectAttempt,
                    max: _maxReconnects,
                    onCancel: () {
                      _reconnectTimer?.cancel();
                      setState(() {
                        _isReconnecting = false;
                        _error = 'Cancelled';
                      });
                    },
                  ),
                ),

              // ── Gesture layer ─────────────────────────────────────────
              if (_error.isEmpty && !_isReconnecting && !_playerDisposed)
                Positioned.fill(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapDown: (d) => _lastTap = d.localPosition,
                    onTap: _toggleControls,
                    onDoubleTap: _onDoubleTap,
                    onLongPressStart: _onHoldStart,
                    onLongPressEnd: (_) => _onHoldEnd(),
                    onLongPressCancel: _onHoldEnd,
                    onVerticalDragStart: _onDragStart,
                    onVerticalDragUpdate: _onDragUpdate,
                    onVerticalDragEnd: _onDragEnd,
                  ),
                ),

              // ── Controls overlay ──────────────────────────────────────
              if (!_locked && _error.isEmpty)
                AnimatedOpacity(
                  opacity: _ctrlVisible ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 250),
                  // Hidden controls must not keep remote focus.
                  child: ExcludeFocus(
                    excluding: !_ctrlVisible,
                    child: IgnorePointer(
                      ignoring: !_ctrlVisible,
                      child: _ControlsOverlay(
                        playFocusNode: _playFocus,
                        title: widget.title,
                        isLive: _isLive,
                        playing: _playing,
                        quality: _quality,
                        isFavorite: _isLive ? _isFavorite : false,
                        pos: _pendingSeek ?? _pos,
                        dur: _dur,
                        isSeeking: _isSeeking,
                        seekVal: _seekVal,
                        volume: _volume,
                        onBack: _exitPlayer,
                        onTogglePlay: _togglePlay,
                        onToggleLock: () => setState(() => _locked = true),
                        onToggleFav: _isLive ? _toggleFavorite : null,
                        onShowTracks: _showTracks,
                        onSeekStart: (v) => setState(() {
                          _isSeeking = true;
                          _seekVal = v;
                        }),
                        onSeekChange: (v) => setState(() => _seekVal = v),
                        onSeekEnd: (v) {
                          setState(() => _isSeeking = false);
                          _seekTo(v);
                        },
                        onVolumeChange: (v) {
                          setState(() => _volume = v);
                          _player.setVolume(v * 100);
                        },
                        isVideoFill: _videoFill,
                        onToggleFit: () =>
                            setState(() => _videoFill = !_videoFill),
                        onSeekBack: () => _stepSeek(false),
                        onSeekFwd: () => _stepSeek(true),
                      ),
                    ),
                  ),
                ),

              // ── Lock overlay ──────────────────────────────────────────
              if (_locked)
                _LockOverlay(
                  onUnlock: () {
                    setState(() => _locked = false);
                    _showControls(focusPlay: true);
                  },
                ),

              // ── Skip indicators ───────────────────────────────────────
              if (_showSkipLeft && !_isLive)
                Positioned(
                  left: 32,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _SkipIndicator(seconds: -_skipAmount.abs()),
                  ),
                ),
              if (_showSkipRight && !_isLive)
                Positioned(
                  right: 32,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: _SkipIndicator(seconds: _skipAmount.abs()),
                  ),
                ),

              // ── Volume / Brightness overlays ──────────────────────────
              if (_showVol)
                Center(
                  child: _GestureOverlay(
                    icon: _volume > 0.5
                        ? Icons.volume_up_rounded
                        : _volume > 0
                        ? Icons.volume_down_rounded
                        : Icons.volume_off_rounded,
                    value: _volume,
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
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BUFFERING BADGE (shows over video, not blocking)
// ─────────────────────────────────────────────────────────────────────────────
class _BufferingBadge extends StatelessWidget {
  final bool isLive;
  final String? bufPct;
  const _BufferingBadge({required this.isLive, this.bufPct});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              color: Colors.white,
              strokeWidth: 1.5,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            isLive
                ? 'Buffering...'
                : bufPct != null
                ? 'Buffering $bufPct'
                : 'Buffering...',
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RECONNECT OVERLAY
// ─────────────────────────────────────────────────────────────────────────────
class _ReconnectOverlay extends StatelessWidget {
  final int attempt;
  final int max;
  final VoidCallback onCancel;
  const _ReconnectOverlay({
    required this.attempt,
    required this.max,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
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
            'Reconnecting ($attempt/$max)',
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
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white70),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTROLS OVERLAY
// ─────────────────────────────────────────────────────────────────────────────
class _ControlsOverlay extends StatelessWidget {
  final FocusNode? playFocusNode;
  final String title;
  final bool isLive;
  final bool playing;
  final String quality;
  final bool isFavorite;
  final Duration pos;
  final Duration dur;
  final bool isSeeking;
  final double seekVal;
  final double volume;
  final VoidCallback onBack;
  final VoidCallback onTogglePlay;
  final VoidCallback onToggleLock;
  final VoidCallback? onToggleFav;
  final VoidCallback onShowTracks;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChange;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onVolumeChange;
  final bool isVideoFill;
  final VoidCallback onToggleFit;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekFwd;

  const _ControlsOverlay({
    this.playFocusNode,
    required this.title,
    required this.isLive,
    required this.playing,
    required this.quality,
    required this.isFavorite,
    required this.pos,
    required this.dur,
    required this.isSeeking,
    required this.seekVal,
    required this.volume,
    required this.onBack,
    required this.onTogglePlay,
    required this.onToggleLock,
    required this.onToggleFav,
    required this.onShowTracks,
    required this.onSeekStart,
    required this.onSeekChange,
    required this.onSeekEnd,
    required this.onVolumeChange,
    required this.isVideoFill,
    required this.onToggleFit,
    required this.onSeekBack,
    required this.onSeekFwd,
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
            _TopBar(
              title: title,
              isLive: isLive,
              quality: quality,
              isFavorite: isFavorite,
              onBack: onBack,
              onLock: onToggleLock,
              onFav: onToggleFav,
              onTracks: onShowTracks,
            ),
            const Spacer(),
            _CenterPlay(
              playing: playing,
              onTap: onTogglePlay,
              focusNode: playFocusNode,
            ),
            const Spacer(),
            _BottomBar(
              isLive: isLive,
              playing: playing,
              pos: pos,
              dur: dur,
              volume: volume,
              isSeeking: isSeeking,
              seekVal: seekVal,
              onTogglePlay: onTogglePlay,
              onSeekStart: onSeekStart,
              onSeekChange: onSeekChange,
              onSeekEnd: onSeekEnd,
              onVolumeChange: onVolumeChange,
              isVideoFill: isVideoFill,
              onToggleFit: onToggleFit,
              onSeekBack: onSeekBack,
              onSeekFwd: onSeekFwd,
            ),
          ],
        ),
      ),
    );
  }
}

class _TopBar extends StatelessWidget {
  final String title;
  final bool isLive;
  final String quality;
  final bool isFavorite;
  final VoidCallback onBack;
  final VoidCallback onLock;
  final VoidCallback? onFav;
  final VoidCallback onTracks;

  const _TopBar({
    required this.title,
    required this.isLive,
    required this.quality,
    required this.isFavorite,
    required this.onBack,
    required this.onLock,
    required this.onFav,
    required this.onTracks,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 12, 4),
      child: Row(
        children: [
          _PlayerIconBtn(icon: Icons.arrow_back_ios_new, onTap: onBack),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    shadows: [Shadow(color: Colors.black, blurRadius: 6)],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (isLive)
                  const Text(
                    '● LIVE',
                    style: TextStyle(
                      color: AppTheme.error,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
              ],
            ),
          ),
          if (quality.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
              ),
              child: Text(
                quality,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          const SizedBox(width: 6),
          if (onFav != null)
            _PlayerIconBtn(
              icon: isFavorite ? Icons.favorite : Icons.favorite_border,
              iconColor: isFavorite ? AppTheme.error : Colors.white,
              onTap: onFav!,
            ),
          _PlayerIconBtn(
            icon: Icons.settings,
            tooltip: 'Audio & Subtitles',
            onTap: onTracks,
          ),
          _PlayerIconBtn(
            icon: Icons.lock_outline,
            tooltip: 'Lock screen',
            onTap: onLock,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLAYER ICON BUTTON — TV-focusable replacement for IconButton in overlays
// ─────────────────────────────────────────────────────────────────────────────
class _PlayerIconBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color iconColor;
  final String? tooltip;
  double get size => 22;

  const _PlayerIconBtn({
    required this.icon,
    required this.onTap,
    this.iconColor = Colors.white,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    Widget btn = TvFocusable(
      autoScroll: false,
      onActivate: onTap,
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused ? Colors.white.withValues(alpha: 0.20) : null,
          border: focused
              ? Border.all(color: Colors.white.withValues(alpha: 0.7), width: 2)
              : null,
        ),
        child: Icon(icon, color: iconColor, size: size),
      ),
    );
    if (tooltip != null) btn = Tooltip(message: tooltip!, child: btn);
    return btn;
  }
}

class _CenterPlay extends StatefulWidget {
  final bool playing;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  const _CenterPlay({
    required this.playing,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_CenterPlay> createState() => _CenterPlayState();
}

class _CenterPlayState extends State<_CenterPlay> {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      autofocus: true,
      autoScroll: false,
      onActivate: widget.onTap,
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 60,
        height: 60,
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.18),
          shape: BoxShape.circle,
          border: Border.all(
            color: focused
                ? AppTheme.primary
                : Colors.white.withValues(alpha: 0.35),
            width: focused ? 3 : 1.5,
          ),
        ),
        child: Icon(
          widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
          color: Colors.white,
          size: 34,
        ),
      ),
    );
  }
}

class _BottomBar extends StatelessWidget {
  final bool isLive;
  final bool playing;
  final Duration pos;
  final Duration dur;
  final double volume;
  final bool isSeeking;
  final double seekVal;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onSeekStart;
  final ValueChanged<double> onSeekChange;
  final ValueChanged<double> onSeekEnd;
  final ValueChanged<double> onVolumeChange;
  final bool isVideoFill;
  final VoidCallback onToggleFit;
  final VoidCallback onSeekBack;
  final VoidCallback onSeekFwd;

  const _BottomBar({
    required this.isLive,
    required this.playing,
    required this.pos,
    required this.dur,
    required this.volume,
    required this.isSeeking,
    required this.seekVal,
    required this.onTogglePlay,
    required this.onSeekStart,
    required this.onSeekChange,
    required this.onSeekEnd,
    required this.onVolumeChange,
    required this.isVideoFill,
    required this.onToggleFit,
    required this.onSeekBack,
    required this.onSeekFwd,
  });

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final progress = dur.inMilliseconds > 0
        ? pos.inMilliseconds / dur.inMilliseconds
        : 0.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Seek bar (VOD only)
          if (!isLive) ...[
            SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                activeTrackColor: AppTheme.primary,
                inactiveTrackColor: Colors.white24,
                thumbColor: Colors.white,
                overlayColor: AppTheme.primary.withValues(alpha: 0.3),
              ),
              child: TvSlider(
                value: isSeeking ? seekVal : progress.clamp(0.0, 1.0),
                onChangeStart: onSeekStart,
                onChanged: onSeekChange,
                onChangeEnd: onSeekEnd,
                onStepDown: onSeekBack,
                onStepUp: onSeekFwd,
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Text(
                    _fmt(pos),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    _fmt(dur),
                    style: const TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOCK, SKIP, GESTURE overlays
// ─────────────────────────────────────────────────────────────────────────────
class _LockOverlay extends StatelessWidget {
  final VoidCallback onUnlock;
  const _LockOverlay({required this.onUnlock});

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16),
          child: TvFocusable(
            autofocus: true,
            autoScroll: false,
            onActivate: onUnlock,
            builder: (focused, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                shape: BoxShape.circle,
                border: Border.all(
                  color: focused ? AppTheme.primary : Colors.white30,
                  width: focused ? 2.5 : 1.5,
                ),
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: Colors.white,
                size: 22,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SkipIndicator extends StatelessWidget {
  final int seconds;
  const _SkipIndicator({required this.seconds});

  static String _label(int s) {
    if (s < 60) return '${s}s';
    final m = s ~/ 60;
    final r = s % 60;
    if (m < 60) return r == 0 ? '${m}m' : '${m}m ${r}s';
    final h = m ~/ 60;
    final rm = m % 60;
    return rm == 0 ? '${h}h' : '${h}h ${rm}m';
  }

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
          seconds < 0 ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
          color: Colors.white,
          size: 28,
        ),
        const SizedBox(height: 4),
        Text(
          _label(seconds.abs()),
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
// ERROR VIEW
// ─────────────────────────────────────────────────────────────────────────────
class _ErrorView extends StatelessWidget {
  final String title;
  final String url;
  final String errorMsg;
  final bool isLive;
  final VoidCallback onRetry;

  const _ErrorView({
    required this.title,
    required this.url,
    required this.errorMsg,
    required this.isLive,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    // Web HTTP stream special case
    if (errorMsg == WebProxyClient.webHttpStreamError) {
      return SafeArea(
        child: Column(
          children: [
            Row(
              children: [
                IconButton(
                  onPressed: () {
                    _exitCtx(context);
                    Navigator.of(context).pop();
                  },
                  icon: const Icon(
                    Icons.arrow_back_ios_new,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
                Expanded(
                  child: Text(
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const Spacer(),
            const Icon(
              Icons.no_encryption_outlined,
              color: AppTheme.warning,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              'HTTP Stream — Not Supported in Browser',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 10),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                'Chrome blocks HTTP streams on HTTPS pages.\n'
                'Use the Android or Windows app for full streaming,\n'
                'or open the link below to watch/download directly.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => launchUrl(
                Uri.parse(url),
                mode: LaunchMode.externalApplication,
              ),
              icon: const Icon(Icons.open_in_new),
              label: const Text('Open / Download in Browser'),
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 28,
                  vertical: 13,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(30),
                ),
              ),
            ),
            const Spacer(),
          ],
        ),
      );
    }
    return SafeArea(
      child: Column(
        children: [
          // Back button row
          Row(
            children: [
              IconButton(
                onPressed: () {
                  _exitCtx(context);
                  Navigator.of(context).pop();
                },
                icon: const Icon(
                  Icons.arrow_back_ios_new,
                  color: Colors.white,
                  size: 20,
                ),
              ),
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              if (isLive)
                Container(
                  margin: const EdgeInsets.only(right: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.error,
                    borderRadius: BorderRadius.circular(5),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white54, width: 2),
            ),
            child: const Icon(
              Icons.error_outline,
              color: Colors.white70,
              size: 40,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Stream unavailable',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'The stream could not be loaded.',
            style: TextStyle(color: Colors.white54, fontSize: 13),
          ),
          const SizedBox(height: 28),
          TvFocusable(
            autofocus: true,
            autoScroll: false,
            onActivate: onRetry,
            builder: (focused, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                border: focused
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.7),
                        width: 2,
                      )
                    : null,
              ),
              child: ExcludeFocus(
                child: ElevatedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded),
                  label: const Text('Retry'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: focused
                        ? AppTheme.primary.withValues(alpha: 0.85)
                        : AppTheme.primary,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 32,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const Spacer(),
        ],
      ),
    );
  }

  static void _exitCtx(BuildContext ctx) {
    if (kIsWeb) return;
    try {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    } catch (_) {}
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TRACK SHEET — language display, filtered tracks, overflow-safe
// ─────────────────────────────────────────────────────────────────────────────
class _TrackSheet extends StatefulWidget {
  final Player player;
  const _TrackSheet({required this.player});

  @override
  State<_TrackSheet> createState() => _TrackSheetState();
}

class _TrackSheetState extends State<_TrackSheet>
    with SingleTickerProviderStateMixin {
  late final TabController _tab;

  @override
  void initState() {
    super.initState();
    _tab = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tab.dispose();
    super.dispose();
  }

  // Resolve a human-readable track label from id/language/title
  static String _trackLabel(String? id, String? language, String? title) {
    const langs = {
      'eng': 'English',
      'hin': 'Hindi',
      'tam': 'Tamil',
      'tel': 'Telugu',
      'kan': 'Kannada',
      'mal': 'Malayalam',
      'mar': 'Marathi',
      'ben': 'Bengali',
      'pun': 'Punjabi',
      'guj': 'Gujarati',
      'urd': 'Urdu',
      'ara': 'Arabic',
      'fre': 'French',
      'ger': 'German',
      'spa': 'Spanish',
      'por': 'Portuguese',
      'rus': 'Russian',
      'zho': 'Chinese',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'ita': 'Italian',
      'dut': 'Dutch',
      'tur': 'Turkish',
      'und': 'Mixed',
    };
    if (id == 'auto') return 'Default';
    final langName = language?.isNotEmpty == true
        ? langs[language!.toLowerCase()]
        : null;
    if (langName != null) return langName;
    if (language?.isNotEmpty == true) return language!.toUpperCase();
    if (title?.isNotEmpty == true) return title!;
    return id ?? 'Track';
  }

  @override
  Widget build(BuildContext context) {
    final tracks = widget.player.state.tracks;

    // Filter audio: remove 'no' (mute handled by volume control)
    final audioTracks = tracks.audio.where((t) => t.id != 'no').toList();

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const SizedBox(height: 12),
        Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppTheme.textMuted,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 12),
        const Text(
          'Audio & Subtitles',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        TabBar(
          controller: _tab,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [
            Tab(text: 'Audio'),
            Tab(text: 'Subtitles'),
          ],
        ),
        // Constrained height — prevents bottom overflow
        ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.35,
          ),
          child: TabBarView(
            controller: _tab,
            children: [
              _TrackList(
                tracks: audioTracks,
                label: (t) => _trackLabel(t.id, t.language, t.title),
                isCurrent: (t) => widget.player.state.track.audio.id == t.id,
                onTap: (t) {
                  widget.player.setAudioTrack(t);
                  Navigator.pop(context);
                },
              ),
              _TrackList(
                tracks: tracks.subtitle,
                label: (t) => t.id == 'no'
                    ? 'Off'
                    : _trackLabel(t.id, t.language, t.title),
                isCurrent: (t) => widget.player.state.track.subtitle.id == t.id,
                onTap: (t) {
                  widget.player.setSubtitleTrack(t);
                  Navigator.pop(context);
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
      ],
    );
  }
}

class _TrackList<T> extends StatelessWidget {
  final List<T> tracks;
  final String Function(T) label;
  final bool Function(T) isCurrent;
  final void Function(T) onTap;
  const _TrackList({
    required this.tracks,
    required this.label,
    required this.isCurrent,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (tracks.isEmpty) {
      return const Center(
        child: Text(
          'No tracks',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: tracks.length,
      separatorBuilder: (_, _) =>
          const Divider(color: AppTheme.divider, height: 1),
      itemBuilder: (_, i) {
        final t = tracks[i];
        return ListTile(
          title: Text(label(t)),
          trailing: isCurrent(t)
              ? const Icon(Icons.check, color: AppTheme.primary)
              : null,
          selected: isCurrent(t),
          selectedColor: AppTheme.primary,
          onTap: () => onTap(t),
        );
      },
    );
  }
}
