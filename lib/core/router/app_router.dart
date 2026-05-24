import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../screens/add_playlist/add_playlist_screen.dart';
import '../../screens/home/home_screen.dart';
import '../../screens/live_tv/live_tv_screen.dart';
import '../../screens/movies/movies_screen.dart';
import '../../screens/player/player_screen.dart';
import '../../screens/series/series_screen.dart';
import '../../screens/settings/settings_screen.dart';
import '../../screens/splash/splash_screen.dart';
import '../../screens/sync/sync_screen.dart';

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/splash',
    routes: [
      GoRoute(path: '/splash', builder: (_, _) => const SplashScreen()),
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
      // Same screen for ALL platforms — no isStandalone needed
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
