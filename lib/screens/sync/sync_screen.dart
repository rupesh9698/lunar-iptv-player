import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/app_providers.dart';
import '../../services/cache_service.dart';
import '../../services/m3u_service.dart';

enum _FetchStatus { idle, loading, done, failed }

class _SyncItem {
  final String label;
  final IconData icon;
  _FetchStatus status = _FetchStatus.idle;
  String? subtitle;
  String? errorMessage;

  _SyncItem(this.label, this.icon);
}

class SyncScreen extends ConsumerStatefulWidget {
  final bool isManualRefresh;
  const SyncScreen({super.key, this.isManualRefresh = false});

  @override
  ConsumerState<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends ConsumerState<SyncScreen> {
  List<_SyncItem> _items = [
    _SyncItem('Live TV', Icons.tv_outlined),
    _SyncItem('Movies', Icons.video_library_outlined),
    _SyncItem('Series', Icons.theaters_outlined),
  ];

  String _statusMsg = 'Preparing sync...';
  bool _hasAnyFailure = false;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  static const int _maxRetries = 3;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
    WidgetsBinding.instance.addPostFrameCallback((_) => _runSync());
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
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
        if (mounted) {
          setState(() {
            _statusMsg = '$operationName... (Retry $attempt/$maxRetries)';
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
      final hasData =
          cache.loadLiveStreams(ignoreExpiry: true)?.isNotEmpty ?? false;
      final isFresh = playlist.isM3u
          ? hasData // M3U: any cached data = fresh (no daily expiry)
          : hasData && !cache.isLiveStale(); // Xtream: check 24h expiry

      if (isFresh) {
        // Data is ready — go straight to home without showing sync screen
        if (mounted) context.go('/home');
        return;
      }
    }

    if (playlist.isM3u) {
      // ── M3U sync ────────────────────────────────────────────────────────
      setState(() {
        _items = [_SyncItem('Live TV (M3U)', Icons.subscriptions_outlined)];
      });

      if (widget.isManualRefresh || cache.isLiveStale()) {
        await _step(0, 'Fetching M3U playlist...', () async {
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
              '${streams.length} channels · ${cats.length} categories';
        });
      } else {
        _markDone(0);
      }

      ref.invalidate(liveCategoriesProvider);
      ref.invalidate(liveStreamsProvider);
    } else {
      // ── Xtream sync ─────────────────────────────────────────────────────
      setState(() {
        _items = [
          _SyncItem('Live TV', Icons.tv_outlined),
          _SyncItem('Movies', Icons.video_library_outlined),
          _SyncItem('Series', Icons.theaters_outlined),
        ];
      });

      final service = ref.read(xtreamServiceProvider);
      if (service == null) {
        if (mounted) context.go('/home');
        return;
      }

      bool hasLive = false, hasVod = false, hasSeries = false;

      // Live TV
      if (widget.isManualRefresh || cache.isLiveStale()) {
        await _step(0, 'Fetching Live TV channels...', () async {
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
          _items[0].subtitle = '${ch.length} channels';
          hasLive = ch.isNotEmpty;
        });
      } else {
        _markDone(0);
        hasLive = cache.loadLiveStreams(ignoreExpiry: true)?.isNotEmpty ?? true;
      }

      // Movies
      if (widget.isManualRefresh || cache.isVodStale()) {
        await _step(1, 'Fetching Movies library...', () async {
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
          _items[1].subtitle = '${streams.length} movies';
          hasVod = streams.isNotEmpty;
        });
      } else {
        _markDone(1);
        hasVod = cache.loadVodStreams(ignoreExpiry: true)?.isNotEmpty ?? true;
      }

      // Series
      if (widget.isManualRefresh || cache.isSeriesStale()) {
        await _step(2, 'Fetching Series library...', () async {
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
          _items[2].subtitle = '${series.length} series';
          hasSeries = series.isNotEmpty;
        });
      } else {
        _markDone(2);
        hasSeries =
            cache.loadSeriesList(ignoreExpiry: true)?.isNotEmpty ?? true;
      }

      await cache.saveContentFlags(
        hasLive: hasLive,
        hasVod: hasVod,
        hasSeries: hasSeries,
      );

      ref.invalidate(liveCategoriesProvider);
      ref.invalidate(liveStreamsProvider);
      ref.invalidate(vodCategoriesProvider);
      ref.invalidate(vodStreamsProvider);
      ref.invalidate(seriesCategoriesProvider);
      ref.invalidate(seriesListProvider);
    }

    ref.read(cacheLastSyncProvider.notifier).state = DateTime.now();

    final msg = _hasAnyFailure
        ? 'Sync completed with some issues'
        : 'All done! Launching Lunar IPTV Player...';
    if (mounted) setState(() => _statusMsg = msg);

    await Future.delayed(const Duration(milliseconds: 900));
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

  Future<void> _step(
    int idx,
    String loadingMsg,
    Future<void> Function() work,
  ) async {
    if (!mounted) return;

    setState(() {
      _items[idx].status = _FetchStatus.loading;
      _items[idx].errorMessage = null;
      _statusMsg = loadingMsg;
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
          _items[idx].subtitle = 'Failed';
          _items[idx].errorMessage = e.toString();
          _hasAnyFailure = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            _TopBar(now: _now),
            Expanded(child: _Cards(items: _items)),
            _BottomBar(message: _statusMsg),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Top Bar (Unchanged with minor animation)
class _TopBar extends StatelessWidget {
  final DateTime now;
  const _TopBar({required this.now});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
      child: Row(
        children: [
          Row(
            children: [
              SizedBox(
                width: 40,
                height: 40,
                child: Image.asset(
                  'assets/images/logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Lunar IPTV Player',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
          const Spacer(),
          const Text(
            'Fetching Data',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                DateFormat('hh:mm a').format(now),
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                DateFormat('EEE\ndd MMM').format(now),
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                ),
                textAlign: TextAlign.right,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ──────────────────────────────────────────────────────────────
// Cards with improved animations
class _Cards extends StatelessWidget {
  final List<_SyncItem> items;
  const _Cards({required this.items});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Row(
        children: items
            .map(
              (item) => Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: _SyncCard(item: item),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SyncCard extends StatelessWidget {
  final _SyncItem item;
  const _SyncCard({required this.item});

  @override
  Widget build(BuildContext context) {
    final isLoading = item.status == _FetchStatus.loading;
    final isDone = item.status == _FetchStatus.done;
    final isFailed = item.status == _FetchStatus.failed;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeOutCubic,
      clipBehavior: Clip.hardEdge,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      decoration: BoxDecoration(
        color: isLoading
            ? AppTheme.surface
            : AppTheme.surface.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isDone
              ? AppTheme.success.withValues(alpha: 0.4)
              : isFailed
              ? AppTheme.error.withValues(alpha: 0.4)
              : isLoading
              ? AppTheme.primary.withValues(alpha: 0.4)
              : AppTheme.divider,
          width: isLoading ? 2 : 1,
        ),
        boxShadow: isLoading
            ? [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  blurRadius: 30,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Status Badge
          SizedBox(
            height: 26,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (isDone)
                  const Icon(
                    Icons.check_circle,
                    color: AppTheme.success,
                    size: 24,
                  ).animate().scale(duration: 400.ms),
                if (isFailed)
                  const Icon(Icons.error, color: AppTheme.error, size: 24),
              ],
            ),
          ),

          const SizedBox(height: 8),

          // Icon + Loader
          SizedBox(
            width: 110,
            height: 110,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.surfaceVariant,
                    border: Border.all(
                      color: isDone
                          ? AppTheme.success.withValues(alpha: 0.3)
                          : AppTheme.divider,
                      width: 3,
                    ),
                  ),
                  child: Icon(
                    item.icon,
                    size: 38,
                    color: isDone || isLoading
                        ? AppTheme.textPrimary
                        : AppTheme.textMuted,
                  ),
                ),
                if (isLoading)
                  SizedBox(
                    width: 108,
                    height: 108,
                    child: CircularProgressIndicator(
                      strokeWidth: 4,
                      strokeCap: StrokeCap.round,
                      valueColor: const AlwaysStoppedAnimation(
                        AppTheme.primary,
                      ),
                    ),
                  ).animate().rotate(duration: 1200.ms, curve: Curves.linear),
              ],
            ),
          ),

          const SizedBox(height: 20),

          Text(
            item.label,
            style: TextStyle(
              color: isDone || isLoading
                  ? AppTheme.textPrimary
                  : AppTheme.textMuted,
              fontSize: 15.5,
              fontWeight: FontWeight.w600,
            ),
          ),

          if (item.subtitle != null) ...[
            const SizedBox(height: 6),
            Text(
              item.subtitle!,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12.5,
              ),
            ),
          ],

          if (item.errorMessage != null && isFailed)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'Tap to retry later',
                style: TextStyle(
                  color: AppTheme.error.withValues(alpha: 0.8),
                  fontSize: 11,
                ),
              ),
            ),
        ],
      ),
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1);
  }
}

// ──────────────────────────────────────────────────────────────
class _BottomBar extends StatelessWidget {
  final String message;
  const _BottomBar({required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: Text(
          message,
          key: ValueKey(message),
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 14.5,
            fontWeight: FontWeight.w500,
          ),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}
