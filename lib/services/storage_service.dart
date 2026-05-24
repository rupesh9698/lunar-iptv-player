import 'package:hive_flutter/hive_flutter.dart';
import '../models/xtream_models.dart';
import '../core/constants/app_constants.dart';

class StorageService {
  static StorageService? _instance;
  static StorageService get instance => _instance ??= StorageService._();
  StorageService._();

  late Box _playlistBox;
  late Box _settingsBox;
  late Box _favoritesBox;
  late Box _categoryOrderBox;
  late Box _hiddenCategoriesBox;
  late Box _watchHistoryBox;

  Future<void> init() async {
    await Hive.initFlutter();
    // final dir = await getApplicationSupportDirectory();
    // await Hive.initFlutter(dir.path);
    _playlistBox = await Hive.openBox(AppConstants.playlistBox);
    _settingsBox = await Hive.openBox(AppConstants.settingsBox);
    _favoritesBox = await Hive.openBox(AppConstants.favoritesBox);
    _categoryOrderBox = await Hive.openBox(AppConstants.categoryOrderBox);
    _hiddenCategoriesBox =
    await Hive.openBox(AppConstants.hiddenCategoriesBox);
    _watchHistoryBox = await Hive.openBox(AppConstants.watchHistoryBox);
  }

  // ── Playlists ─────────────────────────────────────────────────
  List<Playlist> getPlaylists() {
    return _playlistBox.values
        .map((v) => Playlist.fromMap(v as Map))
        .toList();
  }

  Future<void> savePlaylist(Playlist playlist) async {
    await _playlistBox.put(playlist.id, playlist.toMap());
  }

  Future<void> deletePlaylist(String id) async {
    await _playlistBox.delete(id);
  }

  // ── Active Playlist ───────────────────────────────────────────
  String? getActivePlaylistId() =>
      _settingsBox.get(AppConstants.activePlaylistKey) as String?;

  Future<void> setActivePlaylistId(String? id) async =>
      _settingsBox.put(AppConstants.activePlaylistKey, id);

  // ── Settings ──────────────────────────────────────────────────
  dynamic getSetting(String key, [dynamic defaultValue]) =>
      _settingsBox.get(key, defaultValue: defaultValue);

  Future<void> setSetting(String key, dynamic value) =>
      _settingsBox.put(key, value);

  // ── Favorites ─────────────────────────────────────────────────
  Set<String> getFavorites(String type) {
    final data = _favoritesBox.get(type);
    if (data == null) return {};
    return (data as List).map((e) => e.toString()).toSet();
  }

  Future<void> toggleFavorite(String type, String id) async {
    final favorites = getFavorites(type);
    if (favorites.contains(id)) {
      favorites.remove(id);
    } else {
      favorites.add(id);
    }
    await _favoritesBox.put(type, favorites.toList());
  }

  bool isFavorite(String type, String id) => getFavorites(type).contains(id);

  // ── Category Management ───────────────────────────────────────
  Set<String> getHiddenCategories(String type) {
    final data = _hiddenCategoriesBox.get(type);
    if (data == null) return {};
    return (data as List).map((e) => e.toString()).toSet();
  }

  Future<void> setHiddenCategories(String type, Set<String> ids) async {
    await _hiddenCategoriesBox.put(type, ids.toList());
  }

  Future<void> toggleCategoryVisibility(String type, String id) async {
    final hidden = getHiddenCategories(type);
    if (hidden.contains(id)) {
      hidden.remove(id);
    } else {
      hidden.add(id);
    }
    await _hiddenCategoriesBox.put(type, hidden.toList());
  }

  // ── Parental Locked Categories ────────────────────────────────────────────
  Set<String> getParentalLockedCategories(String type) {
    final data = _settingsBox.get('parental_locked_$type');
    if (data == null) return {};
    return (data as List).map((e) => e.toString()).toSet();
  }

  Future<void> setParentalLockedCategories(
      String type, Set<String> ids) async {
    await _settingsBox.put('parental_locked_$type', ids.toList());
  }

  Future<void> toggleParentalLocked(String type, String id) async {
    final locked = getParentalLockedCategories(type);
    if (locked.contains(id)) {
      locked.remove(id);
    } else {
      locked.add(id);
    }
    await _settingsBox.put('parental_locked_$type', locked.toList());
  }

  List<String> getCategoryOrder(String type) {
    final data = _categoryOrderBox.get(type);
    if (data == null) return [];
    return (data as List).map((e) => e.toString()).toList();
  }

  Future<void> saveCategoryOrder(String type, List<String> ids) async {
    await _categoryOrderBox.put(type, ids);
  }

  // ── Watch History ─────────────────────────────────────────────
  List<WatchHistoryItem> getWatchHistory() {
    return _watchHistoryBox.values
        .map((v) => WatchHistoryItem.fromMap(v as Map))
        .toList()
      ..sort((a, b) => b.watchedAt.compareTo(a.watchedAt));
  }

  Future<void> addToHistory(WatchHistoryItem item) async {
    await _watchHistoryBox.put(item.id, item.toMap());
  }

  Future<void> updateWatchPosition(String id, int positionSeconds) async {
    final item = _watchHistoryBox.get(id);
    if (item != null) {
      final map = Map<String, dynamic>.from(item as Map);
      map['position'] = positionSeconds;
      await _watchHistoryBox.put(id, map);
    }
  }

  int getWatchPosition(String id) {
    final item = _watchHistoryBox.get(id);
    if (item == null) return 0;
    return (item as Map)['position'] as int? ?? 0;
  }

  Future<void> clearHistory() async => _watchHistoryBox.clear();

  // ── Parental Control ──────────────────────────────────────────
  String? getParentalPin() =>
      _settingsBox.get(AppConstants.parentalPinKey) as String?;

  Future<void> setParentalPin(String pin) =>
      _settingsBox.put(AppConstants.parentalPinKey, pin);

  bool isParentalEnabled() =>
      _settingsBox.get(AppConstants.parentalEnabledKey, defaultValue: false)
      as bool;

  Future<void> setParentalEnabled(bool value) =>
      _settingsBox.put(AppConstants.parentalEnabledKey, value);
}