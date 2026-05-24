import 'package:flutter_cache_manager/flutter_cache_manager.dart';

/// Larger image cache: 2000 objects, 14-day stale period.
/// flutter_cache_manager is already a transitive dep of cached_network_image.
class AppCacheManager {
  AppCacheManager._();

  static const String _key = 'lunip_img_cache_v1';

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 2000,
    ),
  );
}
