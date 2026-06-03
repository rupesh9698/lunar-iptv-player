import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/providers/movies_provider.dart';
import 'package:lunar_iptv_player/providers/series_provider.dart';

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
// Increment this to force all behavior providers to re-read fresh data.
final behaviorRefreshProvider = StateProvider<int>((ref) => 0);

// ── Recommended "For You" Vod ─────────────────────────────────────────────
// Surfaces unseen high-rated movies from categories matching user's top genres.
final forYouVodProvider = Provider<AsyncValue<List<VodStream>>>((ref) {
  ref.watch(behaviorRefreshProvider); // Refresh when behavior data changes

  return ref.watch(vodAllStreamsProvider).whenData((all) {
    if (all.isEmpty) return [];

    final topGenres = BehaviorService.instance.getTopGenres(topN: 6);

    // Score every movie: genre match boost + rating + search ranking
    final scored = <(VodStream, double)>[];
    for (final movie in all) {
      final watchCount = BehaviorService.instance.getWatchCount(movie.streamId);
      if (watchCount > 8) continue; // Skip content user is already done with

      double base = movie.ratingValue / 10.0;

      // Genre match boost via category name (approximate)
      if (topGenres.isNotEmpty) {
        final catLower = (movie.categoryId ?? '').toLowerCase();
        for (final genre in topGenres) {
          if (catLower.contains(genre.toLowerCase())) {
            base += 0.4;
            break;
          }
        }
      }

      final score = BehaviorService.instance.getSearchScore(
        movie.streamId,
        base,
      );
      scored.add((movie, score));
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(25).map((e) => e.$1).toList();
  });
});

// ── Recommended "For You" Series ─────────────────────────────────────────
final forYouSeriesProvider = Provider<AsyncValue<List<Series>>>((ref) {
  ref.watch(behaviorRefreshProvider);

  return ref.watch(seriesAllListProvider).whenData((all) {
    if (all.isEmpty) return [];

    final topGenres = BehaviorService.instance.getTopGenres(topN: 6);

    final scored = <(Series, double)>[];
    for (final s in all) {
      final watchCount = BehaviorService.instance.getWatchCount(s.seriesId);
      if (watchCount > 5) continue;

      double base = s.ratingValue / 10.0;
      if (topGenres.isNotEmpty) {
        final catLower = (s.categoryId ?? '').toLowerCase();
        for (final genre in topGenres) {
          if (catLower.contains(genre.toLowerCase())) {
            base += 0.4;
            break;
          }
        }
      }

      final score = BehaviorService.instance.getSearchScore(s.seriesId, base);
      scored.add((s, score));
    }

    scored.sort((a, b) => b.$2.compareTo(a.$2));
    return scored.take(25).map((e) => e.$1).toList();
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
