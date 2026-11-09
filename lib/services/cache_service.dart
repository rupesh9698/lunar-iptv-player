import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../models/xtream_models.dart';

/// Handles local caching of all API content to avoid refetching on every startup.
/// Data is scoped per playlist ID so switching playlists uses correct cache.
///
/// ── Performance design (large libraries: 60k+ movies, 20k+ series) ─────────
/// • The content box is a Hive **LazyBox**: values stay on disk until asked
///   for. (A regular box loads every cached JSON blob — all libraries plus
///   every channel's EPG — into RAM at app start.)
/// • Big lists are JSON-decoded in a **background isolate** (never on the UI
///   thread) and decoded **once**: the result is kept in memory and shared by
///   every screen/provider until the playlist changes or the list is re-saved.
/// • Repeated short strings (category ids, stream types, extensions…) are
///   interned while decoding, which noticeably cuts heap use for huge lists.
/// • Cheap `has…()` checks answer "is anything cached?" without decoding.
class CacheService {
  static const _kContentBox = 'stream1_content_v2';
  static const _kMetaBox = 'stream1_meta_v2';
  static const _kMaxAge = Duration(hours: 24);

  // Content keys
  static const _kLiveCats = 'live_cats';
  static const _kLiveStreams = 'live_streams';
  static const _kVodCats = 'vod_cats';
  static const _kVodStreams = 'vod_streams';
  static const _kSeriesCats = 'series_cats';
  static const _kSeriesList = 'series_list';
  static const _kEpgPrefix = 'epg_';

  // Timestamp keys
  static const _kTsLive = 'ts_live';
  static const _kTsVod = 'ts_vod';
  static const _kTsSeries = 'ts_series';

  // Item-count keys (lets has…() answer without decoding)
  static const _kCountLive = 'count_live';
  static const _kCountVod = 'count_vod';
  static const _kCountSeries = 'count_series';

  /// EPG entries are a 30-minute cache; if more than this many accumulate on
  /// disk they are purged at start-up so the box never grows unbounded.
  static const _kMaxEpgEntries = 400;

  static CacheService? _instance;
  static CacheService get instance => _instance ??= CacheService._();
  CacheService._();

  LazyBox? _contentBox;
  Box? _metaBox;
  String _playlistId = 'default';

  // ── In-memory decoded copies (one per content type, active playlist) ──
  List<XtreamCategory>? _liveCatsMem, _vodCatsMem, _seriesCatsMem;
  List<LiveStream>? _liveMem;
  List<VodStream>? _vodMem;
  List<Series>? _seriesMem;
  // In-flight decodes, so concurrent callers share one isolate job.
  Future<List<LiveStream>?>? _liveLoading;
  Future<List<VodStream>?>? _vodLoading;
  Future<List<Series>?>? _seriesLoading;

  Future<void> init() async {
    _contentBox = await Hive.openLazyBox(_kContentBox);
    _metaBox = await Hive.openBox(_kMetaBox);
    _purgeOldEpg();
  }

  void setActivePlaylist(String playlistId) {
    final id = playlistId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
    if (id == _playlistId) return;
    _playlistId = id;
    _dropMemory();
  }

  void _dropMemory() {
    _liveCatsMem = _vodCatsMem = _seriesCatsMem = null;
    _liveMem = null;
    _vodMem = null;
    _seriesMem = null;
    _liveLoading = null;
    _vodLoading = null;
    _seriesLoading = null;
  }

  void _purgeOldEpg() {
    final box = _contentBox;
    if (box == null) return;
    final epgKeys = box.keys
        .where((k) => k.toString().contains('_$_kEpgPrefix'))
        .toList();
    if (epgKeys.length > _kMaxEpgEntries) {
      box.deleteAll(epgKeys).then((_) => box.compact()).ignore();
    }
  }

  // ── Key helpers ───────────────────────────────────────────────────
  String _k(String base) => '${_playlistId}_$base';

  bool _isStale(String tsKey) {
    final ts = _metaBox?.get(_k(tsKey)) as int?;
    if (ts == null) return true;
    return DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(ts)) >
        _kMaxAge;
  }

  Future<void> _setTs(String tsKey) async =>
      _metaBox?.put(_k(tsKey), DateTime.now().millisecondsSinceEpoch);

  DateTime? _getTs(String tsKey) {
    final ts = _metaBox?.get(_k(tsKey)) as int?;
    return ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
  }

  Future<String?> _raw(String base) async =>
      await _contentBox?.get(_k(base)) as String?;

  /// Rewrites the box file after replacing a multi-megabyte value; Hive's
  /// default strategy counts deleted *entries*, not bytes, so without this
  /// the file grows by the size of the whole library on every refresh.
  Future<void> _compactSoon() async {
    try {
      await _contentBox?.compact();
    } catch (_) {}
  }

  // ── Save methods (encoding runs in an isolate for large lists) ───────

  Future<void> saveLiveCategories(List<XtreamCategory> cats) async {
    _liveCatsMem = cats;
    await _contentBox?.put(_k(_kLiveCats), _encodeCats(cats));
    await _setTs(_kTsLive);
  }

  Future<void> saveLiveStreams(List<LiveStream> streams) async {
    _liveMem = streams;
    _liveLoading = null;
    final encoded = await compute(_encodeStreams, streams);
    await _contentBox?.put(_k(_kLiveStreams), encoded);
    await _metaBox?.put(_k(_kCountLive), streams.length);
    _compactSoon().ignore();
  }

  Future<void> saveVodCategories(List<XtreamCategory> cats) async {
    _vodCatsMem = cats;
    await _contentBox?.put(_k(_kVodCats), _encodeCats(cats));
    await _setTs(_kTsVod);
  }

  Future<void> saveVodStreams(List<VodStream> streams) async {
    _vodMem = streams;
    _vodLoading = null;
    final encoded = await compute(_encodeVodStreams, streams);
    await _contentBox?.put(_k(_kVodStreams), encoded);
    await _metaBox?.put(_k(_kCountVod), streams.length);
    _compactSoon().ignore();
  }

  Future<void> saveSeriesCategories(List<XtreamCategory> cats) async {
    _seriesCatsMem = cats;
    await _contentBox?.put(_k(_kSeriesCats), _encodeCats(cats));
    await _setTs(_kTsSeries);
  }

  Future<void> saveSeriesList(List<Series> list) async {
    _seriesMem = list;
    _seriesLoading = null;
    final encoded = await compute(_encodeSeriesList, list);
    await _contentBox?.put(_k(_kSeriesList), encoded);
    await _metaBox?.put(_k(_kCountSeries), list.length);
    _compactSoon().ignore();
  }

  Future<void> saveEpg(String streamId, List<EpgListing> epg) async {
    if (epg.isEmpty) return;
    final key = _k('$_kEpgPrefix$streamId');
    final data = {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': epg
          .map(
            (e) => {
              'id': e.id,
              'epg_id': e.epgId,
              'title': e.title,
              'description': e.description,
              'start': e.start,
              'end': e.end,
              'start_timestamp': e.startTimestamp,
              'stop_timestamp': e.stopTimestamp,
            },
          )
          .toList(),
    };
    await _contentBox?.put(key, jsonEncode(data));
  }

  // ── Cheap presence checks (no decoding) ───────────────────────────

  /// true / false when known, null when nothing is cached at all.
  bool? _nonEmpty(List? mem, String countKey, String contentKey) {
    if (mem != null) return mem.isNotEmpty;
    final count = _metaBox?.get(_k(countKey)) as int?;
    if (count != null) return count > 0;
    // Caches written before counts existed: presence of the blob.
    if (_contentBox?.containsKey(_k(contentKey)) ?? false) return true;
    return null;
  }

  bool? liveStreamsNonEmpty() =>
      _nonEmpty(_liveMem, _kCountLive, _kLiveStreams);
  bool? vodStreamsNonEmpty() => _nonEmpty(_vodMem, _kCountVod, _kVodStreams);
  bool? seriesListNonEmpty() =>
      _nonEmpty(_seriesMem, _kCountSeries, _kSeriesList);

  bool hasLiveStreams() => liveStreamsNonEmpty() ?? false;
  bool hasVodStreams() => vodStreamsNonEmpty() ?? false;
  bool hasSeriesList() => seriesListNonEmpty() ?? false;

  // ── Load methods (async; decoded once, then served from memory) ───

  Future<List<XtreamCategory>?> loadLiveCategories({
    bool ignoreExpiry = false,
  }) async {
    if (!ignoreExpiry && _isStale(_kTsLive)) return null;
    return _liveCatsMem ??= _decodeCats(await _raw(_kLiveCats));
  }

  Future<List<XtreamCategory>?> loadVodCategories({
    bool ignoreExpiry = false,
  }) async {
    if (!ignoreExpiry && _isStale(_kTsVod)) return null;
    return _vodCatsMem ??= _decodeCats(await _raw(_kVodCats));
  }

  Future<List<XtreamCategory>?> loadSeriesCategories({
    bool ignoreExpiry = false,
  }) async {
    if (!ignoreExpiry && _isStale(_kTsSeries)) return null;
    return _seriesCatsMem ??= _decodeCats(await _raw(_kSeriesCats));
  }

  Future<List<LiveStream>?> loadLiveStreams({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsLive)) return Future.value(null);
    if (_liveMem != null) return Future.value(_liveMem);
    final pid = _playlistId;
    return _liveLoading ??= () async {
      final raw = await _raw(_kLiveStreams);
      final list = raw == null ? null : await compute(decodeLiveList, raw);
      if (pid == _playlistId) {
        _liveMem = list;
        _liveLoading = null;
      }
      return list;
    }();
  }

  Future<List<VodStream>?> loadVodStreams({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsVod)) return Future.value(null);
    if (_vodMem != null) return Future.value(_vodMem);
    final pid = _playlistId;
    return _vodLoading ??= () async {
      final raw = await _raw(_kVodStreams);
      final list = raw == null ? null : await compute(decodeVodList, raw);
      if (pid == _playlistId) {
        _vodMem = list;
        _vodLoading = null;
      }
      return list;
    }();
  }

  Future<List<Series>?> loadSeriesList({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsSeries)) return Future.value(null);
    if (_seriesMem != null) return Future.value(_seriesMem);
    final pid = _playlistId;
    return _seriesLoading ??= () async {
      final raw = await _raw(_kSeriesList);
      final list = raw == null ? null : await compute(decodeSeriesList, raw);
      if (pid == _playlistId) {
        _seriesMem = list;
        _seriesLoading = null;
      }
      return list;
    }();
  }

  Future<List<EpgListing>?> loadEpg(
    String streamId, {
    Duration maxAge = const Duration(minutes: 30),
  }) async {
    final raw = await _raw('$_kEpgPrefix$streamId');
    if (raw == null) return null;
    try {
      final map = jsonDecode(raw) as Map;
      final ts = map['ts'] as int;
      final age = DateTime.now().difference(
        DateTime.fromMillisecondsSinceEpoch(ts),
      );
      if (age > maxAge) return null;
      final list = map['data'] as List;
      return list
          .map((e) => EpgListing.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  // ── Metadata ──────────────────────────────────────────────────────

  DateTime? lastUpdatedLive() => _getTs(_kTsLive);
  DateTime? lastUpdatedVod() => _getTs(_kTsVod);
  DateTime? lastUpdatedSeries() => _getTs(_kTsSeries);

  bool isLiveStale() => _isStale(_kTsLive);
  bool isVodStale() => _isStale(_kTsVod);
  bool isSeriesStale() => _isStale(_kTsSeries);

  bool hasAnyCache() =>
      _contentBox?.containsKey(_k(_kLiveCats)) == true ||
      _contentBox?.containsKey(_k(_kVodCats)) == true ||
      _contentBox?.containsKey(_k(_kSeriesCats)) == true;

  // ── Content flags (what content types this playlist has) ─────────────────

  Future<void> saveContentFlags({
    required bool hasLive,
    required bool hasVod,
    required bool hasSeries,
  }) async {
    await _metaBox?.put(_k('has_live'), hasLive);
    await _metaBox?.put(_k('has_vod'), hasVod);
    await _metaBox?.put(_k('has_series'), hasSeries);
  }

  /// Returns content availability flags.
  /// Defaults to true (show all) for playlists without saved flags (backward compat).
  ({bool hasLive, bool hasVod, bool hasSeries}) getContentFlags() {
    final hasLive = _metaBox?.get(_k('has_live')) as bool? ?? true;
    final hasVod = _metaBox?.get(_k('has_vod')) as bool? ?? true;
    final hasSeries = _metaBox?.get(_k('has_series')) as bool? ?? true;
    return (hasLive: hasLive, hasVod: hasVod, hasSeries: hasSeries);
  }

  Future<void> clearAll() async {
    _dropMemory();
    final keys = [
      _kLiveCats,
      _kLiveStreams,
      _kVodCats,
      _kVodStreams,
      _kSeriesCats,
      _kSeriesList,
    ].map(_k).toList();
    // Also clear EPG
    final epgKeys =
        _contentBox?.keys
            .where(
              (k) => k.toString().startsWith('${_playlistId}_$_kEpgPrefix'),
            )
            .toList() ??
        [];
    await _contentBox?.deleteAll([...keys, ...epgKeys]);
    await _metaBox?.deleteAll(
      [
        _kTsLive,
        _kTsVod,
        _kTsSeries,
        _kCountLive,
        _kCountVod,
        _kCountSeries,
      ].map(_k).toList(),
    );
    await _compactSoon();
  }

  // ── Static encoders (used in compute isolates) ────────────────────

  static String _encodeCats(List<XtreamCategory> cats) => jsonEncode(
    cats
        .map(
          (c) => {
            'category_id': c.categoryId,
            'category_name': c.categoryName,
            'parent_id': c.parentId,
          },
        )
        .toList(),
  );

  static List<XtreamCategory>? _decodeCats(dynamic raw) {
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw as String) as List;
      return list
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return null;
    }
  }

  static String _encodeStreams(List<LiveStream> s) => jsonEncode(
    s
        .map(
          (c) => {
            'num': c.num,
            'name': c.name,
            'stream_type': c.streamType,
            'stream_id': c.streamId,
            'stream_icon': c.streamIcon ?? '',
            'epg_channel_id': c.epgChannelId ?? '',
            'added': c.added ?? '',
            'category_id': c.categoryId ?? '',
            'custom_sid': c.customSid ?? '',
            'tv_archive': c.tvArchive ?? 0,
            'direct_source': c.directSource ?? '',
          },
        )
        .toList(),
  );

  static String _encodeVodStreams(List<VodStream> s) => jsonEncode(
    s
        .map(
          (v) => {
            'num': v.num,
            'name': v.name,
            'stream_type': v.streamType,
            'stream_id': v.streamId,
            'stream_icon': v.streamIcon ?? '',
            'rating': v.rating ?? '',
            'rating_5based': v.rating5based ?? '0',
            'added': v.added ?? '',
            'category_id': v.categoryId ?? '',
            'container_extension': v.containerExtension ?? 'mp4',
          },
        )
        .toList(),
  );

  static String _encodeSeriesList(List<Series> s) => jsonEncode(
    s
        .map(
          (v) => {
            'series_id': v.seriesId,
            'name': v.name,
            'cover': v.cover ?? '',
            'plot': v.plot ?? '',
            'cast': v.cast ?? '',
            'director': v.director ?? '',
            'genre': v.genre ?? '',
            'releaseDate': v.releaseDate ?? '',
            'rating': v.rating ?? '',
            'rating_5based': v.rating5based ?? '0',
            'backdrop_path': v.backdropPath ?? '',
            'category_id': v.categoryId ?? '',
          },
        )
        .toList(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// ISOLATE DECODERS (top-level so compute() can send them)
// Strings that repeat across tens of thousands of items are interned so the
// whole list shares one instance each.
// ─────────────────────────────────────────────────────────────────────────────
class _Interner {
  final Map<String, String> _pool = {};
  String? call(dynamic v) {
    if (v == null) return null;
    final s = v is String ? v : v.toString();
    if (s.length > 24) return s; // only short, repetitive values
    return _pool.putIfAbsent(s, () => s);
  }
}

@visibleForTesting
List<LiveStream> decodeLiveList(String raw) {
  final i = _Interner();
  final list = jsonDecode(raw) as List;
  return List<LiveStream>.generate(list.length, (n) {
    final j = list[n] as Map<String, dynamic>;
    return LiveStream(
      num: j['num']?.toString() ?? '0',
      name: j['name']?.toString() ?? 'Unknown Channel',
      streamType: i(j['stream_type']) ?? 'live',
      streamId: j['stream_id']?.toString() ?? '',
      streamIcon: j['stream_icon']?.toString(),
      epgChannelId: j['epg_channel_id']?.toString(),
      added: i(j['added']),
      categoryId: i(j['category_id']),
      tvArchive: i(j['tv_archive']),
      directSource: i(j['direct_source']),
      customSid: i(j['custom_sid']),
    );
  }, growable: false);
}

@visibleForTesting
List<VodStream> decodeVodList(String raw) {
  final i = _Interner();
  final list = jsonDecode(raw) as List;
  return List<VodStream>.generate(list.length, (n) {
    final j = list[n] as Map<String, dynamic>;
    return VodStream(
      num: j['num']?.toString() ?? '0',
      name: j['name']?.toString() ?? 'Unknown Movie',
      streamType: i(j['stream_type']) ?? 'movie',
      streamId: j['stream_id']?.toString() ?? '',
      streamIcon: j['stream_icon']?.toString(),
      rating: i(j['rating']),
      rating5based: i(j['rating_5based']),
      added: j['added']?.toString(),
      categoryId: i(j['category_id']),
      containerExtension: i(j['container_extension']) ?? 'mp4',
      customSid: i(j['custom_sid']),
      directSource: i(j['direct_source']),
    );
  }, growable: false);
}

@visibleForTesting
List<Series> decodeSeriesList(String raw) {
  final i = _Interner();
  final list = jsonDecode(raw) as List;
  return List<Series>.generate(list.length, (n) {
    final j = list[n] as Map<String, dynamic>;
    String? s(String k) {
      final v = j[k]?.toString();
      return (v == null || v.isEmpty) ? null : v;
    }

    return Series(
      seriesId: j['series_id']?.toString() ?? '',
      name: j['name']?.toString() ?? 'Unknown Series',
      cover: s('cover'),
      plot: s('plot'),
      cast: s('cast'),
      director: s('director'),
      genre: i(s('genre')),
      releaseDate: i(s('releaseDate') ?? s('release_date')),
      rating: i(j['rating']),
      rating5based: i(j['rating_5based']),
      categoryId: i(j['category_id']),
      backdropPath: s('backdrop_path'),
    );
  }, growable: false);
}
