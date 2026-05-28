import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:lunar_iptv_player/services/stream_proxy_service.dart';
import '../models/xtream_models.dart';
import '../core/constants/app_constants.dart';

class XtreamService {
  final Playlist playlist;
  final http.Client _client;

  XtreamService({required this.playlist}) : _client = http.Client();

  void dispose() => _client.close();

  Uri _buildUri(String action, [Map<String, String>? extra]) {
    final params = {
      'username': playlist.username,
      'password': playlist.password,
      if (action.isNotEmpty) 'action': action,
      ...?extra,
    };
    final base = playlist.baseUrl;
    final rawUrl = Uri.parse(
      '${base}player_api.php',
    ).replace(queryParameters: params).toString();
    // On web, route API calls through HTTPS proxy to avoid Mixed Content
    final resolvedUrl = StreamProxyService.resolveApi(rawUrl);
    return Uri.parse(resolvedUrl);
  }

  Future<T> _get<T>(Uri uri, T Function(dynamic) parser) async {
    final response = await _client
        .get(uri, headers: {'Accept': 'application/json'})
        .timeout(const Duration(seconds: 30));

    if (response.statusCode != 200) {
      throw Exception('HTTP ${response.statusCode}: ${response.reasonPhrase}');
    }
    return parser(json.decode(response.body));
  }

  // ── Authentication & Account Info ────────────────────────────
  Future<AccountInfo> getAccountInfo() async {
    final uri = _buildUri('');
    return _get(
      uri,
      (data) => AccountInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  // ── Live TV ──────────────────────────────────────────────────
  Future<List<XtreamCategory>> getLiveCategories() async {
    final uri = _buildUri(AppConstants.actionGetLiveCategories);
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<LiveStream>> getLiveStreams({String? categoryId}) async {
    final uri = _buildUri(
      AppConstants.actionGetLiveStreams,
      categoryId != null ? {'category_id': categoryId} : null,
    );
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => LiveStream.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  // ── Movies (VOD) ─────────────────────────────────────────────
  Future<List<XtreamCategory>> getVodCategories() async {
    final uri = _buildUri(AppConstants.actionGetVodCategories);
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<VodStream>> getVodStreams({String? categoryId}) async {
    final uri = _buildUri(
      AppConstants.actionGetVodStreams,
      categoryId != null ? {'category_id': categoryId} : null,
    );
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => VodStream.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<VodInfo> getVodInfo(String vodId) async {
    final uri = _buildUri(AppConstants.actionGetVodInfo, {'vod_id': vodId});
    return _get(uri, (data) => VodInfo.fromJson(data as Map<String, dynamic>));
  }

  // ── Series ───────────────────────────────────────────────────
  Future<List<XtreamCategory>> getSeriesCategories() async {
    final uri = _buildUri(AppConstants.actionGetSeriesCategories);
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => XtreamCategory.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<List<Series>> getSeries({String? categoryId}) async {
    final uri = _buildUri(
      AppConstants.actionGetSeries,
      categoryId != null ? {'category_id': categoryId} : null,
    );
    return _get(
      uri,
      (data) => (data as List)
          .map((e) => Series.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Future<SeriesInfo> getSeriesInfo(String seriesId) async {
    final uri = _buildUri(AppConstants.actionGetSeriesInfo, {
      'series_id': seriesId,
    });
    return _get(
      uri,
      (data) => SeriesInfo.fromJson(data as Map<String, dynamic>),
    );
  }

  // ── EPG ──────────────────────────────────────────────────────
  Future<List<EpgListing>> getShortEpg(String streamId, {int limit = 4}) async {
    final uri = _buildUri(AppConstants.actionGetShortEpg, {
      'stream_id': streamId,
      'limit': limit.toString(),
    });
    return _get(uri, (data) {
      final listings = data['epg_listings'];
      if (listings is List) {
        return listings
            .map((e) => EpgListing.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return <EpgListing>[];
    });
  }

  Future<List<EpgListing>> getSimpleDataTable(String streamId) async {
    final uri = _buildUri('get_simple_data_table', {'stream_id': streamId});
    return _get(uri, (data) {
      // get_simple_data_table returns same format as get_short_epg
      final listings = data['epg_listings'];
      if (listings is List) {
        return listings
            .map((e) => EpgListing.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      return <EpgListing>[];
    });
  }

  // ── Stream URLs ──────────────────────────────────────────────
  String getLiveUrl(String streamId, {String format = 'ts'}) =>
      playlist.getLiveStreamUrl(streamId, format: format);

  String getVodUrl(String streamId, String ext) =>
      playlist.getVodStreamUrl(streamId, ext);

  String getSeriesUrl(String episodeId, String ext) =>
      playlist.getSeriesStreamUrl(episodeId, ext);

  // ── Search ───────────────────────────────────────────────────
  Future<Map<String, dynamic>> searchAll(String query) async {
    final q = query.toLowerCase();
    final futures = await Future.wait([
      getLiveStreams(),
      getVodStreams(),
      getSeries(),
    ]);

    final live = (futures[0] as List<LiveStream>)
        .where((e) => e.name.toLowerCase().contains(q))
        .take(20)
        .toList();
    final vod = (futures[1] as List<VodStream>)
        .where((e) => e.name.toLowerCase().contains(q))
        .take(20)
        .toList();
    final series = (futures[2] as List<Series>)
        .where((e) => e.name.toLowerCase().contains(q))
        .take(20)
        .toList();

    return {'live': live, 'vod': vod, 'series': series};
  }
}
