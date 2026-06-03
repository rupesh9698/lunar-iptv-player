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
import '../../core/utils/platform_utils.dart';
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

  // ── Seek ────────────────────────────────────────────────────────────
  bool _isSeeking = false;
  double _seekVal = 0.0;

  // ── Double-tap ──────────────────────────────────────────────────────
  Offset _lastTap = Offset.zero;
  bool _showSkipLeft = false;
  bool _showSkipRight = false;
  static const _skipSecs = 10;

  // ── Gesture (volume / brightness) ───────────────────────────────────
  double _volume = 1.0;
  double _brightness = 0.5;
  bool _showVol = false;
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
    _playerDisposed = true;
    _hideTimer?.cancel();
    _reconnectTimer?.cancel();
    // ── Save final position + stop behavior timer ─────────────────────────────
    _positionTimer?.cancel();
    if (!_isLive && !_playerDisposed) _saveCurrentPosition();
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

    _player = Player(
      configuration: const PlayerConfiguration(
        // Disable libass on low-spec devices — saves ~15MB RAM
        libass: false,
      ),
    );
    _ctrl = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // Use low-res surface on Android to reduce GPU pressure
        enableHardwareAcceleration: true,
        // Limit surface size — huge benefit on 720p TV displays
        width: 1280,
        height: 720,
      ),
    );

    // ── MPV properties ────────────────────────────────────────────────────────
    await _setMpvProp('network-timeout', '15');

    if (_isLive) {
      await _setMpvProp('cache', 'yes');
      await _setMpvProp('cache-secs', '5');
      await _setMpvProp('cache-initial', '0');
      await _setMpvProp('cache-pause', 'no');
      await _setMpvProp('cache-pause-initial', 'no');
      await _setMpvProp('demuxer-max-bytes', '6MiB');
      await _setMpvProp('demuxer-max-back-bytes', '2MiB');
      await _setMpvProp(
        'stream-lavf-o',
        'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,'
            'reconnect_delay_max=5,timeout=15000000',
      );
    } else {
      await _setMpvProp('cache', 'yes');
      await _setMpvProp('cache-secs', '30');
      await _setMpvProp('cache-initial', '500000');
      await _setMpvProp('demuxer-max-bytes', '16MiB');
      await _setMpvProp('demuxer-max-back-bytes', '8MiB');
      await _setMpvProp('demuxer-readahead-secs', '10');
    }

    // ── Universal low-spec optimisations ─────────────────────────────────────
    await _setMpvProp('hwdec', 'auto-safe');
    await _setMpvProp('video-sync', 'audio');
    await _setMpvProp('framedrop', 'decoder+vo');
    await _setMpvProp('vd-lavc-threads', '1');
    await _setMpvProp('vd-lavc-fast', 'yes');
    await _setMpvProp('vd-lavc-skiploopfilter', 'nonkey');
    await _setMpvProp('vd-lavc-skipframe', 'nonref');
    await _setMpvProp('audio-buffer', '0.1');
    await _setMpvProp('scale', 'bilinear');
    await _setMpvProp('dscale', 'bilinear');
    await _setMpvProp('correct-downscaling', 'no');
    await _setMpvProp('sigmoid-upscaling', 'no');

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
        if (!_isSeeking && mounted) setState(() => _pos = v);
      }),
      _player.stream.duration.listen((v) {
        if (mounted) setState(() => _dur = v);
      }),
      _player.stream.buffer.listen((v) {
        if (mounted) setState(() => _buf = v);
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
      _player.stream.error.listen((e) {
        if (e.isEmpty || !mounted) return;
        _handleStreamError(e);
      }),
    ]);

    await _player.setVolume(100);

    // Open media — VOD: seek to saved position after open completes
    if (!_isLive && widget.startPosition > 3.0) {
      // Listen for first duration event which confirms media is loaded
      late StreamSubscription<Duration> _durSub;
      _durSub = _player.stream.duration.listen((dur) async {
        if (dur.inSeconds > 0) {
          _durSub.cancel();
          await Future.delayed(const Duration(milliseconds: 300));
          if (mounted && !_playerDisposed) {
            final seekTo = Duration(seconds: widget.startPosition.round());
            await _player.seek(seekTo.clamp(Duration.zero, dur));
          }
        }
      });
      _subs.add(_durSub);
    }

    await _player.open(Media(widget.url));
    await PlatformUtils.enableWakelock();

    // ── Behavior tracking ─────────────────────────────────────────────────────
    BehaviorService.instance.startWatchTimer(widget.id, name: widget.title);

    // ── Periodic position save (VOD only, every 10s) ─────────────────────────
    if (!_isLive) {
      _positionTimer = Timer.periodic(const Duration(seconds: 10), (_) {
        if (!_playerDisposed && mounted) _saveCurrentPosition();
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
      if (mounted && _playing && !_isSeeking) {
        setState(() => _ctrlVisible = false);
      }
    });
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _ctrlVisible = !_ctrlVisible);
    if (_ctrlVisible) _resetHideTimer();
  }

  void _togglePlay() {
    _player.playOrPause();
    _resetHideTimer();
  }

  void _seekRelative(int secs) {
    if (_isLive) return;
    _player.seek((_pos + Duration(seconds: secs)).clamp(Duration.zero, _dur));
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
    if (_lastTap.dx < w / 3) {
      _seekRelative(-_skipSecs);
      setState(() => _showSkipLeft = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showSkipLeft = false);
      });
    } else if (_lastTap.dx > w * 2 / 3) {
      _seekRelative(_skipSecs);
      setState(() => _showSkipRight = true);
      Future.delayed(const Duration(milliseconds: 700), () {
        if (mounted) setState(() => _showSkipRight = false);
      });
    } else {
      _togglePlay();
    }
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

  Future<void> _setMpvProp(String key, String value) async {
    try {
      // ignore: avoid_dynamic_calls
      await (_player as dynamic).setProperty(key, value);
    } catch (_) {}
  }

  /// Saves position for Continue Watching. Skips very short content
  /// and near-complete content (handled by BehaviorService internally).
  void _saveCurrentPosition() {
    if (_dur.inSeconds < 30 || _playerDisposed || _pos == Duration.zero) return;
    BehaviorService.instance
        .savePosition(
          id: widget.id,
          url: widget.url,
          positionSeconds: _pos.inSeconds.toDouble(),
          durationSeconds: _dur.inSeconds.toDouble(),
          type: widget.type,
          title: widget.title,
          imageUrl: widget.imageUrl,
        )
        .ignore();
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

  // ─────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        if (mounted) setState(() => _playerDisposed = true);
        _exitImmersive();
        try {
          _player.stop();
        } catch (_) {}
        // Always use Navigator.pop so we return to calling screen (not home)
        if (context.canPop()) {
          Navigator.of(context).pop();
        } else {
          context.go('/home');
        }
      },
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
                child: IgnorePointer(
                  ignoring: !_ctrlVisible,
                  child: _ControlsOverlay(
                    title: widget.title,
                    isLive: _isLive,
                    playing: _playing,
                    quality: _quality,
                    isFavorite: _isLive ? _isFavorite : false,
                    pos: _pos,
                    dur: _dur,
                    isSeeking: _isSeeking,
                    seekVal: _seekVal,
                    volume: _volume,
                    onBack: () {
                      _exitImmersive();
                      Navigator.of(context).pop();
                    },
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
                    onToggleFit: () => setState(() => _videoFill = !_videoFill),
                    onSeekBack: () => _seekRelative(-10),
                    onSeekFwd: () => _seekRelative(10),
                  ),
                ),
              ),

            // ── Lock overlay ──────────────────────────────────────────
            if (_locked)
              _LockOverlay(onUnlock: () => setState(() => _locked = false)),

            // ── Skip indicators ───────────────────────────────────────
            if (_showSkipLeft)
              const Positioned(
                left: 32,
                top: 0,
                bottom: 0,
                child: Center(child: _SkipIndicator(seconds: -_skipSecs)),
              ),
            if (_showSkipRight)
              const Positioned(
                right: 32,
                top: 0,
                bottom: 0,
                child: Center(child: _SkipIndicator(seconds: _skipSecs)),
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
            _CenterPlay(playing: playing, onTap: onTogglePlay),
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
          IconButton(
            onPressed: onBack,
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: Colors.white,
              size: 20,
            ),
          ),
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
            IconButton(
              onPressed: onFav,
              icon: Icon(
                isFavorite ? Icons.favorite : Icons.favorite_border,
                color: isFavorite ? AppTheme.error : Colors.white,
                size: 22,
              ),
            ),
          IconButton(
            onPressed: onTracks,
            icon: const Icon(Icons.settings, color: Colors.white, size: 22),
            tooltip: 'Audio & Subtitles',
          ),
          IconButton(
            onPressed: onLock,
            icon: const Icon(Icons.lock_outline, color: Colors.white, size: 22),
            tooltip: 'Lock screen',
          ),
        ],
      ),
    );
  }
}

class _CenterPlay extends StatefulWidget {
  final bool playing;
  final VoidCallback onTap;
  const _CenterPlay({required this.playing, required this.onTap});

  @override
  State<_CenterPlay> createState() => _CenterPlayState();
}

class _CenterPlayState extends State<_CenterPlay> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 60,
          height: 60,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.18),
            shape: BoxShape.circle,
            border: Border.all(
              color: _focused
                  ? AppTheme.primary
                  : Colors.white.withValues(alpha: 0.35),
              width: _focused ? 3 : 1.5,
            ),
          ),
          child: Icon(
            widget.playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
            color: Colors.white,
            size: 34,
          ),
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
              child: Slider(
                value: isSeeking ? seekVal : progress.clamp(0.0, 1.0),
                onChangeStart: onSeekStart,
                onChanged: onSeekChange,
                onChangeEnd: onSeekEnd,
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

          // Controls row
          Row(
            children: [
              // Play/Pause
              IconButton(
                onPressed: onTogglePlay,
                padding: const EdgeInsets.all(8),
                icon: Icon(
                  playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                  color: Colors.white,
                  size: 30,
                ),
              ),

              if (!isLive) ...[
                _CtrlBtn(Icons.replay_10_rounded, onSeekBack),
                _CtrlBtn(Icons.forward_10_rounded, onSeekFwd),
              ],

              const Spacer(),

              // Volume (desktop)
              if (PlatformUtils.isDesktop) ...[
                Icon(
                  volume > 0.5 ? Icons.volume_up : Icons.volume_off,
                  color: Colors.white,
                  size: 20,
                ),
                SizedBox(
                  width: 80,
                  child: SliderTheme(
                    data: SliderThemeData(
                      trackHeight: 2,
                      thumbShape: const RoundSliderThumbShape(
                        enabledThumbRadius: 5,
                      ),
                      overlayShape: const RoundSliderOverlayShape(
                        overlayRadius: 10,
                      ),
                      activeTrackColor: Colors.white,
                      inactiveTrackColor: Colors.white30,
                      thumbColor: Colors.white,
                    ),
                    child: Slider(value: volume, onChanged: onVolumeChange),
                  ),
                ),
                const SizedBox(width: 8),
              ],

              GestureDetector(
                onTap: onToggleFit,
                child: Icon(
                  isVideoFill
                      ? Icons.fullscreen_exit_rounded
                      : Icons.fullscreen_rounded,
                  color: Colors.white,
                  size: 24,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CtrlBtn extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _CtrlBtn(this.icon, this.onTap);

  @override
  Widget build(BuildContext context) => GestureDetector(
    onTap: onTap,
    child: Padding(
      padding: const EdgeInsets.all(8),
      child: Icon(icon, color: Colors.white, size: 24),
    ),
  );
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
        child: GestureDetector(
          onTap: onUnlock,
          child: Container(
            margin: const EdgeInsets.only(right: 16),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.55),
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white30, width: 1.5),
            ),
            child: const Icon(
              Icons.lock_rounded,
              color: Colors.white,
              size: 22,
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
          '${seconds.abs()}s',
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
          ElevatedButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('Retry'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
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
