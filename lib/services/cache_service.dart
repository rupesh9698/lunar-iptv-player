import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:path_provider/path_provider.dart';

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
/// • On native platforms the three big libraries live in plain files in a
///   compact one-row-per-item format (see [_LibCodec]) that a background
///   isolate reads AND parses — nothing touches the UI thread, and no JSON
///   maps are built (~3-4× faster than JSON on TV boxes). Older Hive/JSON
///   caches are migrated automatically on first load. Web keeps Hive/JSON.
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

  /// Folder for the big library files (null on web).
  Directory? _libDir;

  Future<void> init() async {
    _contentBox = await Hive.openLazyBox(_kContentBox);
    _metaBox = await Hive.openBox(_kMetaBox);
    _purgeOldEpg();
    if (!kIsWeb) {
      try {
        final base = await getApplicationSupportDirectory();
        final dir = Directory('${base.path}${Platform.pathSeparator}lib_cache');
        await dir.create(recursive: true);
        _libDir = dir;
      } catch (e) {
        debugPrint('Library file cache unavailable: $e');
      }
    }
  }

  /// Test hook: use a specific folder for the library files.
  @visibleForTesting
  set libraryDirectory(Directory? dir) => _libDir = dir;

  String? _libPath(String kind) => _libDir == null
      ? null
      : '${_libDir!.path}${Platform.pathSeparator}${_playlistId}_$kind.lib';

  bool _libExists(String kind) {
    final path = _libPath(kind);
    return path != null && File(path).existsSync();
  }

  /// Shared loader: memory → library file (isolate read+parse) → legacy
  /// Hive JSON (isolate decode, then migrated to a file in the background).
  Future<List<T>?> _loadLib<T>({
    required String kind,
    required String hiveKey,
    required List<T> Function(String path) readFile,
    required List<T> Function(String json) decodeJson,
    required Future<void> Function(String path, List<T> list) writeFile,
  }) async {
    final sw = Stopwatch()..start();
    final path = _libPath(kind);
    if (path != null && File(path).existsSync()) {
      try {
        final list = await compute(readFile, path);
        debugPrint(
          '[cache] $kind: ${list.length} items in '
          '${sw.elapsedMilliseconds} ms (file)',
        );
        return list;
      } catch (e) {
        debugPrint('[cache] $kind file unreadable, falling back: $e');
      }
    }
    final raw = await _raw(hiveKey);
    if (raw == null) return null;
    final list = await compute(decodeJson, raw);
    debugPrint(
      '[cache] $kind: ${list.length} items in '
      '${sw.elapsedMilliseconds} ms (legacy json)',
    );
    if (path != null) {
      // Migrate: write the fast file, then drop the big JSON from Hive.
      () async {
        try {
          await writeFile(path, list);
          await _contentBox?.delete(_k(hiveKey));
          await _compactSoon();
        } catch (e) {
          debugPrint('[cache] $kind migration failed: $e');
        }
      }();
    }
    return list;
  }

  /// Shared saver: library file on native, Hive JSON on web.
  Future<void> _saveLib<T>({
    required String kind,
    required String hiveKey,
    required String countKey,
    required List<T> list,
    required Future<void> Function(String path, List<T> list) writeFile,
    required String Function(List<T>) encodeJson,
  }) async {
    final path = _libPath(kind);
    if (path != null) {
      await writeFile(path, list);
      if (_contentBox?.containsKey(_k(hiveKey)) ?? false) {
        await _contentBox?.delete(_k(hiveKey));
        _compactSoon().ignore();
      }
    } else {
      final encoded = await compute(encodeJson, list);
      await _contentBox?.put(_k(hiveKey), encoded);
      _compactSoon().ignore();
    }
    await _metaBox?.put(_k(countKey), list.length);
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
    await _saveLib(
      kind: 'live',
      hiveKey: _kLiveStreams,
      countKey: _kCountLive,
      list: streams,
      writeFile: (p, l) => compute(writeLiveFile, (p, l)),
      encodeJson: _encodeStreams,
    );
  }

  Future<void> saveVodCategories(List<XtreamCategory> cats) async {
    _vodCatsMem = cats;
    await _contentBox?.put(_k(_kVodCats), _encodeCats(cats));
    await _setTs(_kTsVod);
  }

  Future<void> saveVodStreams(List<VodStream> streams) async {
    _vodMem = streams;
    _vodLoading = null;
    await _saveLib(
      kind: 'vod',
      hiveKey: _kVodStreams,
      countKey: _kCountVod,
      list: streams,
      writeFile: (p, l) => compute(writeVodFile, (p, l)),
      encodeJson: _encodeVodStreams,
    );
  }

  Future<void> saveSeriesCategories(List<XtreamCategory> cats) async {
    _seriesCatsMem = cats;
    await _contentBox?.put(_k(_kSeriesCats), _encodeCats(cats));
    await _setTs(_kTsSeries);
  }

  Future<void> saveSeriesList(List<Series> list) async {
    _seriesMem = list;
    _seriesLoading = null;
    await _saveLib(
      kind: 'series',
      hiveKey: _kSeriesList,
      countKey: _kCountSeries,
      list: list,
      writeFile: (p, l) => compute(writeSeriesFile, (p, l)),
      encodeJson: _encodeSeriesList,
    );
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
  bool? _nonEmpty(List? mem, String countKey, String contentKey, String kind) {
    if (mem != null) return mem.isNotEmpty;
    final count = _metaBox?.get(_k(countKey)) as int?;
    if (count != null) return count > 0;
    // Caches written before counts existed: presence of the data.
    if (_contentBox?.containsKey(_k(contentKey)) ?? false) return true;
    if (_libExists(kind)) return true;
    return null;
  }

  bool? liveStreamsNonEmpty() =>
      _nonEmpty(_liveMem, _kCountLive, _kLiveStreams, 'live');
  bool? vodStreamsNonEmpty() =>
      _nonEmpty(_vodMem, _kCountVod, _kVodStreams, 'vod');
  bool? seriesListNonEmpty() =>
      _nonEmpty(_seriesMem, _kCountSeries, _kSeriesList, 'series');

  /// Loads the big libraries in the background (one after another, in an
  /// isolate) so opening Movies / Series is instant. Safe to call often.
  Future<void> prewarm({bool vod = true, bool series = true}) async {
    try {
      if (vod && hasVodStreams()) await loadVodStreams(ignoreExpiry: true);
      if (series && hasSeriesList()) {
        await loadSeriesList(ignoreExpiry: true);
      }
    } catch (e) {
      debugPrint('[cache] prewarm failed: $e');
    }
  }

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
      final list = await _loadLib<LiveStream>(
        kind: 'live',
        hiveKey: _kLiveStreams,
        readFile: readLiveFile,
        decodeJson: decodeLiveList,
        writeFile: (p, l) => compute(writeLiveFile, (p, l)),
      );
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
      final list = await _loadLib<VodStream>(
        kind: 'vod',
        hiveKey: _kVodStreams,
        readFile: readVodFile,
        decodeJson: decodeVodList,
        writeFile: (p, l) => compute(writeVodFile, (p, l)),
      );
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
      final list = await _loadLib<Series>(
        kind: 'series',
        hiveKey: _kSeriesList,
        readFile: readSeriesFile,
        decodeJson: decodeSeriesList,
        writeFile: (p, l) => compute(writeSeriesFile, (p, l)),
      );
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
    for (final kind in const ['live', 'vod', 'series']) {
      final path = _libPath(kind);
      if (path == null) continue;
      try {
        final f = File(path);
        if (f.existsSync()) await f.delete();
      } catch (_) {}
    }
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

// ─────────────────────────────────────────────────────────────────────────────
// LIBRARY FILE CODEC
// One item per line, fields separated by U+001F (unit separator). Parsing is
// a single pass of indexOf/substring over the file — no JSON maps — and the
// whole read + parse runs in a background isolate.
// ─────────────────────────────────────────────────────────────────────────────
class _LibCodec {
  static const String magic = 'LUNARLIB1';
  static const String sep = '\u001f';
  static final RegExp _bad = RegExp('[\n\r\u001f]');

  static String clean(String? v) =>
      v == null ? '' : (v.contains(_bad) ? v.replaceAll(_bad, ' ') : v);

  static void write(String path, int fields, Iterable<List<String?>> rows) {
    final sb = StringBuffer(magic)..write('\n');
    for (final r in rows) {
      for (var f = 0; f < fields; f++) {
        if (f > 0) sb.write(sep);
        sb.write(clean(r[f]));
      }
      sb.write('\n');
    }
    final tmp = File('$path.tmp');
    tmp.writeAsStringSync(sb.toString(), flush: true);
    tmp.renameSync(path); // atomic replace — never a half-written cache
  }

  static List<T> read<T>(
    String path,
    int fields,
    T Function(List<String> f, _Interner i) build,
  ) {
    final raw = File(path).readAsStringSync();
    if (!raw.startsWith(magic)) {
      throw const FormatException('Not a library cache file');
    }
    final out = <T>[];
    final interner = _Interner();
    final f = List<String>.filled(fields, '');
    var pos = raw.indexOf('\n') + 1;
    final len = raw.length;
    while (pos < len) {
      var end = raw.indexOf('\n', pos);
      if (end < 0) end = len;
      if (end > pos) {
        var start = pos;
        for (var i = 0; i < fields; i++) {
          if (start > end) {
            f[i] = '';
            continue;
          }
          var stop = i == fields - 1 ? end : raw.indexOf(sep, start);
          if (stop < 0 || stop > end) stop = end;
          f[i] = raw.substring(start, stop);
          start = stop + 1;
        }
        out.add(build(f, interner));
      }
      pos = end + 1;
    }
    return out;
  }
}

String? _nz(String v) => v.isEmpty ? null : v;

@visibleForTesting
Future<void> writeVodFile((String, List<VodStream>) a) async => _LibCodec.write(
  a.$1,
  10,
  a.$2.map(
    (v) => [
      v.num,
      v.name,
      v.streamType,
      v.streamId,
      v.streamIcon,
      v.rating,
      v.rating5based,
      v.added,
      v.categoryId,
      v.containerExtension,
    ],
  ),
);

@visibleForTesting
List<VodStream> readVodFile(String path) => _LibCodec.read(
  path,
  10,
  (f, i) => VodStream(
    num: f[0],
    name: f[1],
    streamType: i(f[2].isEmpty ? 'movie' : f[2])!,
    streamId: f[3],
    streamIcon: f[4],
    rating: i(f[5]),
    rating5based: i(f[6]),
    added: f[7],
    categoryId: i(f[8]),
    containerExtension: i(f[9].isEmpty ? 'mp4' : f[9]),
  ),
);

@visibleForTesting
Future<void> writeSeriesFile((String, List<Series>) a) async => _LibCodec.write(
  a.$1,
  12,
  a.$2.map(
    (v) => [
      v.seriesId,
      v.name,
      v.cover,
      v.plot,
      v.cast,
      v.director,
      v.genre,
      v.releaseDate,
      v.rating,
      v.rating5based,
      v.backdropPath,
      v.categoryId,
    ],
  ),
);

@visibleForTesting
List<Series> readSeriesFile(String path) => _LibCodec.read(
  path,
  12,
  (f, i) => Series(
    seriesId: f[0],
    name: f[1],
    cover: _nz(f[2]),
    plot: _nz(f[3]),
    cast: _nz(f[4]),
    director: _nz(f[5]),
    genre: i(_nz(f[6])),
    releaseDate: i(_nz(f[7])),
    rating: i(f[8]),
    rating5based: i(f[9]),
    backdropPath: _nz(f[10]),
    categoryId: i(f[11]),
  ),
);

@visibleForTesting
Future<void> writeLiveFile((String, List<LiveStream>) a) async =>
    _LibCodec.write(
      a.$1,
      11,
      a.$2.map(
        (c) => [
          c.num,
          c.name,
          c.streamType,
          c.streamId,
          c.streamIcon,
          c.epgChannelId,
          c.added,
          c.categoryId,
          c.tvArchive,
          c.directSource,
          c.customSid,
        ],
      ),
    );

@visibleForTesting
List<LiveStream> readLiveFile(String path) => _LibCodec.read(
  path,
  11,
  (f, i) => LiveStream(
    num: f[0],
    name: f[1],
    streamType: i(f[2].isEmpty ? 'live' : f[2])!,
    streamId: f[3],
    streamIcon: f[4],
    epgChannelId: f[5],
    added: i(f[6]),
    categoryId: i(f[7]),
    tvArchive: i(f[8]),
    directSource: i(f[9]),
    customSid: i(f[10]),
  ),
);
