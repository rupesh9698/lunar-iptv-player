/// Human-readable names for audio / subtitle tracks.
///
/// Streams describe their tracks inconsistently: a 3-letter code ("hin"),
/// a 2-letter one ("en"), a tag ("pt-BR"), a full name ("English"), only
/// a title ("Hindi [Original]"), muxer junk ("SoundHandler") or nothing.
/// [describeTracks] turns whatever is there into a name plus a detail
/// line, and falls back to "Audio 1" / "Subtitle 1" when there's nothing.
library;

class TrackLabel {
  /// Main line, e.g. "English", "Hindi [Original]", "Audio 2".
  final String name;

  /// Second line, e.g. "Commentary · E-AC3 · 5.1 · Default" ('' if none).
  final String detail;

  const TrackLabel(this.name, [this.detail = '']);

  @override
  String toString() => detail.isEmpty ? name : '$name ($detail)';
}

/// What we know about one track (mirrors media_kit's track fields).
class TrackInfo {
  final String id;
  final String? title;
  final String? language;
  final String? codec;
  final int? channelsCount;
  final bool? isDefault;

  const TrackInfo(
    this.id, {
    this.title,
    this.language,
    this.codec,
    this.channelsCount,
    this.isDefault,
  });
}

const Map<String, String> _languages = {
  // ISO 639-1
  'af': 'Afrikaans', 'am': 'Amharic', 'ar': 'Arabic', 'as': 'Assamese',
  'az': 'Azerbaijani', 'be': 'Belarusian', 'bg': 'Bulgarian',
  'bn': 'Bengali', 'bo': 'Tibetan', 'bs': 'Bosnian', 'ca': 'Catalan',
  'cs': 'Czech', 'cy': 'Welsh', 'da': 'Danish', 'de': 'German',
  'el': 'Greek', 'en': 'English', 'eo': 'Esperanto', 'es': 'Spanish',
  'et': 'Estonian', 'eu': 'Basque', 'fa': 'Persian', 'fi': 'Finnish',
  'fil': 'Filipino', 'fo': 'Faroese', 'fr': 'French', 'ga': 'Irish',
  'gl': 'Galician', 'gu': 'Gujarati', 'he': 'Hebrew', 'hi': 'Hindi',
  'hr': 'Croatian', 'hu': 'Hungarian', 'hy': 'Armenian', 'id': 'Indonesian',
  'is': 'Icelandic', 'it': 'Italian', 'ja': 'Japanese', 'jv': 'Javanese',
  'ka': 'Georgian', 'kk': 'Kazakh', 'km': 'Khmer', 'kn': 'Kannada',
  'ko': 'Korean', 'ku': 'Kurdish', 'ky': 'Kyrgyz', 'la': 'Latin',
  'lb': 'Luxembourgish', 'lo': 'Lao', 'lt': 'Lithuanian', 'lv': 'Latvian',
  'mk': 'Macedonian', 'ml': 'Malayalam', 'mn': 'Mongolian', 'mr': 'Marathi',
  'ms': 'Malay', 'mt': 'Maltese', 'my': 'Burmese', 'nb': 'Norwegian Bokmål',
  'ne': 'Nepali', 'nl': 'Dutch', 'nn': 'Norwegian Nynorsk',
  'no': 'Norwegian', 'or': 'Odia', 'pa': 'Punjabi', 'pl': 'Polish',
  'ps': 'Pashto', 'pt': 'Portuguese', 'ro': 'Romanian', 'ru': 'Russian',
  'sa': 'Sanskrit', 'sd': 'Sindhi', 'si': 'Sinhala', 'sk': 'Slovak',
  'sl': 'Slovenian', 'so': 'Somali', 'sq': 'Albanian', 'sr': 'Serbian',
  'sv': 'Swedish', 'sw': 'Swahili', 'ta': 'Tamil', 'te': 'Telugu',
  'tg': 'Tajik', 'th': 'Thai', 'tk': 'Turkmen', 'tl': 'Tagalog',
  'tr': 'Turkish', 'tt': 'Tatar', 'ug': 'Uyghur', 'uk': 'Ukrainian',
  'ur': 'Urdu', 'uz': 'Uzbek', 'vi': 'Vietnamese', 'yi': 'Yiddish',
  'yo': 'Yoruba', 'zh': 'Chinese', 'zu': 'Zulu',
  // ISO 639-2 (bibliographic and terminology codes)
  'afr': 'Afrikaans', 'amh': 'Amharic', 'ara': 'Arabic', 'asm': 'Assamese',
  'aze': 'Azerbaijani', 'bel': 'Belarusian', 'ben': 'Bengali',
  'bho': 'Bhojpuri', 'bod': 'Tibetan', 'tib': 'Tibetan', 'bos': 'Bosnian',
  'bul': 'Bulgarian', 'cat': 'Catalan', 'ces': 'Czech', 'cze': 'Czech',
  'chi': 'Chinese', 'zho': 'Chinese', 'cmn': 'Mandarin', 'yue': 'Cantonese',
  'cym': 'Welsh', 'wel': 'Welsh', 'dan': 'Danish', 'deu': 'German',
  'ger': 'German', 'ell': 'Greek', 'gre': 'Greek', 'eng': 'English',
  'epo': 'Esperanto', 'est': 'Estonian', 'eus': 'Basque', 'baq': 'Basque',
  'fas': 'Persian', 'per': 'Persian', 'fao': 'Faroese', 'fin': 'Finnish',
  'fra': 'French', 'fre': 'French', 'gle': 'Irish', 'glg': 'Galician',
  'guj': 'Gujarati', 'heb': 'Hebrew', 'hin': 'Hindi', 'hrv': 'Croatian',
  'hun': 'Hungarian', 'hye': 'Armenian', 'arm': 'Armenian',
  'ind': 'Indonesian', 'isl': 'Icelandic', 'ice': 'Icelandic',
  'ita': 'Italian', 'jav': 'Javanese', 'jpn': 'Japanese', 'kan': 'Kannada',
  'kat': 'Georgian', 'geo': 'Georgian', 'kaz': 'Kazakh', 'khm': 'Khmer',
  'kir': 'Kyrgyz', 'kok': 'Konkani', 'kor': 'Korean', 'kur': 'Kurdish',
  'lao': 'Lao', 'lat': 'Latin', 'lav': 'Latvian', 'lit': 'Lithuanian',
  'ltz': 'Luxembourgish', 'mac': 'Macedonian', 'mkd': 'Macedonian',
  'mai': 'Maithili', 'mal': 'Malayalam', 'mar': 'Marathi', 'may': 'Malay',
  'msa': 'Malay', 'mlt': 'Maltese', 'mon': 'Mongolian', 'mya': 'Burmese',
  'bur': 'Burmese', 'nep': 'Nepali', 'nld': 'Dutch', 'dut': 'Dutch',
  'nob': 'Norwegian Bokmål', 'nno': 'Norwegian Nynorsk',
  'nor': 'Norwegian', 'ori': 'Odia', 'ory': 'Odia', 'pan': 'Punjabi',
  'pun': 'Punjabi', 'pol': 'Polish', 'por': 'Portuguese', 'pus': 'Pashto',
  'ron': 'Romanian', 'rum': 'Romanian', 'rus': 'Russian',
  'san': 'Sanskrit', 'sin': 'Sinhala', 'slk': 'Slovak', 'slo': 'Slovak',
  'slv': 'Slovenian', 'snd': 'Sindhi', 'som': 'Somali', 'spa': 'Spanish',
  'sqi': 'Albanian', 'alb': 'Albanian', 'srp': 'Serbian', 'swa': 'Swahili',
  'swe': 'Swedish', 'tam': 'Tamil', 'tat': 'Tatar', 'tel': 'Telugu',
  'tgk': 'Tajik', 'tgl': 'Tagalog', 'tha': 'Thai',
  'tuk': 'Turkmen', 'tur': 'Turkish', 'uig': 'Uyghur', 'ukr': 'Ukrainian',
  'urd': 'Urdu', 'uzb': 'Uzbek', 'vie': 'Vietnamese', 'yid': 'Yiddish',
  'yor': 'Yoruba', 'zul': 'Zulu',
};

/// "No real language" codes.
const _noLanguage = {'und', 'mul', 'zxx', 'mis', 'qaa', 'unk', 'none'};

const Map<String, String> _regions = {
  'br': 'Brazil',
  'pt': 'Portugal',
  'us': 'US',
  'gb': 'UK',
  'uk': 'UK',
  'au': 'Australia',
  'ca': 'Canada',
  'in': 'India',
  'mx': 'Mexico',
  'es': 'Spain',
  'ar': 'Argentina',
  '419': 'Latin America',
  'fr': 'France',
  'be': 'Belgium',
  'ch': 'Switzerland',
  'at': 'Austria',
  'de': 'Germany',
  'cn': 'China',
  'tw': 'Taiwan',
  'hk': 'Hong Kong',
  'sg': 'Singapore',
  'hans': 'Simplified',
  'hant': 'Traditional',
};

/// "hin" → Hindi, "en" → English, "pt-BR" → Portuguese (Brazil),
/// "english" → English. Null when there's no usable language.
String? languageName(String? code) {
  final raw = code?.trim() ?? '';
  if (raw.isEmpty) return null;
  final parts = raw.toLowerCase().split(RegExp(r'[-_]'));
  final base = parts.first;
  if (_noLanguage.contains(base)) return null;
  final name = _languages[base];
  if (name != null) {
    if (parts.length > 1) {
      final region = _regions[parts[1]] ?? parts[1].toUpperCase();
      return '$name ($region)';
    }
    return name;
  }
  // Already a name ("English", "hindi")?
  if (base.length > 3 && RegExp(r'^[a-z ]+$').hasMatch(raw.toLowerCase())) {
    return raw[0].toUpperCase() + raw.substring(1);
  }
  return raw.toUpperCase();
}

/// Titles that say nothing ("Track 2", "SoundHandler", "und", "2").
bool _isJunkTitle(String t) {
  final s = t.trim().toLowerCase();
  if (s.isEmpty) return true;
  if (RegExp(
    r'^(track|audio|sub(title)?s?|stream)?[\s#._-]*\d*$',
  ).hasMatch(s)) {
    return true;
  }
  if (s.endsWith('handler')) return true; // SoundHandler, VideoHandler…
  if (s.startsWith('iso media file') || s.startsWith('mainconcept')) {
    return true;
  }
  return _noLanguage.contains(s);
}

String? _codecName(String? codec, {required bool audio}) {
  final c = codec?.trim().toLowerCase() ?? '';
  if (c.isEmpty) return null;
  const names = {
    'aac': 'AAC',
    'ac3': 'Dolby Digital',
    'eac3': 'Dolby Digital+',
    'truehd': 'Dolby TrueHD',
    'dts': 'DTS',
    'mp3': 'MP3',
    'mp2': 'MP2',
    'opus': 'Opus',
    'vorbis': 'Vorbis',
    'flac': 'FLAC',
    'alac': 'ALAC',
    'subrip': 'SRT',
    'srt': 'SRT',
    'ass': 'ASS',
    'ssa': 'SSA',
    'webvtt': 'WebVTT',
    'mov_text': 'Text',
    'text': 'Text',
    'hdmv_pgs_subtitle': 'PGS',
    'dvd_subtitle': 'VobSub',
    'dvb_subtitle': 'DVB',
    'dvb_teletext': 'Teletext',
    'eia_608': 'CC',
    'cc_dec': 'CC',
  };
  if (c.startsWith('pcm')) return 'PCM';
  return names[c] ?? (audio ? c.toUpperCase() : null);
}

String? _channelsName(int? n) => switch (n) {
  null || <= 0 => null,
  1 => 'Mono',
  2 => 'Stereo',
  6 => '5.1',
  8 => '7.1',
  _ => '$n ch',
};

/// Labels for a list of tracks of one kind (audio or subtitles), in order.
/// Special mpv entries: "auto" → Auto, "no" → Off.
List<TrackLabel> describeTracks(List<TrackInfo> tracks, {required bool audio}) {
  var n = 0;
  final out = <TrackLabel>[];
  for (final t in tracks) {
    if (t.id == 'auto') {
      out.add(const TrackLabel('Auto', 'Default choice'));
      continue;
    }
    if (t.id == 'no') {
      out.add(TrackLabel(audio ? 'None' : 'Off'));
      continue;
    }
    n++;
    final lang = languageName(t.language);
    final rawTitle = t.title?.trim() ?? '';
    final title = _isJunkTitle(rawTitle) ? null : rawTitle;
    // A title that is just the language (code or name) adds nothing.
    final titleIsLang =
        title != null &&
        (title.toLowerCase() == (t.language ?? '').toLowerCase() ||
            languageName(title) == lang);

    String name;
    final detail = <String>[];
    if (lang != null && title != null && !titleIsLang) {
      if (title.toLowerCase().contains(lang.split(' ').first.toLowerCase())) {
        name = title; // "English (SDH)", "Hindi [Original]"
      } else {
        name = lang;
        detail.add(title); // "Commentary", "Director's cut"
      }
    } else if (lang != null) {
      name = lang;
    } else if (title != null) {
      name = _languages[title.toLowerCase()] ?? title;
    } else {
      name = '${audio ? 'Audio' : 'Subtitle'} $n';
    }

    final codec = _codecName(t.codec, audio: audio);
    if (codec != null) detail.add(codec);
    if (audio) {
      final ch = _channelsName(t.channelsCount);
      if (ch != null) detail.add(ch);
    }
    if (t.isDefault == true) detail.add('Default');
    out.add(TrackLabel(name, detail.join(' · ')));
  }

  // Tell identical entries apart ("English", "English (2)").
  final seen = <String, int>{};
  for (var i = 0; i < out.length; i++) {
    final key = out[i].toString();
    final count = (seen[key] ?? 0) + 1;
    seen[key] = count;
    if (count > 1) {
      out[i] = TrackLabel('${out[i].name} ($count)', out[i].detail);
    }
  }
  return out;
}
