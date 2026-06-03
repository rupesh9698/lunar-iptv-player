import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/services/cache_service.dart';

import '../core/constants/app_constants.dart';
import '../models/xtream_models.dart';
import '../providers/app_providers.dart';
import '../services/storage_service.dart';

class _SeriesSortMsg {
  final List<Series> list;
  final int filterIndex;
  final int sortIndex;
  final String query;
  final List<String> favIds;
  final List<String> recentIds;
  final Map<String, double> scores;

  const _SeriesSortMsg({
    required this.list,
    required this.filterIndex,
    required this.sortIndex,
    required this.query,
    required this.favIds,
    required this.recentIds,
    required this.scores,
  });
}

List<Series> _seriesSortIsolate(_SeriesSortMsg msg) {
  final filter = SeriesFilter.values[msg.filterIndex];
  final sort = SeriesSortBy.values[msg.sortIndex];

  List<Series> filtered;

  switch (filter) {
    case SeriesFilter.favorites:
      filtered = msg.list
          .where((s) => msg.favIds.contains(s.seriesId))
          .toList();
    case SeriesFilter.recent:
      final map = {for (final s in msg.list) s.seriesId: s};
      filtered = msg.recentIds
          .map((id) => map[id])
          .whereType<Series>()
          .toList();
    case SeriesFilter.recentlyAdded:
      filtered = List.from(msg.list)
        ..sort((a, b) {
          final ad = a.releaseDate ?? '';
          final bd = b.releaseDate ?? '';
          return bd.compareTo(ad);
        });
      if (filtered.length > 100) filtered = filtered.sublist(0, 100);
      return filtered;
    case SeriesFilter.all:
      if (msg.query.isEmpty) {
        filtered = List.from(msg.list);
      } else {
        final scored =
            msg.list
                .where((s) => s.name.toLowerCase().contains(msg.query))
                .map((s) => (series: s, score: msg.scores[s.seriesId] ?? 0.5))
                .toList()
              ..sort((a, b) => b.score.compareTo(a.score));
        return scored.map((e) => e.series).toList();
      }
  }

  if (filter != SeriesFilter.all && msg.query.isNotEmpty) {
    filtered = filtered
        .where((s) => s.name.toLowerCase().contains(msg.query))
        .toList();
  }

  if (filter == SeriesFilter.all || filter == SeriesFilter.favorites) {
    switch (sort) {
      case SeriesSortBy.nameAZ:
        filtered.sort((a, b) => a.name.compareTo(b.name));
      case SeriesSortBy.nameZA:
        filtered.sort((a, b) => b.name.compareTo(a.name));
      case SeriesSortBy.ratingHighLow:
        filtered.sort((a, b) => b.ratingValue.compareTo(a.ratingValue));
      case SeriesSortBy.defaultOrder:
        break;
    }
  }
  return filtered;
}

// ── Sort ──────────────────────────────────────────────────────────────────────
enum SeriesSortBy { defaultOrder, nameAZ, nameZA, ratingHighLow }

final seriesSortProvider = StateProvider<SeriesSortBy>(
  (ref) => SeriesSortBy.defaultOrder,
);

// ── Search ────────────────────────────────────────────────────────────────────
final seriesSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Selected series ───────────────────────────────────────────────────────────
final selectedSeriesStreamProvider = StateProvider<Series?>((ref) => null);

// ── SeriesInfo on demand ──────────────────────────────────────────────────────
final seriesInfoProvider = FutureProvider.autoDispose
    .family<SeriesInfo, String>((ref, seriesId) async {
      final service = ref.watch(xtreamServiceProvider);
      if (service == null) throw Exception('No active playlist');
      return service.getSeriesInfo(seriesId);
    });

// ── Sorted + filtered list ────────────────────────────────────────────────────
final sortedSeriesListProvider = FutureProvider<List<Series>>((ref) async {
  final sort = ref.watch(seriesSortProvider);
  final query = ref.watch(seriesSearchQueryProvider).toLowerCase().trim();
  final filter = ref.watch(seriesFilterProvider);
  final favIds = ref.watch(seriesFavoritesProvider).toList();
  final recentIds = ref.watch(recentlyViewedSeriesProvider);

  final List<Series> allList;
  try {
    allList = filter == SeriesFilter.all
        ? await ref.watch(seriesListProvider.future)
        : await ref.watch(seriesAllListProvider.future);
  } catch (_) {
    return [];
  }

  final scores = <String, double>{};
  if (query.isNotEmpty) {
    for (final s in allList) {
      if (s.name.toLowerCase().contains(query)) {
        final t = s.name.toLowerCase().startsWith(query) ? 1.0 : 0.5;
        scores[s.seriesId] = BehaviorService.instance.getSearchScore(
          s.seriesId,
          t,
        );
      }
    }
  }

  return Isolate.run(
    () => _seriesSortIsolate(
      _SeriesSortMsg(
        list: allList,
        filterIndex: filter.index,
        sortIndex: sort.index,
        query: query,
        favIds: favIds,
        recentIds: recentIds,
        scores: scores,
      ),
    ),
  );
});

// ── Favorites ─────────────────────────────────────────────────────────────────
final seriesFavoritesProvider =
    StateNotifierProvider<SeriesFavoritesNotifier, Set<String>>(
      (ref) => SeriesFavoritesNotifier(),
    );

class SeriesFavoritesNotifier extends StateNotifier<Set<String>> {
  SeriesFavoritesNotifier()
    : super(StorageService.instance.getFavorites('series'));

  Future<void> toggle(String id) async {
    await StorageService.instance.toggleFavorite('series', id);
    state = StorageService.instance.getFavorites('series');
  }

  bool isFavorite(String id) => state.contains(id);
}

// ── Hidden categories ─────────────────────────────────────────────────────────
final hiddenSeriesCategoriesProvider =
    StateNotifierProvider<HiddenSeriesCategoriesNotifier, Set<String>>(
      (ref) => HiddenSeriesCategoriesNotifier(),
    );

class HiddenSeriesCategoriesNotifier extends StateNotifier<Set<String>> {
  HiddenSeriesCategoriesNotifier()
    : super(StorageService.instance.getHiddenCategories('series'));

  Future<void> toggle(String categoryId) async {
    await StorageService.instance.toggleCategoryVisibility(
      'series',
      categoryId,
    );
    state = StorageService.instance.getHiddenCategories('series');
  }

  bool isHidden(String id) => state.contains(id);
}

// ── Panel sizing ──────────────────────────────────────────────────────────────
final seriesSidebarWidthProvider = StateProvider<double>((ref) => 220.0);
final seriesDetailWidthProvider = StateProvider<double>((ref) => 340.0);

// ── Series Filter ─────────────────────────────────────────────────────────────
enum SeriesFilter { all, favorites, recent, recentlyAdded }

final seriesFilterProvider = StateProvider<SeriesFilter>(
  (ref) => SeriesFilter.all,
);

// ── Series All List (no category filter) ─────────────────────────────────────
final seriesAllListProvider = FutureProvider<List<Series>>((ref) async {
  final cached = CacheService.instance.loadSeriesList(ignoreExpiry: true);
  if (cached != null) return cached;
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];
  return service.getSeries();
});

// ── Recently Viewed Series ────────────────────────────────────────────────────
final recentlyViewedSeriesProvider =
    StateNotifierProvider<RecentlyViewedSeriesNotifier, List<String>>(
      (ref) => RecentlyViewedSeriesNotifier(),
    );

class RecentlyViewedSeriesNotifier extends StateNotifier<List<String>> {
  RecentlyViewedSeriesNotifier() : super(_load());

  static List<String> _load() {
    final raw =
        StorageService.instance.getSetting(AppConstants.recentSeriesKey)
            as List?;
    return raw?.map((e) => e.toString()).toList() ?? [];
  }

  void add(String seriesId) {
    final updated = [
      seriesId,
      ...state.where((id) => id != seriesId),
    ].take(50).toList();
    state = updated;
    StorageService.instance.setSetting(AppConstants.recentSeriesKey, updated);
  }

  void clear() {
    state = [];
    StorageService.instance.setSetting(
      AppConstants.recentSeriesKey,
      <String>[],
    );
  }
}
