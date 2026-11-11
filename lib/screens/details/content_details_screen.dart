import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/focus_utils.dart';
import '../../core/utils/launcher_utils.dart';
import '../../core/utils/responsive.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/behavior_providers.dart';
import '../../providers/movies_provider.dart';
import '../../providers/series_provider.dart';
import '../../services/behavior_service.dart';
import '../../widgets/app_network_image.dart';

// ═════════════════════════════════════════════════════════════════════════════
// "Cinema" details page for a movie or a series.
//
//   ┌──────────────────────────────────────────────────────────────────┐
//   │ ←   (backdrop: fixed, fades into the page on the left + bottom)  │
//   │                                                                  │
//   │  SERIES · 2 SEASONS                                    ┌──────┐  │
//   │  Title                                                 │poster│  │
//   │  2023 · ★ 8.0 · 2h 54m  [1080p] [5.1] [Hindi]          │      │  │
//   │  Synopsis (3 lines)                                    └──────┘  │
//   │  [▶ Resume S1:E3 ▬▬▬ 47m left] (↺) (♥) (⬇) (▶ Trailer)           │
//   ├──────────────────────────────────────────────────────────────────┤
//   │  Episodes      Season 1   Season 2  (underline tabs)             │
//   │   1  [still]  Title · 59m · plot · progress                 (⬇)  │
//   │  About         synopsis · cast chips  │  Director, Genres, …     │
//   │  More Like This  [poster] [poster] …                             │
//   └──────────────────────────────────────────────────────────────────┘
//
// Remote / keyboard: Back ↔ buttons (Up/Down or Left/Right walk them in
// order) → seasons → episodes (Right = download) → More Like This.
// Touch / mouse: everything is tappable / clickable, with hover states.
//
// Performance: the backdrop is a fixed layer behind the scroll view in a
// RepaintBoundary (no repaint while scrolling); resume points come from
// the Continue Watching list once per build (it used to read + decode a
// saved position for every episode, several times per build); "More Like
// This" is computed once, not on every rebuild.
// ═════════════════════════════════════════════════════════════════════════════

/// Opens the details page for [movie].
void openMovieDetails(BuildContext context, VodStream movie) =>
    context.push('/movie-details', extra: movie);

/// Opens the details page for [series].
void openSeriesDetails(BuildContext context, Series series) =>
    context.push('/series-details', extra: series);

class MovieDetailsScreen extends ConsumerStatefulWidget {
  final VodStream movie;
  const MovieDetailsScreen({super.key, required this.movie});

  @override
  ConsumerState<MovieDetailsScreen> createState() => _MovieDetailsScreenState();
}

class SeriesDetailsScreen extends ConsumerStatefulWidget {
  final Series series;
  const SeriesDetailsScreen({super.key, required this.series});

  @override
  ConsumerState<SeriesDetailsScreen> createState() =>
      _SeriesDetailsScreenState();
}

/// Shown if the route was opened without its item (e.g. a web refresh).
class DetailsMissingScreen extends StatelessWidget {
  const DetailsMissingScreen({super.key});

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: AppTheme.background,
    body: Center(
      child: TvFocusable(
        autofocus: true,
        onActivate: () => context.canPop() ? context.pop() : context.go('/home'),
        builder: (focused, _) => _GlassPill(
          icon: Icons.arrow_back_rounded,
          label: 'Go back',
          focused: focused,
        ),
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared focus plumbing
// ─────────────────────────────────────────────────────────────────────────────
mixin _DetailsNav<T extends ConsumerStatefulWidget> on ConsumerState<T> {
  final scroll = ScrollController();
  final backFocus = FocusNode(debugLabel: 'detailsBack');
  final List<FocusNode> actionFocus = [];
  final List<FocusNode> similarFocus = [];

  int actionCount = 0;
  int similarCount = 0;

  FocusNode actionNode(int i) => _grow(actionFocus, i, 'detailsAction');
  FocusNode similarNode(int i) => _grow(similarFocus, i, 'detailsSimilar');

  static FocusNode _grow(List<FocusNode> list, int i, String label) {
    while (list.length <= i) {
      list.add(FocusNode(debugLabel: '$label${list.length}'));
    }
    return list[i];
  }

  /// First focus stop below the buttons (seasons / episodes / similar).
  FocusNode? get belowActions;

  /// Focus stop the "More Like This" row goes Up to.
  FocusNode? get aboveSimilar;

  void go(FocusNode? n, {bool down = false, bool up = false}) {
    if (n == null) {
      // Nothing further down: reveal the rest of the page (About…).
      if (down && scroll.hasClients) {
        scroll.animateTo(
          scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
      return;
    }
    _reach(n, down ? 1 : (up ? -1 : 0), 0);
  }

  /// Focuses [n]. Slivers far from the viewport aren't built yet (e.g.
  /// "More Like This" below a long About section), so scroll towards it
  /// [dir] half a screen per frame until it exists.
  void _reach(FocusNode n, int dir, int tries) {
    if (!mounted) return;
    if (n.context != null) {
      n.requestFocus();
      return;
    }
    if (tries > 40 || !scroll.hasClients) return;
    if (dir != 0) {
      final p = scroll.position;
      final t = (p.pixels + dir * p.viewportDimension * 0.5).clamp(
        p.minScrollExtent,
        p.maxScrollExtent,
      );
      if (t == p.pixels) return; // reached the end without finding it
      scroll.jumpTo(t);
    } else {
      WidgetsBinding.instance.scheduleFrame();
    }
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _reach(n, dir, tries + 1),
    );
  }

  /// Arrow handler. Up/Down are always consumed (a null target keeps focus
  /// in place); a null Left/Right is consumed too so focus never jumps out
  /// of a row sideways into something unrelated.
  KeyEventResult Function(LogicalKeyboardKey) arrows({
    FocusNode? Function()? up,
    FocusNode? Function()? down,
    FocusNode? Function()? left,
    FocusNode? Function()? right,
  }) {
    return (key) {
      if (key == LogicalKeyboardKey.arrowUp) {
        go(up?.call(), up: true);
      } else if (key == LogicalKeyboardKey.arrowDown) {
        go(down?.call(), down: true);
      } else if (key == LogicalKeyboardKey.arrowLeft) {
        go(left?.call());
      } else if (key == LogicalKeyboardKey.arrowRight) {
        go(right?.call());
      } else {
        return KeyEventResult.ignored;
      }
      return KeyEventResult.handled;
    };
  }

  /// The buttons form one sequence (Resume → Start Over → Favourite →
  /// Download → Trailer): Down / Right go to the next one, Up / Left to
  /// the previous. Down from the last leaves for the episodes / More Like
  /// This, Up from the first goes to Back.
  KeyEventResult Function(LogicalKeyboardKey) actionArrows(int i) {
    final prev = i > 0 ? actionNode(i - 1) : null;
    final next = i + 1 < actionCount ? actionNode(i + 1) : null;
    return arrows(
      up: () => prev ?? backFocus,
      down: () => next ?? belowActions,
      left: () => prev,
      right: () => next,
    );
  }

  /// Last button — what the section below goes Up to.
  FocusNode get lastAction =>
      actionCount > 0 ? actionNode(actionCount - 1) : backFocus;

  /// Puts remote focus on the first button once the page is up, in case
  /// autofocus lost the race (e.g. focus still on the previous page).
  void focusFirstAction([int tries = 0]) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final scope = FocusScope.of(context);
      final inPage = scope.hasFocus && scope.focusedChild != null;
      if (inPage && FocusManager.instance.primaryFocus != scope) return;
      final first = actionCount > 0 ? actionNode(0) : backFocus;
      if (first.context != null) {
        first.requestFocus();
      } else if (tries < 20) {
        focusFirstAction(tries + 1);
      }
    });
  }

  KeyEventResult Function(LogicalKeyboardKey) get backArrows => arrows(
    down: () => actionCount > 0 ? actionNode(0) : belowActions,
    right: () => actionCount > 0 ? actionNode(0) : null,
  );

  KeyEventResult Function(LogicalKeyboardKey) similarArrows(int i) => arrows(
    up: () => aboveSimilar,
    left: () => i > 0 ? similarNode(i - 1) : null,
    right: () => i + 1 < similarCount ? similarNode(i + 1) : null,
  );

  void disposeNav() {
    scroll.dispose();
    backFocus.dispose();
    for (final n in [...actionFocus, ...similarFocus]) {
      n.dispose();
    }
  }

  void goBack() {
    if (context.canPop()) {
      context.pop();
    } else {
      context.go('/home');
    }
  }

  void push(Map<String, dynamic> extra) => context.push('/player', extra: extra);

  void download(String url) =>
      launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);

  /// Resume points by content id, from the Continue Watching list (watched
  /// so it refreshes after playing). One small list per build instead of
  /// a storage read + JSON decode per episode.
  Map<String, _Resume> resumePoints() {
    final out = <String, _Resume>{};
    for (final m in ref.watch(continueWatchingProvider)) {
      final r = _Resume.fromMap(m);
      final id = m['id']?.toString();
      if (r != null && id != null) out[id] = r;
    }
    return out;
  }

  // "More Like This" is computed once per (library, category).
  Object? _similarFor;
  List<Object> _similar = const [];

  List<X> similarFrom<X extends Object>(
    List<X>? all,
    String? categoryId,
    bool Function(X) sameCategoryOther,
  ) {
    if (all == null || categoryId == null) return const [];
    if (!identical(_similarFor, all)) {
      _similarFor = all;
      final out = <X>[];
      for (final x in all) {
        if (sameCategoryOther(x)) {
          out.add(x);
          if (out.length >= 24) break;
        }
      }
      _similar = out;
    }
    return _similar.cast<X>();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOVIE
// ─────────────────────────────────────────────────────────────────────────────
class _MovieDetailsScreenState extends ConsumerState<MovieDetailsScreen>
    with _DetailsNav {
  VodStream get movie => widget.movie;

  @override
  FocusNode? get belowActions => similarCount > 0 ? similarNode(0) : null;

  @override
  FocusNode? get aboveSimilar => lastAction;

  @override
  void initState() {
    super.initState();
    focusFirstAction();
  }

  @override
  void dispose() {
    disposeNav();
    super.dispose();
  }

  void _play(VodInfo? info, {double start = 0}) {
    final service = ref.read(xtreamServiceProvider);
    if (service == null) return;
    final genre = info?.info?.genre;
    if (genre != null) {
      for (final g in genre.split(',')) {
        if (g.trim().isNotEmpty) {
          BehaviorService.instance.recordGenreAccess(g.trim());
        }
      }
    }
    BehaviorService.instance.startWatchTimer(movie.streamId);
    ref.read(recentlyViewedVodProvider.notifier).add(movie.streamId);
    push({
      'title': movie.name,
      'url': service.getVodUrl(movie.streamId, _ext(info)),
      'imageUrl': movie.streamIcon,
      'type': 'movie',
      'id': movie.streamId,
      'startPosition': start,
    });
  }

  String _ext(VodInfo? info) =>
      info?.movieData?.containerExtension ?? movie.containerExtension ?? 'mp4';

  @override
  Widget build(BuildContext context) {
    final infoAsync = ref.watch(vodInfoProvider(movie.streamId));
    final vod = infoAsync.valueOrNull;
    final info = vod?.info;
    final resume = resumePoints()[movie.streamId];
    final isFav = ref.watch(vodFavoritesProvider).contains(movie.streamId);
    final service = ref.watch(xtreamServiceProvider);
    final trailer = info?.youtubeTrailer;

    final similar = similarFrom<VodStream>(
      ref.watch(vodAllStreamsProvider).valueOrNull,
      movie.categoryId,
      (m) => m.categoryId == movie.categoryId && m.streamId != movie.streamId,
    );
    similarCount = similar.length;

    final actions = <_Action>[
      if (resume != null) ...[
        _Action(
          icon: Icons.play_arrow_rounded,
          label: 'Resume',
          primary: true,
          progress: resume.progress,
          caption: resume.leftLabel,
          onTap: () => _play(vod, start: resume.position),
        ),
        _Action(
          icon: Icons.replay_rounded,
          label: 'Start Over',
          onTap: () => _play(vod),
        ),
      ] else
        _Action(
          icon: Icons.play_arrow_rounded,
          label: 'Play',
          primary: true,
          onTap: () => _play(vod),
        ),
      _Action(
        icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        label: isFav ? 'Favourited' : 'Favourite',
        active: isFav,
        onTap: () =>
            ref.read(vodFavoritesProvider.notifier).toggle(movie.streamId),
      ),
      if (service != null)
        _Action(
          icon: Icons.download_rounded,
          label: 'Download',
          onTap: () => download(service.getVodUrl(movie.streamId, _ext(vod))),
        ),
      if (trailer != null && trailer.isNotEmpty)
        _Action(
          icon: Icons.smart_display_outlined,
          label: 'Trailer',
          onTap: () => launchYouTubeTrailer(context, trailer),
        ),
    ];

    final year = _year(info?.releaseDate);
    final rating = info?.rating ?? movie.ratingValue;
    final dur = _durationLabel(info?.durationSecs, info?.duration);
    final lang = _langName(info?.audioLanguage ?? info?.videoLanguage);

    return _DetailsPage(
      nav: this,
      kind: 'MOVIE',
      title: info?.name?.isNotEmpty == true ? info!.name! : movie.name,
      originalTitle: info?.oName,
      backdrop: _firstHttp([
        info?.backdropPath,
        info?.coverBig,
        info?.movieImage,
        movie.streamIcon,
      ]),
      poster: _firstHttp([info?.coverBig, info?.movieImage, movie.streamIcon]),
      rating: rating,
      meta: [?year, ?dur],
      badges: [
        ?info?.qualityLabel,
        if ((info?.audioChannels ?? 0) >= 6) '5.1',
        if (lang.isNotEmpty) lang,
        if (info?.mpaaRating?.isNotEmpty == true) info!.mpaaRating!,
      ],
      genres: info?.genre,
      synopsis: info?.plot ?? info?.description,
      loading: infoAsync.isLoading && vod == null,
      error: infoAsync.hasError && vod == null
          ? () => ref.invalidate(vodInfoProvider(movie.streamId))
          : null,
      actions: actions,
      cast: info?.cast,
      facts: [
        ('Director', info?.director),
        ('Genres', info?.genre),
        ('Country', info?.country),
        ('Released', info?.releaseDate),
        ('Audio', lang.isEmpty ? null : lang),
        (
          'Video',
          [?info?.qualityLabel, ?info?.videoCodec?.toUpperCase()].join(' · '),
        ),
      ],
      similar: [
        for (final m in similar)
          _SimilarItem(
            title: m.name,
            image: m.streamIcon,
            rating: m.ratingValue,
            onTap: () => context.pushReplacement('/movie-details', extra: m),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SERIES
// ─────────────────────────────────────────────────────────────────────────────
class _SeriesDetailsScreenState extends ConsumerState<SeriesDetailsScreen>
    with _DetailsNav {
  Series get series => widget.series;
  String? _season;
  final Map<String, FocusNode> _seasonFocus = {};
  final List<FocusNode> _epFocus = [];
  final List<FocusNode> _epDlFocus = [];
  List<String> _seasonKeys = const [];
  int _epCount = 0;

  FocusNode _seasonNode(String k) =>
      _seasonFocus.putIfAbsent(k, () => FocusNode(debugLabel: 'season$k'));
  FocusNode _epNode(int i) => _DetailsNav._grow(_epFocus, i, 'episode');
  FocusNode _epDlNode(int i) => _DetailsNav._grow(_epDlFocus, i, 'episodeDl');

  FocusNode? get _seasonEntry =>
      _season != null && _seasonKeys.contains(_season)
      ? _seasonNode(_season!)
      : null;

  @override
  FocusNode? get belowActions =>
      _seasonEntry ??
      (_epCount > 0 ? _epNode(0) : null) ??
      (similarCount > 0 ? similarNode(0) : null);

  @override
  FocusNode? get aboveSimilar =>
      (_epCount > 0 ? _epNode(_epCount - 1) : null) ??
      _seasonEntry ??
      lastAction;

  FocusNode get _aboveEpisodes => _seasonEntry ?? lastAction;

  @override
  void initState() {
    super.initState();
    focusFirstAction();
  }

  @override
  void dispose() {
    disposeNav();
    for (final n in [..._seasonFocus.values, ..._epFocus, ..._epDlFocus]) {
      n.dispose();
    }
    super.dispose();
  }

  static List<String> _sortedKeys(Iterable<String> keys) =>
      keys.toList()..sort(
        (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
      );

  /// Most recently watched, unfinished episode of this series.
  (Episode, _Resume)? _resumeEpisode(
    SeriesInfo info,
    Map<String, _Resume> resume,
  ) {
    if (resume.isEmpty) return null;
    (Episode, _Resume)? best;
    for (final list in info.seasons.values) {
      for (final ep in list) {
        final r = resume[ep.id];
        if (r != null && (best == null || r.timestamp > best.$2.timestamp)) {
          best = (ep, r);
        }
      }
    }
    return best;
  }

  void _playEpisode(SeriesInfo info, Episode ep, {double start = 0}) {
    final service = ref.read(xtreamServiceProvider);
    if (service == null) return;
    final id = series.seriesId.isNotEmpty
        ? series.seriesId
        : info.series.seriesId;
    if (id.isNotEmpty) {
      ref.read(recentlyViewedSeriesProvider.notifier).add(id);
    }
    final name = info.series.name.isNotEmpty ? info.series.name : series.name;
    final title = _episodeTitle(ep);
    push({
      'title':
          '$name · S${ep.season}E${ep.episodeNum.padLeft(2, '0')}'
          '${title.isNotEmpty ? ' · $title' : ''}',
      'url': service.getSeriesUrl(ep.id, ep.containerExtension ?? 'mkv'),
      'imageUrl': info.series.cover ?? series.cover,
      'type': 'series',
      'id': ep.id,
      'startPosition': start,
    });
  }

  @override
  Widget build(BuildContext context) {
    final infoAsync = ref.watch(seriesInfoProvider(series.seriesId));
    final info = infoAsync.valueOrNull;
    final resumeMap = resumePoints();
    final isFav = ref.watch(seriesFavoritesProvider).contains(series.seriesId);
    final s = info?.series;

    final keys = info == null
        ? const <String>[]
        : _sortedKeys(info.seasons.keys);
    final resume = info == null ? null : _resumeEpisode(info, resumeMap);
    _season ??= keys.isEmpty
        ? null
        : (resume != null && keys.contains(resume.$1.season)
              ? resume.$1.season
              : keys.first);
    if (_season != null && !keys.contains(_season) && keys.isNotEmpty) {
      _season = keys.first;
    }
    final episodes = info == null || _season == null
        ? const <Episode>[]
        : (info.seasons[_season] ?? const <Episode>[]);
    _seasonKeys = keys;
    _epCount = episodes.length;

    final firstEp = keys.isEmpty || info == null
        ? null
        : (info.seasons[keys.first]?.isNotEmpty == true
              ? info.seasons[keys.first]!.first
              : null);
    final trailer = s?.youtubeTrailer?.isNotEmpty == true
        ? s!.youtubeTrailer
        : series.youtubeTrailer;

    final similar = similarFrom<Series>(
      ref.watch(seriesAllListProvider).valueOrNull,
      series.categoryId,
      (x) => x.categoryId == series.categoryId && x.seriesId != series.seriesId,
    );
    similarCount = similar.length;

    final actions = <_Action>[
      if (resume != null) ...[
        _Action(
          icon: Icons.play_arrow_rounded,
          label: 'Resume S${resume.$1.season}:E${resume.$1.episodeNum}',
          primary: true,
          progress: resume.$2.progress,
          caption: resume.$2.leftLabel,
          onTap: () => _playEpisode(info!, resume.$1, start: resume.$2.position),
        ),
        if (firstEp != null && firstEp.id != resume.$1.id)
          _Action(
            icon: Icons.replay_rounded,
            label: 'From S${firstEp.season}:E${firstEp.episodeNum}',
            onTap: () => _playEpisode(info!, firstEp),
          ),
      ] else
        _Action(
          icon: Icons.play_arrow_rounded,
          label: info == null
              ? 'Loading…'
              : firstEp == null
              ? 'No episodes'
              : 'Play S${firstEp.season}:E${firstEp.episodeNum}',
          primary: true,
          onTap: firstEp == null ? null : () => _playEpisode(info!, firstEp),
        ),
      _Action(
        icon: isFav ? Icons.favorite_rounded : Icons.favorite_border_rounded,
        label: isFav ? 'Favourited' : 'Favourite',
        active: isFav,
        onTap: () =>
            ref.read(seriesFavoritesProvider.notifier).toggle(series.seriesId),
      ),
      if (trailer != null && trailer.isNotEmpty)
        _Action(
          icon: Icons.smart_display_outlined,
          label: 'Trailer',
          onTap: () => launchYouTubeTrailer(context, trailer),
        ),
    ];

    final year = _year(s?.releaseDate ?? series.releaseDate);
    final rating10 = double.tryParse(s?.rating ?? series.rating ?? '') ?? 0;
    final seasonCount = keys.length;
    final langs = <String>{
      if (info != null)
        for (final l in info.seasons.values) ...[
          for (final e in l)
            if (e.audioLanguage?.isNotEmpty == true)
              _langName(e.audioLanguage),
        ],
    }..remove('');
    final service = ref.watch(xtreamServiceProvider);
    final meta = info?.seasonMeta[_season];
    final pad = _pad(context);
    final fallbackStill =
        meta?.cover ??
        _firstHttp([s?.backdropPath, series.backdropPath]) ??
        s?.cover ??
        series.cover;

    return _DetailsPage(
      nav: this,
      kind: seasonCount > 0
          ? 'SERIES · $seasonCount SEASON${seasonCount == 1 ? '' : 'S'}'
          : 'SERIES',
      title: s?.name.isNotEmpty == true && s!.name != 'Unknown Series'
          ? s.name
          : series.name,
      backdrop:
          _firstHttp([s?.backdropPath, series.backdropPath, s?.cover]) ??
          series.cover,
      poster: _firstHttp([s?.cover, series.cover]),
      rating: rating10,
      meta: [?year],
      badges: [...langs.take(3)],
      genres: s?.genre ?? series.genre,
      synopsis: (s?.plot?.isNotEmpty == true ? s!.plot : null) ?? series.plot,
      loading: false,
      actions: actions,
      cast: s?.cast ?? series.cast,
      facts: [
        ('Director', s?.director ?? series.director),
        ('Genres', s?.genre ?? series.genre),
        ('Released', s?.releaseDate ?? series.releaseDate),
        ('Audio', langs.isEmpty ? null : langs.join(', ')),
      ],
      middle: [
        const _SectionTitle('Episodes'),
        if (infoAsync.isLoading && info == null)
          const SliverToBoxAdapter(child: _Loading())
        else if (infoAsync.hasError && info == null)
          SliverToBoxAdapter(
            child: _ErrorBox(
              onRetry: () =>
                  ref.invalidate(seriesInfoProvider(series.seriesId)),
            ),
          )
        else ...[
          if (keys.isNotEmpty)
            SliverToBoxAdapter(child: _seasonTabs(keys, info!)),
          if (meta?.overview?.isNotEmpty == true &&
              meta!.overview != (s?.plot ?? series.plot))
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(pad, 4, pad, 10),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 820),
                  child: Text(
                    meta.overview!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      height: 1.5,
                    ),
                  ),
                ),
              ),
            ),
          if (episodes.isEmpty)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Text(
                  'No episodes available',
                  style: TextStyle(color: AppTheme.textMuted),
                ),
              ),
            )
          else
            SliverList(
              delegate: SliverChildBuilderDelegate((ctx, i) {
                final ep = episodes[i];
                final r = resumeMap[ep.id];
                return _EpisodeRow(
                  key: ValueKey('ep_${ep.id}'),
                  episode: ep,
                  fallbackImage: fallbackStill,
                  resume: r,
                  focusNode: _epNode(i),
                  downloadFocus: service == null ? null : _epDlNode(i),
                  onArrowKey: arrows(
                    up: () => i > 0 ? _epNode(i - 1) : _aboveEpisodes,
                    down: () => i + 1 < _epCount
                        ? _epNode(i + 1)
                        : (similarCount > 0 ? similarNode(0) : null),
                    right: () => service == null ? null : _epDlNode(i),
                  ),
                  onDownloadArrowKey: arrows(
                    up: () => i > 0 ? _epDlNode(i - 1) : _aboveEpisodes,
                    down: () => i + 1 < _epCount
                        ? _epDlNode(i + 1)
                        : (similarCount > 0 ? similarNode(0) : null),
                    left: () => _epNode(i),
                  ),
                  onPlay: () =>
                      _playEpisode(info!, ep, start: r?.position ?? 0),
                  onDownload: service == null
                      ? null
                      : () => download(
                          service.getSeriesUrl(
                            ep.id,
                            ep.containerExtension ?? 'mkv',
                          ),
                        ),
                );
              }, childCount: episodes.length),
            ),
        ],
      ],
      similar: [
        for (final x in similar)
          _SimilarItem(
            title: x.name,
            image: x.cover,
            rating: double.tryParse(x.rating ?? '') ?? 0,
            onTap: () => context.pushReplacement('/series-details', extra: x),
          ),
      ],
    );
  }

  /// Season tabs: text with an underline under the open season (TV-style).
  Widget _seasonTabs(List<String> keys, SeriesInfo info) {
    return SizedBox(
      height: 50,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: _pad(context) - 10),
        itemCount: keys.length,
        itemBuilder: (_, i) {
          final k = keys[i];
          final sel = k == _season;
          final name = info.seasonMeta[k]?.name;
          final label = name != null && name.isNotEmpty ? name : 'Season $k';
          final count = info.seasons[k]?.length ?? 0;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: TvFocusable(
              focusNode: _seasonNode(k),
              onActivate: () => setState(() => _season = k),
              onArrowKey: arrows(
                up: () => lastAction,
                down: () => _epCount > 0
                    ? _epNode(0)
                    : (similarCount > 0 ? similarNode(0) : null),
                left: () => i > 0 ? _seasonNode(keys[i - 1]) : null,
                right: () =>
                    i + 1 < keys.length ? _seasonNode(keys[i + 1]) : null,
              ),
              builder: (focused, _) => _Hover(
                builder: (hover) => Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: focused
                        ? Colors.white
                        : hover
                        ? Colors.white.withValues(alpha: 0.08)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        count > 0 ? '$label  ·  $count' : label,
                        style: TextStyle(
                          color: focused
                              ? Colors.black
                              : sel
                              ? Colors.white
                              : AppTheme.textSecondary,
                          fontSize: 14,
                          fontWeight: sel || focused
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                      const SizedBox(height: 5),
                      Container(
                        height: 3,
                        width: 26,
                        decoration: BoxDecoration(
                          color: sel ? _accent : Colors.transparent,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page layout
// ─────────────────────────────────────────────────────────────────────────────

/// Warm accent used for the "cinema" look (rating, progress, tabs).
const _accent = Color(0xFFE50914);
const _gold = Color(0xFFFFC94D);

class _Action {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final bool primary;
  final bool active;
  final double? progress;
  final String? caption;

  const _Action({
    required this.icon,
    required this.label,
    required this.onTap,
    this.primary = false,
    this.active = false,
    this.progress,
    this.caption,
  });
}

class _SimilarItem {
  final String title;
  final String? image;
  final double rating;
  final VoidCallback onTap;

  const _SimilarItem({
    required this.title,
    required this.image,
    required this.rating,
    required this.onTap,
  });
}

/// Vertical space kept around zoomable posters so the zoom isn't clipped.
const double _zoomRoom = 14;

double _pad(BuildContext context) {
  final w = Responsive.of(context).width;
  return w < 640 ? 18 : (w < 1280 ? 40 : 56);
}

class _DetailsPage extends StatelessWidget {
  final _DetailsNav nav;
  final String kind;
  final String title;
  final String? originalTitle;
  final String? backdrop;
  final String? poster;
  final double rating;
  final List<String> meta;
  final List<String> badges;
  final String? genres;
  final String? synopsis;
  final bool loading;
  final VoidCallback? error;
  final List<_Action> actions;
  final String? cast;
  final List<(String, String?)> facts;
  final List<Widget> middle; // slivers between hero and About
  final List<_SimilarItem> similar;

  const _DetailsPage({
    required this.nav,
    required this.kind,
    required this.title,
    this.originalTitle,
    required this.backdrop,
    required this.poster,
    required this.rating,
    required this.meta,
    required this.badges,
    required this.genres,
    required this.synopsis,
    required this.loading,
    this.error,
    required this.actions,
    required this.cast,
    required this.facts,
    this.middle = const [],
    required this.similar,
  });

  @override
  Widget build(BuildContext context) {
    final r = Responsive.of(context);
    final narrow = r.width < 720 || r.height > r.width;
    nav.actionCount = actions.length;
    final heroH = narrow
        ? r.width * 10 / 16
        : (r.height * 0.88).clamp(380.0, 860.0);

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          // ── Fixed backdrop (doesn't scroll or repaint with the page) ──
          Positioned(
            top: 0,
            left: narrow ? 0 : r.width * 0.22,
            right: 0,
            height: heroH,
            child: RepaintBoundary(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  backdrop == null
                      ? const ColoredBox(color: AppTheme.surface)
                      : AppNetworkImage(
                          url: backdrop,
                          fit: BoxFit.cover,
                          fallback: const ColoredBox(color: AppTheme.surface),
                        ),
                  DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: narrow
                          ? const LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Color(0x990A0C14),
                                Color(0x000A0C14),
                                Color(0x660A0C14),
                                AppTheme.background,
                              ],
                              stops: [0.0, 0.3, 0.7, 1.0],
                            )
                          : const LinearGradient(
                              begin: Alignment.centerLeft,
                              end: Alignment.centerRight,
                              colors: [
                                AppTheme.background,
                                Color(0xB30A0C14),
                                Color(0x330A0C14),
                                Color(0x000A0C14),
                              ],
                              stops: [0.0, 0.3, 0.6, 1.0],
                            ),
                    ),
                  ),
                  if (!narrow)
                    const DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color(0x800A0C14),
                            Color(0x000A0C14),
                            Color(0x000A0C14),
                            AppTheme.background,
                          ],
                          stops: [0.0, 0.2, 0.6, 1.0],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // ── Scrolling content ─────────────────────────────────────────
          CustomScrollView(
            controller: nav.scroll,
            slivers: [
              SliverToBoxAdapter(
                child: narrow
                    ? _narrowHero(context, heroH)
                    : _wideHero(context, r, heroH),
              ),
              if (loading)
                const SliverToBoxAdapter(child: _Loading())
              else if (error != null)
                SliverToBoxAdapter(child: _ErrorBox(onRetry: error!)),
              ...middle,
              ..._about(context, narrow),
              if (similar.isNotEmpty) ...[
                const _SectionTitle('More Like This'),
                SliverToBoxAdapter(child: _similarRow(context, narrow)),
              ],
              const SliverToBoxAdapter(child: SizedBox(height: 48)),
            ],
          ),

          // ── Back (always reachable, never scrolls away) ───────────────
          Positioned(
            top: 12,
            left: narrow ? 8 : _pad(context) - 14,
            child: SafeArea(child: _BackButton(nav: nav)),
          ),
        ],
      ),
    );
  }

  // ── Wide (TV / desktop / tablet landscape) ──────────────────────────────
  Widget _wideHero(BuildContext context, Responsive r, double h) {
    final pad = _pad(context);
    // Phones in landscape / small windows: tighter type, no poster card.
    final short = r.height < 560;
    final posterW = (h * 0.36).clamp(130.0, 250.0);
    final showPoster = r.width >= 900 && !short;
    // The hero grows with its content (at least the backdrop's height)
    // and always keeps room for the Back button above the text. It used
    // to be a fixed height with the text pinned to the bottom, so on a
    // short screen the text ran up under the Back button.
    return Container(
      constraints: BoxConstraints(minHeight: h),
      alignment: Alignment.bottomLeft,
      padding: EdgeInsets.fromLTRB(pad, short ? 68 : 84, pad, short ? 16 : 24),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(
                right: showPoster ? pad : r.width * (short ? 0.08 : 0.18),
              ),
              child: _HeroInfo(
                kind: kind,
                title: title,
                originalTitle: originalTitle,
                rating: rating,
                meta: meta,
                badges: badges,
                genres: genres,
                synopsis: synopsis,
                big: true,
                short: short,
                actions: Wrap(
                  spacing: short ? 10 : 12,
                  runSpacing: short ? 10 : 12,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (var i = 0; i < actions.length; i++)
                      _ActionButton(
                        action: actions[i],
                        focusNode: nav.actionNode(i),
                        autofocus: i == 0,
                        onArrowKey: nav.actionArrows(i),
                        dense: short,
                      ),
                  ],
                ),
              ),
            ),
          ),
          if (showPoster)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: _Poster(url: poster, width: posterW),
            ),
        ],
      ),
    );
  }

  // ── Narrow (phones / portrait) ──────────────────────────────────────────
  Widget _narrowHero(BuildContext context, double backdropH) {
    final pad = _pad(context);
    final primary = actions.where((a) => a.primary).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(height: backdropH - 70),
        Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _Poster(url: poster, width: 96),
              const SizedBox(width: 14),
              Expanded(
                child: _HeroInfo(
                  kind: kind,
                  title: title,
                  originalTitle: originalTitle,
                  rating: rating,
                  meta: meta,
                  badges: const [],
                  genres: null,
                  synopsis: null,
                  big: false,
                  actions: const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 14, pad, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (badges.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [for (final b in badges) _Chip(b)],
                ),
                const SizedBox(height: 14),
              ],
              for (var i = 0; i < primary; i++)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: _ActionButton(
                    action: actions[i],
                    focusNode: nav.actionNode(i),
                    autofocus: i == 0,
                    onArrowKey: nav.actionArrows(i),
                    expand: true,
                  ),
                ),
              if (actions.length > primary)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    for (var i = primary; i < actions.length; i++)
                      _ActionButton(
                        action: actions[i],
                        focusNode: nav.actionNode(i),
                        autofocus: false,
                        onArrowKey: nav.actionArrows(i),
                        compact: true,
                      ),
                  ],
                ),
              if (synopsis != null && synopsis!.trim().isNotEmpty) ...[
                const SizedBox(height: 14),
                Text(
                  synopsis!.trim(),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: AppTheme.textPrimary.withValues(alpha: 0.82),
                    fontSize: 13.5,
                    height: 1.5,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // ── About: synopsis + cast | facts ─────────────────────────────────────
  List<Widget> _about(BuildContext context, bool narrow) {
    final rows = facts
        .where((e) => e.$2 != null && e.$2!.trim().isNotEmpty)
        .toList();
    final castNames = (cast ?? '')
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(12)
        .toList();
    final hasSyn = synopsis?.trim().isNotEmpty ?? false;
    if (rows.isEmpty && castNames.isEmpty && !hasSyn) return const [];
    final pad = _pad(context);

    final story = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (hasSyn)
          Text(
            synopsis!.trim(),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 14,
              height: 1.6,
            ),
          ),
        if (castNames.isNotEmpty) ...[
          const SizedBox(height: 16),
          const _Eyebrow('CAST'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [for (final c in castNames) _Chip(c, soft: true)],
          ),
        ],
      ],
    );
    final factList = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final row in rows) ...[
          _Eyebrow(row.$1.toUpperCase()),
          const SizedBox(height: 4),
          Text(
            row.$2!.trim(),
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13.5,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 14),
        ],
      ],
    );

    return [
      _SectionTitle('About $title'),
      SliverToBoxAdapter(
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: pad),
          child: narrow
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [story, const SizedBox(height: 18), factList],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 3, child: story),
                    SizedBox(width: pad),
                    Expanded(flex: 2, child: factList),
                  ],
                ),
        ),
      ),
    ];
  }

  Widget _similarRow(BuildContext context, bool narrow) {
    final w = narrow ? 112.0 : 146.0;
    return SizedBox(
      // Room above and below for the focus zoom — the list clips its
      // children, so a zoomed poster was cut off at the top.
      height: w * 1.5 + 36 + 2 * _zoomRoom,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(
          horizontal: _pad(context) - 6,
          vertical: _zoomRoom,
        ),
        itemCount: similar.length,
        itemBuilder: (_, i) {
          final it = similar[i];
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: TvFocusable(
              focusNode: nav.similarNode(i),
              onActivate: it.onTap,
              onArrowKey: nav.similarArrows(i),
              builder: (focused, _) => _Hover(
                builder: (hover) => SizedBox(
                  width: w,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      AnimatedScale(
                        scale: focused ? 1.06 : (hover ? 1.03 : 1.0),
                        duration: const Duration(milliseconds: 150),
                        child: Container(
                          width: w,
                          height: w * 1.5,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: focused ? Colors.white : Colors.transparent,
                              width: 2.5,
                            ),
                            color: AppTheme.surfaceVariant,
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Stack(
                            fit: StackFit.expand,
                            children: [
                              AppNetworkImage(
                                url: it.image,
                                fit: BoxFit.cover,
                                fallback: const Icon(
                                  Icons.movie_outlined,
                                  color: AppTheme.textMuted,
                                ),
                              ),
                              if (it.rating > 0)
                                Positioned(
                                  top: 6,
                                  left: 6,
                                  child: _RatingPill(it.rating, small: true),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 7),
                      Text(
                        it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: 12,
                          fontWeight: focused
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _HeroInfo extends StatelessWidget {
  final String kind;
  final String title;
  final String? originalTitle;
  final double rating;
  final List<String> meta;
  final List<String> badges;
  final String? genres;
  final String? synopsis;
  final bool big;
  final bool short; // short screen (phone landscape): compact type
  final Widget actions;

  const _HeroInfo({
    this.short = false,
    required this.kind,
    required this.title,
    required this.originalTitle,
    required this.rating,
    required this.meta,
    required this.badges,
    required this.genres,
    required this.synopsis,
    required this.big,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final g = genres
        ?.split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .take(4)
        .join('   •   ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 4,
              height: 14,
              decoration: BoxDecoration(
                color: _accent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            Flexible(child: _Eyebrow(kind, color: Colors.white70)),
          ],
        ),
        const SizedBox(height: 10),
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: big ? (short ? 28 : 40) : 22,
            fontWeight: FontWeight.w900,
            height: 1.08,
            letterSpacing: big ? -0.8 : -0.3,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 14)],
          ),
        ),
        if (originalTitle != null &&
            originalTitle!.isNotEmpty &&
            originalTitle != title)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              originalTitle!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
            ),
          ),
        SizedBox(height: short ? 8 : 12),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (rating > 0) _RatingPill(rating),
            for (final m in meta)
              Text(
                m,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.88),
                  fontSize: big ? 15 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            for (final b in badges) _Chip(b),
          ],
        ),
        if (g != null && g.isNotEmpty) ...[
          const SizedBox(height: 10),
          Text(
            g,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
        if (synopsis != null && synopsis!.trim().isNotEmpty) ...[
          const SizedBox(height: 14),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: Text(
              synopsis!.trim(),
              maxLines: short ? 2 : 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.8),
                fontSize: short ? 13.5 : 14.5,
                height: 1.55,
              ),
            ),
          ),
        ],
        if (big) SizedBox(height: short ? 14 : 22),
        actions,
      ],
    );
  }
}

class _ActionButton extends StatelessWidget {
  final _Action action;
  final FocusNode focusNode;
  final bool autofocus;
  final KeyEventResult Function(LogicalKeyboardKey) onArrowKey;
  final bool compact; // icon above label (phone action row)
  final bool expand;
  final bool dense; // short screens: smaller buttons

  const _ActionButton({
    this.dense = false,
    required this.action,
    required this.focusNode,
    required this.autofocus,
    required this.onArrowKey,
    this.compact = false,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final a = action;
    return Builder(
      builder: (ctx) => TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: a.onTap,
      onArrowKey: onArrowKey,
      // Not the default "centre the focused item": on a short screen that
      // scrolled the page as it opened and pushed the title up under the
      // Back button. The buttons live in the hero, so show the page from
      // the top whenever that keeps the button in view.
      autoScroll: false,
      onFocusChange: (f) {
        if (f) _revealHero(ctx);
      },
      builder: (focused, pressed) => _Hover(
        builder: (hover) {
          if (compact) {
            return Container(
              width: 84,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                color: focused
                    ? Colors.white
                    : hover
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    a.icon,
                    size: 24,
                    color: a.active
                        ? _accent
                        : (focused ? Colors.black : Colors.white),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: focused ? Colors.black : AppTheme.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            );
          }
          final primary = a.primary;
          final enabled = a.onTap != null;
          // Primary: solid white. Others: glass pills that turn white when
          // focused — one unmistakable "you are here".
          final bg = primary || focused
              ? Colors.white
              : Colors.white.withValues(alpha: hover ? 0.22 : 0.14);
          final fg = primary || focused ? Colors.black : Colors.white;
          final iconColor = a.active ? _accent : fg;
          final button = AnimatedScale(
            scale: focused ? 1.07 : 1.0,
            duration: const Duration(milliseconds: 140),
            child: Container(
              constraints: BoxConstraints(
                minWidth: expand ? double.infinity : 0,
                minHeight: dense ? 42 : 50,
              ),
              decoration: BoxDecoration(
                color: enabled ? bg : bg.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(primary ? 10 : 26),
                border: Border.all(
                  color: focused && primary ? _accent : Colors.transparent,
                  width: 2.5,
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: primary ? (dense ? 20 : 26) : (dense ? 14 : 18),
                      vertical: dense ? 8 : 11,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(a.icon, size: primary ? 28 : 21, color: iconColor),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            a.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: primary ? 16 : 14,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (a.caption != null) ...[
                          const SizedBox(width: 12),
                          Text(
                            a.caption!,
                            style: TextStyle(
                              color: fg.withValues(alpha: 0.55),
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (a.progress != null)
                    LinearProgressIndicator(
                      value: a.progress!.clamp(0.0, 1.0),
                      minHeight: 4,
                      backgroundColor: Colors.black12,
                      color: _accent,
                    ),
                ],
              ),
            ),
          );
          // In a row, as wide as the label — not the whole row.
          return expand ? button : IntrinsicWidth(child: button);
        },
      ),
      ),
    );
  }

  /// Scroll to the very top if the button is then still fully on screen;
  /// otherwise just far enough to show it.
  static void _revealHero(BuildContext ctx) {
    final pos = Scrollable.maybeOf(ctx)?.position;
    final box = ctx.findRenderObject() as RenderBox?;
    if (pos == null || box == null || !box.attached) return;
    final viewport = pos.context.notificationContext?.findRenderObject();
    if (viewport is! RenderBox) return;
    final topInView = box.localToGlobal(Offset.zero, ancestor: viewport).dy;
    final bottomAtTop = topInView + pos.pixels + box.size.height;
    if (bottomAtTop + 16 <= pos.viewportDimension) {
      if (pos.pixels > 0) {
        pos.animateTo(
          0,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    } else {
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.85,
        duration: const Duration(milliseconds: 250),
      );
    }
  }
}

class _BackButton extends StatelessWidget {
  final _DetailsNav nav;
  const _BackButton({required this.nav});

  @override
  Widget build(BuildContext context) => TvFocusable(
    focusNode: nav.backFocus,
    onActivate: nav.goBack,
    onArrowKey: nav.backArrows,
    autoScroll: false,
    builder: (focused, _) => _Hover(
      builder: (hover) => Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: focused
              ? Colors.white
              : Colors.black.withValues(alpha: hover ? 0.7 : 0.45),
        ),
        child: Icon(
          Icons.arrow_back_rounded,
          color: focused ? Colors.black : Colors.white,
        ),
      ),
    ),
  );
}

class _Poster extends StatelessWidget {
  final String? url;
  final double width;
  const _Poster({required this.url, required this.width});

  @override
  Widget build(BuildContext context) => Container(
    width: width,
    height: width * 1.5,
    decoration: BoxDecoration(
      color: AppTheme.surfaceVariant,
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      boxShadow: const [
        BoxShadow(color: Colors.black54, blurRadius: 18, offset: Offset(0, 10)),
      ],
    ),
    clipBehavior: Clip.antiAlias,
    child: AppNetworkImage(
      url: url,
      fit: BoxFit.cover,
      fallback: const Icon(Icons.movie_outlined, color: AppTheme.textMuted),
    ),
  );
}

class _EpisodeRow extends StatelessWidget {
  final Episode episode;
  final String? fallbackImage;
  final _Resume? resume;
  final FocusNode focusNode;
  final FocusNode? downloadFocus;
  final KeyEventResult Function(LogicalKeyboardKey) onArrowKey;
  final KeyEventResult Function(LogicalKeyboardKey) onDownloadArrowKey;
  final VoidCallback onPlay;
  final VoidCallback? onDownload;

  const _EpisodeRow({
    super.key,
    required this.episode,
    required this.fallbackImage,
    required this.resume,
    required this.focusNode,
    required this.downloadFocus,
    required this.onArrowKey,
    required this.onDownloadArrowKey,
    required this.onPlay,
    required this.onDownload,
  });

  @override
  Widget build(BuildContext context) {
    final narrow = Responsive.of(context).width < 720;
    final pad = _pad(context);
    final ep = episode;
    final thumbW = narrow ? 132.0 : 220.0;
    final title = _episodeTitle(ep);
    final dur = ep.formattedDuration;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad - 10, 3, pad - 10, 3),
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              focusNode: focusNode,
              onActivate: onPlay,
              onLongPress: onDownload,
              onArrowKey: onArrowKey,
              scrollAlignment: 0.4,
              builder: (focused, _) => _Hover(
                builder: (hover) => Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: focused
                        ? Colors.white.withValues(alpha: 0.12)
                        : hover
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: focused ? Colors.white : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      if (!narrow)
                        SizedBox(
                          width: 44,
                          child: Text(
                            ep.episodeNum,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: focused
                                  ? Colors.white
                                  : AppTheme.textMuted,
                              fontSize: 26,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      if (!narrow) const SizedBox(width: 10),
                      _EpisodeThumb(
                        url: ep.image ?? fallbackImage,
                        width: thumbW,
                        progress: resume?.progress,
                        showPlay: focused || hover,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    narrow
                                        ? '${ep.episodeNum}. $title'
                                        : title,
                                    maxLines: narrow ? 2 : 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                                if (dur.isNotEmpty && !narrow)
                                  Text(
                                    dur,
                                    style: const TextStyle(
                                      color: AppTheme.textSecondary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                              ],
                            ),
                            if (narrow && dur.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 2),
                                child: Text(
                                  dur,
                                  style: const TextStyle(
                                    color: AppTheme.textSecondary,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            if (resume != null)
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  resume!.leftLabel,
                                  style: const TextStyle(
                                    color: _accent,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                            if (ep.plot != null && !narrow) ...[
                              const SizedBox(height: 6),
                              Text(
                                ep.plot!,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (onDownload != null && downloadFocus != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: TvFocusable(
                focusNode: downloadFocus,
                onActivate: onDownload,
                onArrowKey: onDownloadArrowKey,
                builder: (focused, _) => _Hover(
                  builder: (hover) => Tooltip(
                    message: 'Download episode',
                    child: Container(
                      padding: const EdgeInsets.all(11),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: focused
                            ? Colors.white
                            : Colors.white.withValues(
                                alpha: hover ? 0.16 : 0.07,
                              ),
                      ),
                      child: Icon(
                        Icons.download_rounded,
                        size: 20,
                        color: focused ? Colors.black : Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _EpisodeThumb extends StatelessWidget {
  final String? url;
  final double width;
  final double? progress;
  final bool showPlay;

  const _EpisodeThumb({
    required this.url,
    required this.width,
    required this.progress,
    required this.showPlay,
  });

  @override
  Widget build(BuildContext context) => ClipRRect(
    borderRadius: BorderRadius.circular(8),
    child: SizedBox(
      width: width,
      height: width * 9 / 16,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AppNetworkImage(
            url: url,
            fit: BoxFit.cover,
            fallback: const ColoredBox(color: AppTheme.surfaceVariant),
          ),
          if (showPlay)
            ColoredBox(
              color: Colors.black38,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 1.5),
                    color: Colors.black45,
                  ),
                  child: const Icon(
                    Icons.play_arrow_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
              ),
            ),
          if (progress != null)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: LinearProgressIndicator(
                value: progress!.clamp(0.0, 1.0),
                minHeight: 3,
                backgroundColor: Colors.white24,
                color: _accent,
              ),
            ),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(_pad(context), 28, _pad(context), 12),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 21,
          fontWeight: FontWeight.w800,
          letterSpacing: -0.3,
        ),
      ),
    ),
  );
}

class _Eyebrow extends StatelessWidget {
  final String text;
  final Color color;
  const _Eyebrow(this.text, {this.color = AppTheme.textMuted});

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      color: color,
      fontSize: 11,
      fontWeight: FontWeight.w800,
      letterSpacing: 1.6,
    ),
  );
}

class _RatingPill extends StatelessWidget {
  final double rating;
  final bool small;
  const _RatingPill(this.rating, {this.small = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: small ? 6 : 9, vertical: 3),
    decoration: BoxDecoration(
      color: small ? Colors.black.withValues(alpha: 0.7) : const Color(0x33FFC94D),
      borderRadius: BorderRadius.circular(6),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.star_rounded, size: small ? 12 : 15, color: _gold),
        const SizedBox(width: 3),
        Text(
          rating.toStringAsFixed(1),
          style: TextStyle(
            color: _gold,
            fontSize: small ? 11 : 13.5,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    ),
  );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool soft;
  const _Chip(this.text, {this.soft = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: EdgeInsets.symmetric(horizontal: soft ? 10 : 7, vertical: 3),
    decoration: BoxDecoration(
      color: soft ? Colors.white.withValues(alpha: 0.07) : Colors.transparent,
      borderRadius: BorderRadius.circular(soft ? 14 : 4),
      border: soft
          ? null
          : Border.all(color: Colors.white.withValues(alpha: 0.55)),
    ),
    child: Text(
      text,
      style: TextStyle(
        color: soft ? AppTheme.textSecondary : AppTheme.textPrimary,
        fontSize: soft ? 12.5 : 11.5,
        fontWeight: soft ? FontWeight.w500 : FontWeight.w700,
      ),
    ),
  );
}

class _GlassPill extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool focused;
  const _GlassPill({
    required this.icon,
    required this.label,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: focused ? Colors.white : Colors.white.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(24),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: focused ? Colors.black : Colors.white),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            color: focused ? Colors.black : Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );
}

class _Loading extends StatelessWidget {
  const _Loading();

  @override
  Widget build(BuildContext context) => const Padding(
    padding: EdgeInsets.all(32),
    child: Center(
      child: CircularProgressIndicator(color: _accent, strokeWidth: 2),
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorBox({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.symmetric(horizontal: _pad(context), vertical: 20),
    child: Row(
      children: [
        const Icon(Icons.cloud_off_outlined, color: AppTheme.textMuted),
        const SizedBox(width: 10),
        const Expanded(
          child: Text(
            'Could not load details from the server.',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ),
        TvFocusable(
          onActivate: onRetry,
          builder: (focused, _) => _GlassPill(
            icon: Icons.refresh_rounded,
            label: 'Retry',
            focused: focused,
          ),
        ),
      ],
    ),
  );
}

/// Mouse-hover state for pointer users (TvFocusable's `focused` is the
/// remote / keyboard focus ring only).
class _Hover extends StatefulWidget {
  final Widget Function(bool hover) builder;
  const _Hover({required this.builder});

  @override
  State<_Hover> createState() => _HoverState();
}

class _HoverState extends State<_Hover> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
    onEnter: (_) => setState(() => _hover = true),
    onExit: (_) => setState(() => _hover = false),
    child: widget.builder(_hover),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// A saved resume point (Continue Watching).
class _Resume {
  final double position;
  final double duration;
  final int timestamp;

  const _Resume(this.position, this.duration, this.timestamp);

  double get progress => duration > 0 ? position / duration : 0;

  String get leftLabel {
    final left = ((duration - position) / 60).round();
    if (left >= 60) return '${left ~/ 60}h ${left % 60}m left';
    return '${left < 1 ? 1 : left}m left';
  }

  static _Resume? fromMap(Map<String, dynamic> m) {
    final pos = (m['position'] as num?)?.toDouble() ?? 0;
    final dur = (m['duration'] as num?)?.toDouble() ?? 0;
    if (pos <= 3 || dur <= 0) return null;
    return _Resume(pos, dur, (m['timestamp'] as num?)?.toInt() ?? 0);
  }
}

String? _firstHttp(List<String?> urls) {
  for (final u in urls) {
    final t = u?.trim();
    if (t != null && (t.startsWith('http://') || t.startsWith('https://'))) {
      return t;
    }
  }
  return null;
}

String? _year(String? date) {
  if (date == null || date.length < 4) return null;
  final y = date.substring(0, 4);
  return int.tryParse(y) == null ? null : y;
}

String? _durationLabel(int? secs, String? hms) {
  var s = secs ?? 0;
  if (s <= 0 && hms != null) {
    final p = hms.split(':').map(int.tryParse).toList();
    if (p.length == 3 && !p.contains(null)) {
      s = p[0]! * 3600 + p[1]! * 60 + p[2]!;
    }
  }
  if (s <= 0) return null;
  final h = s ~/ 3600;
  final m = (s % 3600) ~/ 60;
  return h > 0 ? '${h}h ${m}m' : '${m}m';
}

String _episodeTitle(Episode ep) {
  final parts = ep.title.split(' - ');
  final t = parts.length >= 2 ? parts.last.trim() : ep.title.trim();
  return t.isEmpty ? 'Episode ${ep.episodeNum}' : t;
}

String _langName(String? code) {
  if (code == null || code.isEmpty) return '';
  const langs = {
    'eng': 'English',
    'hin': 'Hindi',
    'tam': 'Tamil',
    'tel': 'Telugu',
    'kan': 'Kannada',
    'mal': 'Malayalam',
    'mar': 'Marathi',
    'ben': 'Bengali',
    'pan': 'Punjabi',
    'pun': 'Punjabi',
    'guj': 'Gujarati',
    'urd': 'Urdu',
    'ara': 'Arabic',
    'fre': 'French',
    'fra': 'French',
    'ger': 'German',
    'deu': 'German',
    'spa': 'Spanish',
    'por': 'Portuguese',
    'rus': 'Russian',
    'zho': 'Chinese',
    'chi': 'Chinese',
    'jpn': 'Japanese',
    'kor': 'Korean',
    'ita': 'Italian',
    'dut': 'Dutch',
    'tur': 'Turkish',
  };
  final c = code.toLowerCase();
  if (c == 'und') return '';
  return langs[c] ?? code.toUpperCase();
}
