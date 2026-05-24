import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../models/xtream_models.dart';

/// Handles local caching of all API content to avoid refetching on every startup.
/// Data is scoped per playlist ID so switching playlists uses correct cache.
class CacheService {
  static const _kContentBox = 'stream1_content_v2';
  static const _kMetaBox    = 'stream1_meta_v2';
  static const _kMaxAge     = Duration(hours: 24);

  // Content keys
  static const _kLiveCats    = 'live_cats';
  static const _kLiveStreams  = 'live_streams';
  static const _kVodCats     = 'vod_cats';
  static const _kVodStreams   = 'vod_streams';
  static const _kSeriesCats  = 'series_cats';
  static const _kSeriesList   = 'series_list';
  static const _kEpgPrefix   = 'epg_';

  // Timestamp keys
  static const _kTsLive    = 'ts_live';
  static const _kTsVod     = 'ts_vod';
  static const _kTsSeries  = 'ts_series';

  static CacheService? _instance;
  static CacheService get instance => _instance ??= CacheService._();
  CacheService._();

  Box? _contentBox;
  Box? _metaBox;
  String _playlistId = 'default';

  Future<void> init() async {
    _contentBox = await Hive.openBox(_kContentBox);
    _metaBox    = await Hive.openBox(_kMetaBox);
  }

  void setActivePlaylist(String playlistId) {
    _playlistId = playlistId.replaceAll(RegExp(r'[^a-zA-Z0-9]'), '_');
  }

  // ── Key helpers ───────────────────────────────────────────────────
  String _k(String base) => '${_playlistId}_$base';

  bool _isStale(String tsKey) {
    final ts = _metaBox?.get(_k(tsKey)) as int?;
    if (ts == null) return true;
    return DateTime.now()
        .difference(DateTime.fromMillisecondsSinceEpoch(ts)) > _kMaxAge;
  }

  Future<void> _setTs(String tsKey) async =>
      _metaBox?.put(_k(tsKey), DateTime.now().millisecondsSinceEpoch);

  DateTime? _getTs(String tsKey) {
    final ts = _metaBox?.get(_k(tsKey)) as int?;
    return ts == null ? null : DateTime.fromMillisecondsSinceEpoch(ts);
  }

  // ── Save methods (encoding runs in isolate for large lists) ───────

  Future<void> saveLiveCategories(List<XtreamCategory> cats) async {
    await _contentBox?.put(_k(_kLiveCats), _encodeCats(cats));
    await _setTs(_kTsLive);
  }

  Future<void> saveLiveStreams(List<LiveStream> streams) async {
    final encoded = await compute(_encodeStreams, streams);
    await _contentBox?.put(_k(_kLiveStreams), encoded);
  }

  Future<void> saveVodCategories(List<XtreamCategory> cats) async {
    await _contentBox?.put(_k(_kVodCats), _encodeCats(cats));
    await _setTs(_kTsVod);
  }

  Future<void> saveVodStreams(List<VodStream> streams) async {
    final encoded = await compute(_encodeVodStreams, streams);
    await _contentBox?.put(_k(_kVodStreams), encoded);
  }

  Future<void> saveSeriesCategories(List<XtreamCategory> cats) async {
    await _contentBox?.put(_k(_kSeriesCats), _encodeCats(cats));
    await _setTs(_kTsSeries);
  }

  Future<void> saveSeriesList(List<Series> list) async {
    final encoded = await compute(_encodeSeriesList, list);
    await _contentBox?.put(_k(_kSeriesList), encoded);
  }

  Future<void> saveEpg(String streamId, List<EpgListing> epg) async {
    if (epg.isEmpty) return;
    final key = _k('$_kEpgPrefix$streamId');
    final data = {
      'ts': DateTime.now().millisecondsSinceEpoch,
      'data': epg.map((e) => {
        'id': e.id,
        'epg_id': e.epgId,
        'title': e.title,
        'description': e.description,
        'start': e.start,
        'end': e.end,
        'start_timestamp': e.startTimestamp,
        'stop_timestamp': e.stopTimestamp,
      }).toList(),
    };
    await _contentBox?.put(key, jsonEncode(data));
  }

  // ── Load methods ──────────────────────────────────────────────────

  List<XtreamCategory>? loadLiveCategories({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsLive)) return null;
    return _decodeCats(_contentBox?.get(_k(_kLiveCats)));
  }

  List<LiveStream>? loadLiveStreams({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsLive)) return null;
    final raw = _contentBox?.get(_k(_kLiveStreams)) as String?;
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => LiveStream.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  List<XtreamCategory>? loadVodCategories({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsVod)) return null;
    return _decodeCats(_contentBox?.get(_k(_kVodCats)));
  }

  List<VodStream>? loadVodStreams({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsVod)) return null;
    final raw = _contentBox?.get(_k(_kVodStreams)) as String?;
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => VodStream.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  List<XtreamCategory>? loadSeriesCategories({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsSeries)) return null;
    return _decodeCats(_contentBox?.get(_k(_kSeriesCats)));
  }

  List<Series>? loadSeriesList({bool ignoreExpiry = false}) {
    if (!ignoreExpiry && _isStale(_kTsSeries)) return null;
    final raw = _contentBox?.get(_k(_kSeriesList)) as String?;
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw) as List;
      return list
          .map((e) => Series.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  List<EpgListing>? loadEpg(String streamId,
      {Duration maxAge = const Duration(minutes: 30)}) {
    final raw = _contentBox?.get(_k('$_kEpgPrefix$streamId')) as String?;
    if (raw == null) return null;
    try {
      final map  = jsonDecode(raw) as Map;
      final ts   = map['ts'] as int;
      final age  = DateTime.now()
          .difference(DateTime.fromMillisecondsSinceEpoch(ts));
      if (age > maxAge) return null;
      final list = map['data'] as List;
      return list.map((e) => EpgListing.fromJson(
          Map<String, dynamic>.from(e))).toList();
    } catch (_) {
      return null;
    }
  }

  // ── Metadata ──────────────────────────────────────────────────────

  DateTime? lastUpdatedLive()   => _getTs(_kTsLive);
  DateTime? lastUpdatedVod()    => _getTs(_kTsVod);
  DateTime? lastUpdatedSeries() => _getTs(_kTsSeries);

  bool isLiveStale()   => _isStale(_kTsLive);
  bool isVodStale()    => _isStale(_kTsVod);
  bool isSeriesStale() => _isStale(_kTsSeries);

  bool hasAnyCache() =>
      _contentBox?.containsKey(_k(_kLiveCats)) == true ||
          _contentBox?.containsKey(_k(_kVodCats)) == true ||
          _contentBox?.containsKey(_k(_kSeriesCats)) == true;

  Future<void> clearAll() async {
    final keys = [
      _kLiveCats, _kLiveStreams, _kVodCats, _kVodStreams,
      _kSeriesCats, _kSeriesList,
    ].map(_k).toList();
    // Also clear EPG
    final epgKeys = _contentBox?.keys
        .where((k) => k.toString().startsWith('${_playlistId}_$_kEpgPrefix'))
        .toList() ?? [];
    await _contentBox?.deleteAll([...keys, ...epgKeys]);
    await _metaBox?.deleteAll(
        [_kTsLive, _kTsVod, _kTsSeries].map(_k).toList());
  }

  // ── Static encoders (used in compute isolates) ────────────────────

  static String _encodeCats(List<XtreamCategory> cats) => jsonEncode(
      cats.map((c) => {
        'category_id': c.categoryId,
        'category_name': c.categoryName,
        'parent_id': c.parentId,
      }).toList());

  static List<XtreamCategory>? _decodeCats(dynamic raw) {
    if (raw == null) return null;
    try {
      final list = jsonDecode(raw as String) as List;
      return list
          .map((e) => XtreamCategory.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    } catch (_) {
      return null;
    }
  }

  // In _encodeStreams static method, replace the map with:
  static String _encodeStreams(List<LiveStream> s) => jsonEncode(s
      .map((c) => {
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
  })
      .toList());

  static String _encodeVodStreams(List<VodStream> s) => jsonEncode(s
      .map((v) => {
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
  })
      .toList());

  static String _encodeSeriesList(List<Series> s) => jsonEncode(s
      .map((v) => {
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
  })
      .toList());
}