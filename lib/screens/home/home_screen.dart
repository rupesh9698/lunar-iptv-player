import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:upgrader/upgrader.dart';

import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../services/cache_service.dart';
import '../add_playlist/add_playlist_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerBackgroundRefreshIfStale();
    });
  }

  void _triggerBackgroundRefreshIfStale() {
    final cache = CacheService.instance;
    if (cache.isLiveStale() || cache.isVodStale() || cache.isSeriesStale()) {
      ref.read(backgroundRefreshProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch sync timestamp so home rebuilds immediately after sync completes
    ref.watch(cacheLastSyncProvider);

    final playlist = ref.watch(activePlaylistProvider);
    if (playlist == null) return _buildNoPlaylist();
    return _buildHome();
  }

  Widget _buildHome() {
    final accountAsync = ref.watch(accountInfoProvider);
    final cache = CacheService.instance;
    final lastUpdate = cache.lastUpdatedLive();

    return UpgradeAlert(
      showIgnore: true,
      showLater: true,
      barrierDismissible: false,
      upgrader: Upgrader(
        // Check once every 3 days — don't nag the user
        durationUntilAlertAgain: const Duration(days: 1),
      ),
      // Don't show update dialog on loading/error states
      navigatorKey: GlobalKey<NavigatorState>(),
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, _) => _showExitDialog(),
        child: Scaffold(
          backgroundColor: AppTheme.background,
          body: SafeArea(
            child: Row(
              children: [
                SizedBox(
                  width: 280,
                  child: _LeftPanel(
                    accountAsync: accountAsync,
                    lastUpdate: lastUpdate,
                    onRefresh: () => context.go('/sync', extra: 'manual'),
                  ),
                ),
                const VerticalDivider(color: AppTheme.divider, width: 1),
                Expanded(child: _RightPanel(cache: cache)),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNoPlaylist() {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 88,
              height: 88,
              child: Image.asset("assets/images/logo.png", fit: BoxFit.contain),
            ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
            const SizedBox(height: 24),
            const Text(
              'Lunar IPTV Player',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 28,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Your premium IPTV player',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              autofocus: true,
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AddPlaylistScreen()),
              ),
              icon: const Icon(Icons.add),
              label: const Text('Add Playlist'),
            ).animate().slideY(begin: 0.3, delay: 400.ms),
          ],
        ),
      ),
    );
  }

  Future<void> _showExitDialog() async {
    final exit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Exit Lunar IPTV Player?'),
        content: const Text('Are you sure you want to exit?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Exit'),
          ),
        ],
      ),
    );
    if (exit == true && mounted) {
      // Exit app
      SystemNavigator.pop();
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LEFT PANEL
// ─────────────────────────────────────────────────────────────────────────────
class _LeftPanel extends StatelessWidget {
  final AsyncValue<AccountInfo?> accountAsync;
  final DateTime? lastUpdate;
  final VoidCallback onRefresh;

  const _LeftPanel({
    required this.accountAsync,
    required this.lastUpdate,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppTheme.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Logo + clock
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: Image.asset(
                        "assets/images/logo.png",
                        fit: BoxFit.contain,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Lunar IPTV Player',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 2,
                      ),
                    ),
                  ],
                ).animate().fadeIn(duration: 500.ms).slideX(begin: -0.15),
                const SizedBox(height: 20),
                const _LiveClock()
                    .animate()
                    .fadeIn(delay: 150.ms, duration: 500.ms)
                    .slideX(begin: -0.1),
              ],
            ),
          ),

          const Spacer(),

          // Account + buttons
          Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                accountAsync.when(
                  data: (info) => info != null
                      ? _AccountCard(info: info, lastUpdate: lastUpdate)
                      : const SizedBox.shrink(),
                  loading: () => const SizedBox.shrink(),
                  error: (_, _) => const SizedBox.shrink(),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const AddPlaylistScreen(),
                        ),
                      ),
                      icon: const Icon(Icons.add, size: 16),
                      label: const Text('Add Playlist'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppTheme.primary,
                        side: const BorderSide(color: AppTheme.primary),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    )
                    .animate()
                    .fadeIn(delay: 300.ms, duration: 400.ms)
                    .slideY(begin: 0.2),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE CLOCK — updates every second
// ─────────────────────────────────────────────────────────────────────────────
class _LiveClock extends StatefulWidget {
  const _LiveClock();
  @override
  State<_LiveClock> createState() => _LiveClockState();
}

class _LiveClockState extends State<_LiveClock> {
  late DateTime _now;
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
    _now = DateTime.now();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          DateFormat('EEE, dd MMM yyyy').format(_now),
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        Text(
          DateFormat('hh:mm:ss a').format(_now),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AccountInfo info;
  final DateTime? lastUpdate;
  const _AccountCard({required this.info, this.lastUpdate});

  @override
  Widget build(BuildContext context) {
    final u = info.userInfo;
    final exp = u.expirationDate;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.person,
                  color: AppTheme.primary,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      u.username,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (exp != null)
                      Text(
                        'Exp: ${DateFormat('dd MMM yy').format(exp)}',
                        style: TextStyle(
                          color: u.isExpired
                              ? AppTheme.error
                              : AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _StatusBadge(
                u.status == 'Active' ? AppTheme.success : AppTheme.error,
                u.status,
              ),
              const Spacer(),
              if (lastUpdate != null)
                Text(
                  _timeAgo(lastUpdate!),
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  String _timeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    return DateFormat('dd MMM').format(dt);
  }
}

class _StatusBadge extends StatelessWidget {
  final Color color;
  final String label;
  const _StatusBadge(this.color, this.label);

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: Text(
      label,
      style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// RIGHT PANEL — SCROLLABLE nav cards
// ─────────────────────────────────────────────────────────────────────────────
class _RightPanel extends StatelessWidget {
  final CacheService cache;
  const _RightPanel({required this.cache});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Browse',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ).animate().fadeIn(duration: 400.ms).slideX(begin: -0.1),

          const SizedBox(height: 20),

          GridView.count(
            crossAxisCount: 2,
            crossAxisSpacing: 20,
            mainAxisSpacing: 20,
            childAspectRatio: 1.65,
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            children: [
              _NavCard(
                    label: 'Live TV',
                    sublabel: _buildSublabel(
                      cache.lastUpdatedLive(),
                      'channels',
                    ),
                    icon: Icons.tv_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1565C0), Color(0xFF42A5F5)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => context.push('/live-tv'),
                  )
                  .animate()
                  .fadeIn(delay: 0.ms, duration: 450.ms)
                  .slideY(begin: 0.18, curve: Curves.easeOutCubic),

              _NavCard(
                    label: 'Movies',
                    sublabel: _buildSublabel(cache.lastUpdatedVod(), 'movies'),
                    icon: Icons.movie_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF6A1B9A), Color(0xFFAB47BC)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => context.push('/movies'),
                  )
                  .animate()
                  .fadeIn(delay: 100.ms, duration: 450.ms)
                  .slideY(begin: 0.18, curve: Curves.easeOutCubic),

              _NavCard(
                    label: 'Series',
                    sublabel: _buildSublabel(
                      cache.lastUpdatedSeries(),
                      'series',
                    ),
                    icon: Icons.video_library_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1B5E20), Color(0xFF66BB6A)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => context.push('/series'),
                  )
                  .animate()
                  .fadeIn(delay: 200.ms, duration: 450.ms)
                  .slideY(begin: 0.18, curve: Curves.easeOutCubic),

              _NavCard(
                    label: 'Settings',
                    sublabel: 'Preferences & Account',
                    icon: Icons.settings_rounded,
                    gradient: const LinearGradient(
                      colors: [Color(0xFF37474F), Color(0xFF78909C)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    onTap: () => context.push('/settings'),
                  )
                  .animate()
                  .fadeIn(delay: 300.ms, duration: 450.ms)
                  .slideY(begin: 0.18, curve: Curves.easeOutCubic),
            ],
          ),
        ],
      ),
    );
  }

  String _buildSublabel(DateTime? lastUpdate, String unit) {
    if (lastUpdate == null) return 'Not synced yet';
    final diff = DateTime.now().difference(lastUpdate);
    if (diff.inSeconds < 60) return 'Just synced';
    if (diff.inMinutes < 5) return 'Just updated';
    if (diff.inHours < 1) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Updated ${diff.inHours}h ago';
    return 'Updated ${diff.inDays}d ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NAV CARD
// ─────────────────────────────────────────────────────────────────────────────
class _NavCard extends StatefulWidget {
  final String label;
  final String sublabel;
  final IconData icon;
  final LinearGradient gradient;
  final VoidCallback onTap;

  const _NavCard({
    required this.label,
    required this.sublabel,
    required this.icon,
    required this.gradient,
    required this.onTap,
  });

  @override
  State<_NavCard> createState() => _NavCardState();
}

class _NavCardState extends State<_NavCard> {
  bool _hover = false;
  bool _focused = false;
  bool _pressed = false;

  double get _shadowAlpha => _hover || _focused ? 0.55 : 0.35;
  double get _shadowBlur => _hover || _focused ? 32 : 22;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        // Handles: TV remote Select/Enter, keyboard Enter/Space, gamepad A
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          setState(() => _pressed = true);
          widget.onTap();
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          setState(() => _pressed = false);
          return KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() {
          _hover = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed
                ? 0.96
                : (_hover || _focused)
                ? 1.04
                : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              curve: Curves.easeOutCubic,
              decoration: BoxDecoration(
                gradient: widget.gradient,
                borderRadius: BorderRadius.circular(20),
                // White border appears on TV-remote/keyboard focus
                border: _focused
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.75),
                        width: 2.5,
                      )
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: widget.gradient.colors.first.withValues(
                      alpha: _shadowAlpha,
                    ),
                    blurRadius: _shadowBlur,
                    offset: const Offset(0, 10),
                  ),
                ],
              ),
              padding: const EdgeInsets.all(24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(widget.icon, color: Colors.white, size: 32)
                      .animate(target: _hover || _focused ? 1 : 0)
                      .scaleXY(
                        end: 1.15,
                        duration: 200.ms,
                        curve: Curves.easeOut,
                      ),
                  const Spacer(),
                  Text(
                    widget.label,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    widget.sublabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 12.5,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
