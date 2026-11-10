import 'dart:convert';

int _parseInt(dynamic v, [int d = 0]) {
  if (v == null) return d;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString()) ?? d;
}

enum PlaylistType { xtream, m3u }

// ============================================================
// PLAYLIST MODEL
// ============================================================
class Playlist {
  final String id;
  final String name;
  final String serverUrl;
  final String username;
  final String password;
  final DateTime addedAt;
  DateTime? lastUpdated;
  bool isActive;
  final PlaylistType type;
  final String? m3uUrl;

  Playlist({
    required this.id,
    required this.name,
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    required this.addedAt,
    this.lastUpdated,
    this.isActive = false,
    this.type = PlaylistType.xtream,
    this.m3uUrl,
  });

  bool get isM3u     => type == PlaylistType.m3u;
  bool get isXtream  => type == PlaylistType.xtream;

  /// Returns the playback URL for a live channel.
  /// M3U: uses directSource stored in the channel.
  /// Xtream: constructs from server/username/password.
  String getChannelUrl(LiveStream channel, {String format = 'ts'}) {
    if (isM3u) return channel.directSource ?? '';
    return getLiveStreamUrl(channel.streamId, format: format);
  }

  String get baseUrl {
    if (isM3u) return '';
    final url = serverUrl.endsWith('/') ? serverUrl : '$serverUrl/';
    return url;
  }

  String get playerApiUrl {
    if (isM3u) return '';
    return '${baseUrl}player_api.php?username=$username&password=$password';
  }

  String getLiveStreamUrl(String streamId, {String format = 'ts'}) =>
      '${baseUrl}live/$username/$password/$streamId.$format';

  String getVodStreamUrl(String streamId, String ext) =>
      '${baseUrl}movie/$username/$password/$streamId.$ext';

  String getSeriesStreamUrl(String episodeId, String ext) =>
      '${baseUrl}series/$username/$password/$episodeId.$ext';

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'serverUrl': serverUrl,
    'username': username,
    'password': password,
    'addedAt': addedAt.toIso8601String(),
    'lastUpdated': lastUpdated?.toIso8601String(),
    'isActive': isActive,
    'type': type == PlaylistType.m3u ? 'm3u' : 'xtream',
    'm3uUrl': m3uUrl,
  };

  factory Playlist.fromMap(Map<dynamic, dynamic> map) => Playlist(
    id:          map['id'] as String,
    name:        map['name'] as String,
    serverUrl:   (map['serverUrl'] as String?) ?? '',
    username:    (map['username'] as String?) ?? '',
    password:    (map['password'] as String?) ?? '',
    addedAt:     DateTime.parse(map['addedAt'] as String),
    lastUpdated: map['lastUpdated'] != null
        ? DateTime.parse(map['lastUpdated'] as String)
        : null,
    isActive:    map['isActive'] as bool? ?? false,
    type: (map['type'] as String?) == 'm3u'
        ? PlaylistType.m3u
        : PlaylistType.xtream,
    m3uUrl: map['m3uUrl'] as String?,
  );
}

// ============================================================
// ACCOUNT INFO MODEL
// ============================================================
class AccountInfo {
  final UserInfo userInfo;
  final ServerInfo serverInfo;

  AccountInfo({required this.userInfo, required this.serverInfo});

  factory AccountInfo.fromJson(Map<String, dynamic> json) => AccountInfo(
    userInfo: UserInfo.fromJson(json['user_info'] ?? {}),
    serverInfo: ServerInfo.fromJson(json['server_info'] ?? {}),
  );
}

class UserInfo {
  final String username;
  final String password;
  final int auth;
  final String status;
  final String? expDate;
  final bool isTrial;
  final int activeConnections;
  final int maxConnections;
  final List<String> allowedOutputFormats;

  UserInfo({
    required this.username,
    required this.password,
    required this.auth,
    required this.status,
    this.expDate,
    required this.isTrial,
    required this.activeConnections,
    required this.maxConnections,
    required this.allowedOutputFormats,
  });

  DateTime? get expirationDate {
    if (expDate == null || expDate == '0') return null;
    final ts = int.tryParse(expDate!);
    if (ts == null) return null;
    return DateTime.fromMillisecondsSinceEpoch(ts * 1000);
  }

  bool get isExpired {
    final exp = expirationDate;
    if (exp == null) return false;
    return exp.isBefore(DateTime.now());
  }

  factory UserInfo.fromJson(Map<String, dynamic> json) => UserInfo(
    username: json['username']?.toString() ?? '',
    password: json['password']?.toString() ?? '',
    auth: _parseInt(json['auth']),
    status: json['status']?.toString() ?? 'Unknown',
    expDate: json['exp_date']?.toString(),
    isTrial: json['is_trial']?.toString() == '1',
    activeConnections: _parseInt(json['active_cons']),
    maxConnections: _parseInt(json['max_connections'], 1),
    allowedOutputFormats:
        (json['allowed_output_formats'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        ['m3u8', 'ts'],
  );
}

class ServerInfo {
  final String url;
  final String port;
  final String protocol;
  final String timezone;
  final String timeNow;

  ServerInfo({
    required this.url,
    required this.port,
    required this.protocol,
    required this.timezone,
    required this.timeNow,
  });

  factory ServerInfo.fromJson(Map<String, dynamic> json) => ServerInfo(
    url: json['url']?.toString() ?? '',
    port: json['port']?.toString() ?? '',
    protocol: json['server_protocol']?.toString() ?? 'http',
    timezone: json['timezone']?.toString() ?? 'UTC',
    timeNow: json['time_now']?.toString() ?? '',
  );
}

// ============================================================
// CATEGORY MODEL
// ============================================================
class XtreamCategory {
  final String categoryId;
  final String categoryName;
  final int parentId;
  bool isHidden;
  int sortOrder;

  XtreamCategory({
    required this.categoryId,
    required this.categoryName,
    required this.parentId,
    this.isHidden = false,
    this.sortOrder = 0,
  });

  factory XtreamCategory.fromJson(Map<String, dynamic> json) => XtreamCategory(
    categoryId: json['category_id']?.toString() ?? '',
    categoryName: json['category_name']?.toString() ?? 'Unknown',
    parentId: _parseInt(json['parent_id']),
  );

  @override
  bool operator ==(Object other) =>
      other is XtreamCategory && categoryId == other.categoryId;

  @override
  int get hashCode => categoryId.hashCode;
}

// ============================================================
// LIVE STREAM MODEL
// ============================================================
class LiveStream {
  final String num;
  final String name;
  final String streamType;
  final String streamId;
  final String? streamIcon;
  final String? epgChannelId;
  final String? added;
  final String? categoryId;
  final String? tvArchive;
  final String? directSource;
  final String? customSid;
  bool isFavorite;

  LiveStream({
    required this.num,
    required this.name,
    required this.streamType,
    required this.streamId,
    this.streamIcon,
    this.epgChannelId,
    this.added,
    this.categoryId,
    this.tvArchive,
    this.directSource,
    this.customSid,
    this.isFavorite = false,
  });

  factory LiveStream.fromJson(Map<String, dynamic> json) => LiveStream(
    num: json['num']?.toString() ?? '0',
    name: json['name']?.toString() ?? 'Unknown Channel',
    streamType: json['stream_type']?.toString() ?? 'live',
    streamId: json['stream_id']?.toString() ?? '',
    streamIcon: json['stream_icon']?.toString(),
    epgChannelId: json['epg_channel_id']?.toString(),
    added: json['added']?.toString(),
    categoryId: json['category_id']?.toString(),
    tvArchive: json['tv_archive']?.toString(),
    directSource: json['direct_source']?.toString(),
    customSid: json['custom_sid']?.toString(),
  );
}

// ============================================================
// VOD (MOVIE) STREAM MODEL
// ============================================================
class VodStream {
  final String num;
  final String name;
  final String streamType;
  final String streamId;
  final String? streamIcon;
  final String? rating;
  final String? rating5based;
  final String? added;
  final String? categoryId;
  final String? containerExtension;
  final String? customSid;
  final String? directSource;
  final VodInfo? info;
  bool isFavorite;

  VodStream({
    required this.num,
    required this.name,
    required this.streamType,
    required this.streamId,
    this.streamIcon,
    this.rating,
    this.rating5based,
    this.added,
    this.categoryId,
    this.containerExtension,
    this.customSid,
    this.directSource,
    this.info,
    this.isFavorite = false,
  });

  double get ratingValue => double.tryParse(rating5based ?? '0') ?? 0.0;

  factory VodStream.fromJson(Map<String, dynamic> json) => VodStream(
    num: json['num']?.toString() ?? '0',
    name: json['name']?.toString() ?? 'Unknown Movie',
    streamType: json['stream_type']?.toString() ?? 'movie',
    streamId: json['stream_id']?.toString() ?? '',
    streamIcon: json['stream_icon']?.toString(),
    rating: json['rating']?.toString(),
    rating5based: json['rating_5based']?.toString(),
    added: json['added']?.toString(),
    categoryId: json['category_id']?.toString(),
    containerExtension: json['container_extension']?.toString() ?? 'mp4',
    customSid: json['custom_sid']?.toString(),
    directSource: json['direct_source']?.toString(),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// VOD INFO
// ─────────────────────────────────────────────────────────────────────────────
class VodInfo {
  final VodInfoDetails? info;
  final VodMovieData?   movieData;

  const VodInfo({this.info, this.movieData});

  factory VodInfo.fromJson(Map<String, dynamic> json) => VodInfo(
    info:      json['info']       != null
        ? VodInfoDetails.fromJson(json['info']       as Map<String, dynamic>)
        : null,
    movieData: json['movie_data'] != null
        ? VodMovieData.fromJson(  json['movie_data'] as Map<String, dynamic>)
        : null,
  );
}

class VodInfoDetails {
  final String? name;
  final String? oName;
  final String? coverBig;
  final String? movieImage;
  final String? releaseDate;
  final String? youtubeTrailer;
  final String? director;
  final String? cast;
  final String? description;
  final String? plot;
  final String? mpaaRating;
  final String? country;
  final String? genre;
  final String? language;
  final String? backdropPath;   // first element if array
  final int?    durationSecs;
  final String? duration;
  final int?    bitrate;
  final double? rating;
  final String? age;
  final String? tmdbId;
  final String? audioLanguage;
  final String? videoLanguage;
  final int?    videoHeight;   // from the ffprobe "video" block
  final String? videoCodec;
  final int?    audioChannels;

  /// "4K" / "1080p" / "720p" / "SD" label, or null if unknown.
  String? get qualityLabel => _qualityLabel(videoHeight);

  const VodInfoDetails({
    this.videoHeight, this.videoCodec, this.audioChannels,
    this.name, this.oName, this.coverBig, this.movieImage,
    this.releaseDate, this.youtubeTrailer, this.director, this.cast,
    this.description, this.plot, this.mpaaRating, this.country,
    this.genre, this.language, this.backdropPath, this.durationSecs,
    this.duration, this.bitrate, this.rating, this.age, this.tmdbId,
    this.audioLanguage,
    this.videoLanguage,
  });

  factory VodInfoDetails.fromJson(Map<String, dynamic> json) {
    String? backdrop;
    final rawBd = json['backdrop_path'];
    if (rawBd is List && rawBd.isNotEmpty) {
      backdrop = rawBd.first?.toString();
    } else if (rawBd is String && rawBd.isNotEmpty) {
      backdrop = rawBd;
    }

    // Extract language from nested audio/video tags
    String? audioLang;
    String? videoLang;
    int? vHeight;
    String? vCodec;
    int? aChannels;
    try {
      final audioMap = json['audio'] is Map ? json['audio'] as Map : null;
      audioLang = (audioMap?['tags'] as Map?)?['language']?.toString();
      aChannels = int.tryParse('${audioMap?['channels'] ?? ''}');
      final videoMap = json['video'] is Map ? json['video'] as Map : null;
      videoLang = (videoMap?['tags'] as Map?)?['language']?.toString();
      vHeight = int.tryParse('${videoMap?['height'] ?? ''}');
      vCodec = videoMap?['codec_name']?.toString();
    } catch (_) {}

    return VodInfoDetails(
      name:           json['name']?.toString(),
      oName:          json['o_name']?.toString(),
      coverBig:       json['cover_big']?.toString(),
      movieImage:     json['movie_image']?.toString(),
      releaseDate:    json['releasedate']?.toString(),
      youtubeTrailer: json['youtube_trailer']?.toString(),
      director:       json['director']?.toString(),
      cast: json['cast']?.toString() ?? json['actors']?.toString(),
      description:    json['description']?.toString(),
      plot:           json['plot']?.toString(),
      mpaaRating:     json['mpaa_rating']?.toString(),
      country:        json['country']?.toString(),
      genre:          json['genre']?.toString(),
      language:       json['language']?.toString(),
      backdropPath:   backdrop,
      durationSecs:   json['duration_secs'] != null
          ? int.tryParse(json['duration_secs'].toString()) : null,
      duration:       json['duration']?.toString(),
      bitrate:        json['bitrate'] != null
          ? int.tryParse(json['bitrate'].toString()) : null,
      rating:         json['rating'] != null
          ? double.tryParse(json['rating'].toString()) : null,
      age:            json['age']?.toString(),
      tmdbId:         json['tmdb_id']?.toString(),
      audioLanguage:  audioLang,
      videoLanguage:  videoLang,
      videoHeight:    vHeight,
      videoCodec:     vCodec,
      audioChannels:  aChannels,
    );
  }
}

String? _qualityLabel(int? h) {
  if (h == null || h <= 0) return null;
  if (h >= 2000) return '4K';
  if (h >= 1000) return '1080p';
  if (h >= 700) return '720p';
  if (h >= 560) return '576p';
  return 'SD';
}

/// Season metadata from get_series_info's "seasons" array.
class SeasonMeta {
  final String number;
  final String? name;
  final String? overview;
  final String? cover;
  final String? airDate;
  final int? episodeCount;
  final double? rating;

  const SeasonMeta({
    required this.number,
    this.name,
    this.overview,
    this.cover,
    this.airDate,
    this.episodeCount,
    this.rating,
  });

  factory SeasonMeta.fromJson(Map<String, dynamic> j) => SeasonMeta(
    number: '${j['season_number'] ?? ''}',
    name: j['name']?.toString(),
    overview: j['overview']?.toString(),
    cover: (j['cover_big'] ?? j['cover'])?.toString(),
    airDate: j['air_date']?.toString(),
    episodeCount: int.tryParse('${j['episode_count'] ?? ''}'),
    rating: double.tryParse('${j['vote_average'] ?? ''}'),
  );
}

class VodMovieData {
  final String? streamId;
  final String? name;
  final String? added;
  final String? categoryId;
  final String? containerExtension;

  const VodMovieData({
    this.streamId, this.name, this.added,
    this.categoryId, this.containerExtension,
  });

  factory VodMovieData.fromJson(Map<String, dynamic> json) => VodMovieData(
    streamId:           json['stream_id']?.toString(),
    name:               json['name']?.toString(),
    added:              json['added']?.toString(),
    categoryId:         json['category_id']?.toString(),
    containerExtension: json['container_extension']?.toString(),
  );
}

// ============================================================
// SERIES MODEL
// ============================================================
class Series {
  final String seriesId;
  final String name;
  final String? cover;
  final String? plot;
  final String? cast;
  final String? director;
  final String? genre;
  final String? releaseDate;
  final String? rating;
  final String? rating5based;
  final String? categoryId;
  final String? backdropPath;
  final String? youtubeTrailer;
  final String? episodeRunTime;
  bool isFavorite;

  Series({
    required this.seriesId,
    required this.name,
    this.cover,
    this.plot,
    this.cast,
    this.director,
    this.genre,
    this.releaseDate,
    this.rating,
    this.rating5based,
    this.categoryId,
    this.backdropPath,
    this.youtubeTrailer,
    this.episodeRunTime,
    this.isFavorite = false,
  });

  double get ratingValue => double.tryParse(rating5based ?? '0') ?? 0.0;

  factory Series.fromJson(Map<String, dynamic> json) => Series(
    seriesId: json['series_id']?.toString() ?? '',
    name: json['name']?.toString() ?? 'Unknown Series',
    cover: json['cover']?.toString(),
    plot: json['plot']?.toString(),
    cast: json['cast']?.toString(),
    director: json['director']?.toString(),
    genre: json['genre']?.toString(),
    releaseDate:
        json['release_date']?.toString() ?? json['releaseDate']?.toString(),
    rating: json['rating']?.toString(),
    rating5based: json['rating_5based']?.toString(),
    categoryId: json['category_id']?.toString(),
    backdropPath: _parseBackdropPath(json['backdrop_path']),
    youtubeTrailer: json['youtube_trailer']?.toString(),
    episodeRunTime: json['episode_run_time']?.toString(),
  );

  static String? _parseBackdropPath(dynamic raw) {
    if (raw == null) return null;
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is List && raw.isNotEmpty) return raw.first.toString();
    return null;
  }
}

class SeriesInfo {
  final Series series;
  final Map<String, List<Episode>> seasons;

  /// Season number → name / overview / cover (may be empty).
  final Map<String, SeasonMeta> seasonMeta;

  SeriesInfo({
    required this.series,
    required this.seasons,
    this.seasonMeta = const {},
  });

  factory SeriesInfo.fromJson(Map<String, dynamic> json) {
    // Merge outer series_id into info if not present
    final infoRaw = json['info'] as Map<String, dynamic>? ?? {};
    final infoMap = Map<String, dynamic>.from(infoRaw);
    if (!infoMap.containsKey('series_id') && json.containsKey('series_id')) {
      infoMap['series_id'] = json['series_id'];
    }

    final seasons = <String, List<Episode>>{};
    final rawEpisodes = json['episodes'];
    if (rawEpisodes is Map) {
      rawEpisodes.forEach((seasonNum, episodeList) {
        if (episodeList is List) {
          seasons['$seasonNum'] = episodeList
              .whereType<Map>()
              .map((e) => Episode.fromJson(Map<String, dynamic>.from(e)))
              .toList();
        }
      });
    } else if (rawEpisodes is List) {
      // Some panels send a list of season lists.
      for (final list in rawEpisodes.whereType<List>()) {
        for (final e in list.whereType<Map>()) {
          final ep = Episode.fromJson(Map<String, dynamic>.from(e));
          (seasons[ep.season] ??= []).add(ep);
        }
      }
    }

    final meta = <String, SeasonMeta>{};
    final rawSeasons = json['seasons'];
    if (rawSeasons is List) {
      for (final m in rawSeasons.whereType<Map>()) {
        final sm = SeasonMeta.fromJson(Map<String, dynamic>.from(m));
        if (sm.number.isNotEmpty) meta[sm.number] = sm;
      }
    }

    return SeriesInfo(
      series: Series.fromJson(infoMap),
      seasons: seasons,
      seasonMeta: meta,
    );
  }
}

class Episode {
  final String id;
  final String episodeNum;
  final String title;
  final String? containerExtension;
  final String? duration;
  final String? releaseDate;
  final String? customSid;
  final String? added;
  final String season;
  final String? audioLanguage;
  final String? plot;
  final String? image; // episode still (info.movie_image)
  final double? rating;
  final int? durationSecs;

  Episode({
    this.plot,
    this.image,
    this.rating,
    this.durationSecs,
    required this.id,
    required this.episodeNum,
    required this.title,
    this.containerExtension,
    this.duration,
    this.releaseDate,
    this.customSid,
    this.added,
    required this.season,
    this.audioLanguage,
  });

  String get formattedDuration {
    if (duration == null || duration!.isEmpty) return '';
    final parts = duration!.split(':');
    if (parts.length != 3) return duration!;
    final h = int.tryParse(parts[0]) ?? 0;
    final m = int.tryParse(parts[1]) ?? 0;
    if (h > 0) return '${h}h ${m}m';
    return '${m}m';
  }

  factory Episode.fromJson(Map<String, dynamic> json) {
    String? duration;
    String? releaseDate;
    String? audioLanguage;
    String? plot;
    String? image;
    double? rating;
    int? durationSecs;

    final infoRaw = json['info'];
    if (infoRaw is Map) {
      duration    = infoRaw['duration']?.toString();
      releaseDate = infoRaw['releasedate']?.toString();
      final p = infoRaw['plot']?.toString().trim();
      plot = (p == null || p.isEmpty) ? null : p;
      final img = (infoRaw['movie_image'] ?? infoRaw['cover_big'])
          ?.toString()
          .trim();
      image = (img == null || !img.startsWith('http')) ? null : img;
      rating = double.tryParse('${infoRaw['rating'] ?? ''}');
      durationSecs = int.tryParse('${infoRaw['duration_secs'] ?? ''}');
      try {
        final audioMap = infoRaw['audio'] as Map?;
        audioLanguage = (audioMap?['tags'] as Map?)?['language']?.toString();
      } catch (_) {}
    }

    return Episode(
      id:                 json['id']?.toString() ?? '',
      episodeNum:         _parseInt(json['episode_num']).toString(),
      title:              json['title']?.toString() ?? 'Episode',
      containerExtension: json['container_extension']?.toString() ?? 'mkv',
      duration:           duration,
      releaseDate:        releaseDate,
      customSid:          json['custom_sid']?.toString(),
      added:              json['added']?.toString(),
      season:             json['season']?.toString() ?? '1',
      audioLanguage:      audioLanguage,
      plot:               plot,
      image:              image,
      rating:             rating,
      durationSecs:       durationSecs,
    );
  }
}

// ============================================================
// EPG MODEL
// ============================================================
class EpgListing {
  final String id;
  final String epgId;
  final String title; // base64 encoded
  final String description; // base64 encoded
  final String start;
  final String end;
  final int startTimestamp;
  final int stopTimestamp;

  EpgListing({
    required this.id,
    required this.epgId,
    required this.title,
    required this.description,
    required this.start,
    required this.end,
    required this.startTimestamp,
    required this.stopTimestamp,
  }) : _plain = false;

  /// A listing whose [title] / [description] are plain text (external
  /// XMLTV guide) rather than the Xtream API's base64.
  EpgListing.plain({
    required this.title,
    required this.description,
    required this.startTimestamp,
    required this.stopTimestamp,
    this.epgId = '',
  }) : id = '',
       start = '',
       end = '',
       _plain = true;

  final bool _plain;

  // Decoded once and memoised — EPG blocks are rebuilt constantly, and
  // base64 + UTF-8 decoding on every build was measurable on TV boxes.
  late final String decodedTitle = _plain
      ? title.trim()
      : _decodeB64(title).trim();
  late final String decodedDescription = _plain
      ? description.trim()
      : _decodeB64(description).trim();

  static String _decodeB64(String v) {
    if (v.isEmpty) return '';
    try {
      return utf8.decode(base64.decode(base64.normalize(v)));
    } catch (_) {
      return v; // already plain text
    }
  }

  /// Placeholder / filler entries some providers overlay on real schedules
  /// ("Movie — Bringing the best in cinema.").
  bool get isGeneric => _kGenericTitles.contains(decodedTitle.toLowerCase());

  static const Set<String> _kGenericTitles = {
    '',
    'movie',
    'movies',
    'film',
    'films',
    'program',
    'programme',
    'programming',
    'no information',
    'no info',
    'no information available',
    'information not available',
    'no epg',
    'epg not available',
    'not available',
    'n/a',
    'tba',
    'to be announced',
    'off air',
  };

  EpgListing copyWith({int? startTimestamp, int? stopTimestamp}) => _plain
      ? EpgListing.plain(
          title: title,
          description: description,
          epgId: epgId,
          startTimestamp: startTimestamp ?? this.startTimestamp,
          stopTimestamp: stopTimestamp ?? this.stopTimestamp,
        )
      : EpgListing(
    id: id,
    epgId: epgId,
    title: title,
    description: description,
    start: start,
    end: end,
    startTimestamp: startTimestamp ?? this.startTimestamp,
    stopTimestamp: stopTimestamp ?? this.stopTimestamp,
  );

  DateTime get startTime =>
      DateTime.fromMillisecondsSinceEpoch(startTimestamp * 1000);

  DateTime get endTime =>
      DateTime.fromMillisecondsSinceEpoch(stopTimestamp * 1000);

  double get progress {
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    if (now < startTimestamp) return 0.0;
    if (now > stopTimestamp) return 1.0;
    return (now - startTimestamp) / (stopTimestamp - startTimestamp);
  }

  bool get isCurrent {
    final now = DateTime.now();
    return startTime.isBefore(now) && endTime.isAfter(now);
  }

  factory EpgListing.fromJson(Map<String, dynamic> json) => EpgListing(
    id: json['id']?.toString() ?? '',
    epgId: json['epg_id']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    description: json['description']?.toString() ?? '',
    start: json['start']?.toString() ?? '',
    end: json['end']?.toString() ?? '',
    startTimestamp: _parseInt(json['start_timestamp']),
    stopTimestamp: _parseInt(json['stop_timestamp']),
  );
}

// ============================================================
// EPG NORMALISATION
// Xtream `get_simple_data_table` returns ~2 weeks of listings, starting
// several days in the PAST, and some providers merge two sources so
// programmes overlap (e.g. a generic "Movie" block on top of the real film,
// or the same schedule twice with an offset). The UI used to take
// `epg.first` as "Now Playing" → titles/descriptions from days ago.
// ============================================================
class EpgNormalizer {
  EpgNormalizer._();

  /// Returns a sorted, non-overlapping schedule starting a little before
  /// [now]: ended programmes are dropped, generic filler loses to real
  /// programmes, and other overlaps are resolved by trimming.
  static List<EpgListing> normalize(
    List<EpgListing> raw, {
    DateTime? now,
    Duration keepPast = const Duration(hours: 3),
    Duration keepFuture = const Duration(hours: 36),
  }) {
    if (raw.isEmpty) return raw;
    final nowS = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    final from = nowS - keepPast.inSeconds;
    final to = nowS + keepFuture.inSeconds;

    final list =
        raw
            .where(
              (e) =>
                  e.stopTimestamp > e.startTimestamp &&
                  e.stopTimestamp > from &&
                  e.startTimestamp < to,
            )
            .toList()
          ..sort((a, b) {
            final c = a.startTimestamp.compareTo(b.startTimestamp);
            // Same start: real programmes before filler, shorter first.
            if (c != 0) return c;
            if (a.isGeneric != b.isGeneric) return a.isGeneric ? 1 : -1;
            return a.stopTimestamp.compareTo(b.stopTimestamp);
          });

    final out = <EpgListing>[];
    for (var e in list) {
      while (out.isNotEmpty && e.startTimestamp < out.last.stopTimestamp) {
        final prev = out.last;
        if (e.isGeneric && !prev.isGeneric) {
          // Filler overlapping a real programme: keep only the part of the
          // filler after the real one ends (if any).
          if (e.stopTimestamp <= prev.stopTimestamp) {
            e = prev; // marker: drop e
            break;
          }
          e = e.copyWith(startTimestamp: prev.stopTimestamp);
          break;
        }
        if (prev.isGeneric && !e.isGeneric) {
          // Real programme beats filler: cut the filler (or drop it).
          if (prev.startTimestamp < e.startTimestamp) {
            out[out.length - 1] = prev.copyWith(stopTimestamp: e.startTimestamp);
            break;
          }
          out.removeLast();
          continue;
        }
        if (prev.decodedTitle == e.decodedTitle) {
          // Same programme twice (offset duplicate source) → keep the
          // earlier one only.
          e = prev;
          break;
        }
        // Two different real programmes overlap: the later-starting one
        // wins from its start time.
        if (prev.startTimestamp < e.startTimestamp) {
          out[out.length - 1] = prev.copyWith(stopTimestamp: e.startTimestamp);
        } else {
          out.removeLast();
          continue;
        }
        break;
      }
      if (identical(e, out.isEmpty ? null : out.last)) continue; // dropped
      out.add(e);
    }
    return out;
  }
}

extension EpgListX on List<EpgListing> {
  /// The programme airing right now, or null (never a past one).
  EpgListing? currentAt([DateTime? now]) {
    final s = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    for (final e in this) {
      if (e.startTimestamp <= s && s < e.stopTimestamp) return e;
    }
    return null;
  }

  /// The first programme starting after now.
  EpgListing? nextAt([DateTime? now]) {
    final s = (now ?? DateTime.now()).millisecondsSinceEpoch ~/ 1000;
    for (final e in this) {
      if (e.startTimestamp > s) return e;
    }
    return null;
  }
}

// ============================================================
// WATCH HISTORY MODEL
// ============================================================
class WatchHistoryItem {
  final String id;
  final String name;
  final String? image;
  final String type; // live, movie, series
  final String streamId;
  final DateTime watchedAt;
  int position; // in seconds

  WatchHistoryItem({
    required this.id,
    required this.name,
    this.image,
    required this.type,
    required this.streamId,
    required this.watchedAt,
    this.position = 0,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'image': image,
    'type': type,
    'streamId': streamId,
    'watchedAt': watchedAt.toIso8601String(),
    'position': position,
  };

  factory WatchHistoryItem.fromMap(Map<dynamic, dynamic> map) =>
      WatchHistoryItem(
        id: map['id'] as String,
        name: map['name'] as String,
        image: map['image'] as String?,
        type: map['type'] as String,
        streamId: map['streamId'] as String,
        watchedAt: DateTime.parse(map['watchedAt'] as String),
        position: (map['position'] as num?)?.toInt() ?? 0,
      );
}
