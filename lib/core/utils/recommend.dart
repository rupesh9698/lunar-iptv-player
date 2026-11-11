/// Recommendation scoring for "Recommended for you" and "More like this".
///
/// Pure functions over light item descriptions, so they are cheap to run on
/// big libraries (tens of thousands of titles) and easy to test.
library;

import 'dart:math' as math;

/// What the scorer needs to know about one movie / series.
class RecItem {
  final String id;
  final String name;
  final String? categoryId;

  /// 0 to 10.
  final double rating;

  /// Genres when the library has them (series lists do), lower case.
  final Set<String> genres;

  /// Seconds since epoch it was added to the provider ("added"), if known.
  final int? addedAt;

  /// Lower-case name (computed once; used for quick word checks).
  final String lower;

  RecItem({
    required this.id,
    required this.name,
    this.categoryId,
    this.rating = 0,
    this.genres = const {},
    this.addedAt,
  }) : lower = name.toLowerCase();
}

// ── Titles ───────────────────────────────────────────────────────────────────

const _stopWords = {
  'the', 'and', 'for', 'with', 'from', 'that', 'this', 'into', 'your', 'you',
  'are', 'not', 'all', 'but', 'his', 'her', 'its', 'who', 'what', 'when',
  'part', 'season', 'episode', 'movie', 'film', 'series', 'chapter', 'vol',
  'volume', 'new', 'one', 'two', 'three',
  // Release / quality tags providers put in names.
  'hd', 'fhd', 'uhd', 'sd', 'hdr', 'hevc', 'x264', 'x265', 'web', 'webrip',
  'bluray', 'brrip', 'dvdrip', 'hdrip', 'cam', 'multi', 'dual', 'audio',
  'sub', 'subs', 'dub', 'dubbed', 'org', 'esub', 'eng', 'hin', '1080p',
  '720p', '480p', '2160p', '4k', '8k',
};

final _splitter = RegExp(r"[^a-z0-9À-￿']+");
final _yearRe = RegExp(r'(?:^|[\s(\[.\-])((?:19|20)\d{2})(?:[\s)\].\-]|$)');
final _prefixTag = RegExp(r'^\s*(?:[A-Z]{2,4}\s*[|:\-]\s*)+');

/// Meaningful words of a title ("Avengers: Endgame (2019) [4K]" ->
/// {avengers, endgame}). Provider prefixes like "EN | " are dropped.
Set<String> titleTokens(String name) {
  final cleaned = name.replaceFirst(_prefixTag, '').toLowerCase();
  final out = <String>{};
  for (final w in cleaned.split(_splitter)) {
    final t = w.replaceAll("'", '');
    if (t.length < 3) continue;
    if (_stopWords.contains(t)) continue;
    if (RegExp(r'^\d+$').hasMatch(t)) continue; // years, numbers
    out.add(t);
  }
  return out;
}

/// Release year in a title, if there is one.
int? titleYear(String name) {
  final m = _yearRe.allMatches(name).lastOrNull;
  final y = m == null ? null : int.tryParse(m.group(1)!);
  // "Blade Runner 2049" is a title, not a release year.
  if (y == null || y > DateTime.now().year + 1) return null;
  return y;
}

/// Genres from a comma / slash separated field, lower case.
Set<String> splitGenres(String? raw) {
  if (raw == null || raw.trim().isEmpty) return const {};
  return raw
      .split(RegExp(r'[,/|&]'))
      .map((g) => g.trim().toLowerCase())
      .where((g) => g.isNotEmpty)
      .toSet();
}

// ── More like this ───────────────────────────────────────────────────────────

/// Items most like [seed]: same franchise (shared title words) first, then
/// shared genres, same category, a close release year and a good rating.
/// Items from other categories only qualify through the title or genres.
List<RecItem> moreLikeThis(
  RecItem seed,
  Iterable<RecItem> all, {
  int max = 24,
  Set<String> seedGenres = const {},
}) {
  final seedTokens = titleTokens(seed.name);
  final seedYear = titleYear(seed.name);
  final genres = {...seed.genres, ...seedGenres};
  final top = <(RecItem, double)>[];

  for (final x in all) {
    if (x.id == seed.id) continue;
    final sameCat = seed.categoryId != null && x.categoryId == seed.categoryId;

    // Cheap pre-check before tokenising: does the name share a word?
    var shared = 0;
    if (seedTokens.isNotEmpty) {
      if (seedTokens.any(x.lower.contains)) {
        shared = seedTokens.intersection(titleTokens(x.name)).length;
      }
    }
    final genreSim = _jaccard(genres, x.genres);
    if (!sameCat && shared == 0 && genreSim < 0.34) continue;

    var score = 0.0;
    if (sameCat) score += 2.0;
    if (shared > 0) score += 3.0 * shared / seedTokens.length + 2.5;
    score += 3.0 * genreSim;
    final y = titleYear(x.name);
    if (seedYear != null && y != null) {
      score += math.max(0, 1 - (seedYear - y).abs() / 8);
    }
    score += 0.8 * (x.rating / 10).clamp(0, 1);
    _pushTop(top, (x, score), max);
  }
  return [for (final e in top) e.$1];
}

// ── Recommended for you ──────────────────────────────────────────────────────

/// One thing the user watched, with how much it counts.
class TasteSignal {
  final String id;

  /// Bigger = stronger (favourite, watched a lot, watched recently).
  final double weight;
  const TasteSignal(this.id, this.weight);
}

/// What the user likes, built from what they watched.
class TasteProfile {
  /// Category id -> 0..1 affinity.
  final Map<String, double> categories;

  /// Genre -> 0..1 affinity.
  final Map<String, double> genres;

  /// Title words of the things they watched most (franchises).
  final Set<String> tokens;

  /// Ids already watched / in progress / favourite (not recommended again).
  final Set<String> seen;

  const TasteProfile({
    this.categories = const {},
    this.genres = const {},
    this.tokens = const {},
    this.seen = const {},
  });

  bool get isEmpty => categories.isEmpty && genres.isEmpty;

  static TasteProfile build(
    Iterable<TasteSignal> signals,
    Map<String, RecItem> byId, {
    Iterable<MapEntry<String, int>> genreCounts = const [],
  }) {
    final cats = <String, double>{};
    final genres = <String, double>{};
    final tokenWeight = <String, double>{};
    final seen = <String>{};
    for (final s in signals) {
      seen.add(s.id);
      final item = byId[s.id];
      if (item == null) continue;
      final c = item.categoryId;
      if (c != null) cats[c] = (cats[c] ?? 0) + s.weight;
      for (final g in item.genres) {
        genres[g] = (genres[g] ?? 0) + s.weight;
      }
      for (final t in titleTokens(item.name)) {
        tokenWeight[t] = (tokenWeight[t] ?? 0) + s.weight;
      }
    }
    for (final g in genreCounts) {
      final k = g.key.trim().toLowerCase();
      if (k.isNotEmpty) genres[k] = (genres[k] ?? 0) + g.value.toDouble();
    }
    Map<String, double> norm(Map<String, double> m) {
      if (m.isEmpty) return m;
      final top = m.values.reduce(math.max);
      return {for (final e in m.entries) e.key: e.value / top};
    }

    final strongTokens =
        (tokenWeight.entries.toList()
              ..sort((a, b) => b.value.compareTo(a.value)))
            .take(12)
            .map((e) => e.key)
            .toSet();
    return TasteProfile(
      categories: norm(cats),
      genres: norm(genres),
      tokens: strongTokens,
      seen: seen,
    );
  }
}

/// Picks for the user: things like what they watched (category, genres,
/// franchise), well rated and recently added, never already seen, and
/// spread over categories (at most [perCategory] from one). With no
/// history it falls back to well rated new arrivals.
List<RecItem> recommendFor(
  TasteProfile taste,
  Iterable<RecItem> all, {
  int max = 25,
  int perCategory = 6,
  Map<String, String> categoryNames = const {},
  int? nowSecs,
}) {
  final now = nowSecs ?? DateTime.now().millisecondsSinceEpoch ~/ 1000;
  final pool = <(RecItem, double)>[];
  final poolSize = max * 6;

  // Genres also match category names ("Action", "Hindi Comedy" ...).
  final catGenreBoost = <String, double>{};
  if (taste.genres.isNotEmpty) {
    for (final e in categoryNames.entries) {
      final name = e.value.toLowerCase();
      var best = 0.0;
      for (final g in taste.genres.entries) {
        if (g.key.length >= 3 && name.contains(g.key)) {
          best = math.max(best, g.value);
        }
      }
      if (best > 0) catGenreBoost[e.key] = best;
    }
  }

  for (final x in all) {
    if (taste.seen.contains(x.id)) continue;
    final rating = (x.rating / 10).clamp(0.0, 1.0);
    var fresh = 0.0;
    if (x.addedAt != null && x.addedAt! > 0) {
      final days = (now - x.addedAt!) / 86400;
      if (days >= 0) fresh = math.max(0, 1 - days / 60);
    }

    double score;
    if (taste.isEmpty) {
      score = rating + 0.5 * fresh;
    } else {
      final cat = taste.categories[x.categoryId] ?? 0;
      final catName = catGenreBoost[x.categoryId] ?? 0;
      var genre = 0.0;
      if (x.genres.isNotEmpty) {
        for (final g in x.genres) {
          genre = math.max(genre, taste.genres[g] ?? 0);
        }
      }
      var franchise = 0.0;
      if (taste.tokens.isNotEmpty) {
        if (taste.tokens.any(x.lower.contains) &&
            titleTokens(x.name).intersection(taste.tokens).isNotEmpty) {
          franchise = 1;
        }
      }
      // Nothing in common with the user's taste: only great new titles.
      if (cat == 0 && catName == 0 && genre == 0 && franchise == 0) {
        score = 0.35 * rating + 0.25 * fresh;
      } else {
        score =
            1.4 * cat +
            0.8 * catName +
            1.2 * genre +
            0.9 * franchise +
            0.7 * rating +
            0.35 * fresh;
      }
    }
    _pushTop(pool, (x, score), poolSize);
  }

  // Variety: no more than [perCategory] from one category.
  final perCat = <String?, int>{};
  final out = <RecItem>[];
  for (final (x, _) in pool) {
    final n = perCat[x.categoryId] ?? 0;
    if (n >= perCategory) continue;
    perCat[x.categoryId] = n + 1;
    out.add(x);
    if (out.length >= max) break;
  }
  return out;
}

// ── helpers ──────────────────────────────────────────────────────────────────

double _jaccard(Set<String> a, Set<String> b) {
  if (a.isEmpty || b.isEmpty) return 0;
  final inter = a.intersection(b).length;
  return inter / (a.length + b.length - inter);
}

/// Keeps [top] sorted by score (desc), at most [k] long.
void _pushTop<T>(List<(T, double)> top, (T, double) item, int k) {
  if (top.length == k && item.$2 <= top.last.$2) return;
  var i = top.length;
  while (i > 0 && top[i - 1].$2 < item.$2) {
    i--;
  }
  top.insert(i, item);
  if (top.length > k) top.removeLast();
}
