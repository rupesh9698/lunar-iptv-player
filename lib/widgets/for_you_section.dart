import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/focus_utils.dart';

/// Generic horizontal "For You" recommendation row.
/// Works for both VodStream and Series.
class ForYouSection extends StatelessWidget {
  final String label;
  final List<({String id, String name, String? imageUrl, double rating})> items;
  final void Function(String id) onTap;

  const ForYouSection({
    super.key,
    required this.label,
    required this.items,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF7B61FF), Color(0xFF4F8EF7)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF7B61FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFF7B61FF).withValues(alpha: 0.3),
                  ),
                ),
                child: const Text(
                  'AI',
                  style: TextStyle(
                    color: Color(0xFF7B61FF),
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Card list ──────────────────────────────────────────────────────
        SizedBox(
          height: 140,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            itemBuilder: (ctx, i) => Padding(
              padding: EdgeInsets.only(right: i < items.length - 1 ? 10 : 0),
              child: SizedBox(
                width: 94,
                child: _ForYouCard(
                  key: ValueKey('fy_${items[i].id}'),
                  item: items[i],
                  index: i,
                  onTap: () => onTap(items[i].id),
                ),
              ),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.06);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CARD
// ─────────────────────────────────────────────────────────────────────────────
class _ForYouCard extends StatefulWidget {
  final ({String id, String name, String? imageUrl, double rating}) item;
  final int index;
  final VoidCallback onTap;

  const _ForYouCard({
    super.key,
    required this.item,
    required this.index,
    required this.onTap,
  });

  @override
  State<_ForYouCard> createState() => _ForYouCardState();
}

class _ForYouCardState extends State<_ForYouCard> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;

    return TvFocusable(
      onActivate: widget.onTap,
      builder: (focused, pressed) => AnimatedScale(
        scale: pressed ? 0.93 : focused ? 1.05 : 1.0,
        duration: const Duration(milliseconds: 140),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: focused
                ? Border.all(
                color: Colors.white.withValues(alpha: 0.75),
                width: 2.5)
                : Border.all(color: Colors.transparent, width: 2.5),
            boxShadow: focused
                ? [
              BoxShadow(
                color: const Color(0xFF7B61FF)
                    .withValues(alpha: 0.35),
                blurRadius: 12,
                spreadRadius: 1,
              ),
            ]
                : null,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              fit: StackFit.expand,
              children: [
                item.imageUrl?.isNotEmpty == true
                    ? CachedNetworkImage(
                  imageUrl: item.imageUrl!,
                  fit: BoxFit.cover,
                  placeholder: (_, _) =>
                      Container(color: AppTheme.surfaceVariant),
                  errorWidget: (_, _, _) => Container(
                    color: AppTheme.surfaceVariant,
                    child: const Icon(Icons.movie_outlined,
                        color: AppTheme.textMuted, size: 24),
                  ),
                )
                    : Container(
                  color: AppTheme.surfaceVariant,
                  child: const Icon(Icons.movie_outlined,
                      color: AppTheme.textMuted, size: 24),
                ),
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.88),
                        ],
                        stops: const [0.45, 1.0],
                      ),
                    ),
                  ),
                ),
                if (item.rating > 0)
                  Positioned(
                    top: 5,
                    right: 5,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.amber.withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        item.rating.toStringAsFixed(1),
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 8,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ),
                Positioned(
                  bottom: 5,
                  left: 5,
                  right: 5,
                  child: Text(
                    item.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      shadows: [
                        Shadow(color: Colors.black, blurRadius: 4)
                      ],
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    )
        .animate()
        .fadeIn(
      delay: Duration(milliseconds: widget.index * 40),
      duration: 300.ms,
    )
        .slideX(begin: 0.08, curve: Curves.easeOutCubic);
  }
}