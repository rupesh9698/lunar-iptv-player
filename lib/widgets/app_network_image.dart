import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/performance.dart';
import '../services/app_cache_manager.dart';
import '../services/stream_proxy_service.dart';

/// A robust network image widget with a light placeholder, error fallback,
/// and proper caching. Use this everywhere instead of Image.network.
///
/// Performance notes (low-spec TVs):
/// • Images are DECODED at their on-screen size (measured with a
///   LayoutBuilder). Poster URLs are frequently 2000×3000 originals — 24 MB
///   each once decoded — which exhausted memory and made posters vanish.
/// • No `maxWidthDiskCache`/`maxHeightDiskCache`: with a plain CacheManager
///   those trip an assertion (every poster showed the fallback in debug
///   builds) and are ignored in release.
/// • The placeholder is static — an animated shimmer per tile kept dozens of
///   animations running while a grid loaded.
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
        : LayoutBuilder(
            builder: (context, constraints) {
              final dpr = MediaQuery.devicePixelRatioOf(context);
              final logicalW =
                  width ??
                  (constraints.hasBoundedWidth ? constraints.maxWidth : 200);
              return CachedNetworkImage(
                imageUrl: cleanUrl,
                imageRenderMethodForWeb: StreamProxyService.imageMethod,
                fit: fit,
                width: width,
                height: height,
                httpHeaders: headers,
                cacheManager: AppCacheManager.instance,
                // Width only → aspect ratio preserved by the decoder.
                memCacheWidth: Perf.decodeWidth(logicalW, dpr),
                placeholder: (_, _) => _ShimmerBox(
                  width: width ?? double.infinity,
                  height: height ?? double.infinity,
                ),
                errorWidget: (_, _, _) => _fallbackWidget(),
                fadeInDuration: Perf.enabled
                    ? Duration.zero
                    : const Duration(milliseconds: 150),
                fadeOutDuration: Duration.zero,
              );
            },
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
    return StreamProxyService.resolveImage(url);
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
    // Static on purpose (see class docs) — cheap even with 50 tiles loading.
    return Container(
      width: width,
      height: height,
      color: AppTheme.surfaceVariant,
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
