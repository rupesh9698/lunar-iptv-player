import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/launcher_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/series_provider.dart';

class SeriesDetailPanel extends ConsumerStatefulWidget {
  final double? width;
  final bool isMobile;

  const SeriesDetailPanel({super.key, this.width, this.isMobile = false});

  @override
  ConsumerState<SeriesDetailPanel> createState() => _SeriesDetailPanelState();

  static String _langCodeToName(String? code) {
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
      'pun': 'Punjabi',
      'guj': 'Gujarati',
      'urd': 'Urdu',
      'ara': 'Arabic',
      'fre': 'French',
      'ger': 'German',
      'spa': 'Spanish',
      'por': 'Portuguese',
      'rus': 'Russian',
      'zho': 'Chinese',
      'jpn': 'Japanese',
      'kor': 'Korean',
      'ita': 'Italian',
      'dut': 'Dutch',
      'tur': 'Turkish',
      'und': 'Unknown',
    };
    return langs[code.toLowerCase()] ?? code.toUpperCase();
  }
}

class _SeriesDetailPanelState extends ConsumerState<SeriesDetailPanel> {
  String? _selectedSeason;
  String? _lastSeriesId;

  List<String> _sortedSeasonKeys(Map<String, List<Episode>> seasons) =>
      seasons.keys.toList()..sort(
        (a, b) => (int.tryParse(a) ?? 0).compareTo(int.tryParse(b) ?? 0),
      );

  void _initSeason(String seriesId, Map<String, List<Episode>> seasons) {
    if (_lastSeriesId == seriesId) return;
    _lastSeriesId = seriesId;
    final keys = _sortedSeasonKeys(seasons);
    if (mounted) {
      setState(() => _selectedSeason = keys.isNotEmpty ? keys.first : null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final series = ref.watch(selectedSeriesStreamProvider);

    if (series == null) {
      return _buildEmptyState();
    }

    final infoAsync = ref.watch(seriesInfoProvider(series.seriesId));

    final content = infoAsync.when(
      loading: () => _buildLoading(),
      error: (e, _) => _buildError(series, e.toString()),
      data: (info) {
        _initSeason(series.seriesId, info.seasons);
        return _buildFull(context, ref, series, info);
      },
    );

    if (widget.isMobile) {
      return DraggableScrollableSheet(
        initialChildSize: 0.92,
        minChildSize: 0.5,
        maxChildSize: 0.97,
        builder: (_, ctrl) => Container(
          decoration: const BoxDecoration(
            color: AppTheme.background,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: content,
        ),
      );
    }

    return SizedBox(
      width: widget.width ?? 360,
      child: Container(color: AppTheme.surface, child: content),
    );
  }

  // ── Empty ─────────────────────────────────────────────────────────
  Widget _buildEmptyState() {
    return SizedBox(
      width: widget.width ?? 360,
      child: Container(
        color: AppTheme.surface,
        child: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.theaters_outlined,
                color: AppTheme.textMuted,
                size: 52,
              ),
              SizedBox(height: 12),
              Text(
                'Select a series',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Loading ───────────────────────────────────────────────────────
  Widget _buildLoading() {
    return const Center(
      child: CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2),
    );
  }

  // ── Error ─────────────────────────────────────────────────────────
  Widget _buildError(Series series, String error) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
            const SizedBox(height: 12),
            Text(
              series.name,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Could not load episodes',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            TextButton.icon(
              onPressed: () =>
                  ref.invalidate(seriesInfoProvider(series.seriesId)),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Full content ──────────────────────────────────────────────────
  Widget _buildFull(
    BuildContext context,
    WidgetRef ref,
    Series series,
    SeriesInfo info,
  ) {
    final isFav = ref.watch(seriesFavoritesProvider).contains(series.seriesId);
    final seasons = info.seasons;
    final keys = _sortedSeasonKeys(seasons);
    final curSeason = _selectedSeason ?? (keys.isNotEmpty ? keys.first : null);
    // final episodes   = curSeason != null ? (seasons[curSeason] ?? []) : [];
    final List<Episode> episodes = curSeason != null
        ? (seasons[curSeason] ?? <Episode>[])
        : <Episode>[];

    return CustomScrollView(
      slivers: [
        // ── Backdrop hero ────────────────────────────────────────
        SliverToBoxAdapter(child: _buildHero(series, info, isFav, ref)),

        // ── Meta info ────────────────────────────────────────────
        SliverToBoxAdapter(child: _buildMeta(series, info)),

        // ── Plot ─────────────────────────────────────────────────
        if ((info.series.plot ?? series.plot ?? '').isNotEmpty)
          SliverToBoxAdapter(
            child: _buildPlot(info.series.plot ?? series.plot ?? ''),
          ),

        // ── Available Languages ───────────────────────────────────────────────────
        SliverToBoxAdapter(child: _buildLanguages(seasons)),

        // ── Cast / Director ──────────────────────────────────────
        SliverToBoxAdapter(child: _buildCastDirector(series, info)),

        // ── Action buttons ───────────────────────────────────────
        SliverToBoxAdapter(
          child: _buildActions(context, ref, series, info, episodes, isFav),
        ),

        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Divider(color: AppTheme.divider, height: 1),
          ),
        ),

        // ── Season selector ──────────────────────────────────────
        if (keys.isNotEmpty)
          SliverToBoxAdapter(child: _buildSeasonSelector(keys, curSeason)),

        // ── Episodes count ───────────────────────────────────────
        if (episodes.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                '${episodes.length} Episode${episodes.length != 1 ? 's' : ''}',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),

        // ── Episode list ──────────────────────────────────────────
        SliverList(
          delegate: SliverChildBuilderDelegate((ctx, i) {
            final ep = episodes[i];
            return _EpisodeTile(
              key: ValueKey('ep_${ep.id}'),
              episode: ep,
              seriesName: series.name,
              seriesCover: series.cover,
              season: curSeason ?? '1',
              onPlay: () => _playEpisode(context, ref, info, ep),
            );
          }, childCount: episodes.length),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: 24)),
      ],
    );
  }

  // ── Hero Section ─────────────────────────────────────────────────
  Widget _buildHero(Series series, SeriesInfo info, bool isFav, WidgetRef ref) {
    final backdrop =
        _firstUrl(info.series.backdropPath) ??
        _firstUrl(series.backdropPath) ??
        series.cover;
    final cover = info.series.cover ?? series.cover;

    return Stack(
      children: [
        // Backdrop
        SizedBox(
          height: 200,
          width: double.infinity,
          child: backdrop != null && backdrop.isNotEmpty
              ? Image.network(
                  backdrop,
                  fit: BoxFit.cover,
                  errorBuilder: (_, _, _) =>
                      Container(color: AppTheme.surfaceVariant),
                )
              : Container(color: AppTheme.surfaceVariant),
        ),

        // Gradient
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  Colors.transparent,
                  AppTheme.surface.withValues(alpha: 0.7),
                  AppTheme.surface,
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                stops: const [0.0, 0.65, 1.0],
              ),
            ),
          ),
        ),

        // Mobile drag handle
        if (widget.isMobile)
          Positioned(
            top: 10,
            left: 0,
            right: 0,
            child: Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white38,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),

        // Close button (non-mobile)
        if (!widget.isMobile)
          Positioned(
            top: 8,
            right: 8,
            child: GestureDetector(
              onTap: () =>
                  ref.read(selectedSeriesStreamProvider.notifier).state = null,
              child: Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.close, color: Colors.white, size: 16),
              ),
            ),
          ),

        // Bottom: poster + title
        Positioned(
          bottom: 0,
          left: 0,
          right: 0,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // Cover poster
                if (cover != null && cover.isNotEmpty)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      cover,
                      width: 60,
                      height: 88,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => const SizedBox.shrink(),
                    ),
                  ),

                const SizedBox(width: 12),

                // Title + meta
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        info.series.name.isNotEmpty
                            ? info.series.name
                            : series.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          shadows: [Shadow(color: Colors.black, blurRadius: 8)],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 4),
                      // Rating + year
                      Row(
                        children: [
                          if ((series.ratingValue) > 0) ...[
                            const Icon(
                              Icons.star_rounded,
                              color: Colors.amber,
                              size: 14,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              series.ratingValue.toStringAsFixed(1),
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                          ],
                          if (series.releaseDate != null &&
                              series.releaseDate!.length >= 4)
                            Text(
                              series.releaseDate!.substring(0, 4),
                              style: const TextStyle(
                                color: Colors.white60,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Meta (genre chips) ────────────────────────────────────────────
  Widget _buildMeta(Series series, SeriesInfo info) {
    final genre = info.series.genre ?? series.genre;
    if (genre == null || genre.isEmpty) return const SizedBox.shrink();

    final genres = genre
        .split(',')
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .take(4)
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: genres
            .map(
              (g) => Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: AppTheme.accent.withValues(alpha: 0.3),
                  ),
                ),
                child: Text(
                  g,
                  style: const TextStyle(
                    color: AppTheme.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            )
            .toList(),
      ),
    );
  }

  // ── Plot ─────────────────────────────────────────────────────────
  Widget _buildPlot(String plot) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SYNOPSIS',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            plot,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
            maxLines: 4,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _buildLanguages(Map<String, List<Episode>> seasons) {
    // Collect unique audio languages across all episodes
    final langs = <String>{};
    for (final episodes in seasons.values) {
      for (final ep in episodes) {
        if (ep.audioLanguage != null && ep.audioLanguage!.isNotEmpty) {
          langs.add(ep.audioLanguage!);
        }
      }
    }
    if (langs.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'AVAILABLE LANGUAGES',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: langs.map((code) {
              final name = SeriesDetailPanel._langCodeToName(code);
              return Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.3),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.language,
                      size: 11,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  // ── Cast / Director ───────────────────────────────────────────────
  Widget _buildCastDirector(Series series, SeriesInfo info) {
    final cast = info.series.cast ?? series.cast;
    final director = info.series.director ?? series.director;

    if ((cast == null || cast.isEmpty) &&
        (director == null || director.isEmpty)) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (director != null && director.isNotEmpty)
            _InfoLine('Director', director),
          if (cast != null && cast.isNotEmpty)
            _InfoLine('Cast', cast, maxLines: 2),
        ],
      ),
    );
  }

  // ── Action buttons ────────────────────────────────────────────────
  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    Series series,
    SeriesInfo info,
    List<Episode> episodes,
    bool isFav,
  ) {
    if (episodes.isEmpty) return const SizedBox.shrink();
    final first = episodes.first;

    // Prefer fetched trailer, fallback to list data
    final trailerKey = info.series.youtubeTrailer?.isNotEmpty == true
        ? info.series.youtubeTrailer
        : series.youtubeTrailer;

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 14, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Watch + Favourite row
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: () => _playEpisode(context, ref, info, first),
                  icon: const Icon(Icons.play_arrow, size: 20),
                  label: Text(
                    'Watch S${first.season}E'
                    '${first.episodeNum.padLeft(2, '0')}',
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Favourite button (moved from hero)
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                decoration: BoxDecoration(
                  color: isFav
                      ? AppTheme.error.withValues(alpha: 0.12)
                      : AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isFav
                        ? AppTheme.error.withValues(alpha: 0.4)
                        : AppTheme.divider,
                  ),
                ),
                child: IconButton(
                  onPressed: () => ref
                      .read(seriesFavoritesProvider.notifier)
                      .toggle(series.seriesId),
                  tooltip: isFav
                      ? 'Remove from Favourites'
                      : 'Add to Favourites',
                  icon: Icon(
                    isFav ? Icons.favorite : Icons.favorite_border,
                    color: isFav ? AppTheme.error : AppTheme.textMuted,
                    size: 22,
                  ),
                  padding: const EdgeInsets.all(10),
                ),
              ),
            ],
          ),
          // Trailer button
          if (trailerKey != null && trailerKey.isNotEmpty) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => launchYouTubeTrailer(context, trailerKey),
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('Trailer'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.textSecondary,
                side: const BorderSide(color: AppTheme.divider),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Season Selector ───────────────────────────────────────────────
  Widget _buildSeasonSelector(List<String> keys, String? current) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SEASONS',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: keys.map((k) {
                final isSel = k == current;
                return GestureDetector(
                  onTap: () => setState(() => _selectedSeason = k),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.only(right: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isSel ? AppTheme.primary : AppTheme.surfaceVariant,
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      'Season $k',
                      style: TextStyle(
                        color: isSel ? Colors.white : AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: isSel ? FontWeight.w700 : FontWeight.w400,
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }

  // ── Play Episode ──────────────────────────────────────────────────
  void _playEpisode(
    BuildContext context,
    WidgetRef ref,
    SeriesInfo info,
    Episode ep,
  ) {
    final service = ref.read(xtreamServiceProvider);
    if (service == null) return;

    // Always use selected series state for the correct persisted seriesId.
    // info.series.seriesId can be empty if API response lacks series_id in info block.
    final selectedSeries = ref.read(selectedSeriesStreamProvider);
    final seriesId = (selectedSeries?.seriesId.isNotEmpty == true)
        ? selectedSeries!.seriesId
        : info.series.seriesId;

    if (seriesId.isNotEmpty) {
      ref.read(recentlyViewedSeriesProvider.notifier).add(seriesId);
    }

    final url = service.getSeriesUrl(ep.id, ep.containerExtension ?? 'mkv');
    final title =
        '${info.series.name.isNotEmpty ? info.series.name : (selectedSeries?.name ?? '')} '
        '· S${ep.season}E${ep.episodeNum.padLeft(2, '0')}'
        '${ep.title.isNotEmpty ? ' · ${ep.title}' : ''}';

    context.push(
      '/player',
      extra: {
        'title': title,
        'url': url,
        'imageUrl': info.series.cover ?? selectedSeries?.cover,
        'type': 'series',
        'id': ep.id,
      },
    );
  }

  static String? _firstUrl(dynamic raw) {
    if (raw == null) return null;
    if (raw is String && raw.isNotEmpty) return raw;
    if (raw is List && raw.isNotEmpty) return raw.first.toString();
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EPISODE TILE
// ─────────────────────────────────────────────────────────────────────────────
class _EpisodeTile extends StatefulWidget {
  final Episode episode;
  final String seriesName;
  final String? seriesCover;
  final String season;
  final VoidCallback onPlay;

  const _EpisodeTile({
    super.key,
    required this.episode,
    required this.seriesName,
    required this.seriesCover,
    required this.season,
    required this.onPlay,
  });

  @override
  State<_EpisodeTile> createState() => _EpisodeTileState();
}

class _EpisodeTileState extends State<_EpisodeTile> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final ep = widget.episode;
    final epNum = ep.episodeNum.padLeft(2, '0');
    // Clean title: "Farzi - S01E01 - Episode 1" → "Episode 1"
    final title = _cleanTitle(ep.title, ep.episodeNum);
    final dur = ep.formattedDuration;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onPlay,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          color: _hovering
              ? AppTheme.primary.withValues(alpha: 0.08)
              : Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          child: Row(
            children: [
              // Episode number badge
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: _hovering
                      ? AppTheme.primary.withValues(alpha: 0.15)
                      : AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Text(
                  'E$epNum',
                  style: TextStyle(
                    color: _hovering ? AppTheme.primary : AppTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Title + duration
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: _hovering
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight: _hovering
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (dur.isNotEmpty)
                      Text(
                        dur,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),

              // Play icon
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: _hovering ? AppTheme.primary : Colors.transparent,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  Icons.play_arrow_rounded,
                  size: 18,
                  color: _hovering ? Colors.white : AppTheme.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Removes the series name prefix from episode title
  /// "Farzi - S01E01 - Episode 1" → "Episode 1"
  String _cleanTitle(String raw, String epNum) {
    // Try to extract the last part after " - "
    final parts = raw.split(' - ');
    if (parts.length >= 3) return parts.last.trim();
    if (parts.length == 2) return parts.last.trim();
    if (raw.isEmpty) return 'Episode $epNum';
    return raw;
  }
}

class _InfoLine extends StatelessWidget {
  final String label;
  final String value;
  final int maxLines;

  const _InfoLine(this.label, this.value, {this.maxLines = 1});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: RichText(
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        text: TextSpan(
          children: [
            TextSpan(
              text: '$label: ',
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            TextSpan(
              text: value,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
