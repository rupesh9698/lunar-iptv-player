import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/live_player_provider.dart';
import '../../providers/live_tv_provider.dart';
import '../../services/cache_service.dart';
import '../../services/m3u_service.dart';
import '../../services/storage_service.dart';
import 'widgets/epg_timeline.dart';
import 'widgets/live_category_sidebar.dart';
import 'widgets/live_preview_area.dart';

class LiveTVScreen extends ConsumerStatefulWidget {
  const LiveTVScreen({super.key});

  @override
  ConsumerState<LiveTVScreen> createState() => _LiveTVScreenState();
}

class _LiveTVScreenState extends ConsumerState<LiveTVScreen> {
  bool _draggingCategory = false;
  bool _draggingPreview = false;
  bool _epgFullscreen = false;

  // ── Refresh state ── set synchronously in initState (before first build)
  bool _isRefreshing = false;
  bool _hasCache = false; // true if ANY cached streams exist

  String _channelInputStr = '';
  bool _hasRestored = false;
  Timer? _channelInputTimer;
  final FocusNode _keyboardFocus = FocusNode();

  @override
  void initState() {
    super.initState();

    // CRITICAL: Set correct playlist cache context BEFORE any cache access
    final playlist = ref.read(activePlaylistProvider);
    if (playlist != null) {
      CacheService.instance.setActivePlaylist(playlist.id);
    }

    final cache = CacheService.instance;
    final streams = cache.loadLiveStreams(ignoreExpiry: true);
    _hasCache = streams?.isNotEmpty ?? false;

    // M3U: only refresh when cache is empty (don't stale-expire like Xtream)
    // Xtream: refresh when cache is empty OR older than 24h
    final isM3u = playlist?.isM3u ?? false;
    _isRefreshing = !_hasCache || (!isM3u && cache.isLiveStale());

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _keyboardFocus.requestFocus();
      if (_isRefreshing) {
        _doRefresh();
      } else {
        _restoreFromLastWatched();
      }
    });
  }

  // ── Refresh with retry ────────────────────────────────────────────────
  Future<void> _doRefresh() async {
    final playlist = ref.read(activePlaylistProvider);
    // ── M3U refresh ────────────────────────────────────────────────────────────
    if (playlist?.isM3u == true) {
      final url = playlist!.m3uUrl;
      if (url == null || url.isEmpty) {
        if (!_hasCache && mounted) {
          context.go('/home');
        } else if (mounted) {
          setState(() => _isRefreshing = false);
        }
        return;
      }

      bool success = false;
      for (int i = 0; i < 3 && !success; i++) {
        if (i > 0) await Future.delayed(const Duration(seconds: 3));
        try {
          final (cats, streams) = await M3uService.fetchAndParse(
            url,
          ).timeout(const Duration(seconds: 90));
          await CacheService.instance.saveLiveCategories(cats);
          await CacheService.instance.saveLiveStreams(streams);
          await CacheService.instance.saveContentFlags(
            hasLive: streams.isNotEmpty,
            hasVod: false,
            hasSeries: false,
          );
          ref.invalidate(liveCategoriesProvider);
          ref.invalidate(liveStreamsProvider);
          success = true;
        } catch (_) {}
      }

      if (!mounted) return;
      if (!success && !_hasCache) {
        context.go('/home');
      } else {
        setState(() {
          _isRefreshing = false;
          if (success) _hasCache = true;
        });
        if (!_hasRestored) _restoreFromLastWatched();
      }
      return;
    }

    // ── Xtream refresh (existing code unchanged below) ─────────────────────────
    final service = ref.read(xtreamServiceProvider);
    if (service == null) {
      if (!_hasCache && mounted) {
        context.go('/home');
      } else if (mounted) {
        setState(() => _isRefreshing = false);
      }
      return;
    }

    bool success = false;
    const maxTries = 3;
    const retryWait = Duration(seconds: 5);

    for (int attempt = 0; attempt < maxTries && !success; attempt++) {
      if (attempt > 0) await Future.delayed(retryWait);
      try {
        final cats = await service.getLiveCategories().timeout(
          const Duration(seconds: 30),
        );
        final channels = await service.getLiveStreams().timeout(
          const Duration(seconds: 60),
        );

        await CacheService.instance.saveLiveCategories(cats);
        await CacheService.instance.saveLiveStreams(channels);

        ref.invalidate(liveCategoriesProvider);
        ref.invalidate(liveStreamsProvider);
        success = true;
      } on TimeoutException {
        // retry
      } catch (_) {
        // retry
      }
    }

    if (!mounted) return;

    if (!success && !_hasCache) {
      // No data at all — cannot show Live TV
      context.go('/home');
    } else {
      // Success, or failed but has old cache to fall back on
      setState(() => _isRefreshing = false);
      if (!_hasRestored) _restoreFromLastWatched();
    }
  }

  // ── Channel number input ──────────────────────────────────────────────
  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.escape) {
      if (ref.read(livePlayerMaximizedProvider)) {
        ref.read(livePlayerMaximizedProvider.notifier).state = false;
      }
      return;
    }

    String? digit;
    if (key == LogicalKeyboardKey.digit0 || key == LogicalKeyboardKey.numpad0) {
      digit = '0';
    } else if (key == LogicalKeyboardKey.digit1 ||
        key == LogicalKeyboardKey.numpad1) {
      digit = '1';
    } else if (key == LogicalKeyboardKey.digit2 ||
        key == LogicalKeyboardKey.numpad2) {
      digit = '2';
    } else if (key == LogicalKeyboardKey.digit3 ||
        key == LogicalKeyboardKey.numpad3) {
      digit = '3';
    } else if (key == LogicalKeyboardKey.digit4 ||
        key == LogicalKeyboardKey.numpad4) {
      digit = '4';
    } else if (key == LogicalKeyboardKey.digit5 ||
        key == LogicalKeyboardKey.numpad5) {
      digit = '5';
    } else if (key == LogicalKeyboardKey.digit6 ||
        key == LogicalKeyboardKey.numpad6) {
      digit = '6';
    } else if (key == LogicalKeyboardKey.digit7 ||
        key == LogicalKeyboardKey.numpad7) {
      digit = '7';
    } else if (key == LogicalKeyboardKey.digit8 ||
        key == LogicalKeyboardKey.numpad8) {
      digit = '8';
    } else if (key == LogicalKeyboardKey.digit9 ||
        key == LogicalKeyboardKey.numpad9) {
      digit = '9';
    }

    if (digit == null) return;
    setState(() {
      _channelInputStr += digit!;
      if (_channelInputStr.length > 5) {
        _channelInputStr = _channelInputStr.substring(
          _channelInputStr.length - 5,
        );
      }
    });
    _channelInputTimer?.cancel();
    _channelInputTimer = Timer(const Duration(seconds: 2), _navigateToChannel);
  }

  void _navigateToChannel() {
    final input = _channelInputStr;
    if (input.isEmpty) return;
    setState(() => _channelInputStr = '');
    final num = int.tryParse(input);
    if (num == null) return;

    final streams = ref.read(filteredLiveStreamsProvider).value ?? [];
    LiveStream? found;
    for (final s in streams) {
      if (int.tryParse(s.num) == num) {
        found = s;
        break;
      }
    }

    if (found != null) {
      playChannel(context, ref, found);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Channel $input not found'),
          duration: const Duration(seconds: 2),
          backgroundColor: AppTheme.surfaceVariant,
        ),
      );
    }
  }

  // ── Cold-start + post-refresh restore ────────────────────────────────────────
  Future<void> _restoreFromLastWatched() async {
    if (_hasRestored) return;
    final remember =
        StorageService.instance.getSetting(
              AppConstants.rememberPositionKey,
              true,
            )
            as bool;
    if (!remember) return;

    final last = ref.read(lastWatchedLiveProvider);
    if (last.categoryId == null && last.channelId == null) return;

    // Await the future — resolves from Hive cache almost instantly on restart
    List<XtreamCategory> cats;
    try {
      cats = await ref.read(liveCategoriesProvider.future);
    } catch (_) {
      return;
    }

    if (!mounted || _hasRestored || cats.isEmpty) return;
    _hasRestored = true;

    // Restore category selection
    if (last.categoryId != null) {
      final category = cats.cast<XtreamCategory?>().firstWhere(
        (c) => c?.categoryId == last.categoryId,
        orElse: () => null,
      );
      if (category != null) {
        ref.read(liveFilterProvider.notifier).state = LiveFilter.all;
        ref.read(selectedLiveCategoryProvider.notifier).state = category;
      }
    }

    // Give category-filter time to propagate before scrolling
    if (last.channelId != null) {
      await Future.delayed(const Duration(milliseconds: 700));
      if (!mounted) return;

      // Trigger scroll in channel list
      ref.read(liveScrollToChannelProvider.notifier).state = last.channelId;

      // Auto-load into inline player
      LiveStream? channel;
      final filtered = ref.read(filteredLiveStreamsProvider).value;
      if (filtered != null) {
        for (final s in filtered) {
          if (s.streamId == last.channelId) {
            channel = s;
            break;
          }
        }
      }
      if (channel == null) {
        final cached =
            CacheService.instance.loadLiveStreams(ignoreExpiry: true) ?? [];
        for (final s in cached) {
          if (s.streamId == last.channelId) {
            channel = s;
            break;
          }
        }
      }
      if (channel != null && mounted) {
        ref.read(selectedChannelProvider.notifier).state = channel;
        ref.read(epgCacheProvider.notifier).loadEpg(channel.streamId);
      }
    }
  }

  @override
  void dispose() {
    _channelInputTimer?.cancel();
    _keyboardFocus.dispose();
    // Stop inline player — prevents audio bleeding to other screens
    try {
      ref.read(livePlayerProvider.notifier).stop();
    } catch (_) {}
    super.dispose();
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // ── Auto-load channel in inline player when selection changes ──────────
    ref.listen<LiveStream?>(selectedChannelProvider, (prev, next) {
      if (next == null || next.streamId == prev?.streamId) return;

      // Works for both Xtream (constructs URL) and M3U (uses directSource)
      final playlist = ref.read(activePlaylistProvider);
      final url = playlist?.getChannelUrl(next) ?? '';
      if (url.isEmpty) return;

      ref.read(livePlayerProvider.notifier).openChannel(url);
      ref.read(recentlyViewedLiveProvider.notifier).add(next.streamId);
    });

    final isMaximized = ref.watch(livePlayerMaximizedProvider);
    final epgVisible = ref.watch(epgPanelVisibleProvider);
    final sidebarW = ref.watch(categorySidebarWidthProvider);
    final previewH = ref.watch(previewAreaHeightProvider);

    if (_isRefreshing) {
      return _LiveScanScreen(hasOldCache: _hasCache);
    }

    return KeyboardListener(
      focusNode: _keyboardFocus,
      onKeyEvent: _handleKeyEvent,
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (isMaximized) {
            ref.read(livePlayerMaximizedProvider.notifier).state = false;
            return;
          }
          try {
            ref.read(livePlayerProvider.notifier).stop();
          } catch (_) {}
          context.go('/home');
        },
        child: Scaffold(
          backgroundColor: AppTheme.background,
          body: LayoutBuilder(
            builder: (ctx, constraints) {
              const topBarH = 52.0;
              const dividerW = 24.0; // sidebar resize divider width

              final playerLeft = isMaximized ? 0.0 : sidebarW + dividerW;
              final playerTop = isMaximized ? 0.0 : topBarH;
              final playerW = isMaximized
                  ? constraints.maxWidth
                  : constraints.maxWidth - sidebarW - dividerW;
              final playerH = isMaximized
                  ? constraints.maxHeight
                  : epgVisible
                  ? previewH
                  : constraints.maxHeight - topBarH;

              return Stack(
                children: [
                  // ── Layer 1: Main layout ──────────────────────────────
                  _buildLayoutBody(isMaximized, epgVisible),

                  // ── Layer 2: Inline player ────────────────────────────
                  // Stays at the SAME position in the widget tree always
                  // → video never reloads during maximize/minimize.
                  if (!_epgFullscreen || isMaximized)
                    AnimatedPositioned(
                      duration: const Duration(milliseconds: 320),
                      curve: Curves.easeInOutCubic,
                      left: playerLeft,
                      top: playerTop,
                      width: playerW,
                      height: playerH,
                      child: LiveInlinePlayer(
                        isMaximized: isMaximized,
                        onMaximize: () =>
                            ref
                                    .read(livePlayerMaximizedProvider.notifier)
                                    .state =
                                true,
                        onMinimize: () =>
                            ref
                                    .read(livePlayerMaximizedProvider.notifier)
                                    .state =
                                false,
                      ),
                    ),

                  // ── Layer 3: Channel number overlay ───────────────────
                  if (_channelInputStr.isNotEmpty)
                    _ChannelInputOverlay(number: _channelInputStr),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  // ── Main layout ───────────────────────────────────────────────────────
  Widget _buildLayoutBody(bool isMaximized, bool epgVisible) {
    return Column(
      children: [
        _DesktopTopBar(
          epgVisible: epgVisible,
          epgFullscreen: _epgFullscreen,
          onToggleEpg: () =>
              ref.read(epgPanelVisibleProvider.notifier).state = !epgVisible,
          onToggleEpgFullscreen: () =>
              setState(() => _epgFullscreen = !_epgFullscreen),
          onSearch: (q) => ref.read(liveSearchQueryProvider.notifier).state = q,
        ),
        Expanded(
          child: Row(
            children: [
              LiveCategorySidebar(
                width: ref.watch(categorySidebarWidthProvider),
              ),
              _ResizeDivider(
                axis: Axis.vertical,
                isActive: _draggingCategory,
                onDragStart: () => setState(() => _draggingCategory = true),
                onDragEnd: () => setState(() => _draggingCategory = false),
                onDelta: (dx) {
                  final v = (ref.read(categorySidebarWidthProvider) + dx).clamp(
                    160.0,
                    340.0,
                  );
                  ref.read(categorySidebarWidthProvider.notifier).state = v;
                },
              ),
              Expanded(child: _buildMainContent(epgVisible)),
            ],
          ),
        ),
      ],
    );
  }

  /// Handles all three states:
  ///  - EPG hidden  → full preview area (no EPG)
  ///  - EPG fullscreen → full EPG (no preview)
  ///  - Normal → preview on top, EPG on bottom
  Widget _buildMainContent(bool epgVisible) {
    // EPG fullscreen: hide player, show full EPG
    if (_epgFullscreen) return const EpgTimeline();

    // EPG hidden: player in Stack covers entire right panel
    if (!epgVisible) return const SizedBox.expand();

    // Normal: empty placeholder (same height as player) + resize divider + EPG
    return Column(
      children: [
        // PLACEHOLDER — keeps EPG pushed to correct position.
        // The actual player lives in the Stack layer above.
        SizedBox(height: ref.watch(previewAreaHeightProvider)),
        _ResizeDivider(
          axis: Axis.horizontal,
          isActive: _draggingPreview,
          onDragStart: () => setState(() => _draggingPreview = true),
          onDragEnd: () => setState(() => _draggingPreview = false),
          onDelta: (dy) {
            final v = (ref.read(previewAreaHeightProvider) + dy).clamp(
              160.0,
              380.0,
            );
            ref.read(previewAreaHeightProvider.notifier).state = v;
          },
        ),
        const Expanded(child: EpgTimeline()),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE SCAN SCREEN — matches Image 2 style, single card with spinner
// ─────────────────────────────────────────────────────────────────────────────
class _LiveScanScreen extends StatefulWidget {
  final bool hasOldCache;
  const _LiveScanScreen({this.hasOldCache = false});

  @override
  State<_LiveScanScreen> createState() => _LiveScanScreenState();
}

class _LiveScanScreenState extends State<_LiveScanScreen> {
  DateTime _now = DateTime.now();
  Timer? _clockTimer;

  @override
  void initState() {
    super.initState();
    _clockTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) => setState(() => _now = DateTime.now()),
    );
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final lastUpdate = CacheService.instance.lastUpdatedLive();
    final subtitle = widget.hasOldCache && lastUpdate != null
        ? 'Last update: ${_ago(lastUpdate)}'
        : null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ───────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              child: Row(
                children: [
                  _Logo(),
                  const Spacer(),
                  const Text(
                    'Fetching Data',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        DateFormat('hh:mm a').format(_now),
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 26,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      Text(
                        DateFormat('EEE\ndd MMM').format(_now),
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                        textAlign: TextAlign.right,
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // ── Single card ───────────────────────────────────────────
            Expanded(
              child: Center(
                child: _ScanCard(
                  label: 'Live TV',
                  icon: Icons.tv_outlined,
                  isLoading: true,
                  subtitle: subtitle,
                ),
              ),
            ),

            // ── Status text ───────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              child: Text(
                widget.hasOldCache
                    ? 'Refreshing Live TV ...'
                    : 'Fetching Live TV channels for the first time...',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _ago(DateTime dt) {
    final d = DateTime.now().difference(dt);
    if (d.inMinutes < 60) return '${d.inMinutes}m ago';
    if (d.inHours < 24) return '${d.inHours}h ago';
    return '${d.inDays} days ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SCAN CARD — matches SyncScreen card style (reusable for Movies/Series too)
// ─────────────────────────────────────────────────────────────────────────────
class _ScanCard extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool isLoading;
  final String? subtitle;

  const _ScanCard({
    required this.label,
    required this.icon,
    this.isLoading = false,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: 260,
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      decoration: BoxDecoration(
        color: isLoading
            ? AppTheme.surface
            : AppTheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: isLoading
              ? AppTheme.primary.withValues(alpha: 0.3)
              : AppTheme.divider,
          width: isLoading ? 1.5 : 1,
        ),
        boxShadow: isLoading
            ? [
                BoxShadow(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 22),
          SizedBox(
            width: 120,
            height: 120,
            child: Stack(
              alignment: Alignment.center,
              children: [
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.surfaceVariant,
                    border: Border.all(color: AppTheme.divider, width: 2),
                  ),
                  child: Icon(
                    icon,
                    size: 40,
                    color: isLoading
                        ? AppTheme.textPrimary
                        : AppTheme.textMuted,
                  ),
                ),
                if (isLoading)
                  const SizedBox(
                    width: 116,
                    height: 116,
                    child: CircularProgressIndicator(
                      strokeWidth: 3.5,
                      strokeCap: StrokeCap.round,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        AppTheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Text(
            label,
            style: TextStyle(
              color: isLoading ? AppTheme.textPrimary : AppTheme.textMuted,
              fontSize: 16,
              fontWeight: isLoading ? FontWeight.w700 : FontWeight.w400,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOGO
// ─────────────────────────────────────────────────────────────────────────────
class _Logo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: Image.asset('assets/images/logo.png', fit: BoxFit.contain),
        ),
        const SizedBox(width: 8),
        const Text(
          'Lunar IPTV Player',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.5,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL INPUT OVERLAY
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelInputOverlay extends StatelessWidget {
  final String number;
  const _ChannelInputOverlay({required this.number});

  @override
  Widget build(BuildContext context) {
    return Positioned(
      top: 16,
      left: 0,
      right: 0,
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.primary, width: 2),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.3),
                blurRadius: 20,
                spreadRadius: 2,
              ),
            ],
          ),
          child: Text(
            number,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 36,
              fontWeight: FontWeight.w800,
              letterSpacing: 10,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DESKTOP TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _DesktopTopBar extends ConsumerWidget {
  final bool epgVisible;
  final bool epgFullscreen;
  final VoidCallback onToggleEpg;
  final VoidCallback onToggleEpgFullscreen;
  final ValueChanged<String> onSearch;

  const _DesktopTopBar({
    required this.epgVisible,
    required this.epgFullscreen,
    required this.onToggleEpg,
    required this.onToggleEpgFullscreen,
    required this.onSearch,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedCat = ref.watch(selectedLiveCategoryProvider);
    return Container(
      height: 52,
      color: AppTheme.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _FocusableIconButton(
            icon: Icons.arrow_back_ios_new,
            iconColor: AppTheme.textSecondary,
            tooltip: 'Back to Home',
            onTap: () => context.go('/home'),
          ),
          const Icon(Icons.tv_outlined, color: AppTheme.primary, size: 18),
          const SizedBox(width: 8),
          const Text(
            'Live TV',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (selectedCat != null) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6),
              child: Icon(
                Icons.chevron_right,
                color: AppTheme.textMuted,
                size: 16,
              ),
            ),
            Flexible(
              child: Text(
                selectedCat.categoryName,
                style: const TextStyle(color: AppTheme.primary, fontSize: 13),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          const Spacer(),
          _TopBtn(
            icon: epgVisible
                ? Icons.view_timeline_outlined
                : Icons.view_timeline,
            tooltip: epgVisible ? 'Hide EPG' : 'Show EPG',
            isActive: epgVisible,
            onTap: onToggleEpg,
          ),
          const SizedBox(width: 4),
          _TopBtn(
            icon: epgFullscreen
                ? Icons.fullscreen_exit
                : Icons.fit_screen_outlined,
            tooltip: epgFullscreen ? 'Exit EPG Fullscreen' : 'EPG Fullscreen',
            isActive: epgFullscreen,
            onTap: onToggleEpgFullscreen,
          ),
          const SizedBox(width: 4),
          _ExpandableSearch(onChanged: onSearch),
          const SizedBox(width: 4),
          _TopBtn(
            icon: Icons.refresh,
            tooltip: 'Refresh',
            onTap: () {
              ref.invalidate(liveStreamsProvider);
              ref.invalidate(liveCategoriesProvider);
              ref.read(epgCacheProvider.notifier).clear();
            },
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FOCUSABLE ICON BUTTON — TV remote + touch + mouse
// ─────────────────────────────────────────────────────────────────────────────
class _FocusableIconButton extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String tooltip;
  final VoidCallback onTap;

  const _FocusableIconButton({
    required this.icon,
    required this.iconColor,
    required this.tooltip,
    required this.onTap,
  });

  @override
  State<_FocusableIconButton> createState() => _FocusableIconButtonState();
}

class _FocusableIconButtonState extends State<_FocusableIconButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: _focused
                    ? Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.7),
                        width: 2,
                      )
                    : null,
                color: _focused
                    ? AppTheme.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
              ),
              child: Icon(
                widget.icon,
                size: 16,
                color: _focused ? AppTheme.primary : widget.iconColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TopBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final bool isActive;
  final VoidCallback onTap;

  const _TopBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isActive = false,
  });

  @override
  State<_TopBtn> createState() => _TopBtnState();
}

class _TopBtnState extends State<_TopBtn> {
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
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
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: widget.isActive || _focused
                    ? AppTheme.primary.withValues(alpha: 0.20)
                    : _pressed
                    ? AppTheme.primary.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
                border: _focused
                    ? Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.8),
                        width: 2,
                      )
                    : widget.isActive
                    ? Border.all(color: AppTheme.primary.withValues(alpha: 0.3))
                    : null,
              ),
              child: Icon(
                widget.icon,
                size: 18,
                color: (widget.isActive || _focused)
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ExpandableSearch extends StatefulWidget {
  final ValueChanged<String> onChanged;
  const _ExpandableSearch({required this.onChanged});

  @override
  State<_ExpandableSearch> createState() => _ExpandableSearchState();
}

class _ExpandableSearchState extends State<_ExpandableSearch> {
  final _ctrl = TextEditingController();
  bool _expanded = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      width: _expanded ? 200 : 32,
      height: 32,
      decoration: BoxDecoration(
        color: _expanded ? AppTheme.surfaceVariant : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        border: _expanded ? Border.all(color: AppTheme.divider) : null,
      ),
      child: Row(
        children: [
          GestureDetector(
            onTap: () {
              setState(() => _expanded = !_expanded);
              if (!_expanded) {
                _ctrl.clear();
                widget.onChanged('');
              }
            },
            child: SizedBox(
              width: 32,
              height: 32,
              child: Icon(
                _expanded ? Icons.close : Icons.search,
                size: 18,
                color: _expanded ? AppTheme.primary : AppTheme.textSecondary,
              ),
            ),
          ),
          if (_expanded)
            Expanded(
              child: TextField(
                controller: _ctrl,
                autofocus: true,
                onChanged: widget.onChanged,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                ),
                decoration: const InputDecoration(
                  hintText: 'Search channels...',
                  hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 13),
                  border: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                  isDense: true,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESIZE DIVIDER — fat touch target, thin visual
// ─────────────────────────────────────────────────────────────────────────────
class _ResizeDivider extends StatefulWidget {
  final Axis axis;
  final bool isActive;
  final VoidCallback onDragStart;
  final VoidCallback onDragEnd;
  final ValueChanged<double> onDelta;

  const _ResizeDivider({
    required this.axis,
    required this.isActive,
    required this.onDragStart,
    required this.onDragEnd,
    required this.onDelta,
  });

  @override
  State<_ResizeDivider> createState() => _ResizeDividerState();
}

class _ResizeDividerState extends State<_ResizeDivider> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final isH = widget.axis == Axis.horizontal;
    return MouseRegion(
      cursor: isH
          ? SystemMouseCursors.resizeRow
          : SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: !isH ? (_) => widget.onDragStart() : null,
        onHorizontalDragUpdate: !isH ? (d) => widget.onDelta(d.delta.dx) : null,
        onHorizontalDragEnd: !isH ? (_) => widget.onDragEnd() : null,
        onVerticalDragStart: isH ? (_) => widget.onDragStart() : null,
        onVerticalDragUpdate: isH ? (d) => widget.onDelta(d.delta.dy) : null,
        onVerticalDragEnd: isH ? (_) => widget.onDragEnd() : null,
        child: Container(
          // Wide touch target (24px horizontal, 16px vertical)
          width: isH ? double.infinity : 24,
          height: isH ? 16 : double.infinity,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: isH ? 40 : (_hovering || widget.isActive ? 3 : 1),
            height: isH
                ? (_hovering || widget.isActive ? 3 : 1)
                : double.infinity,
            color: _hovering || widget.isActive
                ? AppTheme.primary
                : AppTheme.divider,
            margin: isH
                ? EdgeInsets.zero
                : const EdgeInsets.symmetric(horizontal: 10),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLAY CHANNEL — selects and maximizes the inline player (no new route)
// ─────────────────────────────────────────────────────────────────────────────
void playChannel(BuildContext context, WidgetRef ref, LiveStream channel) {
  // Selecting the channel triggers ref.listen → auto-loads in inline player
  ref.read(selectedChannelProvider.notifier).state = channel;
  ref.read(epgCacheProvider.notifier).loadEpg(channel.streamId);
  // Maximize the inline player
  ref.read(livePlayerMaximizedProvider.notifier).state = true;
}
