import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:cached_network_image/cached_network_image.dart';

import '../../../core/theme/app_theme.dart';
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

  const LiveInlinePlayer({
    super.key,
    required this.isMaximized,
    required this.onMaximize,
    required this.onMinimize,
  });

  @override
  ConsumerState<LiveInlinePlayer> createState() => _LiveInlinePlayerState();
}

class _LiveInlinePlayerState extends ConsumerState<LiveInlinePlayer> {
  bool _ctrlVisible = true;
  Timer? _hideTimer;
  bool _locked = false;
  bool _videoFill = false;
  bool _showChannelGuide = false;

  // Gesture
  bool _isDragging = false;
  bool _dragIsLeft = false;
  bool _showVol = false;
  bool _showBright = false;
  double _brightness = 0.5;
  Offset _lastTap = Offset.zero;
  bool _showSkipLeft = false;
  bool _showSkipRight = false;

  // Channel switching
  LiveStream? _switchingChannel;
  int _switchCurrentIndex = -1;
  int _switchTotalChannels = 0;
  Timer? _channelSwitchTimer;

  @override
  void initState() {
    super.initState();
    _resetHideTimer();
  }

  @override
  void didUpdateWidget(LiveInlinePlayer old) {
    super.didUpdateWidget(old);
    if (old.isMaximized != widget.isMaximized) {
      setState(() {
        _ctrlVisible = true;
        _showChannelGuide = false;
      });
      _resetHideTimer();
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _channelSwitchTimer?.cancel();
    super.dispose();
  }

  void _resetHideTimer() {
    _hideTimer?.cancel();
    if (!_ctrlVisible && mounted) setState(() => _ctrlVisible = true);
    _hideTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && !_locked) setState(() => _ctrlVisible = false);
    });
  }

  void _toggleControls() {
    if (_locked) return;
    setState(() => _ctrlVisible = !_ctrlVisible);
    if (_ctrlVisible) _resetHideTimer();
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
      _channelSwitchTimer = Timer(const Duration(seconds: 2), () {
        if (mounted) setState(() => _switchingChannel = null);
      });
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
    final current = epg.isNotEmpty ? epg.first : null;
    final next = epg.length > 1 ? epg[1] : null;

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

    return Container(
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
              onTogglePlay: () =>
                  ref.read(livePlayerProvider.notifier).togglePlayPause(),
              onVolumeChange: (v) =>
                  ref.read(livePlayerProvider.notifier).setVolume(v),
            ),
          ),
        ],
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
              _OverlayBtn(
                icon: ps.isPlaying
                    ? Icons.pause_rounded
                    : Icons.play_arrow_rounded,
                onTap: () =>
                    ref.read(livePlayerProvider.notifier).togglePlayPause(),
              ),
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
      autofocus: !_showChannelGuide,
      onKeyEvent: (_, event) {
        if (event is! KeyDownEvent) return KeyEventResult.ignored;

        if (event.logicalKey == LogicalKeyboardKey.keyG ||
            (!_ctrlVisible &&
                event.logicalKey == LogicalKeyboardKey.arrowDown)) {
          setState(() => _showChannelGuide = !_showChannelGuide);
          return KeyEventResult.handled;
        }
        if (_showChannelGuide) return KeyEventResult.ignored;

        if (event.logicalKey == LogicalKeyboardKey.pageUp ||
            event.logicalKey == LogicalKeyboardKey.channelUp ||
            event.logicalKey == LogicalKeyboardKey.arrowUp) {
          _switchChannel(-1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.pageDown ||
            event.logicalKey == LogicalKeyboardKey.channelDown ||
            event.logicalKey == LogicalKeyboardKey.arrowDown) {
          _switchChannel(1);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.space) {
          _toggleControls();
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape ||
            event.logicalKey == LogicalKeyboardKey.goBack) {
          widget.onMinimize();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
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
                      onTap: _showChannelGuide
                          ? () => setState(() => _showChannelGuide = false)
                          : _toggleControls,
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
                child: IgnorePointer(
                  ignoring: !_ctrlVisible,
                  child: _MaximizedControls(
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
                    onToggleFit: () => setState(() => _videoFill = !_videoFill),
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
                  onClose: () => setState(() => _showChannelGuide = false),
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
  final LiveStream? channel;
  final LivePlayerState ps;
  final bool isVideoFill;
  final bool isFavorite;
  final VoidCallback onMinimize;
  final VoidCallback onLock;
  final VoidCallback onTogglePlay;
  final ValueChanged<double> onVolumeChange;
  final VoidCallback onToggleFit;
  final VoidCallback? onToggleFav;
  final VoidCallback onPrevChannel;
  final VoidCallback onNextChannel;
  final VoidCallback onToggleGuide;

  const _MaximizedControls({
    required this.channel,
    required this.ps,
    required this.isVideoFill,
    required this.isFavorite,
    required this.onMinimize,
    required this.onLock,
    required this.onTogglePlay,
    required this.onVolumeChange,
    required this.onToggleFit,
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

            // Center play
            GestureDetector(
              onTap: onTogglePlay,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 60,
                height: 60,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.35),
                    width: 1.5,
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
                      child: Slider(
                        value: ps.volume,
                        onChanged: onVolumeChange,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
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
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
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
      child: Tooltip(
        message: widget.tooltip,
        child: GestureDetector(
          onTap: widget.onTap,
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _focused
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.transparent,
                border: _focused
                    ? Border.all(color: Colors.white.withValues(alpha: 0.5))
                    : null,
              ),
              child: Icon(widget.icon, color: Colors.white, size: 24),
            ),
          ),
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

  const _InfoPane({
    required this.channel,
    required this.current,
    required this.next,
    required this.ps,
    required this.onWatchNow,
    required this.onTogglePlay,
    required this.onVolumeChange,
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
  const _FocusableElevatedButton({
    required this.label,
    required this.icon,
    required this.onTap,
  });

  @override
  State<_FocusableElevatedButton> createState() =>
      _FocusableElevatedButtonState();
}

class _FocusableElevatedButtonState extends State<_FocusableElevatedButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
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
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: _focused
              ? Border.all(color: Colors.white.withValues(alpha: 0.7), width: 2)
              : null,
        ),
        child: ElevatedButton.icon(
          onPressed: widget.onTap,
          icon: Icon(widget.icon, size: 18),
          label: Text(widget.label),
          style: ElevatedButton.styleFrom(
            backgroundColor: _focused
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
                    width: 80,
                    height: 54,
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
