import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/series_provider.dart';

class SeriesGrid extends ConsumerWidget {
  final bool isMobile;
  final ValueChanged<Series>? onSeriesTap;

  const SeriesGrid({super.key, this.isMobile = false, this.onSeriesTap});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streamsAsync = ref.watch(sortedSeriesListProvider);
    final selected     = ref.watch(selectedSeriesStreamProvider);

    return Container(
      color: AppTheme.background,
      child: streamsAsync.when(
        data: (list) {
          if (list.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.video_library_outlined,
                      color: AppTheme.textMuted, size: 56),
                  SizedBox(height: 16),
                  Text('No series found',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 16)),
                  SizedBox(height: 8),
                  Text('Try a different category or search',
                      style: TextStyle(
                          color: AppTheme.textMuted, fontSize: 13)),
                ],
              ),
            );
          }

          return LayoutBuilder(builder: (ctx, constraints) {
            final cols = _columns(constraints.maxWidth, isMobile);
            return GridView.builder(
              padding: const EdgeInsets.all(12),
              gridDelegate:
              SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                mainAxisSpacing: 12,
                crossAxisSpacing: 12,
                childAspectRatio: 2 / 3,
              ),
              itemCount: list.length,
              itemBuilder: (_, i) {
                final series = list[i];
                return _SeriesPosterCard(
                  key: ValueKey(series.seriesId),
                  series: series,
                  isSelected:
                  selected?.seriesId == series.seriesId,
                  isMobile: isMobile,
                  onTap: onSeriesTap,
                  index: i,
                );
              },
            );
          });
        },
        loading: () => GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate:
          const SliverGridDelegateWithFixedCrossAxisCount(
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
              const Text('Failed to load series',
                  style: TextStyle(
                      color: AppTheme.textSecondary)),
              const SizedBox(height: 12),
              TextButton.icon(
                onPressed: () =>
                    ref.invalidate(seriesListProvider),
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
    if (isMobile) return width > 500 ? 3 : 2;
    if (width > 1400) return 7;
    if (width > 1100) return 6;
    if (width > 850)  return 5;
    if (width > 600)  return 4;
    return 3;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _SeriesPosterCard extends ConsumerStatefulWidget {
  final Series series;
  final bool isSelected;
  final bool isMobile;
  final ValueChanged<Series>? onTap;
  final int index;

  const _SeriesPosterCard({
    super.key,
    required this.series,
    required this.isSelected,
    required this.isMobile,
    required this.onTap,
    required this.index,
  });

  @override
  ConsumerState<_SeriesPosterCard> createState() =>
      _SeriesPosterCardState();
}

class _SeriesPosterCardState
    extends ConsumerState<_SeriesPosterCard> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isFav = ref
        .watch(seriesFavoritesProvider)
        .contains(widget.series.seriesId);

    return AnimatedScale(
      scale: _hovering || widget.isSelected ? 1.03 : 1.0,
      duration: const Duration(milliseconds: 200),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: _handleTap,
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
                  // Poster
                  _buildPoster(),

                  // Bottom gradient
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                          gradient: AppTheme.darkOverlay),
                    ),
                  ),

                  // Hover overlay
                  if (_hovering)
                    Positioned.fill(
                      child: Container(
                        color: Colors.black.withValues(alpha: 0.32),
                      ),
                    ),

                  // Hover play icon
                  if (_hovering)
                    Center(
                      child: Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: AppTheme.primary
                              .withValues(alpha: 0.92),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.play_circle_outline,
                          color: Colors.white,
                          size: 28,
                        ),
                      ),
                    ),

                  // Rating badge
                  if (widget.series.ratingValue > 0)
                    Positioned(
                      top: 7,
                      right: 7,
                      child: _RatingBadge(
                          rating: widget.series.ratingValue),
                    ),

                  // Seasons badge (if available)
                  Positioned(
                    top: 7,
                    left: 7,
                    child: AnimatedOpacity(
                      opacity: _hovering || isFav ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 200),
                      child: GestureDetector(
                        onTap: () => ref
                            .read(seriesFavoritesProvider.notifier)
                            .toggle(widget.series.seriesId),
                        child: Container(
                          padding: const EdgeInsets.all(5),
                          decoration: BoxDecoration(
                            color: Colors.black
                                .withValues(alpha: 0.65),
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

                  // Title
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(8),
                      child: Text(
                        widget.series.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          shadows: [
                            Shadow(
                                color: Colors.black,
                                blurRadius: 4)
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
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
    final cover = widget.series.cover;
    if (cover != null && cover.isNotEmpty) {
      return Image.network(
        cover,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _placeholder(),
        loadingBuilder: (_, child, progress) =>
        progress == null ? child : _shimmer(),
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
          const Icon(Icons.theaters_outlined,
              color: AppTheme.textMuted, size: 32),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              widget.series.name,
              style: const TextStyle(
                  color: AppTheme.textMuted, fontSize: 10),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _shimmer() {
    return Container(color: AppTheme.surfaceVariant);
  }

  void _handleTap() {
    ref.read(selectedSeriesStreamProvider.notifier).state =
        widget.series;
    widget.onTap?.call(widget.series);
  }
}

class _RatingBadge extends StatelessWidget {
  final double rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding:
      const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
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
              AppTheme.surfaceVariant, AppTheme.card, _anim.value),
          borderRadius: BorderRadius.circular(10),
        ),
      ),
    );
  }
}