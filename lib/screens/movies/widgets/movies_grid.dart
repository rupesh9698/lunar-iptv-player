import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/movies_provider.dart';
import '../../player/player_screen.dart';

class MoviesGrid extends ConsumerWidget {
  final bool isMobile;
  final ValueChanged<VodStream>? onMovieTap;

  const MoviesGrid({super.key, this.isMobile = false, this.onMovieTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamsAsync = ref.watch(sortedVodStreamsProvider);
    final selected     = ref.watch(selectedVodStreamProvider);

    return Container(
      color: AppTheme.background,
      child: streamsAsync.when(
        data: (streams) {
          if (streams.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.movie_outlined,
                      color: AppTheme.textMuted, size: 56),
                  SizedBox(height: 16),
                  Text(
                    'No movies found',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 16),
                  ),
                  SizedBox(height: 8),
                  Text(
                    'Try a different category or search',
                    style: TextStyle(
                        color: AppTheme.textMuted, fontSize: 13),
                  ),
                ],
              ),
            );
          }

          return LayoutBuilder(builder: (ctx, constraints) {
            final cols = _columns(constraints.maxWidth, isMobile);
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2 / 3, // poster ratio
              ),
              itemCount: streams.length,
              itemBuilder: (_, i) {
                final movie = streams[i];
                return _MoviePosterCard(
                  key: ValueKey(movie.streamId),
                  movie: movie,
                  isSelected:
                  selected?.streamId == movie.streamId,
                  isMobile: isMobile,
                  onTap: onMovieTap,
                  index: i,
                );
              },
            );
          });
        },
        loading: () => GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 4,
            mainAxisSpacing: 12,
            crossAxisSpacing: 12,
            childAspectRatio: 2 / 3,
          ),
          itemCount: 20,
          itemBuilder: (_, _) => _ShimmerCard(),
        ),
        error: (e, _) => Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.error_outline,
                  color: AppTheme.error, size: 48),
              const SizedBox(height: 16),
              const Text(
                'Failed to load movies',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () => ref.invalidate(vodStreamsProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  int _columns(double width, bool isMobile) {
    if (isMobile) {
      return width > 500 ? 3 : 2;
    }
    if (width > 1400) return 7;
    if (width > 1100) return 6;
    if (width > 850)  return 5;
    if (width > 600)  return 4;
    return 3;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOVIE POSTER CARD
// ─────────────────────────────────────────────────────────────────────────────
class _MoviePosterCard extends ConsumerStatefulWidget {
  final VodStream movie;
  final bool isSelected;
  final bool isMobile;
  final ValueChanged<VodStream>? onTap;
  final int index;

  const _MoviePosterCard({
    super.key,
    required this.movie,
    required this.isSelected,
    required this.isMobile,
    required this.onTap,
    required this.index,
  });

  @override
  ConsumerState<_MoviePosterCard> createState() =>
      _MoviePosterCardState();
}

class _MoviePosterCardState
    extends ConsumerState<_MoviePosterCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isFav =
    ref.watch(vodFavoritesProvider).contains(widget.movie.streamId);

    return AnimatedScale(
      scale: _hovering || widget.isSelected ? 1.03 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: _handleTap,
          onDoubleTap: _playDirect,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 200),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              boxShadow: widget.isSelected || _hovering
                  ? AppTheme.primaryShadow
                  : AppTheme.cardShadow,
              border: Border.all(
                color: widget.isSelected
                    ? AppTheme.primary
                    : Colors.transparent,
                width: 2,
              ),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ── Poster ─────────────────────────────────────
                  _buildPoster(),

                  // ── Bottom gradient ───────────────────────────
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration:
                      BoxDecoration(gradient: AppTheme.darkOverlay),
                    ),
                  ),

                  // ── Hover dark overlay ────────────────────────
                  if (_hovering)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.35),
                      ),
                    ),

                  // ── Play button (hover) ───────────────────────
                  if (_hovering)
                    Center(
                      child: GestureDetector(
                        onTap: _playDirect,
                        child: Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: AppTheme.primary
                                .withValues(alpha: 0.92),
                            shape: BoxShape.circle,
                            boxShadow: AppTheme.primaryShadow,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: Colors.white,
                            size: 26,
                          ),
                        ),
                      ),
                    ),

                  // ── Rating badge (top right) ──────────────────
                  if (widget.movie.ratingValue > 0)
                    Positioned(
                      top: 7,
                      right: 7,
                      child: _RatingBadge(
                          rating: widget.movie.ratingValue),
                    ),

                  // ── Favorite button (top left on hover) ───────
                  Positioned(
                    top: 7,
                    left: 7,
                    child: AnimatedOpacity(
                      opacity: _hovering || isFav ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: GestureDetector(
                        onTap: () => ref
                            .read(vodFavoritesProvider.notifier)
                            .toggle(widget.movie.streamId),
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color:
                            Colors.black.withValues(alpha: 0.65),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            isFav
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: isFav
                                ? const Color(0xFFEF4444)
                                : Colors.white,
                            size: 13,
                          ),
                        ),
                      ),
                    ),
                  ),

                  // ── Title + year at bottom ────────────────────
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.movie.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              shadows: [
                                Shadow(
                                  color: Colors.black,
                                  blurRadius: 4,
                                )
                              ],
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    )
        .animate()
        .fadeIn(
      duration: 300.ms,
      delay: Duration(
          milliseconds: (widget.index % 20) * 20),
    )
        .slideY(begin: 0.04, end: 0);
  }

  Widget _buildPoster() {
    final icon = widget.movie.streamIcon;
    if (icon != null && icon.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: icon,
        fit: BoxFit.cover,
        placeholder: (_, _) => _placeholder(),
        errorWidget: (_, _, _) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() {
    return Container(
      color: AppTheme.surfaceVariant,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.movie_creation_outlined,
            color: AppTheme.textMuted,
            size: 32,
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              widget.movie.name,
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
              ),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  void _handleTap() {
    ref.read(selectedVodStreamProvider.notifier).state = widget.movie;
    widget.onTap?.call(widget.movie);
  }

  void _playDirect() {
    final service = ref.read(xtreamServiceProvider);
    if (service == null) return;

    final url = service.getVodUrl(
      widget.movie.streamId,
      widget.movie.containerExtension ?? 'mp4',
    );

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          title: widget.movie.name,
          url: url,
          imageUrl: widget.movie.streamIcon,
          type: 'movie',
          id: widget.movie.streamId,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RATING BADGE
// ─────────────────────────────────────────────────────────────────────────────
class _RatingBadge extends StatelessWidget {
  final double rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, color: Colors.white, size: 9),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHIMMER CARD (loading state)
// ─────────────────────────────────────────────────────────────────────────────
class _ShimmerCard extends StatefulWidget {
  @override
  State<_ShimmerCard> createState() => _ShimmerCardState();
}

class _ShimmerCardState extends State<_ShimmerCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _anim = Tween<double>(begin: 0.3, end: 0.7).animate(_ctrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _anim,
      builder: (_, _) => Container(
        decoration: BoxDecoration(
          color: Color.lerp(
            AppTheme.surfaceVariant,
            AppTheme.card,
            _anim.value,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}