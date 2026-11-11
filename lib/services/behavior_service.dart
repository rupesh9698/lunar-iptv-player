import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
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
  final Map<String, String> _activeTypes = {};
  Timer? _flushTimer;

  /// Bumped on every write (watch time, positions, views...). The stats
  /// screen listens to this so it updates live, no restart needed.
  final ValueNotifier<int> changes = ValueNotifier(0);

  /// Bumped only when the user's *taste* changes (a viewing session ended,
  /// something was opened, history cleared). Recommendations follow this
  /// one, so they aren't recomputed every few seconds during playback.
  final ValueNotifier<int> tasteChanges = ValueNotifier(0);

  void _changed({bool taste = false}) {
    changes.value++;
    if (taste) tasteChanges.value++;
  }

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
    _changed(taste: true);
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
    if (url.isEmpty) {
      return; // Never save without a URL — would cause black screen
    }

    final progress = positionSeconds / durationSeconds;

    // Remove if near end (>92%)
    if (progress > 0.92) {
      await _box!.delete(_k('watch_pos_$id'));
      await _prunePositions();
      return;
    }

    // Skip if too early (<3%) to avoid accidental saves
    if (progress < 0.03) return;

    final data = {
      'id': id,
      'url': url,
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
    await _box!.put(_k('content_name_$id'), title);
    _changed();
    await _prunePositions();
  }

  /// Saved resume point for [id] (position, duration, progress, url, …),
  /// or null when there is none.
  Map<String, dynamic>? getPosition(String id) {
    if (_box == null) return null;
    final raw = _box!.get(_k('watch_pos_$id'));
    if (raw == null) return null;
    try {
      return jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (_) {
      return null;
    }
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
    _changed(taste: true);
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
    _changed();
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
    _changed(taste: true);
  }

  /// Genres with how often each was opened, most first.
  List<MapEntry<String, int>> getGenreCounts({int topN = 6}) {
    if (_box == null) return [];
    final prefix = _k('genre_freq_');
    final counts = <String, int>{};
    for (final key in _box!.keys) {
      if (!key.toString().startsWith(prefix)) continue;
      counts[key.toString().substring(prefix.length)] =
          _box!.get(key, defaultValue: 0) as int;
    }
    return (counts.entries.toList()..sort((a, b) => b.value.compareTo(a.value)))
        .take(topN)
        .toList();
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

  /// [type]: 'live', 'movie' or 'series' (for the "what you watch" split).
  void startWatchTimer(String id, {String name = '', String? type}) {
    // A timer already running for this id keeps its time.
    if (_activeTimers.containsKey(id)) _commit(id, flushOnly: true);
    _activeTimers[id] = DateTime.now();
    if (type != null) _activeTypes[id] = type;
    if (_box != null) {
      if (name.isNotEmpty) _box!.put(_k('content_name_$id'), name);
      if (type != null) _box!.put(_k('content_type_$id'), type);
    }
    // Save running time every minute: the stats stay current while
    // something plays, and a crash / force-close loses at most a minute.
    _flushTimer ??= Timer.periodic(const Duration(minutes: 1), (_) {
      if (_activeTimers.isEmpty) {
        _flushTimer?.cancel();
        _flushTimer = null;
        return;
      }
      for (final id in _activeTimers.keys.toList()) {
        _commit(id, flushOnly: true);
      }
      _changed();
    });
  }

  Future<void> stopWatchTimer(String id) async {
    if (_box == null || !_activeTimers.containsKey(id)) return;
    _commit(id);
    _activeTimers.remove(id);
    _activeTypes.remove(id);
    _changed(taste: true);
  }

  /// Adds the time since the timer (re)started to the totals.
  void _commit(String id, {bool flushOnly = false}) {
    final start = _activeTimers[id];
    if (_box == null || start == null) return;
    final now = DateTime.now();
    final seconds = now.difference(start).inSeconds;
    if (flushOnly) _activeTimers[id] = now;
    if (seconds < 5) return;
    void add(String key) =>
        _box!.put(key, (_box!.get(key, defaultValue: 0) as int) + seconds);
    add(_k('total_watch_${_todayKey()}'));
    add(_k('content_watch_$id'));
    add(_k('hour_watch_${now.hour}'));
    final type =
        _activeTypes[id] ?? _box!.get(_k('content_type_$id')) as String?;
    if (type != null) add(_k('type_watch_$type'));
  }

  /// Seconds of the sessions still running (not saved yet).
  int getActiveSeconds() {
    final now = DateTime.now();
    return _activeTimers.values.fold(
      0,
      (sum, start) => sum + now.difference(start).inSeconds,
    );
  }

  bool get isWatching => _activeTimers.isNotEmpty;

  /// Watch seconds per type ('live', 'movie', 'series').
  Map<String, int> getWatchByType() {
    if (_box == null) return {};
    final prefix = _k('type_watch_');
    final out = <String, int>{};
    for (final key in _box!.keys) {
      final k = key.toString();
      if (k.startsWith(prefix)) {
        out[k.substring(prefix.length)] = _box!.get(key) as int? ?? 0;
      }
    }
    return out;
  }

  /// Watch seconds per hour of the day (index 0 to 23).
  List<int> getWatchByHour() {
    if (_box == null) return List.filled(24, 0);
    return [
      for (var h = 0; h < 24; h++)
        _box!.get(_k('hour_watch_$h'), defaultValue: 0) as int,
    ];
  }

  /// Days in a row (ending today, or yesterday if nothing yet today) with
  /// some watch time.
  int getStreakDays() {
    if (_box == null) return 0;
    int secsOn(DateTime d) =>
        _box!.get(_k('total_watch_${_dateKey(d)}'), defaultValue: 0) as int;
    var day = DateTime.now();
    var streak = 0;
    if (secsOn(day) > 0 || isWatching) {
      streak = 1;
    }
    day = day.subtract(const Duration(days: 1));
    while (secsOn(day) > 0 && streak < 3650) {
      streak++;
      day = day.subtract(const Duration(days: 1));
    }
    return streak;
  }

  /// Type recorded for a content id ('live' / 'movie' / 'series'), if any.
  String? getContentType(String id) =>
      _box?.get(_k('content_type_$id')) as String?;

  List<Map<String, dynamic>> getWatchTimeByDay({int days = 7}) {
    if (_box == null) return [];
    final now = DateTime.now();
    final result = <Map<String, dynamic>>[];
    for (int i = days - 1; i >= 0; i--) {
      final date = now.subtract(Duration(days: i));
      final dateKey = _dateKey(date);
      final seconds =
          (_box!.get(_k('total_watch_$dateKey'), defaultValue: 0) as int) +
          (i == 0 ? getActiveSeconds() : 0);
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
            'type': _box!.get(_k('content_type_${e.key}')) as String?,
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
    _changed(taste: true);
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
    _changed(taste: true);
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
      _k('type_watch_'),
      _k('hour_watch_'),
      _k('content_type_'),
    ];
    final toDelete = _box!.keys.where((k) {
      final s = k.toString();
      return prefixes.any((p) => s.startsWith(p));
    }).toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
    _changed(taste: true);
  }

  /// Clears all data across ALL playlists.
  Future<void> clearAll() async {
    await _box?.clear();
    _changed(taste: true);
  }

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
    _changed(taste: true);
  }

  /// Clears watch-time data for current playlist (for stats reset).
  Future<void> clearWatchTime() async {
    if (_box == null) return;
    final prefixes = [
      _k('total_watch_'),
      _k('content_watch_'),
      _k('content_name_'),
      _k('type_watch_'),
      _k('hour_watch_'),
      _k('content_type_'),
    ];
    final toDelete = _box!.keys.where((k) {
      final s = k.toString();
      return prefixes.any((p) => s.startsWith(p));
    }).toList();
    for (final key in toDelete) {
      await _box!.delete(key);
    }
    _changed(taste: true);
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
