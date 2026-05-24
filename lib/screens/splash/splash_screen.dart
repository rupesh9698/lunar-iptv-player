import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/app_providers.dart';
import '../../services/cache_service.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    // Minimal delay — just enough for animations to register before navigation
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(milliseconds: 500), _navigate);
    });
  }

  Future<void> _navigate() async {
    if (!mounted) return;
    final playlist = ref.read(activePlaylistProvider);
    if (playlist == null) {
      context.go('/home');
      return;
    }
    CacheService.instance.setActivePlaylist(playlist.id);
    final hasCache = CacheService.instance.hasAnyCache();
    context.go(hasCache ? '/home' : '/sync');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 96,
              height: 96,
              child: Image.asset(
                'assets/images/logo.png',
                fit: BoxFit.contain,
              ),
            )
                .animate()
                .scale(
              duration: 600.ms,
              curve: Curves.elasticOut,
              begin: const Offset(0.4, 0.4),
            )
                .fadeIn(duration: 300.ms),

            const SizedBox(height: 20),

            const Text(
              'Lunar IPTV Player',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: 3,
              ),
            )
                .animate()
                .fadeIn(delay: 200.ms, duration: 400.ms)
                .slideY(begin: 0.25, curve: Curves.easeOutCubic),

            const SizedBox(height: 6),

            const Text(
              'Premium IPTV Player',
              style: TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13),
            ).animate().fadeIn(delay: 300.ms, duration: 400.ms),

            const SizedBox(height: 48),

            const SizedBox(
              width: 28,
              height: 28,
              child: CircularProgressIndicator(
                color: AppTheme.primary,
                strokeWidth: 2.5,
              ),
            ).animate().fadeIn(delay: 400.ms, duration: 300.ms),
          ],
        ),
      ),
    );
  }
}