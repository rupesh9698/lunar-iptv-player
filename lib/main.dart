import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_native_splash/flutter_native_splash.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:media_kit/media_kit.dart';

import 'core/router/app_router.dart';
import 'core/theme/app_theme.dart';
import 'core/utils/platform_utils.dart';
import 'services/cache_service.dart';
import 'services/storage_service.dart';

void main() async {
  // 1. Capture the instance into a variable ONCE
  final widgetsBinding = WidgetsFlutterBinding.ensureInitialized();

  // 2. Pass that captured variable directly here
  FlutterNativeSplash.preserve(widgetsBinding: widgetsBinding);

  // ── Status bar / navigation bar ────────────────────────────────────
  // Hide system UI for immersive fullscreen experience on Android/iOS
  if (!kIsWeb) {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.immersiveSticky,
      overlays: [], // No overlays = fully hidden
    );
  }

  // ── Orientation ────────────────────────────────────────────────────
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  // ── MediaKit ────────────────────────────────────────────────────────
  // MUST be called before any Player() is created
  if (!kIsWeb) {
    MediaKit.ensureInitialized();
  }

  // ── Services ────────────────────────────────────────────────────────
  await StorageService.instance.init();
  await CacheService.instance.init();
  await BehaviorService.instance.init();
  // Point BehaviorService at the active playlist from first boot
  final activeId = StorageService.instance.getActivePlaylistId();
  if (activeId != null) {
    BehaviorService.instance.setPlaylist(activeId);
  }
  await initializeDateFormatting();
  await PlatformUtils.initWakelock();

  // Set active playlist context in cache service
  if (activeId != null) {
    CacheService.instance.setActivePlaylist(activeId);
  }

  // NOTE: FlutterNativeSplash.remove() is intentionally missing here!
  // The initialization route engine inside app_router.dart drops it now.

  runApp(const ProviderScope(child: LunarIPTVPlayerApp()));
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
      builder: (context, child) =>
          LandscapeEnforcer(child: child ?? const SizedBox.shrink()),
    );
  }
}

// ── Landscape Enforcer ────────────────────────────────────────────────────────
class LandscapeEnforcer extends StatelessWidget {
  final Widget child;
  const LandscapeEnforcer({super.key, required this.child});

  static bool get _isMobile =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  Widget build(BuildContext context) {
    if (!_isMobile) return child;
    return OrientationBuilder(
      builder: (ctx, orientation) {
        if (orientation == Orientation.portrait) {
          return const _RotateDeviceScreen();
        }
        return child;
      },
    );
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
