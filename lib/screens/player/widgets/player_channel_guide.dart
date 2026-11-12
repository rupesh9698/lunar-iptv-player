import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import '../../../services/app_cache_manager.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/focus_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_player_provider.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/stream_proxy_service.dart';

/// TV Guide panel — shown at the bottom of the maximized Live TV player.
/// • Now / Next for the focused channel, with the live show's progress
/// • Horizontal channel strip (focused channel centred) → OK to switch
/// ([onMinimize] is kept for callers; minimize lives in the top bar.)
class PlayerChannelGuide extends ConsumerStatefulWidget {
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  const PlayerChannelGuide({
    super.key,
    required this.onMinimize,
    required this.onClose,
  });

  @override
  ConsumerState<PlayerChannelGuide> createState() => _PlayerChannelGuideState();
}

class _PlayerChannelGuideState extends ConsumerState<PlayerChannelGuide>
    with SingleTickerProviderStateMixin {
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode(debugLabel: 'channelGuide');
  int _focusedIndex = -1;

  /// The guide closes itself after this long without any key press.
  static const Duration _kIdleTimeout = Duration(seconds: 5);
  Timer? _idleTimer;

  void _bumpIdle() {
    _idleTimer?.cancel();
    _idleTimer = Timer(_kIdleTimeout, () {
      if (mounted) widget.onClose();
    });
  }

  late final AnimationController _animCtrl;
  late final Animation<Offset> _slideAnim;

  static const double _itemW = 84.0;
  static const double _itemGap = 10.0;
  static const double _stripPad = 16.0;

  // The info panel shows the focused channel's programmes; its guide data
  // is fetched once browsing pauses (not for every channel skipped past).
  Timer? _epgTimer;
  // Refreshes the progress bar while the guide is open.
  Timer? _tick;

  void _loadEpgSoon(int idx) {
    _epgTimer?.cancel();
    _epgTimer = Timer(const Duration(milliseconds: 250), () {
      if (!mounted) return;
      final channels = ref.read(filteredLiveStreamsProvider).value ?? [];
      if (idx >= 0 && idx < channels.length) {
        ref.read(epgCacheProvider.notifier).loadEpg(channels[idx].streamId);
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Take remote focus explicitly — autofocus alone is ignored when the
      // surrounding scope already has a focused child.
      if (mounted) _focusNode.requestFocus();
      _initFocus();
    });
    _bumpIdle();
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _idleTimer?.cancel();
    _epgTimer?.cancel();
    _tick?.cancel();
    _animCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _initFocus() {
    final channels = ref.read(filteredLiveStreamsProvider).value ?? [];
    final current = ref.read(selectedChannelProvider);
    if (current == null) return;
    final idx = channels.indexWhere((s) => s.streamId == current.streamId);
    if (idx < 0) return;
    setState(() => _focusedIndex = idx);
    _scrollToIndex(idx, animated: false);
  }

  /// Keeps the focused channel in the middle of the strip (the first and
  /// last few can't be centred, so they rest at the strip's ends).
  void _scrollToIndex(int idx, {bool animated = true}) {
    _loadEpgSoon(idx);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final pos = _scrollCtrl.position;
      final target =
          (_stripPad +
                  idx * (_itemW + _itemGap) +
                  _itemW / 2 -
                  pos.viewportDimension / 2)
              .clamp(0.0, pos.maxScrollExtent);
      if (animated && !TvKeyTracker.isRepeating) {
        _scrollCtrl.animateTo(
          target,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      } else {
        _scrollCtrl.jumpTo(target);
      }
    });
  }

  Future<void> _selectChannel(int idx, LiveStream ch) async {
    _bumpIdle();
    // OK on the channel that is already playing: just close the guide
    // (don't restart the stream).
    if (ref.read(selectedChannelProvider)?.streamId == ch.streamId) {
      widget.onClose();
      return;
    }
    setState(() => _focusedIndex = idx);

    ref.read(selectedChannelProvider.notifier).state = ch;
    ref.read(epgCacheProvider.notifier).loadEpg(ch.streamId);
    ref.read(recentlyViewedLiveProvider.notifier).add(ch.streamId);

    final service = ref.read(xtreamServiceProvider);
    if (service != null) {
      await ref
          .read(livePlayerProvider.notifier)
          .openChannel(service.getLiveUrl(ch.streamId));
    }

    // Close guide after selection so the player takes full focus
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final channel = ref.watch(selectedChannelProvider);
    final epgCache = ref.watch(epgCacheProvider);
    final channelsVal = ref.watch(filteredLiveStreamsProvider);
    final channels = channelsVal.value ?? [];

    // Info follows the channel being browsed (the playing one to start).
    final infoCh = _focusedIndex >= 0 && _focusedIndex < channels.length
        ? channels[_focusedIndex]
        : channel;
    final epg = infoCh != null
        ? (epgCache[infoCh.streamId] ?? const <EpgListing>[])
        : const <EpgListing>[];
    final now = DateTime.now();
    final current = epg.currentAt(now);
    final next = epg.nextAt(now);
    final later = next != null
        ? epg.nextAt(next.startTime.add(const Duration(seconds: 1)))
        : null;

    return SlideTransition(
      position: _slideAnim,
      child: Focus(
        focusNode: _focusNode,
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is KeyUpEvent) return KeyEventResult.ignored;
          _bumpIdle(); // any key keeps the guide open for another 5 s
          final isDown = event is KeyDownEvent;

          if (event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.goBack) {
            if (isDown) widget.onClose();
            return KeyEventResult.handled;
          }
          // Up / Down close the strip (back to the full-screen player).
          if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
              event.logicalKey == LogicalKeyboardKey.arrowDown) {
            if (isDown) widget.onClose();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
              _focusedIndex > 0) {
            final ni = _focusedIndex - 1;
            setState(() => _focusedIndex = ni);
            _scrollToIndex(ni);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
              _focusedIndex < channels.length - 1) {
            final ni = _focusedIndex + 1;
            setState(() => _focusedIndex = ni);
            _scrollToIndex(ni);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            if (isDown &&
                _focusedIndex >= 0 &&
                _focusedIndex < channels.length) {
              _selectChannel(_focusedIndex, channels[_focusedIndex]);
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.96),
              ],
              stops: const [0.0, 0.25],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Now / Next for the focused channel ─────────────────
                if (infoCh != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      _stripPad,
                      16,
                      _stripPad,
                      0,
                    ),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 820),
                      child: _NowNextPanel(
                        key: ValueKey(infoCh.streamId),
                        playing: infoCh.streamId == channel?.streamId,
                        loaded: epgCache.containsKey(infoCh.streamId),
                        now: now,
                        current: current,
                        next: next,
                        later: later,
                      ),
                    ),
                  ),

                const SizedBox(height: 14),

                // ── Channel strip ──────────────────────────────────────
                SizedBox(
                  height: 88,
                  child: channels.isEmpty
                      ? const Center(
                          child: Text(
                            'No channels',
                            style: TextStyle(color: Colors.white38),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollCtrl,
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.symmetric(
                            horizontal: _stripPad,
                          ),
                          itemCount: channels.length,
                          itemExtent: _itemW + _itemGap,
                          itemBuilder: (_, i) {
                            final ch = channels[i];
                            final isActive = channel?.streamId == ch.streamId;
                            final isFoc = _focusedIndex == i;
                            return Padding(
                              padding: const EdgeInsets.only(right: _itemGap),
                              child: _ChannelItem(
                                channel: ch,
                                isCurrent: isActive,
                                isFocused: isFoc,
                                width: _itemW,
                                onTap: () => _selectChannel(i, ch),
                              ),
                            );
                          },
                        ),
                ),

                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NOW / NEXT PANEL
// ─────────────────────────────────────────────────────────────────────────────
String _fmtDur(Duration d) {
  final m = d.inMinutes.clamp(0, 99999);
  if (m < 60) return '${m}m';
  final h = m ~/ 60, r = m % 60;
  return r == 0 ? '${h}h' : '${h}h ${r}m';
}

String _hm(DateTime t) => DateFormat('HH:mm').format(t);

/// What's on the focused channel: the live show with a progress bar
/// (start → end, elapsed and time left), its description, and the next
/// two shows.
class _NowNextPanel extends StatelessWidget {
  final bool playing; // the focused channel is the one on screen
  final bool loaded; // its guide data has arrived
  final DateTime now;
  final EpgListing? current;
  final EpgListing? next;
  final EpgListing? later;

  const _NowNextPanel({
    super.key,
    required this.playing,
    required this.loaded,
    required this.now,
    required this.current,
    required this.next,
    required this.later,
  });

  @override
  Widget build(BuildContext context) {
    final cur = current;
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 180),
      child: Column(
        key: ValueKey('${cur?.startTimestamp}-$loaded'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _Tag(
                playing ? 'WATCHING' : 'ON NOW',
                color: playing ? AppTheme.error : AppTheme.primary,
                dot: playing,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  cur?.decodedTitle.isNotEmpty == true
                      ? cur!.decodedTitle
                      : (loaded
                            ? 'No programme information'
                            : 'Loading guide…'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: cur != null ? Colors.white : Colors.white54,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          if (cur != null) ...[
            const SizedBox(height: 10),
            _ShowProgress(show: cur, now: now),
            if (cur.decodedDescription.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                cur.decodedDescription,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: 12,
                  height: 1.35,
                ),
              ),
            ],
          ],
          if (next != null) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 18,
              runSpacing: 6,
              children: [
                _UpNext(label: 'NEXT', show: next!, now: now),
                if (later != null)
                  _UpNext(label: 'LATER', show: later!, now: now),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String text;
  final Color color;
  final bool dot;
  const _Tag(this.text, {required this.color, this.dot = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.18),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.7)),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (dot) ...[
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
        ],
        Text(
          text,
          style: TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.8,
          ),
        ),
      ],
    ),
  );
}

/// 23:18 ━━━━━━●────── 02:17   ·   52m in · 1h 23m left
class _ShowProgress extends StatelessWidget {
  final EpgListing show;
  final DateTime now;
  const _ShowProgress({required this.show, required this.now});

  @override
  Widget build(BuildContext context) {
    final total = show.endTime.difference(show.startTime);
    final done = now.difference(show.startTime);
    final frac = total.inSeconds <= 0
        ? 0.0
        : (done.inSeconds / total.inSeconds).clamp(0.0, 1.0);
    // Time left rounds up (1:29:59 to go reads "1h 30m left").
    final left = Duration(
      minutes: (show.endTime.difference(now).inSeconds / 60).ceil(),
    );
    const time = TextStyle(
      color: Colors.white70,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
    );
    return Row(
      children: [
        Text(_hm(show.startTime), style: time),
        const SizedBox(width: 10),
        Expanded(
          child: SizedBox(
            height: 12,
            child: LayoutBuilder(
              builder: (_, c) {
                final w = c.maxWidth;
                return Stack(
                  clipBehavior: Clip.none,
                  alignment: Alignment.centerLeft,
                  children: [
                    Container(
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.18),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Container(
                      width: w * frac,
                      height: 4,
                      decoration: BoxDecoration(
                        color: AppTheme.primary,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    Positioned(
                      left: (w * frac - 6).clamp(0.0, w - 12),
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: Colors.white,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.6),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(_hm(show.endTime), style: time),
        const SizedBox(width: 16),
        Text(
          '${_fmtDur(done)} in · ',
          style: const TextStyle(color: Colors.white38, fontSize: 12),
        ),
        Text(
          '${_fmtDur(left)} left',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _UpNext extends StatelessWidget {
  final String label;
  final EpgListing show;
  final DateTime now;
  const _UpNext({required this.label, required this.show, required this.now});

  @override
  Widget build(BuildContext context) {
    final starts = show.startTime.difference(now);
    final len = show.endTime.difference(show.startTime);
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 380),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white38,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.8,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            _hm(show.startTime),
            style: const TextStyle(
              color: Colors.white70,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              show.decodedTitle.isEmpty ? 'Unknown' : show.decodedTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label == 'NEXT'
                ? 'in ${_fmtDur(starts)} · ${_fmtDur(len)}'
                : _fmtDur(len),
            style: const TextStyle(color: Colors.white38, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL ITEM
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelItem extends StatefulWidget {
  final LiveStream channel;
  final bool isCurrent;
  final bool isFocused;
  final double width;
  final VoidCallback onTap;

  const _ChannelItem({
    required this.channel,
    required this.isCurrent,
    required this.isFocused,
    required this.width,
    required this.onTap,
  });

  @override
  State<_ChannelItem> createState() => _ChannelItemState();
}

class _ChannelItemState extends State<_ChannelItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.isCurrent || widget.isFocused || _hover;

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          decoration: BoxDecoration(
            color: lit
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.isFocused
                  ? Colors.white
                  : widget.isCurrent
                  ? AppTheme.primary
                  : Colors.white.withValues(alpha: 0.12),
              width: widget.isFocused ? 3 : (widget.isCurrent ? 2 : 1),
            ),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Logo
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: SizedBox(
                  width: 52,
                  height: 36,
                  child: widget.channel.streamIcon?.isNotEmpty == true
                      ? CachedNetworkImage(
                          imageUrl: StreamProxyService.resolveImage(widget.channel.streamIcon!),
                          imageRenderMethodForWeb: StreamProxyService.imageMethod,
                          cacheManager: AppCacheManager.instance,
                          fit: BoxFit.contain,
                          memCacheWidth: 110,
                          placeholder: (_, _) => const Icon(
                            Icons.tv,
                            color: Colors.white30,
                            size: 18,
                          ),
                          errorWidget: (_, _, _) => const Icon(
                            Icons.tv,
                            color: Colors.white30,
                            size: 18,
                          ),
                        )
                      : const Icon(Icons.tv, color: Colors.white30, size: 18),
                ),
              ),
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  widget.channel.name,
                  style: TextStyle(
                    color: widget.isCurrent ? Colors.white : Colors.white60,
                    fontSize: 9,
                    fontWeight: widget.isCurrent
                        ? FontWeight.w700
                        : FontWeight.w400,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
