import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/xtream_models.dart';

class M3uService {
  M3uService._();

  static final _client = http.Client();

  /// Fetches an M3U playlist from [url] and parses it.
  static Future<(List<XtreamCategory>, List<LiveStream>)> fetchAndParse(
      String url, {
        Duration timeout = const Duration(seconds: 60),
      }) async {
    final uri = Uri.parse(url.trim());
    final response = await _client
        .get(uri, headers: {'User-Agent': 'LunarIPTV/1.0'})
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }

    return parseContent(utf8.decode(response.bodyBytes, allowMalformed: true));
  }

  /// Parses M3U playlist string content into categories + live streams.
  static (List<XtreamCategory>, List<LiveStream>) parseContent(String content) {
    final lines = content.split(RegExp(r'\r?\n'));

    if (lines.isEmpty || !lines.first.trim().startsWith('#EXTM3U')) {
      throw Exception('Not a valid M3U file (missing #EXTM3U header)');
    }

    final groupsMap   = <String, XtreamCategory>{};
    final streams     = <LiveStream>[];
    int channelIndex  = 0;

    String? pendingName;
    Map<String, String>? pendingAttrs;

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      if (line.startsWith('#EXTINF')) {
        final parsed  = _parseExtinf(line);
        pendingName   = parsed.$1;
        pendingAttrs  = parsed.$2;
        continue;
      }

      // Skip other comment/metadata lines
      if (line.startsWith('#')) continue;

      // Validate stream URL
      if (!line.startsWith('http://') &&
          !line.startsWith('https://') &&
          !line.startsWith('rtmp://') &&
          !line.startsWith('rtsp://')) {
        pendingName  = null;
        pendingAttrs = null;
        continue;
      }

      channelIndex++;
      final attrs       = pendingAttrs ?? {};
      final displayName = (pendingName?.isNotEmpty == true
          ? pendingName
          : attrs['tvg-name']) ??
          'Channel $channelIndex';
      pendingName  = null;
      pendingAttrs = null;

      final groupTitle = attrs['group-title']?.isNotEmpty == true
          ? attrs['group-title']!
          : 'Uncategorized';
      final tvgId  = attrs['tvg-id'] ?? '';
      final logo   = attrs['tvg-logo'] ?? '';
      final chno   = attrs['tvg-chno'] ?? '$channelIndex';

      // Create category if not already seen
      if (!groupsMap.containsKey(groupTitle)) {
        groupsMap[groupTitle] = XtreamCategory(
          categoryId:   _stableId(groupTitle),
          categoryName: groupTitle,
          parentId:     0,
        );
      }

      final catId    = groupsMap[groupTitle]!.categoryId;
      // Stable ID: tvg-id + name + group ensures same channel → same ID across re-syncs
      final streamId = _stableId('${tvgId}_${displayName}_$groupTitle');

      streams.add(LiveStream(
        num:          chno,
        name:         displayName!,
        streamType:   'live',
        streamId:     streamId,
        streamIcon:   logo.isNotEmpty ? logo : null,
        epgChannelId: tvgId.isNotEmpty ? tvgId : null,
        categoryId:   catId,
        directSource: line, // actual stream URL stored here
      ));
    }

    return (groupsMap.values.toList(), streams);
  }

  // ── Private helpers ────────────────────────────────────────────────────────

  static (String, Map<String, String>) _parseExtinf(String line) {
    final commaIdx = line.lastIndexOf(',');
    final name     = commaIdx >= 0 ? line.substring(commaIdx + 1).trim() : '';
    final attrsPart = commaIdx >= 0 ? line.substring(0, commaIdx) : line;

    final attrs = <String, String>{};
    // Parse quoted attributes: key="value"
    final quoteRe = RegExp(r'([\w-]+)="([^"]*)"');
    for (final m in quoteRe.allMatches(attrsPart)) {
      attrs[m.group(1)!.toLowerCase()] = m.group(2)!;
    }
    // Parse unquoted: key=value
    final unquoteRe = RegExp(r'([\w-]+)=([^ "]+)');
    for (final m in unquoteRe.allMatches(attrsPart)) {
      final key = m.group(1)!.toLowerCase();
      if (!attrs.containsKey(key)) attrs[key] = m.group(2)!;
    }

    return (name, attrs);
  }

  /// Deterministic positive integer hash → string, for stable IDs.
  static String _stableId(String s) {
    int h = 5381;
    for (int i = 0; i < s.length; i++) {
      h = ((h << 5) + h) + s.codeUnitAt(i);
      h = h & 0x7FFFFFFF;
    }
    return h.toString();
  }
}