import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

/// All AI behavior data, isolated per playlist.
class BehaviorService {
  BehaviorService._();
  static final BehaviorService instance = BehaviorService._();

  static const _boxName = 'behavior';
  static const _maxPositionEntries = 50;

  Box? _box;
  String _playlistId = 'default';
  final Map<String, DateTime> _activeTimers = {};

  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  /// Call whenever the active playlist changes.
  void setPlaylist(String playlistId) {
    _playlistId = playlistId.isEmpty ? 'default' : playlistId;
  }

  /// Prefix every key with the current playlist ID.
  String _k(String key) => '${_playlistId}_$key';

  // ── Watch Count ────────────────────────────────────────────────────────────

  Future<void> recordOpen(String id, {String name = ''}) async {
    if (_box == null) return;
    final countKey = _k('watch_count_$id');
    await _box!.put(
      countKey,
      (_box!.get(countKey, defaultValue: 0) as int) + 1,
    );
    if (name.isNotEmpty) {
      await _box!.put(_k('content_name_$id'), name);
    }
  }

  int getWatchCount(String id) {
    if (_box == null) return 0;
    return _box!.get(_k('watch_count_$id'), defaultValue: 0) as int;
  }

  // ── Watch Position (Continue Watching) ────────────────────────────────────

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
    if (_box == null || durationSeconds <= 0) return;

    final progress = positionSeconds / durationSeconds;
    if (progress > 0.90) {
      await _box!.delete(_k('watch_pos_$id'));
      await _prunePositions();
      return;
    }
    if (progress < 0.02) return;

    final data = {
      'id': id,
      'url': url, // ← NEW — needed to resume playback
      'position': positionSeconds,
      'duration': durationSeconds,
      'progress': progress,
      'type': type,
      'title': title,
      'imageUrl': imageUrl ?? '',
      'seriesId': seriesId ?? '',
      'seriesName': seriesName ?? '',
      'season': season ?? '',
      'episode': episode ?? '',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    await _box!.put(_k('watch_pos_$id'), jsonEncode(data));
    // Also store name for stats
    await _box!.put(_k('content_name_$id'), title);
    await _prunePositions();
  }

  Future<void> clearPosition(String id) async {
    await _box?.delete(_k('watch_pos_$id'));
  }

  List<Map<String, dynamic>> getContinueWatching() {
    if (_box == null) return [];
    final prefix = _k('watch_pos_');
    final result = <Map<String, dynamic>>[];

    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final raw = _box!.get(key);
      if (raw == null) continue;
      try {
        result.add(jsonDecode(raw as String) as Map<String, dynamic>);
      } catch (_) {}
    }

    result.sort((a, b) {
      final ta = a['timestamp'] as int? ?? 0;
      final tb = b['timestamp'] as int? ?? 0;
      return tb.compareTo(ta);
    });
    return result.take(20).toList();
  }

  Future<void> _prunePositions() async {
    if (_box == null) return;
    final prefix = _k('watch_pos_');
    final entries = <String, int>{};

    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final raw = _box!.get(key);
      if (raw == null) continue;
      try {
        final map = jsonDecode(raw as String) as Map<String, dynamic>;
        entries[key.toString()] = map['timestamp'] as int? ?? 0;
      } catch (_) {}
    }

    if (entries.length <= _maxPositionEntries) return;
    final sorted = entries.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final toDelete = sorted.skip(_maxPositionEntries).map((e) => e.key);
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  // ── Category Taps ─────────────────────────────────────────────────────────

  Future<void> recordCategoryTap(String categoryId) async {
    if (_box == null) return;
    final key = _k('category_taps_$categoryId');
    await _box!.put(key, (_box!.get(key, defaultValue: 0) as int) + 1);
  }

  int getCategoryTaps(String categoryId) {
    if (_box == null) return 0;
    return _box!.get(_k('category_taps_$categoryId'), defaultValue: 0) as int;
  }

  // ── Hourly Preferences ────────────────────────────────────────────────────

  Future<void> recordHourlyChannelView(
    String channelId, {
    String name = '',
  }) async {
    if (_box == null) return;
    final hour = DateTime.now().hour;
    final key = _k('hourly_${hour}_$channelId');
    await _box!.put(key, (_box!.get(key, defaultValue: 0) as int) + 1);
    if (name.isNotEmpty) {
      await _box!.put(_k('content_name_$channelId'), name);
    }
  }

  List<String> getHourlyTopChannels({int topN = 10}) {
    if (_box == null) return [];
    final hour = DateTime.now().hour;
    final prefix = _k('hourly_${hour}_');
    final counts = <String, int>{};

    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final channelId = key.toString().substring(prefix.length);
      counts[channelId] = _box!.get(key, defaultValue: 0) as int;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(topN)
        .map((e) => e.key)
        .toList();
  }

  /// Returns the stored display name for any content ID.
  String getContentName(String id) {
    if (_box == null) return '';
    return _box!.get(_k('content_name_$id'), defaultValue: '') as String;
  }

  // ── Genre Frequency ───────────────────────────────────────────────────────

  Future<void> recordGenreAccess(String genre) async {
    if (_box == null) return;
    final key = _k('genre_freq_$genre');
    await _box!.put(key, (_box!.get(key, defaultValue: 0) as int) + 1);
  }

  List<String> getTopGenres({int topN = 5}) {
    if (_box == null) return [];
    final prefix = _k('genre_freq_');
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final genre = key.toString().substring(prefix.length);
      counts[genre] = _box!.get(key, defaultValue: 0) as int;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(topN)
        .map((e) => e.key)
        .toList();
  }

  // ── Watch Time Tracking ───────────────────────────────────────────────────

  void startWatchTimer(String id, {String name = ''}) {
    _activeTimers[id] = DateTime.now();
    if (name.isNotEmpty && _box != null) {
      _box!.put(_k('content_name_$id'), name);
    }
  }

  Future<void> stopWatchTimer(String id) async {
    if (_box == null) return;
    final start = _activeTimers.remove(id);
    if (start == null) return;
    final seconds = DateTime.now().difference(start).inSeconds;
    if (seconds < 5) return;

    final dateKey = _todayKey();
    final totalKey = _k('total_watch_$dateKey');
    final contentKey = _k('content_watch_$id');
    await _box!.put(
      totalKey,
      (_box!.get(totalKey, defaultValue: 0) as int) + seconds,
    );
    await _box!.put(
      contentKey,
      (_box!.get(contentKey, defaultValue: 0) as int) + seconds,
    );
  }

  List<Map<String, dynamic>> getWatchTimeByDay({int days = 7}) {
    if (_box == null) return [];
    final now = DateTime.now();
    final result = <Map<String, dynamic>>[];
    for (int i = days - 1; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateKey = _dateKey(date);
      final seconds =
          _box!.get(_k('total_watch_$dateKey'), defaultValue: 0) as int;
      result.add({
        'date': dateKey,
        'label': _shortLabel(date),
        'seconds': seconds,
      });
    }
    return result;
  }

  int getTotalWatchSeconds() {
    if (_box == null) return 0;
    final prefix = _k('total_watch_');
    int total = 0;
    for (final key in _box!.keys) {
      if (key.toString().startsWith(prefix)) {
        total += _box!.get(key, defaultValue: 0) as int;
      }
    }
    return total;
  }

  // ── Search Ranking ────────────────────────────────────────────────────────

  Future<void> recordSearchClick(String id) async {
    if (_box == null) return;
    final key = _k('search_rank_$id');
    final raw = _box!.get(key) as String?;
    Map<String, dynamic> data;
    if (raw != null) {
      try {
        data = jsonDecode(raw) as Map<String, dynamic>;
        data['count'] = (data['count'] as int? ?? 0) + 1;
        data['lastAt'] = DateTime.now().millisecondsSinceEpoch;
      } catch (_) {
        data = {'count': 1, 'lastAt': DateTime.now().millisecondsSinceEpoch};
      }
    } else {
      data = {'count': 1, 'lastAt': DateTime.now().millisecondsSinceEpoch};
    }
    await _box!.put(key, jsonEncode(data));
  }

  double getSearchScore(String id, double textMatchScore) {
    if (_box == null) return textMatchScore;
    final raw = _box!.get(_k('search_rank_$id')) as String?;
    if (raw == null) return textMatchScore;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final count = (data['count'] as int? ?? 0).toDouble();
      final lastAt = data['lastAt'] as int? ?? 0;
      final daysSince = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(lastAt))
          .inDays
          .toDouble();
      return textMatchScore + count * (1.0 / (1.0 + daysSince * 0.1)) * 0.3;
    } catch (_) {
      return textMatchScore;
    }
  }

  // ── Auto Favourite Suggestions ────────────────────────────────────────────

  List<String> getSuggestedFavorites(
    Set<String> currentFavorites, {
    int minViews = 5,
  }) {
    if (_box == null) return [];
    final prefix = _k('watch_count_');
    final suggestions = <String>[];
    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final id = key.toString().substring(prefix.length);
      final count = _box!.get(key, defaultValue: 0) as int;
      if (count >= minViews && !currentFavorites.contains(id)) {
        suggestions.add(id);
      }
    }
    return suggestions;
  }

  // ── Top Content by Watch Time ─────────────────────────────────────────────

  List<Map<String, dynamic>> getTopContentByTime({int topN = 10}) {
    if (_box == null) return [];
    final prefix = _k('content_watch_');
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      final id = key.toString().substring(prefix.length);
      counts[id] = _box!.get(key, defaultValue: 0) as int;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(topN)
        .map((e) {
          final name =
              _box!.get(_k('content_name_${e.key}'), defaultValue: '')
                  as String;
          return {
            'id': e.key,
            'name': name.isNotEmpty ? name : e.key, // ← name for display
            'seconds': e.value,
          };
        })
        .toList();
  }

  // ── Clear methods ─────────────────────────────────────────────────────────

  /// Clears ONLY the current playlist's behavior data.
  Future<void> clearPlaylist() async {
    if (_box == null) return;
    final prefix = '${_playlistId}_';
    final toDelete = _box!.keys
        .where((k) => k.toString().startsWith(prefix))
        .toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  /// Clears ONLY Live TV behavior (hourly prefs, live watch-time).
  /// Called when user taps "Clear Recently Viewed (Live)" in Settings.
  Future<void> clearLiveStats() async {
    if (_box == null) return;
    final prefixes = [
      _k('hourly_'),
      _k('category_taps_'),
      // Keep VOD/series data intact — only remove live-specific keys
    ];
    final toDelete = _box!.keys.where((k) {
      final s = k.toString();
      return prefixes.any((p) => s.startsWith(p));
    }).toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  /// Clears Movies + Series behavior (watch time, positions, genres, search ranks).
  /// Called when user taps "Clear Watch History" in Settings.
  Future<void> clearVodSeriesStats() async {
    if (_box == null) return;
    final prefixes = [
      _k('watch_pos_'),
      _k('watch_count_'),
      _k('content_watch_'),
      _k('content_name_'),
      _k('total_watch_'),
      _k('genre_freq_'),
      _k('search_rank_'),
    ];
    final toDelete = _box!.keys.where((k) {
      final s = k.toString();
      return prefixes.any((p) => s.startsWith(p));
    }).toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  /// Clears all data across ALL playlists.
  Future<void> clearAll() async => await _box?.clear();

  /// Clears only position/continue-watching data for current playlist.
  Future<void> clearContinueWatching() async {
    if (_box == null) return;
    final prefix = _k('watch_pos_');
    final toDelete = _box!.keys
        .where((k) => k.toString().startsWith(prefix))
        .toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  /// Clears watch-time data for current playlist (for stats reset).
  Future<void> clearWatchTime() async {
    if (_box == null) return;
    final prefixes = [
      _k('total_watch_'),
      _k('content_watch_'),
      _k('content_name_'),
    ];
    final toDelete = _box!.keys.where((k) {
      final s = k.toString();
      return prefixes.any((p) => s.startsWith(p));
    }).toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  String _todayKey() => _dateKey(DateTime.now());
  String _dateKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';
  String _shortLabel(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[d.weekday - 1];
  }
}
