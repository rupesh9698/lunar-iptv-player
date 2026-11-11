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
// Full-screen, Netflix-style details page for a movie or a series.
//
//   ┌──────────────────────────────────────────────────────────────┐
//   │ ←                                   (backdrop, fades left)   │
//   │ ┌──────┐ Title                                               │
//   │ │poster│ 2023 · ★ 6.9 · 2h 54m · 1080p · Action, Crime        │
//   │ └──────┘ [▶ Resume] [↺ Start over] [♥] [⬇ Download] [Trailer] │
//   │          Synopsis…                                           │
//   ├──────────────────────────────────────────────────────────────┤
//   │ Episodes   (Season 1) (Season 2)        ← series only        │
//   │ [still] 1. Title · 59m · plot …                     [⬇]      │
//   │ About: synopsis, cast, director, genres, …                   │
//   │ More Like This  [poster] [poster] [poster] …                 │
//   └──────────────────────────────────────────────────────────────┘
//
// Touch, mouse, keyboard and TV remote all work: every control is a
// TvFocusable (tap / click / OK) and the D-pad order is explicit —
//   Back ↔ actions row → seasons → episodes (→ ⬇) → More Like This.
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
        builder: (focused, _) => _PillButton(
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

  /// Number of actions stacked full-width above the icon row on phones.
  int stackedActions = 0;
  bool narrowLayout = false;
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

  /// First focus stop below the actions (seasons / episodes / similar).
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
  /// This, Up from the first goes to Back. (Down used to jump straight
  /// from Resume to More Like This, skipping the other buttons.)
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
    ref.watch(continueWatchingProvider); // refresh resume after playing
    final resume = _Resume.of(movie.streamId);
    final isFav = ref.watch(vodFavoritesProvider).contains(movie.streamId);
    final service = ref.watch(xtreamServiceProvider);
    final trailer = info?.youtubeTrailer;

    final similar = _similarMovies(ref.watch(vodAllStreamsProvider).valueOrNull);
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
          onTap: () =>
              download(service.getVodUrl(movie.streamId, _ext(vod))),
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
      title: info?.name?.isNotEmpty == true ? info!.name! : movie.name,
      originalTitle: info?.oName,
      backdrop: _firstHttp([
        info?.backdropPath,
        info?.coverBig,
        info?.movieImage,
        movie.streamIcon,
      ]),
      poster: _firstHttp([info?.coverBig, info?.movieImage, movie.streamIcon]),
      meta: [
        ?year,
        if (rating > 0) '★ ${rating.toStringAsFixed(1)}',
        ?dur,
        if (info?.mpaaRating?.isNotEmpty == true) info!.mpaaRating!,
      ],
      badges: [
        ?info?.qualityLabel,
        if ((info?.audioChannels ?? 0) >= 6) '5.1',
        if (lang.isNotEmpty) lang,
      ],
      genres: info?.genre,
      synopsis: info?.plot ?? info?.description,
      loading: infoAsync.isLoading && vod == null,
      error: infoAsync.hasError && vod == null
          ? () => ref.invalidate(vodInfoProvider(movie.streamId))
          : null,
      actions: actions,
      about: [
        ('Cast', info?.cast),
        ('Director', info?.director),
        ('Genres', info?.genre),
        ('Country', info?.country),
        ('Released', info?.releaseDate),
        ('Audio', lang.isEmpty ? null : lang),
        ('Video', [?info?.qualityLabel, ?info?.videoCodec?.toUpperCase()]
            .join(' · ')),
      ],
      similar: [
        for (final m in similar)
          _SimilarItem(
            title: m.name,
            image: m.streamIcon,
            rating: m.ratingValue,
            onTap: () =>
                context.pushReplacement('/movie-details', extra: m),
          ),
      ],
    );
  }

  List<VodStream> _similarMovies(List<VodStream>? all) {
    if (all == null || movie.categoryId == null) return const [];
    final out = <VodStream>[];
    for (final m in all) {
      if (m.categoryId == movie.categoryId && m.streamId != movie.streamId) {
        out.add(m);
        if (out.length >= 24) break;
      }
    }
    return out;
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

  FocusNode get _aboveEpisodes =>
      _seasonEntry ?? lastAction;

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
  (Episode, _Resume)? _resumeEpisode(SeriesInfo info) {
    (Episode, _Resume)? best;
    for (final list in info.seasons.values) {
      for (final ep in list) {
        final r = _Resume.of(ep.id);
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
    ref.watch(continueWatchingProvider); // refresh resume after playing
    final isFav = ref.watch(seriesFavoritesProvider).contains(series.seriesId);
    final s = info?.series;

    final keys = info == null
        ? const <String>[]
        : _sortedKeys(info.seasons.keys);
    final resume = info == null ? null : _resumeEpisode(info);
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

    final similar = _similarSeries(
      ref.watch(seriesAllListProvider).valueOrNull,
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
          onTap: () =>
              _playEpisode(info!, resume.$1, start: resume.$2.position),
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

    return _DetailsPage(
      nav: this,
      title: s?.name.isNotEmpty == true && s!.name != 'Unknown Series'
          ? s.name
          : series.name,
      backdrop: _firstHttp([s?.backdropPath, series.backdropPath, s?.cover]) ??
          series.cover,
      poster: _firstHttp([s?.cover, series.cover]),
      meta: [
        ?year,
        if (rating10 > 0) '★ ${rating10.toStringAsFixed(1)}',
        if (seasonCount > 0)
          '$seasonCount Season${seasonCount == 1 ? '' : 's'}',
      ],
      badges: [...langs.take(3)],
      genres: s?.genre ?? series.genre,
      synopsis: (s?.plot?.isNotEmpty == true ? s!.plot : null) ?? series.plot,
      loading: false,
      actions: actions,
      about: [
        ('Cast', s?.cast ?? series.cast),
        ('Director', s?.director ?? series.director),
        ('Genres', s?.genre ?? series.genre),
        ('Released', s?.releaseDate ?? series.releaseDate),
        ('Audio', langs.isEmpty ? null : langs.join(', ')),
      ],
      middle: [
        _SectionTitle(
          'Episodes',
          trailing: episodes.isEmpty ? null : '${episodes.length} episodes',
        ),
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
            SliverToBoxAdapter(child: _seasonChips(keys, info!)),
          if (meta?.overview?.isNotEmpty == true &&
              meta!.overview != (s?.plot ?? series.plot))
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(_pad(context), 0, _pad(context), 12),
                child: Text(
                  meta.overview!,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    height: 1.45,
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
                return _EpisodeRow(
                  key: ValueKey('ep_${ep.id}'),
                  episode: ep,
                  fallbackImage:
                      meta?.cover ??
                      _firstHttp([s?.backdropPath, series.backdropPath]) ??
                      s?.cover ??
                      series.cover,
                  resume: _Resume.of(ep.id),
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
                  onPlay: () {
                    final r = _Resume.of(ep.id);
                    _playEpisode(info!, ep, start: r?.position ?? 0);
                  },
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
            onTap: () =>
                context.pushReplacement('/series-details', extra: x),
          ),
      ],
    );
  }

  Widget _seasonChips(List<String> keys, SeriesInfo info) {
    return SizedBox(
      height: 52,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: _pad(context) - 4),
        itemCount: keys.length,
        itemBuilder: (_, i) {
          final k = keys[i];
          final sel = k == _season;
          final name = info.seasonMeta[k]?.name;
          final label = name != null && name.isNotEmpty ? name : 'Season $k';
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 6),
            child: TvFocusable(
              focusNode: _seasonNode(k),
              onActivate: () => setState(() => _season = k),
              onArrowKey: arrows(
                up: () => lastAction,
                down: () => _epCount > 0
                    ? _epNode(0)
                    : (similarCount > 0 ? similarNode(0) : null),
                left: () => i > 0 ? _seasonNode(keys[i - 1]) : null,
                right: () => i + 1 < keys.length ? _seasonNode(keys[i + 1]) : null,
              ),
              builder: (focused, _) => _Hover(
                builder: (hover) => AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: sel
                        ? Colors.white
                        : (focused || hover)
                        ? Colors.white.withValues(alpha: 0.16)
                        : Colors.white.withValues(alpha: 0.07),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: focused
                          ? (sel ? AppTheme.primary : Colors.white)
                          : Colors.transparent,
                      width: 2.5,
                    ),
                  ),
                  child: Text(
                    label,
                    style: TextStyle(
                      color: sel ? Colors.black : AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: sel ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  List<Series> _similarSeries(List<Series>? all) {
    if (all == null || series.categoryId == null) return const [];
    final out = <Series>[];
    for (final x in all) {
      if (x.categoryId == series.categoryId && x.seriesId != series.seriesId) {
        out.add(x);
        if (out.length >= 24) break;
      }
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Page layout
// ─────────────────────────────────────────────────────────────────────────────
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

double _pad(BuildContext context) {
  final w = Responsive.of(context).width;
  return w < 640 ? 16 : (w < 1280 ? 32 : 48);
}

class _DetailsPage extends StatelessWidget {
  final _DetailsNav nav;
  final String title;
  final String? originalTitle;
  final String? backdrop;
  final String? poster;
  final List<String> meta;
  final List<String> badges;
  final String? genres;
  final String? synopsis;
  final bool loading;
  final VoidCallback? error;
  final List<_Action> actions;
  final List<(String, String?)> about;
  final List<Widget> middle; // slivers between hero and About
  final List<_SimilarItem> similar;

  const _DetailsPage({
    required this.nav,
    required this.title,
    this.originalTitle,
    required this.backdrop,
    required this.poster,
    required this.meta,
    required this.badges,
    required this.genres,
    required this.synopsis,
    required this.loading,
    this.error,
    required this.actions,
    required this.about,
    this.middle = const [],
    required this.similar,
  });

  @override
  Widget build(BuildContext context) {
    final r = Responsive.of(context);
    final narrow = r.width < 720 || r.height > r.width;
    nav.narrowLayout = narrow;
    nav.actionCount = actions.length;
    nav.stackedActions = narrow
        ? actions.where((a) => a.primary || a.icon == Icons.replay_rounded).length
        : 0;

    final aboutRows = about
        .where((e) => e.$2 != null && e.$2!.trim().isNotEmpty)
        .toList();

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        controller: nav.scroll,
        slivers: [
          SliverToBoxAdapter(
            child: narrow ? _narrowHero(context) : _wideHero(context, r),
          ),
          if (loading)
            const SliverToBoxAdapter(child: _Loading())
          else if (error != null)
            SliverToBoxAdapter(child: _ErrorBox(onRetry: error!)),
          ...middle,
          if (aboutRows.isNotEmpty || (synopsis?.isNotEmpty ?? false)) ...[
            _SectionTitle('About $title'),
            SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: _pad(context)),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (synopsis?.isNotEmpty ?? false) ...[
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 900),
                        child: Text(
                          synopsis!,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13.5,
                            height: 1.55,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                    ],
                    for (final row in aboutRows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxWidth: 900),
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: '${row.$1}:  ',
                                  style: const TextStyle(
                                    color: AppTheme.textMuted,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                TextSpan(
                                  text: row.$2!.trim(),
                                  style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                  ),
                                ),
                              ],
                            ),
                            style: const TextStyle(fontSize: 13, height: 1.4),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
          if (similar.isNotEmpty) ...[
            const _SectionTitle('More Like This'),
            SliverToBoxAdapter(child: _similarRow(context, narrow)),
          ],
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  // ── Wide (TV / desktop / tablet landscape) ──────────────────────────────
  Widget _wideHero(BuildContext context, Responsive r) {
    final h = (r.height * 0.86).clamp(360.0, 820.0);
    final pad = _pad(context);
    final posterW = (h * 0.34).clamp(120.0, 230.0);
    return SizedBox(
      height: h,
      child: Stack(
        fit: StackFit.expand,
        children: [
          Positioned(
            top: 0,
            right: 0,
            bottom: 0,
            width: r.width * 0.74,
            child: _backdropImage(),
          ),
          // Fade the backdrop into the page: from the left and the bottom.
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.centerLeft,
                end: Alignment.centerRight,
                colors: [
                  AppTheme.background,
                  AppTheme.background,
                  Color(0xCC0A0C14),
                  Color(0x000A0C14),
                ],
                stops: [0.0, 0.26, 0.48, 0.78],
              ),
            ),
          ),
          const DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0x660A0C14),
                  Color(0x000A0C14),
                  Color(0x000A0C14),
                  AppTheme.background,
                ],
                stops: [0.0, 0.18, 0.62, 1.0],
              ),
            ),
          ),
          Positioned(
            top: 16,
            left: pad - 8,
            child: SafeArea(child: _BackButton(nav: nav)),
          ),
          Positioned(
            left: pad,
            right: r.width * 0.12,
            bottom: 20,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _Poster(url: poster, width: posterW),
                SizedBox(width: pad * 0.8),
                Expanded(
                  child: _HeroInfo(
                    title: title,
                    originalTitle: originalTitle,
                    meta: meta,
                    badges: badges,
                    genres: genres,
                    synopsis: synopsis,
                    big: true,
                    actions: _wideActions(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _wideActions() => Wrap(
    spacing: 10,
    runSpacing: 10,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: [
      for (var i = 0; i < actions.length; i++)
        _ActionButton(
          action: actions[i],
          focusNode: nav.actionNode(i),
          autofocus: i == 0,
          onArrowKey: nav.actionArrows(i),
          compact: false,
        ),
    ],
  );

  // ── Narrow (phones / portrait) ──────────────────────────────────────────
  Widget _narrowHero(BuildContext context) {
    final pad = _pad(context);
    final stacked = nav.stackedActions;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 16 / 10,
          child: Stack(
            fit: StackFit.expand,
            children: [
              _backdropImage(),
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Color(0x990A0C14),
                      Color(0x000A0C14),
                      AppTheme.background,
                    ],
                    stops: [0.0, 0.35, 1.0],
                  ),
                ),
              ),
              Positioned(
                top: 4,
                left: 4,
                child: SafeArea(child: _BackButton(nav: nav)),
              ),
              Positioned(
                left: pad,
                bottom: 0,
                child: _Poster(url: poster, width: 92),
              ),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.fromLTRB(pad, 12, pad, 0),
          child: _HeroInfo(
            title: title,
            originalTitle: originalTitle,
            meta: meta,
            badges: badges,
            genres: genres,
            synopsis: synopsis,
            big: false,
            actions: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < stacked; i++)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _ActionButton(
                      action: actions[i],
                      focusNode: nav.actionNode(i),
                      autofocus: i == 0,
                      onArrowKey: nav.actionArrows(i),
                      compact: false,
                      expand: true,
                    ),
                  ),
                if (actions.length > stacked)
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      for (var i = stacked; i < actions.length; i++)
                        _ActionButton(
                          action: actions[i],
                          focusNode: nav.actionNode(i),
                          autofocus: i == 0,
                          onArrowKey: nav.actionArrows(i),
                          compact: true,
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _backdropImage() => backdrop == null
      ? const ColoredBox(color: AppTheme.surface)
      : AppNetworkImage(
          url: backdrop,
          fit: BoxFit.cover,
          fallback: const ColoredBox(color: AppTheme.surface),
        );

  Widget _similarRow(BuildContext context, bool narrow) {
    final w = narrow ? 108.0 : 138.0;
    return SizedBox(
      height: w * 1.5 + 34,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.symmetric(horizontal: _pad(context) - 6),
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
                            borderRadius: BorderRadius.circular(8),
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
                                  child: _Chip('★ ${it.rating.toStringAsFixed(1)}'),
                                ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        it.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: focused
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: 12,
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
  final String title;
  final String? originalTitle;
  final List<String> meta;
  final List<String> badges;
  final String? genres;
  final String? synopsis;
  final bool big;
  final Widget actions;

  const _HeroInfo({
    required this.title,
    required this.originalTitle,
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
        .join('  ·  ');
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            color: Colors.white,
            fontSize: big ? 32 : 22,
            fontWeight: FontWeight.w800,
            height: 1.15,
            shadows: const [Shadow(color: Colors.black54, blurRadius: 12)],
          ),
        ),
        if (originalTitle != null &&
            originalTitle!.isNotEmpty &&
            originalTitle != title)
          Padding(
            padding: const EdgeInsets.only(top: 2),
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
        const SizedBox(height: 10),
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            for (final m in meta)
              Text(
                m,
                style: TextStyle(
                  color: m.startsWith('★')
                      ? const Color(0xFFFFC94D)
                      : AppTheme.textPrimary.withValues(alpha: 0.85),
                  fontSize: big ? 14 : 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            for (final b in badges) _Chip(b, outlined: true),
          ],
        ),
        if (g != null && g.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            g,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ],
        SizedBox(height: big ? 18 : 14),
        actions,
        if (synopsis != null && synopsis!.trim().isNotEmpty) ...[
          SizedBox(height: big ? 16 : 12),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 680),
            child: Text(
              synopsis!.trim(),
              maxLines: big ? 3 : 4,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: AppTheme.textPrimary.withValues(alpha: 0.8),
                fontSize: big ? 14 : 13,
                height: 1.5,
              ),
            ),
          ),
        ],
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

  const _ActionButton({
    required this.action,
    required this.focusNode,
    required this.autofocus,
    required this.onArrowKey,
    required this.compact,
    this.expand = false,
  });

  @override
  Widget build(BuildContext context) {
    final a = action;
    return TvFocusable(
      focusNode: focusNode,
      autofocus: autofocus,
      onActivate: a.onTap,
      onArrowKey: onArrowKey,
      builder: (focused, pressed) => _Hover(
        builder: (hover) {
          if (compact) {
            return AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 84,
              padding: const EdgeInsets.symmetric(vertical: 8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                color: focused || hover
                    ? Colors.white.withValues(alpha: 0.12)
                    : Colors.transparent,
                border: Border.all(
                  color: focused ? Colors.white : Colors.transparent,
                  width: 2,
                ),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    a.icon,
                    size: 24,
                    color: a.active ? AppTheme.error : Colors.white,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    a.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            );
          }
          final primary = a.primary;
          final enabled = a.onTap != null;
          final bg = primary
              ? (focused ? Colors.white : Colors.white.withValues(alpha: 0.92))
              : (focused
                    ? Colors.white.withValues(alpha: 0.28)
                    : hover
                    ? Colors.white.withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.12));
          final fg = primary ? Colors.black : Colors.white;
          final iconColor = a.active ? AppTheme.error : fg;
          return AnimatedScale(
            scale: focused ? 1.05 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              constraints: BoxConstraints(minWidth: expand ? double.infinity : 0),
              decoration: BoxDecoration(
                color: enabled ? bg : bg.withValues(alpha: 0.4),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: focused
                      ? (primary ? AppTheme.primary : Colors.white)
                      : Colors.transparent,
                  width: 2.5,
                ),
                boxShadow: focused
                    ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 14,
                          offset: const Offset(0, 4),
                        ),
                      ]
                    : null,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: primary ? 22 : 16,
                      vertical: 10,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(a.icon, size: primary ? 26 : 20, color: iconColor),
                        const SizedBox(width: 8),
                        Flexible(
                          child: Text(
                            a.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: fg,
                              fontSize: primary ? 15 : 14,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                        if (a.caption != null) ...[
                          const SizedBox(width: 10),
                          Text(
                            a.caption!,
                            style: TextStyle(
                              color: fg.withValues(alpha: 0.6),
                              fontSize: 12,
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
                      minHeight: 3,
                      backgroundColor: Colors.black12,
                      color: AppTheme.error,
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
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
    builder: (focused, _) => _Hover(
      builder: (hover) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.all(9),
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: focused || hover ? 0.7 : 0.45),
          border: Border.all(
            color: focused ? Colors.white : Colors.transparent,
            width: 2,
          ),
        ),
        child: const Icon(Icons.arrow_back_rounded, color: Colors.white),
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
      borderRadius: BorderRadius.circular(10),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.55),
          blurRadius: 24,
          offset: const Offset(0, 10),
        ),
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
    final thumbW = narrow ? 128.0 : 210.0;
    final title = _episodeTitle(ep);
    final dur = ep.formattedDuration;
    return Padding(
      padding: EdgeInsets.fromLTRB(pad - 8, 2, pad - 8, 2),
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
                builder: (hover) => AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: focused
                        ? Colors.white.withValues(alpha: 0.10)
                        : hover
                        ? Colors.white.withValues(alpha: 0.05)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: focused ? Colors.white : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _EpisodeThumb(
                        url: ep.image ?? fallbackImage,
                        width: thumbW,
                        progress: resume?.progress,
                        showPlay: focused || hover,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    '${ep.episodeNum}. $title',
                                    maxLines: narrow ? 2 : 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 14.5,
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
                                padding: const EdgeInsets.only(top: 3),
                                child: Text(
                                  resume!.leftLabel,
                                  style: const TextStyle(
                                    color: AppTheme.error,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            if (ep.plot != null && !narrow) ...[
                              const SizedBox(height: 6),
                              Text(
                                ep.plot!,
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 12.5,
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
              padding: const EdgeInsets.only(left: 6),
              child: TvFocusable(
                focusNode: downloadFocus,
                onActivate: onDownload,
                onArrowKey: onDownloadArrowKey,
                builder: (focused, _) => _Hover(
                  builder: (hover) => Tooltip(
                    message: 'Download episode',
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.all(10),
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
    borderRadius: BorderRadius.circular(6),
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
          AnimatedOpacity(
            opacity: showPlay ? 1 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: ColoredBox(
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
                color: AppTheme.error,
              ),
            ),
        ],
      ),
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  final String text;
  final String? trailing;
  const _SectionTitle(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => SliverToBoxAdapter(
    child: Padding(
      padding: EdgeInsets.fromLTRB(_pad(context), 22, _pad(context), 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Flexible(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 19,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (trailing != null) ...[
            const SizedBox(width: 12),
            Text(
              trailing!,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    ),
  );
}

class _Chip extends StatelessWidget {
  final String text;
  final bool outlined;
  const _Chip(this.text, {this.outlined = false});

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: outlined ? Colors.transparent : Colors.black.withValues(alpha: 0.65),
      borderRadius: BorderRadius.circular(4),
      border: outlined
          ? Border.all(color: Colors.white.withValues(alpha: 0.5))
          : null,
    ),
    child: Text(
      text,
      style: TextStyle(
        color: outlined ? AppTheme.textPrimary : const Color(0xFFFFC94D),
        fontSize: 11,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

class _PillButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool focused;
  const _PillButton({
    required this.icon,
    required this.label,
    required this.focused,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: focused ? 0.25 : 0.12),
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: focused ? Colors.white : Colors.transparent),
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: Colors.white),
        const SizedBox(width: 8),
        Text(label, style: const TextStyle(color: Colors.white)),
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
      child: CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2),
    ),
  );
}

class _ErrorBox extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorBox({required this.onRetry});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(24),
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
          builder: (focused, _) => _PillButton(
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

  static _Resume? of(String id) {
    final m = BehaviorService.instance.getPosition(id);
    if (m == null) return null;
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
