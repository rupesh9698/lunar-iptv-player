import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/services/cache_service.dart';

import '../core/constants/app_constants.dart';
import '../models/xtream_models.dart';
import '../providers/app_providers.dart';
import '../services/storage_service.dart';

// Top-level — required by compute()
class _VodSortMsg {
  final List<VodStream> streams;
  final int filterIndex;
  final int sortIndex;
  final String query;
  final List<String> favIds;
  final List<String> recentIds;
  final Map<String, double> scores; // pre-computed search scores

  const _VodSortMsg({
    required this.streams,
    required this.filterIndex,
    required this.sortIndex,
    required this.query,
    required this.favIds,
    required this.recentIds,
    required this.scores,
  });
}

List<VodStream> _vodSortIsolate(_VodSortMsg msg) {
  final filter = VodFilter.values[msg.filterIndex];
  final sort = VodSortBy.values[msg.sortIndex];

  List<VodStream> filtered;

  switch (filter) {
    case VodFilter.favorites:
      filtered = msg.streams
          .where((s) => msg.favIds.contains(s.streamId))
          .toList();
    case VodFilter.recent:
      final map = {for (final s in msg.streams) s.streamId: s};
      filtered = msg.recentIds
          .map((id) => map[id])
          .whereType<VodStream>()
          .toList();
    case VodFilter.recentlyAdded:
      filtered = List.from(msg.streams)
        ..sort((a, b) {
          final at = int.tryParse(a.added ?? '0') ?? 0;
          final bt = int.tryParse(b.added ?? '0') ?? 0;
          return bt.compareTo(at);
        });
      if (filtered.length > 100) filtered = filtered.sublist(0, 100);
      return filtered;
    case VodFilter.all:
      if (msg.query.isEmpty) {
        filtered = List.from(msg.streams);
      } else {
        final scored =
            msg.streams
                .where((s) => s.name.toLowerCase().contains(msg.query))
                .map((s) => (stream: s, score: msg.scores[s.streamId] ?? 0.5))
                .toList()
              ..sort((a, b) => b.score.compareTo(a.score));
        return scored.map((e) => e.stream).toList();
      }
  }

  if (filter != VodFilter.all && msg.query.isNotEmpty) {
    filtered = filtered
        .where((s) => s.name.toLowerCase().contains(msg.query))
        .toList();
  }

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
}

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
final sortedVodStreamsProvider = FutureProvider<List<VodStream>>((ref) async {
  final sort = ref.watch(vodSortProvider);
  final query = ref.watch(vodSearchQueryProvider).toLowerCase().trim();
  final filter = ref.watch(vodFilterProvider);
  final favIds = ref.watch(vodFavoritesProvider).toList();
  final recentIds = ref.watch(recentlyViewedVodProvider);

  // Await the correct base list
  final List<VodStream> allStreams;
  try {
    allStreams = filter == VodFilter.all
        ? await ref.watch(vodStreamsProvider.future)
        : await ref.watch(vodAllStreamsProvider.future);
  } catch (_) {
    return [];
  }

  // Pre-compute search scores (fast — only on matched items)
  final scores = <String, double>{};
  if (query.isNotEmpty) {
    for (final s in allStreams) {
      if (s.name.toLowerCase().contains(query)) {
        final t = s.name.toLowerCase().startsWith(query) ? 1.0 : 0.5;
        scores[s.streamId] = BehaviorService.instance.getSearchScore(
          s.streamId,
          t,
        );
      }
    }
  }

  // Run heavy sort in background isolate to prevent ANR
  return Isolate.run(
    () => _vodSortIsolate(
      _VodSortMsg(
        streams: allStreams,
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
