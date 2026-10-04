import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/stream_proxy_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

// ── Player State ──────────────────────────────────────────────────────────────
class LivePlayerState {
  final bool isInitialized;
  final bool isPlaying;
  final bool isBuffering;
  final String error;
  final String quality;
  final double volume;
  final String? currentUrl;
  final int reconnectAttempt;
  final bool isReconnecting;

  const LivePlayerState({
    this.isInitialized = false,
    this.isPlaying = false,
    this.isBuffering = false,
    this.error = '',
    this.quality = '',
    this.volume = 1.0,
    this.currentUrl,
    this.reconnectAttempt = 0,
    this.isReconnecting = false,
  });

  LivePlayerState copyWith({
    bool? isInitialized,
    bool? isPlaying,
    bool? isBuffering,
    String? error,
    String? quality,
    double? volume,
    String? currentUrl,
    int? reconnectAttempt,
    bool? isReconnecting,
  }) => LivePlayerState(
    isInitialized: isInitialized ?? this.isInitialized,
    isPlaying: isPlaying ?? this.isPlaying,
    isBuffering: isBuffering ?? this.isBuffering,
    error: error ?? this.error,
    quality: quality ?? this.quality,
    volume: volume ?? this.volume,
    currentUrl: currentUrl ?? this.currentUrl,
    reconnectAttempt: reconnectAttempt ?? this.reconnectAttempt,
    isReconnecting: isReconnecting ?? this.isReconnecting,
  );
}

// ── Notifier ──────────────────────────────────────────────────────────────────
class LivePlayerNotifier extends StateNotifier<LivePlayerState> {
  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription> _subs = [];
  Timer? _reconnectTimer;

  static const int _maxReconnects = 3;

  LivePlayerNotifier() : super(const LivePlayerState());

  /// Expose for the Video widget — never changes after first init.
  VideoController? get videoController => _videoController;

  void _ensureInitialized() {
    if (_player != null) return;
    _player = Player();
    _videoController = VideoController(_player!);
    _subscribe();
    if (mounted) state = state.copyWith(isInitialized: true);
  }

  void _subscribe() {
    final p = _player!;
    _subs.addAll([
      p.stream.playing.listen((v) {
        if (mounted) state = state.copyWith(isPlaying: v);
      }),
      p.stream.buffering.listen((v) {
        if (mounted) state = state.copyWith(isBuffering: v);
      }),
      p.stream.videoParams.listen((v) {
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
        if (q.isNotEmpty) state = state.copyWith(quality: q);
      }),
      p.stream.error.listen((e) {
        if (e.isEmpty || !mounted) return;
        _handleError(e);
      }),
    ]);
  }

  Future<void> openChannel(String url) async {
    _ensureInitialized();
    _reconnectTimer?.cancel();
    if (!mounted) return;

    // On web, proxy HTTP streams through Cloud Run (HLS/TS compatible)
    final resolvedUrl = StreamProxyService.resolveStream(url);

    state = state.copyWith(
      currentUrl: resolvedUrl,
      error: '',
      reconnectAttempt: 0,
      isReconnecting: false,
      isBuffering: true,
      quality: '',
    );

    await _configureMpv();
    try {
      await _player!.open(Media(resolvedUrl));
      await _player!.setVolume(state.volume * 100);
    } catch (e) {
      if (mounted) {
        state = state.copyWith(
          isBuffering: false,
          error: 'Stream unavailable',
        );
      }
    }
  }

  Future<void> _configureMpv() async {
    try {
      final p = _player as dynamic;

      // ── Fast profile FIRST — mpv's built-in low-end preset. Applying it
      // first means every explicit override below wins, but we inherit
      // every low-cost default mpv maintainers already tuned (disables
      // a cluster of expensive post-processing filters in one shot,
      // safer/more complete than hand-picking flags one by one).
      await p.setProperty('profile', 'fast');

      // ── Video output — 'gpu' (not 'gpu-next') is the leaner, more
      // battle-tested path on Android's OpenGL ES surface. gpu-next uses
      // a heavier internal pipeline that isn't worth it below 1080p60.
      await p.setProperty('vo', 'gpu');
      await p.setProperty('gpu-context', 'android');
      // Keep the swapchain shallow — deeper queues add latency and let
      // weak GPUs fall further behind before a dropped frame is visible.
      await p.setProperty('swapchain-depth', '3');

      // ── Decode — 'auto' engages MediaCodec hardware decode on Android;
      // falls back to software automatically if a codec path is missing.
      await p.setProperty('hwdec', 'auto');
      await p.setProperty(
          'hwdec-codecs', 'h264,hevc,mpeg2video,vp8,vp9,av1');

      // ── Network ────────────────────────────────────────────────────────────
      await p.setProperty('network-timeout', '15');
      await p.setProperty(
        'stream-lavf-o',
        'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,'
            'reconnect_delay_max=2,timeout=12000000,'
            'live_start_index=-1,fflags=nobuffer,analyzeduration=1000000',
      );

      // ── Buffer — 8s absorbs HLS segment boundaries and jitter without
      // ever seeking backward.
      await p.setProperty('cache', 'yes');
      await p.setProperty('cache-secs', '8');
      await p.setProperty('cache-initial', '0');
      await p.setProperty('cache-pause', 'no');
      await p.setProperty('cache-pause-initial', 'no');
      await p.setProperty('cache-pause-wait', '0');
      await p.setProperty('demuxer-max-bytes', '16MiB');
      await p.setProperty('demuxer-max-back-bytes', '1MiB');
      await p.setProperty('demuxer-seekable-cache', 'no');
      await p.setProperty('hls-bitrate', 'max');

      // ── Video decode / drop ──────────────────────────────────────────────
      await p.setProperty('video-sync', 'audio');
      await p.setProperty('framedrop', 'vo');
      await p.setProperty('vd-lavc-threads', '0');
      await p.setProperty('vd-lavc-fast', 'yes');
      await p.setProperty('vd-lavc-skiploopfilter', 'all');
      await p.setProperty('vd-lavc-skipidct', 'nonkey');
      await p.setProperty('vd-lavc-skipframe', 'nonref');
      // Disable dropped-frame-on-seek precision — never needed for live/IPTV
      await p.setProperty('hr-seek', 'no');

      // ── Audio ──────────────────────────────────────────────────────────────
      await p.setProperty('audio-buffer', '0.2');
      await p.setProperty('audio-latency-hack', 'yes');

      // ── Output — every one of these is a real per-frame GPU pass; none
      // are needed for compressed IPTV/streaming content.
      await p.setProperty('scale', 'bilinear');
      await p.setProperty('dscale', 'bilinear');
      await p.setProperty('cscale', 'bilinear');
      await p.setProperty('correct-downscaling', 'no');
      await p.setProperty('sigmoid-upscaling', 'no');
      await p.setProperty('video-latency-hacks', 'yes');
      await p.setProperty('deband', 'no');
      await p.setProperty('blend-subtitles', 'no');
      await p.setProperty('interpolation', 'no');
      await p.setProperty('dither-depth', 'no');
      await p.setProperty('correct-pts', 'yes');
      // OSD/subtitle scaling at video resolution is cheaper than display res
      await p.setProperty('osd-scale-by-window', 'no');
    } catch (_) {}
  }

  void _handleError(String error) {
    if (!mounted) return;
    final attempt = state.reconnectAttempt;
    if (attempt < _maxReconnects && state.currentUrl != null) {
      final next = attempt + 1;
      state = state.copyWith(
        isReconnecting: true,
        reconnectAttempt: next,
        error: '',
      );
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(seconds: next * 3), () {
        if (!mounted || state.currentUrl == null) return;
        state = state.copyWith(isReconnecting: false);
        _player!.open(Media(state.currentUrl!));
      });
    } else {
      state = state.copyWith(
        error: 'Stream unavailable',
        isReconnecting: false,
      );
    }
  }

  void togglePlayPause() => _player?.playOrPause();

  void setVolume(double v) {
    final c = v.clamp(0.0, 1.0);
    _player?.setVolume(c * 100);
    if (mounted) state = state.copyWith(volume: c);
  }

  Future<void> stop() async {
    _reconnectTimer?.cancel();
    try {
      // pause() cuts audio immediately on all platforms;
      // stop() then releases the demuxer/decoder pipeline.
      await _player?.pause();
      await _player?.stop();
    } catch (_) {}
    if (mounted) {
      state = const LivePlayerState();
    }
  }

  void pause() {
    try {
      _player?.pause();
    } catch (_) {}
  }

  void retry() {
    if (state.currentUrl != null) openChannel(state.currentUrl!);
  }

  void clearError() {
    if (mounted) {
      state = state.copyWith(error: '', isReconnecting: false);
    }
  }

  @override
  void dispose() {
    _reconnectTimer?.cancel();
    for (final s in _subs) {
      s.cancel();
    }
    _player?.dispose();
    super.dispose();
  }
}

// ── Provider ──────────────────────────────────────────────────────────────────
final livePlayerProvider =
    StateNotifierProvider<LivePlayerNotifier, LivePlayerState>(
      (ref) => LivePlayerNotifier(),
    );
