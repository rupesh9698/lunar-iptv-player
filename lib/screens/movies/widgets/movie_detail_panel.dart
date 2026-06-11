import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/widgets/auto_fav_banner.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/launcher_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/movies_provider.dart';
import '../../../widgets/app_network_image.dart';

class MovieDetailPanel extends ConsumerWidget {
  final VodStream movie;

  const MovieDetailPanel({super.key, required this.movie});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch VodInfo — load details for selected movie
    final vodInfoAsync = ref.watch(vodInfoProvider(movie.streamId));

    return Container(
      color: AppTheme.surface,
      child: Column(
        children: [
          // Close button row
          Row(
            children: [
              const Spacer(),
              _FocusableCloseButton(
                onTap: () =>
                    ref.read(selectedVodStreamProvider.notifier).state = null,
              ),
            ],
          ),

          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── POSTER — NEVER disappears, uses valueOrNull ──────────
                  // Fix Bug 9: valueOrNull means poster shows immediately
                  // from movie.streamIcon, updates to better image when loaded
                  _buildPoster(movie, vodInfoAsync.valueOrNull),

                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Title
                        Text(
                          vodInfoAsync.valueOrNull?.info?.name ?? movie.name,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                          ),
                        ),

                        if (vodInfoAsync.valueOrNull?.info?.oName != null &&
                            vodInfoAsync.valueOrNull!.info!.oName !=
                                vodInfoAsync.valueOrNull?.info?.name) ...[
                          const SizedBox(height: 2),
                          Text(
                            vodInfoAsync.valueOrNull!.info!.oName!,
                            style: const TextStyle(
                              color: AppTheme.textMuted,
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],

                        const SizedBox(height: 10),

                        // Rating badges row
                        _buildBadges(movie, vodInfoAsync.valueOrNull),

                        const SizedBox(height: 10),

                        // Loading shimmer for text details
                        if (vodInfoAsync.isLoading)
                          _buildLoadingShimmer()
                        else if (vodInfoAsync.hasError)
                          _buildErrorState(ref)
                        else
                          _buildDetails(
                            context,
                            ref,
                            movie,
                            vodInfoAsync.valueOrNull,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── POSTER — always shows something, never a blank loading state ────────
  Widget _buildPoster(VodStream movie, VodInfo? vodInfo) {
    // Priority: cover_big → movie_image → stream_icon (from list)
    final posterUrl = _resolveUrl([
      vodInfo?.info?.coverBig,
      vodInfo?.info?.movieImage,
      movie.streamIcon,
    ]);

    final backdropUrl = _resolveUrl([
      vodInfo?.info?.backdropPath,
      vodInfo?.info?.coverBig,
      vodInfo?.info?.movieImage,
      movie.streamIcon,
    ]);

    return Stack(
      children: [
        // Backdrop
        SizedBox(
          height: 200,
          width: double.infinity,
          child: AppNetworkImage(
            url: backdropUrl,
            fit: BoxFit.cover,
            fallback: Container(color: AppTheme.surfaceVariant),
          ),
        ),
        // Gradient
        Positioned.fill(
          child: Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.transparent,
                  AppTheme.surface.withValues(alpha: 0.5),
                  AppTheme.surface,
                ],
                stops: const [0.0, 0.6, 1.0],
              ),
            ),
          ),
        ),
        // Poster thumbnail overlay (bottom-left)
        Positioned(
          bottom: 0,
          left: 16,
          child: Container(
            width: 80,
            height: 110,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(8),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: AppNetworkImage(url: posterUrl, fit: BoxFit.cover),
            ),
          ),
        ),
      ],
    );
  }

  // ── Rating / year / duration badges ───────────────────────────────────────
  Widget _buildBadges(VodStream movie, VodInfo? vodInfo) {
    final info = vodInfo?.info;
    final rating = info?.rating ?? movie.ratingValue;
    final year =
        info?.releaseDate?.length != null && info!.releaseDate!.length >= 4
        ? info.releaseDate!.substring(0, 4)
        : null;
    final dur = info?.duration;
    final mpaa = info?.mpaaRating;
    final ext =
        vodInfo?.movieData?.containerExtension ?? movie.containerExtension;

    // Language: prefer audio tag, fallback to video tag, fallback to info.language
    final rawLang =
        info?.audioLanguage ?? info?.videoLanguage ?? info?.language;
    final langName = _langCodeToName(rawLang);

    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        if (rating > 0)
          _Badge(
            icon: Icons.star_rounded,
            label: rating.toStringAsFixed(1),
            color: Colors.amber,
          ),
        if (year != null) _Badge(label: year, color: AppTheme.textSecondary),
        if (langName.isNotEmpty)
          _Badge(
            icon: Icons.language,
            label: langName,
            color: AppTheme.primary,
          ),
        if (dur != null && dur.isNotEmpty)
          _Badge(
            icon: Icons.schedule_outlined,
            label: dur,
            color: AppTheme.textSecondary,
          ),
        if (mpaa != null && mpaa.isNotEmpty)
          _Badge(label: mpaa, color: AppTheme.accent),
        if (ext != null && ext.isNotEmpty)
          _Badge(label: ext.toUpperCase(), color: AppTheme.primary),
      ],
    );
  }

  // ── Details section (plot, cast, etc.) ────────────────────────────────────
  Widget _buildDetails(
    BuildContext context,
    WidgetRef ref,
    VodStream movie,
    VodInfo? vodInfo,
  ) {
    final info = vodInfo?.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Auto Favourite Banner ────────────────────────────────────────────────────
        if (AutoFavBanner.shouldShow(
          movie.streamId,
          ref.watch(vodFavoritesProvider),
          minViews: 5,
        ))
          AutoFavBanner(
            key: ValueKey('mfav_${movie.streamId}'),
            contentId: movie.streamId,
            contentName: movie.name,
            onAddFav: () =>
                ref.read(vodFavoritesProvider.notifier).toggle(movie.streamId),
            onDismiss: () {},
          ),
        // Genre chips
        if (info?.genre != null) ...[
          const SizedBox(height: 8),
          // ── Auto Favourite Suggestion ─────────────────────────────────────────────
          Builder(
            builder: (ctx) {
              final watchCount = BehaviorService.instance.getWatchCount(
                movie.streamId,
              );
              final alreadyFav = ref
                  .watch(vodFavoritesProvider)
                  .contains(movie.streamId);
              if (watchCount < 5 || alreadyFav) return const SizedBox.shrink();

              return Container(
                margin: const EdgeInsets.only(bottom: 12),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF7B61FF).withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: const Color(0xFF7B61FF).withValues(alpha: 0.30),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.auto_awesome,
                      color: Color(0xFF7B61FF),
                      size: 14,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        'You\'ve watched this $watchCount times — add to Favourites?',
                        style: TextStyle(
                          color: Color(0xFF7B61FF),
                          fontSize: 11,
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: () => ref
                          .read(vodFavoritesProvider.notifier)
                          .toggle(movie.streamId),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF7B61FF),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Add',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ).animate().fadeIn(duration: 300.ms);
            },
          ),
          _buildGenreChips(info!.genre!),
        ],

        // Plot
        if ((info?.plot ?? info?.description) != null) ...[
          const SizedBox(height: 12),
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
          _ExpandableText(info!.plot ?? info.description ?? ''),
        ],

        const SizedBox(height: 12),

        // Info table
        _buildInfoRow('Director', info?.director),
        _buildInfoRow('Cast', info?.cast),
        _buildInfoRow('Country', info?.country),
        _buildInfoRow('Language', info?.language),
        if (info?.bitrate != null && info!.bitrate! > 0)
          _buildInfoRow('Bitrate', '${info.bitrate} kbps'),

        const SizedBox(height: 16),

        // Action buttons
        _buildActions(context, ref, movie, vodInfo),

        const SizedBox(height: 8),
      ],
    );
  }

  Widget _buildGenreChips(String genre) {
    final genres = genre
        .split(',')
        .map((g) => g.trim())
        .where((g) => g.isNotEmpty)
        .take(4)
        .toList();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: genres
          .map(
            (g) => Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
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
    );
  }

  Widget _buildInfoRow(String label, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: RichText(
        maxLines: 2,
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

  Widget _buildActions(
    BuildContext context,
    WidgetRef ref,
    VodStream movie,
    VodInfo? vodInfo,
  ) {
    final service = ref.read(xtreamServiceProvider);
    final ext =
        vodInfo?.movieData?.containerExtension ??
        movie.containerExtension ??
        'mp4';
    final isFav = ref.watch(vodFavoritesProvider).contains(movie.streamId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            // Watch Now
            Expanded(
              child: ElevatedButton.icon(
                onPressed: service == null
                    ? null
                    : () {
                        // Record genre frequency for "For You" feature (Step 3)
                        if (vodInfo?.info?.genre != null) {
                          for (final g in vodInfo!.info!.genre!.split(',')) {
                            final trimmed = g.trim();
                            if (trimmed.isNotEmpty) {
                              BehaviorService.instance.recordGenreAccess(
                                trimmed,
                              );
                            }
                          }
                        }
                        // Start watch timer (Continue Watching)
                        BehaviorService.instance.startWatchTimer(
                          movie.streamId,
                        );

                        ref
                            .read(recentlyViewedVodProvider.notifier)
                            .add(movie.streamId);
                        final url = service.getVodUrl(movie.streamId, ext);
                        context.push(
                          '/player',
                          extra: {
                            'title': movie.name,
                            'url': url,
                            'imageUrl': movie.streamIcon,
                            'type': 'movie',
                            'id': movie.streamId,
                          },
                        );
                      },
                icon: const Icon(Icons.play_arrow_rounded, size: 22),
                label: const Text(
                  'Watch Now',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            // Favourite button
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
                    .read(vodFavoritesProvider.notifier)
                    .toggle(movie.streamId),
                tooltip: isFav ? 'Remove from Favourites' : 'Add to Favourites',
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
        const SizedBox(height: 8),
        // Download button
        if (service != null)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () {
                final url = service.getVodUrl(movie.streamId, ext);
                launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
              },
              icon: const Icon(Icons.download_outlined, size: 18),
              label: const Text('Download'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.success,
                side: const BorderSide(color: AppTheme.success),
                padding: const EdgeInsets.symmetric(vertical: 11),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        const SizedBox(height: 8),
        if (vodInfo?.info?.youtubeTrailer != null &&
            vodInfo!.info!.youtubeTrailer!.isNotEmpty)
          OutlinedButton.icon(
            onPressed: () =>
                launchYouTubeTrailer(context, vodInfo.info!.youtubeTrailer!),
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
    );
  }

  Widget _buildLoadingShimmer() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(
        4,
        (i) => Container(
          margin: const EdgeInsets.only(bottom: 10),
          height: i == 0 ? 60 : 14,
          width: i == 2 ? 150 : double.infinity,
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
    );
  }

  Widget _buildErrorState(WidgetRef ref) {
    return Column(
      children: [
        const SizedBox(height: 8),
        const Icon(
          Icons.cloud_off_outlined,
          color: AppTheme.textMuted,
          size: 28,
        ),
        const SizedBox(height: 8),
        const Text(
          'Could not load details',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: () => ref.invalidate(vodInfoProvider(movie.streamId)),
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('Retry'),
        ),
      ],
    );
  }

  static String? _resolveUrl(List<String?> urls) {
    for (final u in urls) {
      if (u != null &&
          u.trim().isNotEmpty &&
          (u.startsWith('http://') || u.startsWith('https://'))) {
        return u.trim();
      }
    }
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BADGE WIDGET
// ─────────────────────────────────────────────────────────────────────────────
class _Badge extends StatelessWidget {
  final IconData? icon;
  final String label;
  final Color color;

  const _Badge({this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 10, color: color),
            const SizedBox(width: 3),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LANGUAGE HELPERS
// ─────────────────────────────────────────────────────────────────────────────
String _langCodeToName(String? code) {
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

// ─────────────────────────────────────────────────────────────────────────────
// EXPANDABLE TEXT
// ─────────────────────────────────────────────────────────────────────────────
class _ExpandableText extends StatefulWidget {
  final String text;
  const _ExpandableText(this.text);

  @override
  State<_ExpandableText> createState() => _ExpandableTextState();
}

class _ExpandableTextState extends State<_ExpandableText> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => setState(() => _expanded = !_expanded),
      child: AnimatedCrossFade(
        firstChild: Text(
          widget.text,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        secondChild: Text(
          widget.text,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
            height: 1.5,
          ),
        ),
        crossFadeState: _expanded
            ? CrossFadeState.showSecond
            : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 250),
      ),
    );
  }
}

class _FocusableCloseButton extends StatefulWidget {
  final VoidCallback onTap;
  const _FocusableCloseButton({required this.onTap});

  @override
  State<_FocusableCloseButton> createState() => _FocusableCloseButtonState();
}

class _FocusableCloseButtonState extends State<_FocusableCloseButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.arrowLeft) {
          FocusScope.of(context).focusInDirection(TraversalDirection.left);
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _focused
                  ? AppTheme.primary.withValues(alpha: 0.15)
                  : Colors.transparent,
              border: _focused
                  ? Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.6),
                      width: 2,
                    )
                  : null,
            ),
            child: Icon(
              Icons.close,
              color: _focused ? AppTheme.primary : AppTheme.textMuted,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}
