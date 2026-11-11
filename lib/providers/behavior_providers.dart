import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/providers/movies_provider.dart';
import 'package:lunar_iptv_player/providers/series_provider.dart';

import 'dart:math' as math;

import '../core/utils/recommend.dart';
import '../services/behavior_service.dart';

// ── Continue Watching ─────────────────────────────────────────────────────────
final continueWatchingProvider =
    StateNotifierProvider<ContinueWatchingNotifier, List<Map<String, dynamic>>>(
      (ref) => ContinueWatchingNotifier(),
    );

class ContinueWatchingNotifier
    extends StateNotifier<List<Map<String, dynamic>>> {
  ContinueWatchingNotifier()
    : super(BehaviorService.instance.getContinueWatching());

  void refresh() {
    state = BehaviorService.instance.getContinueWatching();
  }

  Future<void> savePosition({
    required String id,
    required String url,
    required double positionSeconds,
    required double durationSeconds,
    required String type,
    required String title,
    String? imageUrl,
    String? seriesId,
    String? seriesName,
    String? season,
    String? episode,
  }) async {
    await BehaviorService.instance.savePosition(
      id: id,
      url: url,
      positionSeconds: positionSeconds,
      durationSeconds: durationSeconds,
      type: type,
      title: title,
      imageUrl: imageUrl,
      seriesId: seriesId,
      seriesName: seriesName,
      season: season,
      episode: episode,
    );
    refresh();
  }

  Future<void> clear(String id) async {
    await BehaviorService.instance.clearPosition(id);
    refresh();
  }

  Future<void> clearAll() async {
    // Clear only position entries, not all behavior
    for (final item in state) {
      final id = item['id'] as String?;
      if (id != null) await BehaviorService.instance.clearPosition(id);
    }
    refresh();
  }
}

// ── Hourly channel suggestions ────────────────────────────────────────────────
final hourlyChannelSuggestionsProvider = Provider<List<String>>((ref) {
  return BehaviorService.instance.getHourlyTopChannels();
});

// ── Top genres ────────────────────────────────────────────────────────────────
final topGenresProvider = Provider<List<String>>((ref) {
  return BehaviorService.instance.getTopGenres();
});

// ── Watch time by day ─────────────────────────────────────────────────────────
final watchTimeByDayProvider = Provider<List<Map<String, dynamic>>>((ref) {
  return BehaviorService.instance.getWatchTimeByDay(days: 7);
});

// ── Behaviour refresh trigger ─────────────────────────────────────────────────
// Follows BehaviorService.tasteChanges (a viewing session ended, something
// was opened, history cleared), so recommendations update without a
// restart. Can still be bumped by hand.
final behaviorRefreshProvider = StateProvider<int>((ref) {
  final n = BehaviorService.instance.tasteChanges;
  void on() => ref.controller.state++;
  n.addListener(on);
  ref.onDispose(() => n.removeListener(on));
  return 0;
});

/// Provider ratings are "rating" (0 to 10) with "rating_5based" (0 to 5) as a
/// fallback.
double _rating10(String? rating, double fiveBased) {
  final r = double.tryParse(rating ?? '');
  if (r != null && r > 0) return r.clamp(0, 10).toDouble();
  return (fiveBased * 2).clamp(0, 10).toDouble();
}

/// Light descriptions of the whole movie library for the recommenders
/// (built once per library load).
final vodRecItemsProvider = Provider<List<RecItem>?>((ref) {
  final all = ref.watch(vodAllStreamsProvider).valueOrNull;
  if (all == null) return null;
  return [
    for (final m in all)
      RecItem(
        id: m.streamId,
        name: m.name,
        categoryId: m.categoryId,
        rating: _rating10(m.rating, m.ratingValue),
        addedAt: int.tryParse(m.added ?? ''),
      ),
  ];
});

final seriesRecItemsProvider = Provider<List<RecItem>?>((ref) {
  final all = ref.watch(seriesAllListProvider).valueOrNull;
  if (all == null) return null;
  return [
    for (final s in all)
      RecItem(
        id: s.seriesId,
        name: s.name,
        categoryId: s.categoryId,
        rating: _rating10(s.rating, s.ratingValue),
        genres: splitGenres(s.genre),
      ),
  ];
});

/// Recently viewed ids, most recent first, as fading signals.
Iterable<TasteSignal> _recent(List<String> ids, double weight) sync* {
  for (var i = 0; i < ids.length && i < 30; i++) {
    yield TasteSignal(ids[i], weight * math.pow(0.9, i));
  }
}

// ── Recommended "For You" Movies ─────────────────────────────────────────
// Built from what the user actually watched: favourites, watch time, what is
// in progress and recently opened. Those give category, genre and franchise
// affinities; titles are then scored on them plus rating and freshness, with
// at most a few per category so the row stays varied. Nothing watched yet:
// well rated new arrivals.
final forYouVodProvider = Provider<AsyncValue<List<VodStream>>>((ref) {
  ref.watch(behaviorRefreshProvider);
  final favs = ref.watch(vodFavoritesProvider);
  final recent = ref.watch(recentlyViewedVodProvider);
  final inProgress = ref.watch(continueWatchingProvider);
  final cats = ref.watch(vodCategoriesProvider).valueOrNull ?? const [];
  final items = ref.watch(vodRecItemsProvider);

  return ref.watch(vodAllStreamsProvider).whenData((all) {
    if (all.isEmpty || items == null) return [];
    final byId = {for (final x in items) x.id: x};
    final svc = BehaviorService.instance;
    final signals = <TasteSignal>[
      for (final id in favs) TasteSignal(id, 3),
      for (final w in svc.getTopContentByTime(topN: 200))
        if (byId.containsKey(w['id']))
          TasteSignal(
            w['id'] as String,
            1 + math.log(1 + (w['seconds'] as int) / 600),
          ),
      for (final c in inProgress)
        if (c['type'] == 'movie') TasteSignal(c['id'].toString(), 2),
      ..._recent(recent, 1.5),
    ];
    final taste = TasteProfile.build(
      signals,
      byId,
      genreCounts: svc.getGenreCounts(topN: 10),
    );
    final picks = recommendFor(
      taste,
      items,
      categoryNames: {for (final c in cats) c.categoryId: c.categoryName},
    );
    final streams = {for (final m in all) m.streamId: m};
    return [
      for (final p in picks)
        if (streams[p.id] != null) streams[p.id]!,
    ];
  });
});

// ── Recommended "For You" Series ─────────────────────────────────────────
// Same idea; series lists carry genres, so genre taste counts more here.
final forYouSeriesProvider = Provider<AsyncValue<List<Series>>>((ref) {
  ref.watch(behaviorRefreshProvider);
  final favs = ref.watch(seriesFavoritesProvider);
  final recent = ref.watch(recentlyViewedSeriesProvider);
  final cats = ref.watch(seriesCategoriesProvider).valueOrNull ?? const [];
  final items = ref.watch(seriesRecItemsProvider);

  return ref.watch(seriesAllListProvider).whenData((all) {
    if (all.isEmpty || items == null) return [];
    final byId = {for (final x in items) x.id: x};
    final svc = BehaviorService.instance;
    final signals = <TasteSignal>[
      for (final id in favs) TasteSignal(id, 3),
      for (final w in svc.getTopContentByTime(topN: 200))
        if (byId.containsKey(w['id']))
          TasteSignal(
            w['id'] as String,
            1 + math.log(1 + (w['seconds'] as int) / 600),
          ),
      ..._recent(recent, 2),
    ];
    final taste = TasteProfile.build(
      signals,
      byId,
      genreCounts: svc.getGenreCounts(topN: 10),
    );
    final picks = recommendFor(
      taste,
      items,
      categoryNames: {for (final c in cats) c.categoryId: c.categoryName},
    );
    final list = {for (final x in all) x.seriesId: x};
    return [
      for (final p in picks)
        if (list[p.id] != null) list[p.id]!,
    ];
  });
});

// ── Smart Sorted Live Categories ─────────────────────────────────────────
// Categories the user taps most appear first.
final smartLiveCategoriesProvider = FutureProvider<List<XtreamCategory>>((
  ref,
) async {
  final cats = await ref.watch(liveCategoriesProvider.future);
  final sorted = List<XtreamCategory>.from(cats);
  sorted.sort((a, b) {
    final ta = BehaviorService.instance.getCategoryTaps(a.categoryId);
    final tb = BehaviorService.instance.getCategoryTaps(b.categoryId);
    return tb.compareTo(ta); // Most tapped first
  });
  return sorted;
});

// ── Auto Favourite Suggestions ────────────────────────────────────────────
final autoFavSuggestionsProvider = Provider<List<String>>((ref) {
  ref.watch(behaviorRefreshProvider);
  final liveFavs = ref.watch(liveFavoritesNotifierProvider);
  final vodFavs = ref.watch(vodFavoritesProvider);
  final seriesFavs = ref.watch(seriesFavoritesProvider);
  final allFavs = <String>{...liveFavs, ...vodFavs, ...seriesFavs};
  return BehaviorService.instance.getSuggestedFavorites(allFavs, minViews: 5);
});
