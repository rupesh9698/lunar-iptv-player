import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/focus_utils.dart';
import 'core/utils/performance.dart';
import 'core/utils/platform_utils.dart';
import 'core/utils/responsive.dart';
import 'services/cache_service.dart';
import 'services/storage_service.dart';

void main() async {
  // 1. Capture the instance into a variable ONCE
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  // 2. Pass that captured variable directly here
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // ── MediaKit — must be before any Player() is created ───────────────────
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
  }

  // ── System UI + Orientation — defer to after first frame ────────────────
  // Running these before the engine is ready causes frame skips (576 frames
  // skipped in logs). Schedule for after first frame instead.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    if (!kIsWeb) {
      SystemChrome.setEnabledSystemUIMode(
        SystemUiMode.immersiveSticky,
        overlays: [],
      );
      if (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS) {
        SystemChrome.setPreferredOrientations([
          DeviceOrientation.landscapeLeft,
          DeviceOrientation.landscapeRight,
        ]);
      }
    }
  });

  // ── Services — run critical ones first, parallelize the rest ────────────
  // StorageService must be first (others depend on it)
  await StorageService.instance.init();

  // Active playlist ID is needed by both cache and behavior services
  final activeId = StorageService.instance.getActivePlaylistId();

  // Run all remaining inits in parallel — none depend on each other
  await Future.wait([
    CacheService.instance.init(),
    BehaviorService.instance.init(),
    initializeDateFormatting(),
    PlatformUtils.detectAndroidTV(),
    _initDesktopWindow(),
  ]);

  // ── TV remote / keyboard focus ──────────────────────────────────────────
  // Track D-pad auto-repeat so focused list items jump-scroll into view.
  TvKeyTracker.install();

  // ── Low-spec device profile (needs TV detection above) ─────────────────
  await Perf.init();
  // On Android TV there is no touch input: always draw focus rings so the
  // user can see where the remote's focus is from the very first frame
  // (the automatic strategy starts in "touch" mode on Android and hides them).
  if (PlatformUtils.isTV) {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  }

  // Wire active playlist context after parallel init completes
  if (activeId != null) {
    BehaviorService.instance.setPlaylist(activeId);
    CacheService.instance.setActivePlaylist(activeId);
  }

  // Wakelock is non-critical — fire and forget, don't block startup
  PlatformUtils.initWakelock().ignore();

  // NOTE: FlutterNativeSplash.remove() is intentionally missing here!
  // The initialization route engine inside app_router.dart drops it now.

  runApp(const ProviderScope(child: LunarIPTVPlayerApp()));
}

/// Desktop: enforce a sensible minimum window size so the multi-pane layout
/// never gets squeezed into an unusable state.
Future<void> _initDesktopWindow() async {
  if (!PlatformUtils.isDesktop) return;
  try {
    await windowManager.ensureInitialized().timeout(const Duration(seconds: 2));
    await windowManager.setMinimumSize(const Size(800, 480));
  } catch (e) {
    debugPrint('Window manager init skipped: $e');
  }
}

class LunarIPTVPlayerApp extends ConsumerWidget {
  const LunarIPTVPlayerApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final router = ref.watch(routerProvider);
    return MaterialApp.router(
      title: 'Lunar IPTV Player',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      routerConfig: router,
      builder: (context, child) => AdaptiveViewport(
        child: LandscapeEnforcer(child: child ?? const SizedBox.shrink()),
      ),
    );
  }
}

// ── Landscape Enforcer ────────────────────────────────────────────────────────
class LandscapeEnforcer extends StatelessWidget {
  final Widget child;
  const LandscapeEnforcer({super.key, required this.child});

  static bool get _isMobile =>
      !kIsWeb &&
      !PlatformUtils.isTV &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    if (!_isMobile) return child;
    final size = MediaQuery.sizeOf(context);
    // Only phones are asked to rotate. Tablets, foldables, Chromebooks and
    // free-form windows can't always rotate, so they get the (auto-scaled)
    // landscape layout instead of being blocked forever.
    final isPhone = size.shortestSide < 600;
    if (isPhone && size.height > size.width) {
      return const _RotateDeviceScreen();
    }
    return child;
  }
}

class _RotateDeviceScreen extends StatelessWidget {
  const _RotateDeviceScreen();

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 0.25),
              duration: const Duration(milliseconds: 1500),
              curve: Curves.easeInOut,
              onEnd: () {},
              builder: (_, v, child) =>
                  Transform.rotate(angle: v * 3.14159 * 2, child: child),
              child: const Icon(
                Icons.screen_rotation_rounded,
                color: AppTheme.primary,
                size: 72,
              ),
            ),
            const SizedBox(height: 28),
            const Text(
              'Rotate your device',
              style: TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Lunar IPTV Player is designed for landscape mode',
              style: TextStyle(color: Colors.white54, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
