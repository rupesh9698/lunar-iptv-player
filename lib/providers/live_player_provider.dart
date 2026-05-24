import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
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
  }) =>
      LivePlayerState(
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
    state = state.copyWith(
      currentUrl: url,
      error: '',
      reconnectAttempt: 0,
      isReconnecting: false,
      isBuffering: true,
      quality: '',
    );
    await _configureMpv();
    await _player!.open(Media(url));
    await _player!.setVolume(state.volume * 100);
  }

  Future<void> _configureMpv() async {
    try {
      final p = _player as dynamic;
      await p.setProperty('network-timeout', '20');
      await p.setProperty('cache', 'yes');
      await p.setProperty('cache-secs', '15');
      await p.setProperty('cache-initial', '0');
      await p.setProperty('cache-pause', 'no');
      await p.setProperty('cache-pause-initial', 'no');
      await p.setProperty('demuxer-max-bytes', '50MiB');
      await p.setProperty('demuxer-readahead-secs', '10');
      await p.setProperty('stream-lavf-o',
          'reconnect=1,reconnect_at_eof=1,reconnect_streamed=1,'
              'reconnect_delay_max=5,timeout=20000000,rw_timeout=5000000');
      await p.setProperty('hwdec', 'auto-safe');
      await p.setProperty('video-sync', 'audio');
    } catch (_) {}
  }

  void _handleError(String error) {
    if (!mounted) return;
    final attempt = state.reconnectAttempt;
    if (attempt < _maxReconnects && state.currentUrl != null) {
      final next = attempt + 1;
      state = state.copyWith(
          isReconnecting: true, reconnectAttempt: next, error: '');
      _reconnectTimer?.cancel();
      _reconnectTimer = Timer(Duration(seconds: next * 3), () {
        if (!mounted || state.currentUrl == null) return;
        state = state.copyWith(isReconnecting: false);
        _player!.open(Media(state.currentUrl!));
      });
    } else {
      state = state.copyWith(
          error: 'Stream unavailable', isReconnecting: false);
    }
  }

  void togglePlayPause() => _player?.playOrPause();

  void setVolume(double v) {
    final c = v.clamp(0.0, 1.0);
    _player?.setVolume(c * 100);
    if (mounted) state = state.copyWith(volume: c);
  }

  void stop() {
    _reconnectTimer?.cancel();
    try {
      _player?.stop();
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
    if (mounted) state = state.copyWith(error: '', isReconnecting: false);
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