import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/services/cache_service.dart';

import '../core/constants/app_constants.dart';
import '../models/xtream_models.dart';
import '../providers/app_providers.dart';
import '../services/storage_service.dart';

// ── Sort options ──────────────────────────────────────────────────────────────
enum VodSortBy { defaultOrder, nameAZ, nameZA, ratingHighLow, recentlyAdded }

final vodSortProvider = StateProvider<VodSortBy>(
  (ref) => VodSortBy.defaultOrder,
);

// ── Search ────────────────────────────────────────────────────────────────────
final vodSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Selected movie ────────────────────────────────────────────────────────────
final selectedVodStreamProvider = StateProvider<VodStream?>((ref) => null);

// ── VodInfo (fetched on demand per movie) ─────────────────────────────────────
final vodInfoProvider = FutureProvider.autoDispose.family<VodInfo, String>((
  ref,
  vodId,
) async {
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) throw Exception('No active playlist');
  return service.getVodInfo(vodId);
});

// ── Sorted + filtered streams ─────────────────────────────────────────────────
final sortedVodStreamsProvider = Provider<AsyncValue<List<VodStream>>>((ref) {
  final sort = ref.watch(vodSortProvider);
  final query = ref.watch(vodSearchQueryProvider).toLowerCase().trim();
  final filter = ref.watch(vodFilterProvider);
  final favs = ref.watch(vodFavoritesProvider);
  final recentIds = ref.watch(recentlyViewedVodProvider);

  final allAsync = ref.watch(vodAllStreamsProvider);
  final catAsync = ref.watch(vodStreamsProvider);

  // recentlyAdded/favorites/recent need all streams; category filter uses catAsync
  final baseAsync = (filter == VodFilter.all) ? catAsync : allAsync;

  return baseAsync.whenData((streams) {
    List<VodStream> filtered;

    switch (filter) {
      case VodFilter.favorites:
        filtered = streams.where((s) => favs.contains(s.streamId)).toList();
      case VodFilter.recent:
        final map = {for (final s in streams) s.streamId: s};
        filtered = recentIds
            .map((id) => map[id])
            .whereType<VodStream>()
            .toList();
      case VodFilter.recentlyAdded:
        // Sort all by added timestamp, take top 100 — ignores category filter
        filtered = List.from(streams)
          ..sort((a, b) {
            final at = int.tryParse(a.added ?? '0') ?? 0;
            final bt = int.tryParse(b.added ?? '0') ?? 0;
            return bt.compareTo(at);
          });
        if (filtered.length > 100) filtered = filtered.sublist(0, 100);
      case VodFilter.all:
        if (query.isEmpty) {
          filtered = List.from(streams);
        } else {
          // Smart search ranking: text match score + behavior boost
          final scored =
              streams.where((s) => s.name.toLowerCase().contains(query)).map((
                s,
              ) {
                final name = s.name.toLowerCase();
                final textScore = name.startsWith(query) ? 1.0 : 0.5;
                final finalScore = BehaviorService.instance.getSearchScore(
                  s.streamId,
                  textScore,
                );
                return (stream: s, score: finalScore);
              }).toList()..sort((a, b) => b.score.compareTo(a.score));
          filtered = scored.map((e) => e.stream).toList();
        }
    }

    // Apply search to non-all filters
    if (filter != VodFilter.all && query.isNotEmpty) {
      filtered = filtered
          .where((s) => s.name.toLowerCase().contains(query))
          .toList();
    }

    // Apply sort only for all/favorites (recent/recentlyAdded have their own order)
    if (filter == VodFilter.all || filter == VodFilter.favorites) {
      switch (sort) {
        case VodSortBy.nameAZ:
          filtered.sort((a, b) => a.name.compareTo(b.name));
        case VodSortBy.nameZA:
          filtered.sort((a, b) => b.name.compareTo(a.name));
        case VodSortBy.ratingHighLow:
          filtered.sort((a, b) => b.ratingValue.compareTo(a.ratingValue));
        case VodSortBy.recentlyAdded:
          filtered.sort((a, b) {
            final at = int.tryParse(a.added ?? '0') ?? 0;
            final bt = int.tryParse(b.added ?? '0') ?? 0;
            return bt.compareTo(at);
          });
        case VodSortBy.defaultOrder:
          break;
      }
    }

    return filtered;
  });
});

// ── Favorites ─────────────────────────────────────────────────────────────────
final vodFavoritesProvider =
    StateNotifierProvider<VodFavoritesNotifier, Set<String>>(
      (ref) => VodFavoritesNotifier(),
    );

class VodFavoritesNotifier extends StateNotifier<Set<String>> {
  VodFavoritesNotifier() : super(StorageService.instance.getFavorites('vod'));

  Future<void> toggle(String streamId) async {
    await StorageService.instance.toggleFavorite('vod', streamId);
    state = StorageService.instance.getFavorites('vod');
  }

  bool isFavorite(String id) => state.contains(id);
}

// ── Hidden VOD categories ─────────────────────────────────────────────────────
final hiddenVodCategoriesProvider =
    StateNotifierProvider<HiddenVodCategoriesNotifier, Set<String>>(
      (ref) => HiddenVodCategoriesNotifier(),
    );

class HiddenVodCategoriesNotifier extends StateNotifier<Set<String>> {
  HiddenVodCategoriesNotifier()
    : super(StorageService.instance.getHiddenCategories('vod'));

  Future<void> toggle(String categoryId) async {
    await StorageService.instance.toggleCategoryVisibility('vod', categoryId);
    state = StorageService.instance.getHiddenCategories('vod');
  }

  bool isHidden(String id) => state.contains(id);
}

// ── Panel sizing ──────────────────────────────────────────────────────────────
final vodSidebarWidthProvider = StateProvider<double>((ref) => 220.0);
final vodDetailWidthProvider = StateProvider<double>((ref) => 300.0);

// ── Vod Filter ────────────────────────────────────────────────────────────────
enum VodFilter { all, favorites, recent, recentlyAdded }

final vodFilterProvider = StateProvider<VodFilter>((ref) => VodFilter.all);

// ── Vod All Streams (no category filter) ─────────────────────────────────────
final vodAllStreamsProvider = FutureProvider<List<VodStream>>((ref) async {
  final cached = CacheService.instance.loadVodStreams(ignoreExpiry: true);
  if (cached != null) return cached;
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];
  return service.getVodStreams();
});

// ── Recently Viewed VOD ───────────────────────────────────────────────────────
final recentlyViewedVodProvider =
    StateNotifierProvider<RecentlyViewedVodNotifier, List<String>>(
      (ref) => RecentlyViewedVodNotifier(),
    );

class RecentlyViewedVodNotifier extends StateNotifier<List<String>> {
  RecentlyViewedVodNotifier() : super(_load());

  static List<String> _load() {
    final raw =
        StorageService.instance.getSetting(AppConstants.recentVodKey) as List?;
    return raw?.map((e) => e.toString()).toList() ?? [];
  }

  void add(String streamId) {
    final updated = [
      streamId,
      ...state.where((id) => id != streamId),
    ].take(50).toList();
    state = updated;
    StorageService.instance.setSetting(AppConstants.recentVodKey, updated);
  }

  void clear() {
    state = [];
    StorageService.instance.setSetting(AppConstants.recentVodKey, <String>[]);
  }
}
