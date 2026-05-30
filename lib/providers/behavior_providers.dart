import 'package:flutter_riverpod/flutter_riverpod.dart';

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
