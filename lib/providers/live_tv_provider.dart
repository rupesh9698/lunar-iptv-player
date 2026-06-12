import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';

import '../core/constants/app_constants.dart';
import '../models/xtream_models.dart';
import '../providers/app_providers.dart';
import '../services/cache_service.dart';
import '../services/storage_service.dart';

// ── Show Channel Number ───────────────────────────────────────────────────────
final showChannelNumberProvider =
    StateNotifierProvider<ShowChannelNumberNotifier, bool>(
      (ref) => ShowChannelNumberNotifier(),
    );

class ShowChannelNumberNotifier extends StateNotifier<bool> {
  ShowChannelNumberNotifier()
    : super(
        StorageService.instance.getSetting(
              AppConstants.showChannelNumberKey,
              true,
            )
            as bool,
      );

  Future<void> set(bool value) async {
    await StorageService.instance.setSetting(
      AppConstants.showChannelNumberKey,
      value,
    );
    state = value;
  }
}

// ── Last Watched Live — per playlist ─────────────────────────────────────────
typedef _LastWatched = ({String? categoryId, String? channelId});

final lastWatchedLiveProvider =
    StateNotifierProvider<LastWatchedLiveNotifier, _LastWatched>((ref) {
      // Re-creates with correct data when active playlist changes
      final playlistId = ref.watch(activePlaylistProvider)?.id ?? 'default';
      return LastWatchedLiveNotifier(playlistId: playlistId);
    });

class LastWatchedLiveNotifier extends StateNotifier<_LastWatched> {
  final String playlistId;

  LastWatchedLiveNotifier({required this.playlistId})
      : super(_load(playlistId));

  static _LastWatched _load(String pid) => (
  categoryId:
  StorageService.instance.getSetting('last_live_cat_$pid') as String?,
  channelId:
  StorageService.instance.getSetting('last_live_ch_$pid') as String?,
  );

  /// Saves only when rememberPosition setting is enabled.
  Future<void> save({String? categoryId, String? channelId}) async {
    final remember = StorageService.instance.getSetting(
      AppConstants.rememberPositionKey,
      true,
    ) as bool;
    if (!remember) return;

    await StorageService.instance.setSetting(
      'last_live_cat_$playlistId',
      categoryId,
    );
    await StorageService.instance.setSetting(
      'last_live_ch_$playlistId',
      channelId,
    );
    state = (categoryId: categoryId, channelId: channelId);
  }

  Future<void> clear() async {
    await StorageService.instance.setSetting('last_live_cat_$playlistId', null);
    await StorageService.instance.setSetting('last_live_ch_$playlistId', null);
    state = (categoryId: null, channelId: null);
  }
}

// ── EPG Cache ────────────────────────────────────────────────────────────────
final epgCacheProvider =
    StateNotifierProvider<EpgCacheNotifier, Map<String, List<EpgListing>>>(
      (ref) => EpgCacheNotifier(ref),
    );

class EpgCacheNotifier extends StateNotifier<Map<String, List<EpgListing>>> {
  final Ref _ref;
  final Set<String> _loading = {};
  final Map<String, DateTime> _lastFetched = {}; // Throttle tracking

  // Minimum time between API calls for the same stream
  static const _throttle = Duration(seconds: 30);

  EpgCacheNotifier(this._ref) : super({});

  Future<void> loadEpg(String streamId) async {
    // Already in memory
    if (state.containsKey(streamId)) return;
    // Currently loading
    if (_loading.contains(streamId)) return;
    // Throttle: don't re-fetch too soon
    final lastFetch = _lastFetched[streamId];
    if (lastFetch != null && DateTime.now().difference(lastFetch) < _throttle) {
      return;
    }

    _loading.add(streamId);

    try {
      // 1. Check disk cache (30-min TTL)
      final diskCached = CacheService.instance.loadEpg(
        streamId,
        maxAge: const Duration(minutes: 30),
      );
      if (diskCached != null) {
        if (mounted) state = {...state, streamId: diskCached};
        return;
      }

      // 2. Fetch from API
      final service = _ref.read(xtreamServiceProvider);
      if (service == null) return;

      // Try get_simple_data_table first, fall back to get_short_epg
      List<EpgListing> listings;
      try {
        listings = await service.getSimpleDataTable(streamId);
      } catch (_) {
        listings = await service.getShortEpg(streamId, limit: 6);
      }

      // 3. Save to disk cache
      if (listings.isNotEmpty) {
        await CacheService.instance.saveEpg(streamId, listings);
      }

      _lastFetched[streamId] = DateTime.now();

      if (mounted) state = {...state, streamId: listings};
    } catch (_) {
      if (mounted) state = {...state, streamId: []};
    } finally {
      _loading.remove(streamId);
    }
  }

  void clear() {
    state = {};
    _lastFetched.clear();
  }
}

// ── Selected Channel ─────────────────────────────────────────────────────────
final selectedChannelProvider = StateProvider<LiveStream?>((ref) => null);

// ── EPG Visible Hours ────────────────────────────────────────────────────────
final epgHoursProvider = StateProvider<int>((ref) => 8);

// ── EPG Window Start ─────────────────────────────────────────────────────────
final epgWindowStartProvider = StateProvider<DateTime>((ref) {
  // Start 30 minutes before current time, rounded to 30min
  final now = DateTime.now();
  final minutes = now.minute < 30 ? 0 : 30;
  return DateTime(now.year, now.month, now.day, now.hour, minutes);
});

// ── Category Sidebar Width (resizable) ───────────────────────────────────────
final categorySidebarWidthProvider = StateProvider<double>((ref) => 220.0);

// ── Info Panel Visible ────────────────────────────────────────────────────────
final infoPanelVisibleProvider = StateProvider<bool>((ref) => true);

// ── Channel Info Panel Width ─────────────────────────────────────────────────
final infoPanelWidthProvider = StateProvider<double>((ref) => 280.0);

// ── EPG Panel Height ─────────────────────────────────────────────────────────
final epgPanelHeightProvider = StateProvider<double>((ref) => 260.0);

// ── Preview Area Height ──────────────────────────────────────────────────────
final previewAreaHeightProvider = StateProvider<double>((ref) => 240.0);

// ── EPG Panel Visible ────────────────────────────────────────────────────────
final epgPanelVisibleProvider = StateProvider<bool>((ref) => true);

// ── Live Search Query ─────────────────────────────────────────────────────────
final liveSearchQueryProvider = StateProvider<String>((ref) => '');

// ── Filtered Live Streams ────────────────────────────────────────────────────
final liveAllStreamsProvider = FutureProvider<List<LiveStream>>((ref) async {
  final cached = CacheService.instance.loadLiveStreams(ignoreExpiry: true);
  if (cached != null) return cached;
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];
  return service.getLiveStreams();
});

// ── Live UI Filter ────────────────────────────────────────────────────────────
enum LiveFilter { all, favorites, recent }

final liveFilterProvider = StateProvider<LiveFilter>((ref) => LiveFilter.all);

// ── Filtered Live Streams — respects hidden & parental-locked categories ──────
final filteredLiveStreamsProvider = Provider<AsyncValue<List<LiveStream>>>((
  ref,
) {
  final filter = ref.watch(liveFilterProvider);
  final query = ref.watch(liveSearchQueryProvider).toLowerCase().trim();
  final favorites = ref.watch(liveFavoritesNotifierProvider);
  final recentIds = ref.watch(recentlyViewedLiveProvider);
  final hiddenCats = ref.watch(hiddenLiveCategoriesProvider);
  final lockedCats = ref.watch(parentalLockedLiveCategoriesProvider);
  final sessionUnlocked = ref.watch(parentalSessionUnlockedProvider);
  final parentalEnabled = StorageService.instance.isParentalEnabled();

  // Categories whose channels should be hidden everywhere (All Channels, Favorites, Recent)
  final blockedCatIds = <String>{
    ...hiddenCats,
    if (parentalEnabled)
      ...lockedCats.where((id) => !sessionUnlocked.contains(id)),
  };

  List<LiveStream> applyBlock(List<LiveStream> list) {
    if (blockedCatIds.isEmpty) return list;
    return list.where((s) {
      final catId = s.categoryId ?? '';
      return catId.isEmpty || !blockedCatIds.contains(catId);
    }).toList();
  }

  List<LiveStream> search(List<LiveStream> list) {
    final blocked = applyBlock(list);
    if (query.isEmpty) return blocked;
    return blocked.where((s) => s.name.toLowerCase().contains(query)).toList();
  }

  switch (filter) {
    case LiveFilter.favorites:
      return ref
          .watch(liveAllStreamsProvider)
          .whenData(
            (all) => search(
              all.where((s) => favorites.contains(s.streamId)).toList(),
            ),
          );

    case LiveFilter.recent:
      return ref.watch(liveAllStreamsProvider).whenData((all) {
        final map = {for (final s in all) s.streamId: s};
        return search(
          recentIds.map((id) => map[id]).whereType<LiveStream>().toList(),
        );
      });

    case LiveFilter.all:
      // When viewing ALL channels, also filter by hidden/locked categories
      return ref
          .watch(liveStreamsProvider)
          .whenData((streams) => search(streams));
  }
});

// ── Smart Category Ordering ───────────────────────────────────────────────────
// Most-tapped categories move to the top automatically.
// Falls back to original order for untapped categories.
final smartLiveCategoriesProvider = FutureProvider<List<XtreamCategory>>((
  ref,
) async {
  final cats = await ref.watch(liveCategoriesProvider.future);
  if (cats.isEmpty) return cats;

  // Sort by tap count descending; untapped categories keep their original order
  final withTaps =
      cats
          .asMap()
          .entries
          .map(
            (e) => (
              category: e.value,
              taps: BehaviorService.instance.getCategoryTaps(
                e.value.categoryId,
              ),
              original: e.key, // preserve original order for ties
            ),
          )
          .toList()
        ..sort((a, b) {
          final diff = b.taps.compareTo(a.taps);
          return diff != 0 ? diff : a.original.compareTo(b.original);
        });

  return withTaps.map((e) => e.category).toList();
});

// ── Time-of-Day Channel Suggestions ──────────────────────────────────────────
// Surfaces channels the user typically watches at the current hour.
// Refreshes every time filteredLiveStreamsProvider changes (category switch, etc.)
final timeOfDayChannelsProvider = Provider<List<LiveStream>>((ref) {
  final allAsync = ref.watch(liveAllStreamsProvider);

  return allAsync.whenOrNull(
        data: (all) {
          if (all.isEmpty) return null;

          final topIds = BehaviorService.instance.getHourlyTopChannels(
            topN: 10,
          );
          if (topIds.isEmpty) return null;

          final map = {for (final s in all) s.streamId: s};
          final result = topIds
              .map((id) => map[id])
              .whereType<LiveStream>()
              .toList();

          return result.isEmpty ? null : result;
        },
      ) ??
      [];
});

// ── Favorites Management ─────────────────────────────────────────────────────
final liveFavoritesNotifierProvider =
    StateNotifierProvider<LiveFavoritesNotifier, Set<String>>(
      (ref) => LiveFavoritesNotifier(),
    );

class LiveFavoritesNotifier extends StateNotifier<Set<String>> {
  LiveFavoritesNotifier() : super(StorageService.instance.getFavorites('live'));

  Future<void> toggle(String streamId) async {
    await StorageService.instance.toggleFavorite('live', streamId);
    state = StorageService.instance.getFavorites('live');
  }

  bool isFavorite(String streamId) => state.contains(streamId);
}

// ── Hidden Categories ────────────────────────────────────────────────────────
final hiddenLiveCategoriesProvider =
    StateNotifierProvider<HiddenCategoriesNotifier, Set<String>>(
      (ref) => HiddenCategoriesNotifier('live'),
    );

class HiddenCategoriesNotifier extends StateNotifier<Set<String>> {
  HiddenCategoriesNotifier(this._type)
    : super(StorageService.instance.getHiddenCategories(_type));

  final String _type;

  Future<void> toggle(String categoryId) async {
    await StorageService.instance.toggleCategoryVisibility(_type, categoryId);
    state = StorageService.instance.getHiddenCategories(_type);
  }

  bool isHidden(String id) => state.contains(id);
}

// ── Category Order ────────────────────────────────────────────────────────────
final liveCategoryOrderProvider =
    StateNotifierProvider<CategoryOrderNotifier, List<String>>(
      (ref) => CategoryOrderNotifier('live'),
    );

class CategoryOrderNotifier extends StateNotifier<List<String>> {
  CategoryOrderNotifier(this._type)
    : super(StorageService.instance.getCategoryOrder(_type));

  final String _type;

  Future<void> reorder(List<String> newOrder) async {
    await StorageService.instance.saveCategoryOrder(_type, newOrder);
    state = newOrder;
  }
}

// ── Recently Viewed Live Channels ────────────────────────────────────────────
const _kRecentKey = 'recently_viewed_live';

final recentlyViewedLiveProvider =
    StateNotifierProvider<RecentlyViewedLiveNotifier, List<String>>(
      (ref) => RecentlyViewedLiveNotifier(),
    );

class RecentlyViewedLiveNotifier extends StateNotifier<List<String>> {
  RecentlyViewedLiveNotifier() : super(_load());

  static List<String> _load() {
    final raw = StorageService.instance.getSetting(_kRecentKey) as List?;
    return raw?.map((e) => e.toString()).toList() ?? [];
  }

  void add(String streamId) {
    final updated = [
      streamId,
      ...state.where((id) => id != streamId),
    ].take(30).toList();
    state = updated;
    StorageService.instance.setSetting(_kRecentKey, updated);
  }

  void clear() {
    state = [];
    StorageService.instance.setSetting(_kRecentKey, <String>[]);
  }
}

// ── Derived: recently viewed stream objects ───────────────────────────────────
final recentlyViewedStreamsProvider = Provider<AsyncValue<List<LiveStream>>>((
  ref,
) {
  final ids = ref.watch(recentlyViewedLiveProvider);
  final streams = ref.watch(liveStreamsProvider);
  return streams.whenData((all) {
    final map = {for (final s in all) s.streamId: s};
    return ids.map((id) => map[id]).whereType<LiveStream>().toList();
  });
});

// ── Inline Player Maximize State ──────────────────────────────────────────────
final livePlayerMaximizedProvider = StateProvider<bool>((ref) => false);

// ── Parental Locked Live Categories ──────────────────────────────────────────
final parentalLockedLiveCategoriesProvider =
    StateNotifierProvider<ParentalLockedLiveCatsNotifier, Set<String>>(
      (ref) => ParentalLockedLiveCatsNotifier(),
    );

class ParentalLockedLiveCatsNotifier extends StateNotifier<Set<String>> {
  ParentalLockedLiveCatsNotifier()
    : super(StorageService.instance.getParentalLockedCategories('live'));

  Future<void> toggle(String id) async {
    await StorageService.instance.toggleParentalLocked('live', id);
    state = StorageService.instance.getParentalLockedCategories('live');
  }

  bool isLocked(String id) => state.contains(id);
}

// ── Parental Session Unlocked (in-memory only, cleared on restart) ────────────
final parentalSessionUnlockedProvider = StateProvider<Set<String>>(
  (ref) => const {},
);

// ── Scroll-to-Channel trigger (one-shot, for Remember Position) ───────────────
final liveScrollToChannelProvider = StateProvider<String?>((ref) => null);
