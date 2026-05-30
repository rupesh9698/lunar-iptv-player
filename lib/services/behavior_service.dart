import 'dart:convert';

import 'package:hive_flutter/hive_flutter.dart';

/// Single-source behavior tracking for all AI features.
/// Everything is stored in Hive — fully offline, no server needed.
///
/// Keys used:
///   watch_count_{id}          — int: how many times this content was opened
///   watch_pos_{id}            — Map: {position, duration, type, title, imageUrl, timestamp}
///   category_taps_{id}        — int: how many times a category was tapped
///   hourly_{hour}_{channelId} — int: channel views at a given hour-of-day
///   genre_freq_{genre}        — int: how many times genre was accessed
///   search_rank_{id}          — Map: {count, lastAt}
///   total_watch_{yyyyMMdd}    — int: total seconds watched on a date
class BehaviorService {
  BehaviorService._();

  static final BehaviorService instance = BehaviorService._();

  static const _boxName = 'behavior';
  static const _maxPositionEntries = 50;

  Box? _box;

  /// Must be called in main() after Hive.initFlutter()
  Future<void> init() async {
    _box = await Hive.openBox(_boxName);
  }

  Box? get _b {
    // Defensive: returns null instead of asserting — callers must null-check
    return _box;
  }

  // ── Watch Count ───────────────────────────────────────────────────────────

  /// Call whenever a user opens a piece of content (channel, movie, episode).
  Future<void> recordOpen(String id) async {
    if (_box == null) return;
    final key = 'watch_count_$id';
    final current = _box!.get(key, defaultValue: 0) as int;
    await _box!.put(key, current + 1);
  }

  int getWatchCount(String id) {
    if (_box == null) return 0;
    return _box!.get('watch_count_$id', defaultValue: 0) as int;
  }

  // ── Watch Position (Continue Watching) ───────────────────────────────────

  /// Records or updates the playback position for a VOD item or series episode.
  ///
  /// [type] is 'movie' | 'series' | 'episode'
  Future<void> savePosition({
    required String id,
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
      await _box!.delete('watch_pos_$id');
      await _prunePositions();
      return;
    }
    if (progress < 0.02) return;

    final data = {
      'id': id,
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

    await _box!.put('watch_pos_$id', jsonEncode(data));
    await _prunePositions();
  }

  /// Removes a saved position (called when content finishes or user deletes).
  Future<void> clearPosition(String id) async {
    await _box?.delete('watch_pos_$id');
  }

  /// Returns all continue-watching entries sorted by most recently watched.
  /// Max 20 items.
  List<Map<String, dynamic>> getContinueWatching() {
    if (_box == null) return [];
    final result = <Map<String, dynamic>>[];

    for (final key in _box!.keys) {
      if (key.toString().startsWith('watch_pos_')) {
        final raw = _box!.get(key);
        if (raw == null) continue;
        try {
          final map = jsonDecode(raw as String) as Map<String, dynamic>;
          result.add(map);
        } catch (_) {}
      }
    }

    result.sort((a, b) {
      final ta = a['timestamp'] as int? ?? 0;
      final tb = b['timestamp'] as int? ?? 0;
      return tb.compareTo(ta);
    });

    return result.take(20).toList();
  }

  /// Keeps only the most recent [_maxPositionEntries] entries.
  Future<void> _prunePositions() async {
    if (_box == null) return;
    final entries = <String, int>{};
    for (final key in _box!.keys) {
      if (key.toString().startsWith('watch_pos_')) {
        final raw = _box!.get(key);
        if (raw == null) continue;
        try {
          final map = jsonDecode(raw as String) as Map<String, dynamic>;
          entries[key.toString()] = map['timestamp'] as int? ?? 0;
        } catch (_) {}
      }
    }
    if (entries.length <= _maxPositionEntries) return;
    final sorted = entries.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final toDelete = sorted.skip(_maxPositionEntries).map((e) => e.key);
    for (final key in toDelete) {
      await _box!.delete(key);
    }
  }

  // ── Category Taps (Smart Category Ordering) ───────────────────────────────

  Future<void> recordCategoryTap(String categoryId) async {
    if (_box == null) return;
    final key = 'category_taps_$categoryId';
    final current = _box!.get(key, defaultValue: 0) as int;
    await _box!.put(key, current + 1);
  }

  int getCategoryTaps(String categoryId) {
    if (_box == null) return 0;
    return _box!.get('category_taps_$categoryId', defaultValue: 0) as int;
  }

  // ── Hourly Channel Preferences (Time-of-Day) ──────────────────────────────

  Future<void> recordHourlyChannelView(String channelId) async {
    if (_box == null) return;
    final hour = DateTime.now().hour;
    final key = 'hourly_${hour}_$channelId';
    final current = _box!.get(key, defaultValue: 0) as int;
    await _box!.put(key, current + 1);
  }

  List<String> getHourlyTopChannels({int topN = 10}) {
    if (_box == null) return [];
    final hour = DateTime.now().hour;
    final prefix = 'hourly_${hour}_';
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (key.toString().startsWith(prefix)) {
        final channelId = key.toString().substring(prefix.length);
        counts[channelId] = _box!.get(key, defaultValue: 0) as int;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(topN).map((e) => e.key).toList();
  }

  Future<void> recordGenreAccess(String genre) async {
    if (_box == null) return;
    final key = 'genre_freq_$genre';
    final current = _box!.get(key, defaultValue: 0) as int;
    await _box!.put(key, current + 1);
  }

  List<String> getTopGenres({int topN = 5}) {
    if (_box == null) return [];
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (key.toString().startsWith('genre_freq_')) {
        final genre = key.toString().substring('genre_freq_'.length);
        counts[genre] = _box!.get(key, defaultValue: 0) as int;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted.take(topN).map((e) => e.key).toList();
  }

  // ── Daily Watch Time (Dashboard) ─────────────────────────────────────────

  final Map<String, DateTime> _activeTimers = {};

  void startWatchTimer(String id) {
    _activeTimers[id] = DateTime.now();
  }

  Future<void> stopWatchTimer(String id) async {
    if (_box == null) return;
    final start = _activeTimers.remove(id);
    if (start == null) return;
    final seconds = DateTime.now().difference(start).inSeconds;
    if (seconds < 5) return;

    final dateKey = _todayKey();
    final current = _box!.get('total_watch_$dateKey', defaultValue: 0) as int;
    await _box!.put('total_watch_$dateKey', current + seconds);

    final contentKey = 'content_watch_$id';
    final contentCurrent = _box!.get(contentKey, defaultValue: 0) as int;
    await _box!.put(contentKey, contentCurrent + seconds);
  }

  List<Map<String, dynamic>> getWatchTimeByDay({int days = 7}) {
    if (_box == null) return [];
    final result = <Map<String, dynamic>>[];
    final now = DateTime.now();
    for (int i = days - 1; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateKey = _dateKey(date);
      final seconds = _box!.get('total_watch_$dateKey', defaultValue: 0) as int;
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
    int total = 0;
    for (final key in _box!.keys) {
      if (key.toString().startsWith('total_watch_')) {
        total += _box!.get(key, defaultValue: 0) as int;
      }
    }
    return total;
  } // ── Search Ranking ────────────────────────────────────────────────────────

  Future<void> recordSearchClick(String id) async {
    if (_box == null) return;
    final key = 'search_rank_$id';
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

  /// Returns a ranking score for search results.
  /// Higher = more relevant.
  double getSearchScore(String id, double textMatchScore) {
    if (_box == null) return textMatchScore;
    final raw = _box!.get('search_rank_$id') as String?;
    if (raw == null) return textMatchScore;
    try {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      final count = (data['count'] as int? ?? 0).toDouble();
      final lastAt = data['lastAt'] as int? ?? 0;
      final daysSince = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(lastAt))
          .inDays
          .toDouble();
      final recencyBoost = count * (1.0 / (1.0 + daysSince * 0.1));
      return textMatchScore + (recencyBoost * 0.3);
    } catch (_) {
      return textMatchScore;
    }
  }

  // ── Auto Favourite Suggestion ─────────────────────────────────────────────

  /// Returns IDs of items viewed ≥ 5 times that are NOT in the given favorites set.
  List<String> getSuggestedFavorites(
    Set<String> currentFavorites, {
    int minViews = 5,
  }) {
    if (_box == null) return [];
    final suggestions = <String>[];
    for (final key in _box!.keys) {
      if (key.toString().startsWith('watch_count_')) {
        final id = key.toString().substring('watch_count_'.length);
        final count = _box!.get(key, defaultValue: 0) as int;
        if (count >= minViews && !currentFavorites.contains(id)) {
          suggestions.add(id);
        }
      }
    }
    return suggestions;
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  String _todayKey() => _dateKey(DateTime.now());

  String _dateKey(DateTime d) =>
      '${d.year}${d.month.toString().padLeft(2, '0')}${d.day.toString().padLeft(2, '0')}';

  String _shortLabel(DateTime d) {
    const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return days[d.weekday - 1];
  }

  /// Hard reset — clears ALL behavior data.
  Future<void> clearAll() async {
    await _box?.clear();
  }

  // ── Top content by watch time ─────────────────────────────────────────────

  List<Map<String, dynamic>> getTopContentByTime({int topN = 10}) {
    if (_box == null) return [];
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (key.toString().startsWith('content_watch_')) {
        final id = key.toString().substring('content_watch_'.length);
        counts[id] = _box!.get(key, defaultValue: 0) as int;
      }
    }
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return sorted
        .take(topN)
        .map((e) => {'id': e.key, 'seconds': e.value})
        .toList();
  }
}
