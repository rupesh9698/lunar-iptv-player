import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/app_cache_manager.dart';

import '../core/theme/app_theme.dart';

/// A robust network image widget with shimmer loading, error fallback,
/// and proper caching. Use this everywhere instead of Image.network.
class AppNetworkImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final Widget? fallback;
  final double? width;
  final double? height;
  final BorderRadius? borderRadius;
  final Map<String, String>? headers;

  const AppNetworkImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.fallback,
    this.width,
    this.height,
    this.borderRadius,
    this.headers,
  });

  @override
  Widget build(BuildContext context) {
    final cleanUrl = _sanitizeUrl(url);

    final child = cleanUrl == null
        ? _fallbackWidget()
        : CachedNetworkImage(
            imageUrl: cleanUrl,
            fit: fit,
            width: width,
            height: height,
            httpHeaders: headers,
            cacheManager:
                AppCacheManager.instance, // ← custom cache (2000 objects)
            memCacheHeight: height != null ? (height! * 2).toInt() : null,
            memCacheWidth: width != null ? (width! * 2).toInt() : null,
            maxHeightDiskCache: 600,
            maxWidthDiskCache: 400,
            placeholder: (_, _) => _ShimmerBox(
              width: width ?? double.infinity,
              height: height ?? double.infinity,
            ),
            errorWidget: (_, _, _) => _fallbackWidget(),
            fadeInDuration: const Duration(milliseconds: 200),
            fadeOutDuration: const Duration(milliseconds: 100),
          );

    if (borderRadius != null) {
      return ClipRRect(borderRadius: borderRadius!, child: child);
    }
    return child;
  }

  Widget _fallbackWidget() {
    return fallback ??
        Container(
          width: width,
          height: height,
          color: AppTheme.surfaceVariant,
          child: const Center(
            child: Icon(
              Icons.image_not_supported_outlined,
              color: AppTheme.textMuted,
              size: 28,
            ),
          ),
        );
  }

  static String? _sanitizeUrl(String? raw) {
    if (raw == null || raw.trim().isEmpty) return null;
    final url = raw.trim();
    if (!url.startsWith('http://') && !url.startsWith('https://')) return null;
    return url;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shimmer Loading Placeholder
// ─────────────────────────────────────────────────────────────────────────────
class _ShimmerBox extends StatelessWidget {
  final double width;
  final double height;

  const _ShimmerBox({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Container(
          width: width,
          height: height,
          color: AppTheme.surfaceVariant,
        )
        .animate(onPlay: (c) => c.repeat(reverse: true))
        .shimmer(
          duration: 1200.ms,
          color: AppTheme.cardHover.withValues(alpha: 0.6),
        );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Poster-specific widget (2:3 aspect ratio with rating badge)
// ─────────────────────────────────────────────────────────────────────────────
class PosterImage extends StatelessWidget {
  final String? url;
  final double? rating;
  final BorderRadius borderRadius;

  const PosterImage({
    super.key,
    required this.url,
    this.rating,
    this.borderRadius = const BorderRadius.all(Radius.circular(10)),
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: borderRadius,
      child: Stack(
        fit: StackFit.expand,
        children: [
          AppNetworkImage(
            url: url,
            fit: BoxFit.cover,
            fallback: Container(
              color: AppTheme.surfaceVariant,
              child: const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.movie_creation_outlined,
                    color: AppTheme.textMuted,
                    size: 28,
                  ),
                ],
              ),
            ),
          ),
          if (rating != null && rating! > 0)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
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
                      rating!.toStringAsFixed(1),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
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
}
