import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/performance.dart';
import '../../providers/app_providers.dart';
import '../../services/cache_service.dart';
import '../../services/m3u_service.dart';

enum _FetchStatus { idle, loading, done, failed }

class _SyncItem {
  final String label;
  final IconData icon;

  /// Card accent (ring, glow, background tint while it syncs).
  final Color accent;
  _FetchStatus status = _FetchStatus.idle;

  /// Result line ("14,890 channels", "Synced 3h ago") or, while loading,
  /// progress ("Retrying, 1 of 3").
  String? subtitle;
  String? errorMessage;

  _SyncItem(this.label, this.icon, this.accent);
}

const _liveAccent = Color(0xFFFF5A7A);
const _moviesAccent = Color(0xFF4F8DFF);
const _seriesAccent = Color(0xFFB57BFF);

final _count = NumberFormat.decimalPattern();

class SyncScreen extends ConsumerStatefulWidget {
  final bool isManualRefresh;
  const SyncScreen({super.key, this.isManualRefresh = false});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  List<_SyncItem> _items = [
    _SyncItem('Live TV', Icons.live_tv_rounded, _liveAccent),
    _SyncItem('Movies', Icons.movie_creation_outlined, _moviesAccent),
    _SyncItem('Series', Icons.video_library_outlined, _seriesAccent),
  ];

  bool _hasAnyFailure = false;
  bool _finished = false;
  int _active = -1;

  static const int _maxRetries = 3;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSync());
  }

  // Strong retry with timeout
  Future<T> _withRetry<T>(
    Future<T> Function() operation, {
    required String operationName,
    int maxRetries = _maxRetries,
  }) async {
    int attempt = 0;

    while (attempt <= maxRetries) {
      try {
        return await operation().timeout(
          const Duration(seconds: 25),
          onTimeout: () => throw TimeoutException('$operationName timed out'),
        );
      } catch (e) {
        attempt++;

        if (attempt > maxRetries) {
          rethrow;
        }

        final delay = Duration(milliseconds: 700 * attempt);
        if (mounted && _active >= 0) {
          setState(() {
            _items[_active].subtitle = 'Retrying, $attempt of $maxRetries';
          });
        }
        await Future.delayed(delay);
      }
    }
    throw Exception('$operationName failed after $maxRetries retries');
  }

  Future<void> _runSync() async {
    final playlist = ref.read(activePlaylistProvider);
    if (playlist == null) {
      if (mounted) context.go('/home');
      return;
    }

    final cache = CacheService.instance;
    cache.setActivePlaylist(playlist.id);

    setState(() => _hasAnyFailure = false);

    // ── Guard: skip sync if data exists AND is fresh AND not manual ──────────
    // This prevents the double-sync-on-restart bug.
    if (!widget.isManualRefresh) {
      final hasData = cache.liveStreamsNonEmpty() ?? false;
      final isFresh = playlist.isM3u
          ? hasData // M3U: any cached data = fresh (no daily expiry)
          : hasData && !cache.isLiveStale(); // Xtream: check 24h expiry

      if (isFresh) {
        // Data is ready: go straight to home without showing sync screen
        if (mounted) context.go('/home');
        return;
      }
    }

    if (playlist.isM3u) {
      // ── M3U sync ────────────────────────────────────────────────────────
      setState(() {
        _items = [
          _SyncItem('Live TV', Icons.playlist_play_rounded, _liveAccent),
        ];
      });

      if (widget.isManualRefresh || cache.isLiveStale()) {
        await _step(0, () async {
          final m3uUrl = playlist.m3uUrl!;
          final (cats, streams) = await M3uService.fetchAndParse(m3uUrl);
          await cache.saveLiveCategories(cats);
          await cache.saveLiveStreams(streams);
          await cache.saveContentFlags(
            hasLive: streams.isNotEmpty,
            hasVod: false,
            hasSeries: false,
          );
          _items[0].subtitle =
              '${_count.format(streams.length)} channels\n'
              '${_count.format(cats.length)} categories';
        });
      } else {
        _markDone(0);
      }

      ref.invalidate(liveCategoriesProvider);
      ref.invalidate(liveAllStreamsProvider);
    } else {
      // ── Xtream sync ─────────────────────────────────────────────────────
      final service = ref.read(xtreamServiceProvider);
      if (service == null) {
        if (mounted) context.go('/home');
        return;
      }

      bool hasLive = false, hasVod = false, hasSeries = false;

      // Live TV
      if (widget.isManualRefresh || cache.isLiveStale()) {
        await _step(0, () async {
          final cats = await _withRetry(
            () => service.getLiveCategories(),
            operationName: 'Live TV Categories',
          );
          final ch = await _withRetry(
            () => service.getLiveStreams(),
            operationName: 'Live TV Streams',
          );
          await cache.saveLiveCategories(cats);
          await cache.saveLiveStreams(ch);
          _items[0].subtitle = '${_count.format(ch.length)} channels';
          hasLive = ch.isNotEmpty;
        });
      } else {
        _markDone(0);
        hasLive = cache.liveStreamsNonEmpty() ?? true;
      }

      // Movies
      if (widget.isManualRefresh || cache.isVodStale()) {
        await _step(1, () async {
          final cats = await _withRetry(
            () => service.getVodCategories(),
            operationName: 'Movies Categories',
          );
          final streams = await _withRetry(
            () => service.getVodStreams(),
            operationName: 'Movies Library',
          );
          await cache.saveVodCategories(cats);
          await cache.saveVodStreams(streams);
          _items[1].subtitle = '${_count.format(streams.length)} movies';
          hasVod = streams.isNotEmpty;
        });
      } else {
        _markDone(1);
        hasVod = cache.vodStreamsNonEmpty() ?? true;
      }

      // Series
      if (widget.isManualRefresh || cache.isSeriesStale()) {
        await _step(2, () async {
          final cats = await _withRetry(
            () => service.getSeriesCategories(),
            operationName: 'Series Categories',
          );
          final series = await _withRetry(
            () => service.getSeries(),
            operationName: 'Series Library',
          );
          await cache.saveSeriesCategories(cats);
          await cache.saveSeriesList(series);
          _items[2].subtitle = '${_count.format(series.length)} series';
          hasSeries = series.isNotEmpty;
        });
      } else {
        _markDone(2);
        hasSeries = cache.seriesListNonEmpty() ?? true;
      }

      await cache.saveContentFlags(
        hasLive: hasLive,
        hasVod: hasVod,
        hasSeries: hasSeries,
      );

      ref.invalidate(liveCategoriesProvider);
      ref.invalidate(liveAllStreamsProvider);
      ref.invalidate(vodCategoriesProvider);
      ref.invalidate(vodAllStreamsProvider);
      ref.invalidate(seriesCategoriesProvider);
      ref.invalidate(seriesAllListProvider);
    }

    ref.read(cacheLastSyncProvider.notifier).state = DateTime.now();

    if (mounted) {
      setState(() {
        _finished = true;
        _active = -1;
      });
    }

    await Future.delayed(const Duration(milliseconds: 1100));
    if (mounted) context.go('/home');
  }

  void _markDone(int idx) {
    if (!mounted) return;
    final ts = idx == 0
        ? CacheService.instance.lastUpdatedLive()
        : idx == 1
        ? CacheService.instance.lastUpdatedVod()
        : CacheService.instance.lastUpdatedSeries();
    final sub = ts != null ? 'Synced ${_relTime(ts)}' : 'Up to date';
    setState(() {
      _items[idx].status = _FetchStatus.done;
      _items[idx].subtitle = sub;
    });
  }

  static String _relTime(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 1) return 'just now';
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays}d ago';
  }

  Future<void> _step(int idx, Future<void> Function() work) async {
    if (!mounted) return;

    setState(() {
      _active = idx;
      _items[idx].status = _FetchStatus.loading;
      _items[idx].subtitle = null;
      _items[idx].errorMessage = null;
    });

    try {
      await work();
      if (mounted) {
        setState(() => _items[idx].status = _FetchStatus.done);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _items[idx].status = _FetchStatus.failed;
          _items[idx].subtitle = "Couldn't sync this time";
          _items[idx].errorMessage = e.toString();
          _hasAnyFailure = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => _SyncView(
    items: _items,
    active: _active,
    finished: _finished,
    hasAnyFailure: _hasAnyFailure,
  );
}

/// Sync screen with fake progress, for previews / widget tests.
/// [states]: one of 'idle', 'loading', 'done', 'failed' per card.
@visibleForTesting
Widget debugSyncPreview(
  List<String> states, {
  List<String?> subtitles = const [],
  bool finished = false,
}) {
  final items = [
    _SyncItem('Live TV', Icons.live_tv_rounded, _liveAccent),
    _SyncItem('Movies', Icons.movie_creation_outlined, _moviesAccent),
    _SyncItem('Series', Icons.video_library_outlined, _seriesAccent),
  ];
  for (var i = 0; i < states.length; i++) {
    items[i].status = _FetchStatus.values.byName(states[i]);
    if (i < subtitles.length) items[i].subtitle = subtitles[i];
  }
  return _SyncView(
    items: items,
    active: states.indexOf('loading'),
    finished: finished,
    hasAnyFailure: states.contains('failed'),
  );
}

class _SyncView extends StatelessWidget {
  final List<_SyncItem> items;
  final int active;
  final bool finished;
  final bool hasAnyFailure;

  const _SyncView({
    required this.items,
    required this.active,
    required this.finished,
    required this.hasAnyFailure,
  });

  @override
  Widget build(BuildContext context) {
    final accent = active >= 0
        ? items[active].accent
        : finished
        ? (hasAnyFailure ? AppTheme.warning : AppTheme.success)
        : AppTheme.primary;

    final String title;
    final String subtitle;
    if (finished) {
      title = hasAnyFailure ? 'Almost there' : 'All set';
      subtitle = hasAnyFailure
          ? "Some parts didn't sync. Opening what we have"
          : 'Opening your library';
    } else if (active >= 0) {
      title = 'Updating your library';
      subtitle = items.length > 1
          ? 'Step ${active + 1} of ${items.length} · ${items[active].label}'
          : 'Getting your channels';
    } else {
      title = 'Updating your library';
      subtitle = 'Getting ready';
    }

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // Soft glow in the colour of whatever is syncing. Static paint;
          // it only animates when the step changes.
          Positioned.fill(child: _Backdrop(color: accent)),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, box) {
                final short = box.maxHeight < 420;
                return Column(
                  children: [
                    const _TopBar(),
                    _Headline(
                      title: title,
                      subtitle: subtitle,
                      compact: short,
                      steps: items.map((i) => i.status).toList(),
                      accents: items.map((i) => i.accent).toList(),
                    ),
                    Expanded(
                      child: _Cards(items: items, active: active),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Backdrop
class _Backdrop extends StatelessWidget {
  final Color color;
  const _Backdrop({required this.color});

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: color),
        duration: const Duration(milliseconds: 700),
        builder: (context, c, _) => DecoratedBox(
          decoration: BoxDecoration(
            gradient: RadialGradient(
              center: const Alignment(0, 0.15),
              radius: 1.1,
              colors: [
                (c ?? color).withValues(alpha: 0.13),
                AppTheme.background.withValues(alpha: 0),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Top bar: logo · name · clock (the clock ticks on its own, so the rest
// of the screen never rebuilds once a second)
class _TopBar extends StatelessWidget {
  const _TopBar();

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final pad = w < 600 ? 16.0 : 32.0;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad, 14, pad, 0),
      child: Row(
        children: [
          SizedBox(
            width: 34,
            height: 34,
            child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
          ),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              'Lunar IPTV Player',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.2,
              ),
            ),
          ),
          const SizedBox(width: 12),
          const _Clock(),
        ],
      ),
    );
  }
}

class _Clock extends StatefulWidget {
  const _Clock();

  @override
  State<_Clock> createState() => _ClockState();
}

class _ClockState extends State<_Clock> {
  DateTime _now = DateTime.now();
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Minute-precision clock: one rebuild a minute, aligned to the minute.
    _timer = Timer(Duration(seconds: 60 - _now.second), () {
      _tick();
      _timer = Timer.periodic(const Duration(minutes: 1), (_) => _tick());
    });
  }

  void _tick() {
    if (mounted) setState(() => _now = DateTime.now());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          DateFormat('hh:mm a').format(_now),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        Text(
          DateFormat('EEE, d MMM').format(_now),
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Headline + step bar
class _Headline extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool compact;
  final List<_FetchStatus> steps;
  final List<Color> accents;

  const _Headline({
    required this.title,
    required this.subtitle,
    required this.compact,
    required this.steps,
    required this.accents,
  });

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.sizeOf(context).width;
    final titleSize = (w * 0.032).clamp(20.0, 34.0);
    return Padding(
      padding: EdgeInsets.fromLTRB(24, compact ? 4 : 12, 24, compact ? 6 : 18),
      child: Column(
        children: [
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 350),
            child: Text(
              title,
              key: ValueKey(title),
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: compact ? titleSize * 0.8 : titleSize,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.2,
              ),
            ),
          ),
          SizedBox(height: compact ? 2 : 6),
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            child: Text(
              subtitle,
              key: ValueKey(subtitle),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: compact ? 12 : 14,
              ),
            ),
          ),
          SizedBox(height: compact ? 8 : 14),
          // One segment per step, coloured as it completes.
          SizedBox(
            width: math.min(w * 0.5, 420),
            height: 5,
            child: Row(
              children: [
                for (var i = 0; i < steps.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  Expanded(
                    child: _Segment(status: steps[i], accent: accents[i]),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Segment extends StatelessWidget {
  final _FetchStatus status;
  final Color accent;
  const _Segment({required this.status, required this.accent});

  @override
  Widget build(BuildContext context) {
    final fill = switch (status) {
      _FetchStatus.done => 1.0,
      _FetchStatus.failed => 1.0,
      _FetchStatus.loading => 0.5,
      _FetchStatus.idle => 0.0,
    };
    final color = switch (status) {
      _FetchStatus.done => AppTheme.success,
      _FetchStatus.failed => AppTheme.error,
      _ => accent,
    };
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: Colors.white.withValues(alpha: 0.08)),
          if (status == _FetchStatus.loading)
            _Sweep(color: color)
          else
            TweenAnimationBuilder<double>(
              tween: Tween(end: fill),
              duration: const Duration(milliseconds: 600),
              curve: Curves.easeOutCubic,
              builder: (context, v, _) => FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: v,
                child: ColoredBox(color: color),
              ),
            ),
        ],
      ),
    );
  }
}

/// A light band sliding along the active step (transform only, cheap).
class _Sweep extends StatefulWidget {
  final Color color;
  const _Sweep({required this.color});

  @override
  State<_Sweep> createState() => _SweepState();
}

class _SweepState extends State<_Sweep> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: widget.color.withValues(alpha: 0.35)),
        SlideTransition(
          position: Tween(
            begin: const Offset(-1, 0),
            end: const Offset(1.7, 0),
          ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut)),
          child: FractionallySizedBox(
            widthFactor: 0.6,
            alignment: Alignment.centerLeft,
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    widget.color.withValues(alpha: 0),
                    widget.color,
                    widget.color.withValues(alpha: 0),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Cards: the one syncing zooms in, the others step back.
class _Cards extends StatelessWidget {
  final List<_SyncItem> items;
  final int active;
  const _Cards({required this.items, required this.active});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, box) {
        // Landscape only (the app is locked to it). Phones get tighter
        // spacing; big screens keep cards a sensible shape.
        final hPad = box.maxWidth < 900 ? 24.0 : 40.0;
        final gap = box.maxWidth < 900 ? 16.0 : 24.0;
        final maxCardW = math.min(
          360.0,
          (box.maxWidth - 2 * hPad) / items.length,
        );
        final cardH = math.max(
          120.0,
          // Room for the active card's 6 % zoom above and below.
          math.min((box.maxHeight - 20) / 1.1, maxCardW * 1.05),
        );

        Widget card(int i) =>
            _SyncCard(
                  item: items[i],
                  isActive: i == active,
                  anyActive: active >= 0,
                )
                .animate(delay: (90 * i).ms)
                .fadeIn(duration: 380.ms)
                .moveY(begin: 18, end: 0, curve: Curves.easeOutCubic);

        return Padding(
          padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 20),
          child: Center(
            child: SizedBox(
              height: cardH,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0) SizedBox(width: gap),
                    SizedBox(width: maxCardW - gap, child: card(i)),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _SyncCard extends StatelessWidget {
  final _SyncItem item;
  final bool isActive;
  final bool anyActive;

  const _SyncCard({
    required this.item,
    required this.isActive,
    required this.anyActive,
  });

  @override
  Widget build(BuildContext context) {
    final low = Perf.enabled;
    final status = item.status;
    final isDone = status == _FetchStatus.done;
    final isFailed = status == _FetchStatus.failed;
    final idle = status == _FetchStatus.idle;

    // Zoom: the syncing card comes forward, the rest step back.
    final scale = isActive
        ? 1.06
        : anyActive
        ? 0.88
        : 1.0;
    final opacity = isActive || isDone || isFailed ? 1.0 : 0.55;

    final borderColor = isActive
        ? item.accent.withValues(alpha: 0.85)
        : isDone
        ? AppTheme.success.withValues(alpha: 0.45)
        : isFailed
        ? AppTheme.error.withValues(alpha: 0.55)
        : AppTheme.divider;

    final statusText = switch (status) {
      _FetchStatus.loading => item.subtitle ?? 'Syncing…',
      _FetchStatus.idle => 'Waiting',
      _ => item.subtitle ?? (isDone ? 'Done' : "Couldn't sync this time"),
    };

    return AnimatedScale(
      scale: scale,
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutBack,
      child: AnimatedOpacity(
        opacity: opacity,
        duration: const Duration(milliseconds: 350),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(22),
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                Color.alphaBlend(
                  item.accent.withValues(alpha: isActive ? 0.16 : 0.05),
                  AppTheme.surface,
                ),
                AppTheme.surface.withValues(alpha: 0.9),
              ],
            ),
            border: Border.all(color: borderColor, width: isActive ? 2 : 1),
            // A still glow (no animated blur: that was what made the
            // spinner stutter on TV boxes). Skipped in performance mode.
            boxShadow: isActive && !low
                ? [
                    BoxShadow(
                      color: item.accent.withValues(alpha: 0.22),
                      blurRadius: 28,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: LayoutBuilder(
            builder: (context, box) {
              final base = math.min(box.maxWidth, box.maxHeight);
              final disc = (base * 0.36).clamp(44.0, 128.0);
              final labelSize = (base * 0.075).clamp(14.0, 24.0);
              final subSize = (base * 0.052).clamp(11.0, 16.0);

              final emblem = _Emblem(
                item: item,
                size: disc,
                spinning: status == _FetchStatus.loading,
              );
              final texts = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    item.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: idle
                          ? AppTheme.textSecondary
                          : AppTheme.textPrimary,
                      fontSize: labelSize,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Text(
                      statusText,
                      key: ValueKey(statusText),
                      textAlign: TextAlign.center,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isFailed
                            ? AppTheme.error.withValues(alpha: 0.9)
                            : isActive
                            ? item.accent
                            : AppTheme.textSecondary,
                        fontSize: subSize,
                        fontWeight: isActive
                            ? FontWeight.w600
                            : FontWeight.w500,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              );

              return Stack(
                children: [
                  Positioned(top: 14, right: 14, child: _Badge(status: status)),
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          emblem,
                          SizedBox(height: base * 0.08),
                          texts,
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
    );
  }
}

class _Badge extends StatelessWidget {
  final _FetchStatus status;
  const _Badge({required this.status});

  @override
  Widget build(BuildContext context) {
    final icon = switch (status) {
      _FetchStatus.done => const Icon(
        Icons.check_circle_rounded,
        color: AppTheme.success,
        size: 24,
      ),
      _FetchStatus.failed => const Icon(
        Icons.error_rounded,
        color: AppTheme.error,
        size: 24,
      ),
      _ => null,
    };
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 300),
      transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
      child: icon ?? const SizedBox(width: 24, height: 24),
    );
  }
}

/// Icon disc with the loading ring around it.
class _Emblem extends StatelessWidget {
  final _SyncItem item;
  final double size;
  final bool spinning;
  const _Emblem({
    required this.item,
    required this.size,
    required this.spinning,
  });

  @override
  Widget build(BuildContext context) {
    final done = item.status == _FetchStatus.done;
    final idle = item.status == _FetchStatus.idle;
    final ring = size * 1.22;
    return SizedBox(
      width: ring,
      height: ring,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Color.alphaBlend(
                item.accent.withValues(alpha: idle ? 0.04 : 0.14),
                AppTheme.surfaceVariant,
              ),
              border: Border.all(
                color: done
                    ? AppTheme.success.withValues(alpha: 0.45)
                    : item.accent.withValues(alpha: idle ? 0.15 : 0.35),
                width: 2,
              ),
            ),
            child: Icon(
              item.icon,
              size: size * 0.46,
              color: idle ? AppTheme.textMuted : AppTheme.textPrimary,
            ),
          ),
          if (spinning)
            _Spinner(size: ring, color: item.accent, stroke: size * 0.06),
        ],
      ),
    );
  }
}

/// Loading ring that stays smooth on weak TV boxes: the comet-shaped arc
/// is painted once and only *rotated* every frame (a transform, no
/// repaint), unlike CircularProgressIndicator, which repaints its arc each
/// frame (and was also wrapped in a second rotation here).
class _Spinner extends StatefulWidget {
  final double size;
  final Color color;
  final double stroke;
  const _Spinner({
    required this.size,
    required this.color,
    required this.stroke,
  });

  @override
  State<_Spinner> createState() => _SpinnerState();
}

class _SpinnerState extends State<_Spinner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RotationTransition(
      turns: _ctrl,
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.square(widget.size),
          painter: _CometArcPainter(
            color: widget.color,
            stroke: widget.stroke.clamp(3.0, 6.0),
          ),
        ),
      ),
    );
  }
}

class _CometArcPainter extends CustomPainter {
  final Color color;
  final double stroke;
  const _CometArcPainter({required this.color, required this.stroke});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final arcRect = rect.deflate(stroke / 2);
    const sweep = math.pi * 1.5;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.butt
      ..shader = SweepGradient(
        startAngle: 0,
        endAngle: sweep,
        colors: [color.withValues(alpha: 0), color],
      ).createShader(rect);
    canvas.drawArc(arcRect, 0, sweep, false, paint);
    // Rounded, bright head of the comet.
    final r = arcRect.width / 2;
    final head = rect.center + Offset(math.cos(sweep), math.sin(sweep)) * r;
    canvas.drawCircle(head, stroke / 2, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_CometArcPainter old) =>
      old.color != color || old.stroke != stroke;
}
