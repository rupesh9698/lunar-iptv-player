import 'package:flutter/material.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../providers/app_providers.dart';
import '../../screens/add_playlist/add_playlist_screen.dart';
import '../../screens/home/home_screen.dart';
import '../../screens/live_tv/live_tv_screen.dart';
import '../../screens/movies/movies_screen.dart';
import '../../screens/player/player_screen.dart';
import '../../screens/series/series_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/sync/sync_screen.dart';
import '../../screens/splash/splash_screen.dart'; // Import your custom splash screen widget
import '../../services/cache_service.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/init', // Keep initialization as the hidden gatekeeper
    routes: [
      GoRoute(path: '/init', builder: (context, _) => const _AppInitializer()),
      GoRoute(
        path: '/splash',
        builder: (_, _) => const SplashScreen(), // Registered correctly now
      ),
      GoRoute(path: '/home', builder: (_, _) => const HomeScreen()),
      GoRoute(
        path: '/add-playlist',
        builder: (_, _) => const AddPlaylistScreen(),
      ),
      GoRoute(
        path: '/sync',
        builder: (_, state) =>
            SyncScreen(isManualRefresh: state.extra == 'manual'),
      ),
      GoRoute(path: '/live-tv', builder: (_, _) => const LiveTVScreen()),
      GoRoute(path: '/movies', builder: (_, _) => const MoviesScreen()),
      GoRoute(path: '/series', builder: (_, _) => const SeriesScreen()),
      GoRoute(path: '/settings', builder: (_, _) => const SettingsScreen()),
      GoRoute(
        path: '/player',
        builder: (_, state) {
          final extra = state.extra as Map<String, dynamic>? ?? {};
          return PlayerScreen(
            title: extra['title'] as String? ?? '',
            url: extra['url'] as String? ?? '',
            imageUrl: extra['imageUrl'] as String?,
            type: extra['type'] as String? ?? 'live',
            id: extra['id'] as String? ?? '',
          );
        },
      ),
    ],
  );
});

class _AppInitializer extends ConsumerStatefulWidget {
  const _AppInitializer();

  @override
  ConsumerState<_AppInitializer> createState() => _AppInitializerState();
}

class _AppInitializerState extends ConsumerState<_AppInitializer> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _handleNavigation());
  }

  Future<void> _handleNavigation() async {
    if (!mounted) return;

    try {
      final playlist = ref.read(activePlaylistProvider);

      if (playlist != null) {
        CacheService.instance.setActivePlaylist(playlist.id);
      }
    } catch (e) {
      debugPrint('Init route error: $e');
    }

    if (mounted) {
      // Divert directly to the animation asset loop stage
      context.go('/splash');
      // Safe to drop native presentation layout now
      FlutterNativeSplash.remove();
    }
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0A0C14),
      body:
          SizedBox.shrink(), // Dropped spinner because native splash is still covering this
    );
  }
}
