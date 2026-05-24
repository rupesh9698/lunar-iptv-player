import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../core/constants/app_constants.dart';
import '../models/xtream_models.dart';
import '../services/cache_service.dart';
import '../services/storage_service.dart';
import '../services/xtream_service.dart';

// ── Storage Provider ─────────────────────────────────────────────────────────
final storageProvider = Provider<StorageService>(
  (ref) => StorageService.instance,
);

// ── Active Playlist ──────────────────────────────────────────────────────────
final playlistsProvider =
    StateNotifierProvider<PlaylistNotifier, List<Playlist>>((ref) {
      return PlaylistNotifier(ref.read(storageProvider));
    });

class PlaylistNotifier extends StateNotifier<List<Playlist>> {
  final StorageService _storage;

  PlaylistNotifier(this._storage) : super(_storage.getPlaylists());

  Future<void> addPlaylist(Playlist playlist) async {
    await _storage.savePlaylist(playlist);
    state = _storage.getPlaylists();
  }

  Future<void> removePlaylist(String id) async {
    await _storage.deletePlaylist(id);
    // If removed playlist was active, clear active
    if (_storage.getActivePlaylistId() == id) {
      await _storage.setActivePlaylistId(null);
    }
    state = _storage.getPlaylists();
  }

  Future<void> setActive(String id) async {
    await _storage.setActivePlaylistId(id);
    state = state
        .map(
          (p) => Playlist(
            id: p.id,
            name: p.name,
            serverUrl: p.serverUrl,
            username: p.username,
            password: p.password,
            addedAt: p.addedAt,
            lastUpdated: p.lastUpdated,
            isActive: p.id == id,
          ),
        )
        .toList();
  }
}

final activePlaylistProvider = Provider<Playlist?>((ref) {
  final playlists = ref.watch(playlistsProvider);
  final storage = ref.read(storageProvider);
  final activeId = storage.getActivePlaylistId();
  if (activeId == null) return null;
  try {
    return playlists.firstWhere((p) => p.id == activeId);
  } catch (_) {
    if (playlists.isNotEmpty) return playlists.first;
    return null;
  }
});

// ── Xtream Service ───────────────────────────────────────────────────────────
final xtreamServiceProvider = Provider<XtreamService?>((ref) {
  final playlist = ref.watch(activePlaylistProvider);
  if (playlist == null) return null;
  return XtreamService(playlist: playlist);
});

// ── Account Info ─────────────────────────────────────────────────────────────
final accountInfoProvider = FutureProvider<AccountInfo?>((ref) async {
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return null;
  return service.getAccountInfo();
});

// ── Live TV ──────────────────────────────────────────────────────────────────
final liveCategoriesProvider = FutureProvider<List<XtreamCategory>>((
  ref,
) async {
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];

  // 1. Try cache (even if stale — we refresh in background)
  final cached = CacheService.instance.loadLiveCategories(ignoreExpiry: true);
  if (cached != null) return cached;

  // 2. No cache → fetch and save
  final cats = await service.getLiveCategories();
  await CacheService.instance.saveLiveCategories(cats);
  return cats;
});

final selectedLiveCategoryProvider = StateProvider<XtreamCategory?>(
  (ref) => null,
);

final liveStreamsProvider = FutureProvider<List<LiveStream>>((ref) async {
  final service = ref.watch(xtreamServiceProvider);
  final category = ref.watch(selectedLiveCategoryProvider);
  if (service == null) return [];

  // Try cache (all channels stored together)
  final allCached = CacheService.instance.loadLiveStreams(ignoreExpiry: true);
  if (allCached != null) {
    if (category == null) return allCached;
    return allCached.where((s) => s.categoryId == category.categoryId).toList();
  }

  // No cache → fetch (with category filter)
  final streams = await service.getLiveStreams(
    categoryId: category?.categoryId,
  );
  return streams;
});

// ── Movies (VOD) ─────────────────────────────────────────────────────────────
final vodCategoriesProvider = FutureProvider<List<XtreamCategory>>((ref) async {
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];

  final cached = CacheService.instance.loadVodCategories(ignoreExpiry: true);
  if (cached != null) return cached;

  final cats = await service.getVodCategories();
  await CacheService.instance.saveVodCategories(cats);
  return cats;
});

final selectedVodCategoryProvider = StateProvider<XtreamCategory?>(
  (ref) => null,
);

final vodStreamsProvider = FutureProvider<List<VodStream>>((ref) async {
  final service = ref.watch(xtreamServiceProvider);
  final category = ref.watch(selectedVodCategoryProvider);
  if (service == null) return [];

  final allCached = CacheService.instance.loadVodStreams(ignoreExpiry: true);
  if (allCached != null) {
    if (category == null) return allCached;
    return allCached.where((s) => s.categoryId == category.categoryId).toList();
  }

  final streams = await service.getVodStreams(categoryId: category?.categoryId);
  return streams;
});

// ── Series ───────────────────────────────────────────────────────────────────
final seriesCategoriesProvider = FutureProvider<List<XtreamCategory>>((
  ref,
) async {
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];

  final cached = CacheService.instance.loadSeriesCategories(ignoreExpiry: true);
  if (cached != null) return cached;

  final cats = await service.getSeriesCategories();
  await CacheService.instance.saveSeriesCategories(cats);
  return cats;
});

final selectedSeriesCategoryProvider = StateProvider<XtreamCategory?>(
  (ref) => null,
);

final seriesListProvider = FutureProvider<List<Series>>((ref) async {
  final service = ref.watch(xtreamServiceProvider);
  final category = ref.watch(selectedSeriesCategoryProvider);
  if (service == null) return [];

  final allCached = CacheService.instance.loadSeriesList(ignoreExpiry: true);
  if (allCached != null) {
    if (category == null) return allCached;
    return allCached.where((s) => s.categoryId == category.categoryId).toList();
  }

  final series = await service.getSeries(categoryId: category?.categoryId);
  return series;
});

// ── Search ───────────────────────────────────────────────────────────────────
final searchQueryProvider = StateProvider<String>((ref) => '');

final searchResultsProvider = FutureProvider<Map<String, dynamic>>((ref) async {
  final query = ref.watch(searchQueryProvider);
  if (query.isEmpty) return {};
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return {};
  return service.searchAll(query);
});

// ── Favorites ────────────────────────────────────────────────────────────────
final favoritesRefreshProvider = StateProvider<int>((ref) => 0);

final liveFavoritesProvider = FutureProvider<List<LiveStream>>((ref) async {
  ref.watch(favoritesRefreshProvider);
  final service = ref.watch(xtreamServiceProvider);
  if (service == null) return [];
  final storage = ref.read(storageProvider);
  final favIds = storage.getFavorites('live');
  if (favIds.isEmpty) return [];
  final streams = await service.getLiveStreams();
  return streams.where((s) => favIds.contains(s.streamId)).toList();
});

// ── Settings ─────────────────────────────────────────────────────────────────
final settingsProvider =
    StateNotifierProvider<SettingsNotifier, Map<String, dynamic>>((ref) {
      return SettingsNotifier(ref.read(storageProvider));
    });

class SettingsNotifier extends StateNotifier<Map<String, dynamic>> {
  final StorageService _storage;

  SettingsNotifier(this._storage)
    : super({
        AppConstants.streamFormatKey: _storage.getSetting(
          AppConstants.streamFormatKey,
          'm3u8',
        ),
        AppConstants.autoUpdateKey: _storage.getSetting(
          AppConstants.autoUpdateKey,
          false,
        ),
        AppConstants.rememberPositionKey: _storage.getSetting(
          AppConstants.rememberPositionKey,
          true,
        ),
        AppConstants.showChannelNumberKey: _storage.getSetting(
          AppConstants.showChannelNumberKey,
          true,
        ),
        AppConstants.parentalEnabledKey: _storage.isParentalEnabled(),
      });

  Future<void> update(String key, dynamic value) async {
    await _storage.setSetting(key, value);
    state = {...state, key: value};
  }

  dynamic get(String key) => state[key];
}

// ── Background refresh provider ────────────────────────────────────────────
// Triggered when cache is stale; runs silently in background
final backgroundRefreshProvider = FutureProvider<void>((ref) async {
  final service = ref.read(xtreamServiceProvider);
  if (service == null) return;

  final cache = CacheService.instance;

  // Refresh live TV if stale
  if (cache.isLiveStale()) {
    try {
      final cats = await service.getLiveCategories();
      final ch = await service.getLiveStreams();
      await cache.saveLiveCategories(cats);
      await cache.saveLiveStreams(ch);
      ref.invalidate(liveCategoriesProvider);
      ref.invalidate(liveStreamsProvider);
    } catch (_) {}
  }

  // Refresh VOD if stale
  if (cache.isVodStale()) {
    try {
      final cats = await service.getVodCategories();
      final streams = await service.getVodStreams();
      await cache.saveVodCategories(cats);
      await cache.saveVodStreams(streams);
      ref.invalidate(vodCategoriesProvider);
      ref.invalidate(vodStreamsProvider);
    } catch (_) {}
  }

  // Refresh series if stale
  if (cache.isSeriesStale()) {
    try {
      final cats = await service.getSeriesCategories();
      final series = await service.getSeries();
      await cache.saveSeriesCategories(cats);
      await cache.saveSeriesList(series);
      ref.invalidate(seriesCategoriesProvider);
      ref.invalidate(seriesListProvider);
    } catch (_) {}
  }
});

// ── Cache Sync Timestamp — incremented after every sync to force home rebuild ─
final cacheLastSyncProvider = StateProvider<DateTime?>((ref) => null);
