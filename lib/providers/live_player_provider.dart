import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/stream_proxy_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../core/utils/player_tuning.dart';

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

  Future<void>? _tuned;

  void _ensureInitialized() {
    if (_player != null) return;
    _player = Player(configuration: PlayerTuning.playerConfig());
    _videoController = VideoController(
      _player!,
      configuration: PlayerTuning.videoConfig(),
    );
    // Tune ONCE per player (it used to re-send ~40 options on every
    // channel change, slowing down zapping).
    _tuned = PlayerTuning.apply(_player!, live: true);
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

    await _tuned;
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
