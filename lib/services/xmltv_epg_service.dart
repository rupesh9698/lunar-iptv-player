import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/xtream_models.dart';
import 'storage_service.dart';

// ============================================================================
// External XMLTV programme guide
//
// Many Xtream providers ship a poor EPG (generic "Movie — Bringing the best
// in cinema." blocks, stale titles). This service downloads free XMLTV
// guides (epgshare01 by default), matches their channels to the playlist's
// channels and keeps a small, per-playlist index on disk:
//
//  * Download + gunzip + parse is streamed inside a background isolate — a
//    60-130 MB guide never lives in memory as one string, which matters on
//    1-2 GB TV boxes.
//  * Only programmes of channels that match the playlist and fall inside a
//    -3 h … +48 h window are kept (a few MB at most).
//  * Refreshed every 12 h in the background; the Xtream EPG is still used for
//    channels the guide doesn't cover, or where it only has filler.
// ============================================================================

class XmltvSource {
  final String id;
  final String label;
  final String url;
  const XmltvSource(this.id, this.label, this.url);
}

/// Result of matching + parsing: listings per guide channel, and which
/// guide channel each playlist stream uses.
class XmltvIndex {
  final Map<String, List<EpgListing>> channels;
  final Map<String, String> streamToChannel;
  final DateTime updated;
  const XmltvIndex(this.channels, this.streamToChannel, this.updated);

  List<EpgListing>? listingsFor(String streamId) {
    final ch = streamToChannel[streamId];
    return ch == null ? null : channels[ch];
  }

  int get matchedStreams => streamToChannel.length;
}

/// What the matcher needs to know about a playlist channel.
class XmltvChannelRef {
  final String streamId;
  final String name;
  final String? epgId;
  const XmltvChannelRef(this.streamId, this.name, this.epgId);
}

class XmltvEpgService {
  XmltvEpgService._();
  static final XmltvEpgService instance = XmltvEpgService._();

  static const _base = 'https://epgshare01.online/epgshare01/epg_ripper_';

  /// Free, daily-updated guides (epgshare01.online), one file per region.
  static const List<XmltvSource> presets = [
    XmltvSource('IN1', 'India', '${_base}IN1.xml.gz'),
    XmltvSource('IN4', 'India (DishTV)', '${_base}IN4.xml.gz'),
    XmltvSource('UK1', 'United Kingdom', '${_base}UK1.xml.gz'),
    XmltvSource('US2', 'United States', '${_base}US2.xml.gz'),
    XmltvSource('CA2', 'Canada', '${_base}CA2.xml.gz'),
    XmltvSource('AU1', 'Australia', '${_base}AU1.xml.gz'),
    XmltvSource('AE1', 'UAE / Arabic', '${_base}AE1.xml.gz'),
    XmltvSource('PK1', 'Pakistan', '${_base}PK1.xml.gz'),
    XmltvSource('DE1', 'Germany', '${_base}DE1.xml.gz'),
    XmltvSource('FR1', 'France', '${_base}FR1.xml.gz'),
    XmltvSource('ES1', 'Spain', '${_base}ES1.xml.gz'),
    XmltvSource('IT1', 'Italy', '${_base}IT1.xml.gz'),
    XmltvSource('NL1', 'Netherlands', '${_base}NL1.xml.gz'),
    XmltvSource('PT1', 'Portugal', '${_base}PT1.xml.gz'),
    XmltvSource('PL1', 'Poland', '${_base}PL1.xml.gz'),
    XmltvSource('TR1', 'Turkey', '${_base}TR1.xml.gz'),
    XmltvSource('BR1', 'Brazil', '${_base}BR1.xml.gz'),
    XmltvSource('MX1', 'Mexico', '${_base}MX1.xml.gz'),
    XmltvSource('US_SPORTS1', 'Sports (US)', '${_base}US_SPORTS1.xml.gz'),
    XmltvSource('BEIN1', 'beIN Sports', '${_base}BEIN1.xml.gz'),
  ];

  /// IN1 (JioTV data) and IN4 (DishTV data) complement each other: each
  /// has real titles for channels where the other only has "Movie" blocks.
  static const List<String> defaultSources = [
    '${_base}IN1.xml.gz',
    '${_base}IN4.xml.gz',
  ];

  static const refreshEvery = Duration(hours: 12);
  static const _kEnabled = 'xmltv_epg_enabled';
  static const _kSources = 'xmltv_epg_sources';

  // ── Settings ─────────────────────────────────────────────────────────────
  bool get supported => !kIsWeb;

  /// Test hooks: guide folder and sources without Hive / path_provider.
  @visibleForTesting
  Directory? testDirectory;
  @visibleForTesting
  List<String>? testSources;

  bool get enabled =>
      supported &&
      (testSources != null ||
          StorageService.instance.getSetting(_kEnabled, true) == true);

  Future<void> setEnabled(bool v) async {
    await StorageService.instance.setSetting(_kEnabled, v);
    _invalidate();
  }

  List<String> get sources {
    if (testSources != null) return testSources!;
    final raw = StorageService.instance.getSetting(_kSources);
    if (raw is List) {
      return raw.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
    }
    return List.of(defaultSources);
  }

  Future<void> setSources(List<String> urls) async {
    await StorageService.instance.setSetting(_kSources, urls.toSet().toList());
    _invalidate();
  }

  // ── State ────────────────────────────────────────────────────────────────
  XmltvIndex? _index;
  String? _indexSig;
  Future<XmltvIndex?>? _loading;
  Future<void>? _refreshing;
  DateTime? _lastAttempt;
  String? lastError;

  final _updates = StreamController<XmltvIndex?>.broadcast();

  /// Fires when a (re)built guide becomes available.
  Stream<XmltvIndex?> get updates => _updates.stream;

  XmltvIndex? get current => _index;
  bool get isRefreshing => _refreshing != null;

  @visibleForTesting
  void resetMemory() => _invalidate();

  void _invalidate() {
    _index = null;
    _indexSig = null;
    _loading = null;
    _updates.add(null);
  }

  String _sig(String playlistId) => '$playlistId|${sources.join(',')}';

  Future<File?> _file(String playlistId) async {
    if (!supported) return null;
    final dir =
        testDirectory ??
        Directory(
          '${(await getApplicationSupportDirectory()).path}'
          '${Platform.pathSeparator}lib_cache',
        );
    await dir.create(recursive: true);
    return File('${dir.path}${Platform.pathSeparator}${playlistId}_xmltv.json');
  }

  /// The guide for [playlistId]: from memory, else from disk. Returns null
  /// while nothing is available yet — a download is then started in the
  /// background and [updates] fires when it is done.
  Future<XmltvIndex?> index({
    required String playlistId,
    required Future<List<XmltvChannelRef>> Function() channels,
  }) {
    if (!enabled || sources.isEmpty) return Future.value(null);
    final sig = _sig(playlistId);
    if (_indexSig == sig && _index != null) {
      _refreshIfStale(playlistId, channels);
      return Future.value(_index);
    }
    if (_indexSig == sig && _loading != null) {
      // Nothing usable yet and the last download failed a while ago → retry.
      final last = _lastAttempt;
      if (_index == null &&
          _refreshing == null &&
          last != null &&
          DateTime.now().difference(last) > const Duration(minutes: 20)) {
        refresh(playlistId: playlistId, channels: channels);
      }
      return _loading!;
    }
    _indexSig = sig;
    _index = null;
    return _loading = () async {
      try {
        final f = await _file(playlistId);
        if (f != null && f.existsSync()) {
          final idx = await _readInIsolate(f.path, sig);
          if (_indexSig != sig) return null;
          if (idx != null) {
            _index = idx;
            _refreshIfStale(playlistId, channels);
            return idx;
          }
        }
      } catch (e) {
        debugPrint('[xmltv] read failed: $e');
      }
      refresh(playlistId: playlistId, channels: channels);
      return null;
    }();
  }

  void _refreshIfStale(
    String playlistId,
    Future<List<XmltvChannelRef>> Function() channels,
  ) {
    final idx = _index;
    if (idx == null || DateTime.now().difference(idx.updated) > refreshEvery) {
      refresh(playlistId: playlistId, channels: channels);
    }
  }

  /// Downloads and re-matches every source now (one at a time).
  Future<void> refresh({
    required String playlistId,
    required Future<List<XmltvChannelRef>> Function() channels,
  }) {
    if (!enabled) return Future.value();
    return _refreshing ??= () async {
      final sig = _sig(playlistId);
      final urls = sources;
      final sw = Stopwatch()..start();
      _lastAttempt = DateTime.now();
      _updates.add(_index); // "updating…" for listeners such as Settings
      try {
        final refs = await channels();
        if (refs.isEmpty) return;
        final f = await _file(playlistId);
        final path = f?.path;
        final names = [for (final r in refs) r.name];
        final ids = [for (final r in refs) r.streamId];
        final epgIds = [for (final r in refs) r.epgId ?? ''];
        final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
        final res = await _buildInIsolate(
          urls,
          ids,
          names,
          epgIds,
          nowS,
          path,
          sig,
        );
        lastError = res.errors.isEmpty ? null : res.errors.join('\n');
        if (_indexSig == sig || _indexSig == null) {
          _indexSig = sig;
          _index = res.index;
          _loading = null;
          _updates.add(res.index);
        }
        debugPrint(
          '[xmltv] ${res.index.matchedStreams}/${refs.length} channels '
          'matched in ${sw.elapsedMilliseconds} ms'
          '${res.errors.isEmpty ? '' : '. Errors: ${res.errors.join('; ')}'}',
        );
      } catch (e) {
        lastError = e.toString();
        debugPrint('[xmltv] refresh failed: $e');
      } finally {
        _refreshing = null;
        _updates.add(_index);
      }
    }();
  }

  // Static, so the isolate closures capture only their arguments (not this
  // service and its StreamController, which can't cross isolates).
  static Future<XmltvIndex?> _readInIsolate(String path, String sig) =>
      Isolate.run(() => _readIndexFile(path, sig));

  static Future<_BuildResult> _buildInIsolate(
    List<String> urls,
    List<String> ids,
    List<String> names,
    List<String> epgIds,
    int nowS,
    String? path,
    String sig,
  ) =>
      Isolate.run(() => _buildIndex(urls, ids, names, epgIds, nowS, path, sig));

  Future<void> clearCache(String playlistId) async {
    try {
      final f = await _file(playlistId);
      if (f != null && f.existsSync()) await f.delete();
    } catch (_) {}
    _invalidate();
  }
}

// ════════════════════════════════════════════════════════════════════════════
// Isolate side
// ════════════════════════════════════════════════════════════════════════════

class _BuildResult {
  final XmltvIndex index;
  final List<String> errors;
  _BuildResult(this.index, this.errors);
}

const _kPast = 3 * 3600;
final _latin = RegExp(r'^[ -~]*[A-Za-z0-9]');
const _kFuture = 48 * 3600;

XmltvIndex? _readIndexFile(String path, String sig) {
  final j = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  if (j['v'] != 1 || j['sig'] != sig) return null;
  return _indexFromJson(j);
}

XmltvIndex _indexFromJson(Map<String, dynamic> j) {
  final nowS = DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final channels = <String, List<EpgListing>>{};
  (j['ch'] as Map<String, dynamic>).forEach((id, progs) {
    final list = <EpgListing>[];
    for (final p in progs as List) {
      final stop = p[1] as int;
      if (stop < nowS - _kPast) continue;
      list.add(
        EpgListing.plain(
          epgId: id,
          startTimestamp: p[0] as int,
          stopTimestamp: stop,
          title: p[2] as String,
          description: p[3] as String,
        ),
      );
    }
    channels[id] = list;
  });
  final map = (j['map'] as Map<String, dynamic>).cast<String, String>();
  return XmltvIndex(
    channels,
    map,
    DateTime.fromMillisecondsSinceEpoch((j['ts'] as int) * 1000),
  );
}

Future<_BuildResult> _buildIndex(
  List<String> urls,
  List<String> streamIds,
  List<String> names,
  List<String> epgIds,
  int nowS,
  String? path,
  String sig,
) async {
  final matcher = XmltvMatcher(names, epgIds);
  // guide channel key ("<source>|<id>") → raw programmes
  final progs = <String, List<List<Object>>>{};
  // stream index → (channel key, priority)
  final candidates = <int, Map<String, int>>{};
  final errors = <String>[];

  for (var s = 0; s < urls.length; s++) {
    final url = urls[s];
    final wanted = <String, String>{}; // guide channel id → key
    try {
      await XmltvParser.parseUrl(
        url,
        onChannel: (id, displayNames) {
          final hits = matcher.match(id, displayNames);
          if (hits.isEmpty) return;
          final key = '$s|$id';
          wanted[id] = key;
          hits.forEach((i, prio) {
            (candidates[i] ??= {})[key] = prio;
          });
        },
        onProgramme: (ch, start, stop, title, desc) {
          final key = wanted[ch];
          if (key == null) return;
          if (stop <= nowS - _kPast || start >= nowS + _kFuture) return;
          if (stop <= start) return;
          (progs[key] ??= []).add([start, stop, title, desc]);
        },
      );
    } catch (e) {
      errors.add('${Uri.tryParse(url)?.pathSegments.lastOrNull ?? url}: $e');
    }
  }

  // Score each guide channel by its real (non-filler) programmes — the same
  // channel often exists in several guides, some with only "Movie" blocks.
  final real = <String, int>{};
  progs.forEach((k, list) {
    list.sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    // Real titles count once, English (Latin-script) ones twice, so an
    // English guide wins over a regional-script one when both are real.
    var score = 0;
    for (final p in list) {
      final title = p[2] as String;
      if (XmltvMatcher.isFiller(title)) continue;
      score += _latin.hasMatch(title) ? 2 : 1;
    }
    real[k] = score;
  });

  final map = <String, String>{};
  candidates.forEach((i, cands) {
    String? best;
    var bestReal = -1, bestPrio = -1, bestTotal = -1;
    cands.forEach((k, prio) {
      final r = real[k] ?? 0;
      final t = progs[k]?.length ?? 0;
      if (t == 0) return;
      final better =
          r > bestReal ||
          (r == bestReal && prio > bestPrio) ||
          (r == bestReal && prio == bestPrio && t > bestTotal);
      if (better) {
        best = k;
        bestReal = r;
        bestPrio = prio;
        bestTotal = t;
      }
    });
    if (best != null && bestReal > 0) map[streamIds[i]] = best!;
  });

  final used = map.values.toSet();
  final ch = <String, List<List<Object>>>{for (final k in used) k: progs[k]!};
  final json = <String, dynamic>{
    'v': 1,
    'sig': sig,
    'ts': nowS,
    'ch': ch,
    'map': map,
  };
  if (path != null && (map.isNotEmpty || errors.isEmpty)) {
    try {
      File(path).writeAsStringSync(jsonEncode(json), flush: true);
    } catch (e) {
      errors.add('write: $e');
    }
  }
  return _BuildResult(_indexFromJson(json), errors);
}

// ── Channel matching ────────────────────────────────────────────────────────

/// Matches guide channels to playlist channels by EPG id, then by a
/// normalised name ("IN: SONY MAX (FHD)" ≈ "Sony Max HD" ≈ `Sony.Max.SD.in`).
class XmltvMatcher {
  // priority 3: exact epg id; 2: normalised epg id; 1: normalised name
  final Map<String, List<int>> _exact = {};
  final Map<String, List<int>> _idKey = {};
  final Map<String, List<int>> _nameKey = {};

  XmltvMatcher(List<String> names, List<String> epgIds) {
    for (var i = 0; i < names.length; i++) {
      final e = epgIds[i].trim().toLowerCase();
      if (e.isNotEmpty) {
        (_exact[e] ??= []).add(i);
        final k = idKey(e);
        if (k.length >= 3) (_idKey[k] ??= []).add(i);
      }
      final n = nameKey(names[i]);
      if (n.length >= 2) (_nameKey[n] ??= []).add(i);
    }
  }

  /// Matching playlist indices → priority.
  Map<int, int> match(String id, List<String> displayNames) {
    final out = <int, int>{};
    void add(List<int>? hits, int prio) {
      if (hits == null) return;
      for (final i in hits) {
        if ((out[i] ?? 0) < prio) out[i] = prio;
      }
    }

    final lid = id.trim().toLowerCase();
    add(_exact[lid], 3);
    final keys = <String>{idKey(lid), for (final d in displayNames) nameKey(d)}
      ..removeWhere((k) => k.length < 2);
    for (final k in keys) {
      add(_idKey[k], 2);
      add(_nameKey[k], 1);
    }
    return out;
  }

  static final _prefix = RegExp(r'^\s*[^:|]{1,14}\s*[:|]\s*');
  static final _brackets = RegExp(r'[\(\[\{][^\)\]\}]*[\)\]\}]');
  static final _nonWord = RegExp(r'[^\p{L}\p{N}]+', unicode: true);
  // Superscript / modifier letters used as decoration: "SONY MAX ᴴᴰ".
  static final _modifiers = RegExp(r'[ʰ-˿ᴬ-ᶿ⁰-₟]');
  static final _countrySuffix = RegExp(r'\.[a-z]{2,3}\d?$');
  static final _qualitySuffix = RegExp(r'(fhd|uhd|hd|sd|4k)$');
  static const _noise = {
    'hd',
    'fhd',
    'uhd',
    'sd',
    'hq',
    'lq',
    '4k',
    '8k',
    'hevc',
    'h264',
    'h265',
    '1080p',
    '720p',
    '1080',
    '720',
    '576p',
    '480p',
    '50fps',
    '60fps',
    'fps',
    'tv',
    'channel',
    'backup',
    'vip',
    'raw',
    'live',
    'plus',
    'hdr',
  };

  /// "IN: SONY MAX (FHD)" → "sonymax"; "Star Gold 2 [4K]" → "stargold2".
  static String nameKey(String name) {
    var s = name.toLowerCase();
    // Country / group prefix: "IN: ", "UK | ", "PB | " (only one level).
    final m = _prefix.firstMatch(s);
    if (m != null && m.end < s.length) s = s.substring(m.end);
    s = s
        .replaceAll(_brackets, ' ')
        .replaceAll(_modifiers, ' ')
        .replaceAll('+', ' plus ');
    final words = s.split(_nonWord).where((w) => w.isNotEmpty);
    return words.where((w) => !_noise.contains(w)).join();
  }

  /// "Sony.Max.HD.in" → "sonymax"; "sonymaxhd.in" → "sonymax".
  static String idKey(String id) {
    var s = id.toLowerCase().replaceFirst(_countrySuffix, '');
    s = s.replaceAll('+', ' plus ');
    final words = s.split(_nonWord).where((w) => w.isNotEmpty);
    var k = words.where((w) => !_noise.contains(w)).join();
    if (k.length > 5) k = k.replaceFirst(_qualitySuffix, '');
    return k;
  }

  static bool isFiller(String title) => EpgListing.plain(
    title: title,
    description: '',
    startTimestamp: 0,
    stopTimestamp: 0,
  ).isGeneric;
}

// ── Streaming XMLTV parser ──────────────────────────────────────────────────

typedef XmltvChannelCb = void Function(String id, List<String> displayNames);
typedef XmltvProgrammeCb =
    void Function(
      String channel,
      int start,
      int stop,
      String title,
      String desc,
    );

class XmltvParser {
  XmltvParser._();

  static Future<void> parseUrl(
    String url, {
    required XmltvChannelCb onChannel,
    required XmltvProgrammeCb onProgramme,
  }) async {
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 20)
      ..userAgent = 'LunarIPTV/1.0';
    try {
      final req = await client.getUrl(Uri.parse(url));
      final res = await req.close().timeout(const Duration(seconds: 30));
      if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}');
      await parseBytes(
        res,
        onChannel: onChannel,
        onProgramme: onProgramme,
      ).timeout(const Duration(minutes: 4));
    } finally {
      client.close(force: true);
    }
  }

  /// Parses an XMLTV byte stream (gzip detected automatically).
  static Future<void> parseBytes(
    Stream<List<int>> bytes, {
    required XmltvChannelCb onChannel,
    required XmltvProgrammeCb onProgramme,
  }) async {
    // bytes → (gunzip) → UTF-8 → scanner, all as synchronous chunked sinks:
    // only the current chunk and one partial element are ever in memory.
    final scanner = _Scanner(onChannel, onProgramme);
    final text = const Utf8Decoder(
      allowMalformed: true,
    ).startChunkedConversion(scanner);
    Sink<List<int>>? sink;
    await for (final chunk in bytes) {
      if (chunk.isEmpty) continue;
      if (sink == null) {
        // Sniff the gzip magic on the first chunk.
        final gz = chunk.length >= 2 && chunk[0] == 0x1f && chunk[1] == 0x8b;
        sink = gz ? gzip.decoder.startChunkedConversion(text) : text;
      }
      sink.add(chunk);
    }
    (sink ?? text).close();
  }

  /// Parses a whole XMLTV document held in memory (tests / small guides).
  static void parseString(
    String xml, {
    required XmltvChannelCb onChannel,
    required XmltvProgrammeCb onProgramme,
  }) {
    _Scanner(onChannel, onProgramme)
      ..add(xml)
      ..close();
  }

  /// "20261110000000 +0530" → unix seconds (UTC).
  static int? parseTime(String v) {
    final t = v.trim();
    if (t.length < 12) return null;
    final y = int.tryParse(t.substring(0, 4));
    final mo = int.tryParse(t.substring(4, 6));
    final d = int.tryParse(t.substring(6, 8));
    final h = int.tryParse(t.substring(8, 10));
    final mi = int.tryParse(t.substring(10, 12));
    final se = t.length >= 14 ? int.tryParse(t.substring(12, 14)) ?? 0 : 0;
    if (y == null || mo == null || d == null || h == null || mi == null) {
      return null;
    }
    var secs = DateTime.utc(y, mo, d, h, mi, se).millisecondsSinceEpoch ~/ 1000;
    final tz = RegExp(r'([+-])(\d{2}):?(\d{2})').firstMatch(t.substring(12));
    if (tz != null) {
      final off = int.parse(tz[2]!) * 3600 + int.parse(tz[3]!) * 60;
      secs -= tz[1] == '+' ? off : -off;
    }
    return secs;
  }
}

class _Scanner implements Sink<String> {
  final XmltvChannelCb onChannel;
  final XmltvProgrammeCb onProgramme;
  String _buf = '';

  _Scanner(this.onChannel, this.onProgramme);

  @override
  void add(String chunk) {
    _buf = _buf.isEmpty ? chunk : _buf + chunk;
    var pos = 0;
    while (true) {
      final lt = _buf.indexOf('<', pos);
      if (lt < 0) {
        pos = _buf.length;
        break;
      }
      if (_buf.startsWith('<programme', lt)) {
        final end = _buf.indexOf('</programme>', lt);
        if (end < 0) {
          // Self-closing <programme …/> has no content → skip it.
          final gt = _buf.indexOf('>', lt);
          if (gt > 0 && _buf.codeUnitAt(gt - 1) == 0x2f) {
            pos = gt + 1;
            continue;
          }
          pos = lt;
          break;
        }
        _programme(_buf.substring(lt, end));
        pos = end + 12;
      } else if (_buf.startsWith('<channel', lt)) {
        final end = _buf.indexOf('</channel>', lt);
        if (end < 0) {
          pos = lt;
          break;
        }
        _channel(_buf.substring(lt, end));
        pos = end + 10;
      } else {
        final gt = _buf.indexOf('>', lt);
        if (gt < 0) {
          pos = lt;
          break;
        }
        pos = gt + 1;
      }
    }
    _buf = pos >= _buf.length ? '' : _buf.substring(pos);
    // A malformed element must not make the buffer grow without bound.
    if (_buf.length > 4 << 20) _buf = '';
  }

  @override
  void close() => _buf = '';

  static final _attr = RegExp(r'''([\w:-]+)\s*=\s*("([^"]*)"|'([^']*)')''');

  static Map<String, String> _attrs(String tag) {
    final m = <String, String>{};
    for (final a in _attr.allMatches(tag)) {
      m[a[1]!] = a[3] ?? a[4] ?? '';
    }
    return m;
  }

  static List<String> _texts(String el, String tag) {
    final out = <String>[];
    var pos = 0;
    while (true) {
      final s = el.indexOf('<$tag', pos);
      if (s < 0) break;
      final gt = el.indexOf('>', s);
      if (gt < 0) break;
      // `<titlex` must not match `<title`
      final c = el.codeUnitAt(s + tag.length + 1);
      if (c != 0x3e && c != 0x20 && c != 0x2f && c != 0x09 && c != 0x0a) {
        pos = gt + 1;
        continue;
      }
      if (el.codeUnitAt(gt - 1) == 0x2f) {
        pos = gt + 1;
        continue;
      }
      final e = el.indexOf('</$tag>', gt);
      if (e < 0) break;
      out.add(_unescape(el.substring(gt + 1, e)).trim());
      pos = e;
    }
    return out;
  }

  void _channel(String el) {
    final gt = el.indexOf('>');
    if (gt < 0) return;
    final id = _attrs(el.substring(0, gt))['id'];
    if (id == null || id.isEmpty) return;
    onChannel(id, _texts(el, 'display-name'));
  }

  void _programme(String el) {
    final gt = el.indexOf('>');
    if (gt < 0) return;
    final a = _attrs(el.substring(0, gt));
    final ch = a['channel'];
    final start = XmltvParser.parseTime(a['start'] ?? '');
    final stop = XmltvParser.parseTime(a['stop'] ?? '');
    if (ch == null || start == null || stop == null) return;
    final titles = _texts(el, 'title');
    if (titles.isEmpty) return;
    var desc = _texts(el, 'desc').firstOrNull ?? '';
    if (desc.isEmpty) desc = _texts(el, 'sub-title').firstOrNull ?? '';
    onProgramme(ch, start, stop, titles.first, desc);
  }

  static final _entity = RegExp(r'&(#x[0-9a-fA-F]+|#\d+|amp|lt|gt|quot|apos);');

  static String _unescape(String s) {
    if (s.startsWith('<![CDATA[') && s.endsWith(']]>')) {
      return s.substring(9, s.length - 3);
    }
    if (!s.contains('&')) return s;
    return s.replaceAllMapped(_entity, (m) {
      final e = m[1]!;
      switch (e) {
        case 'amp':
          return '&';
        case 'lt':
          return '<';
        case 'gt':
          return '>';
        case 'quot':
          return '"';
        case 'apos':
          return "'";
      }
      final code = e.startsWith('#x')
          ? int.tryParse(e.substring(2), radix: 16)
          : int.tryParse(e.substring(1));
      return code == null ? m[0]! : String.fromCharCode(code);
    });
  }
}
