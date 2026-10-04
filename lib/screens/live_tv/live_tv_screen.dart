import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/focus_utils.dart';
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

  // ── TV remote long-press detection (repeat-count based) ────────────────────
  int _categoryOkRepeatCount = 0;
  static const int _kLongPressRepeatThreshold = 5;

  // ── Panel focus nodes ──────────────────────────────────────────────────────
  final _categoryPanelFocus = FocusScopeNode(debugLabel: 'CategoryPanel');
  final _channelPanelFocus = FocusScopeNode(debugLabel: 'ChannelPanel');
  final _previewPanelFocus = FocusScopeNode(debugLabel: 'PreviewPanel');

  // ── Cross-panel navigation nodes (shared with child widgets) ───────────────
  // These let arrow keys jump directly between regions regardless of which
  // FocusScope each widget lives in — see TvNav in focus_utils.dart.
  final FocusNode backBtnFocus = FocusNode(debugLabel: 'liveTvBack');
  final FocusNode categorySearchFocus = FocusNode(debugLabel: 'categorySearch');
  final FocusNode channelSearchFocus = FocusNode(debugLabel: 'channelSearch');
  final FocusNode refreshEpgFocus = FocusNode(debugLabel: 'refreshEpg');
  final FocusNode epgFullscreenFocus = FocusNode(debugLabel: 'epgFullscreen');
  final FocusNode watchNowFocus = FocusNode(debugLabel: 'watchNow');
  final FocusNode miniPlayPauseFocus = FocusNode(debugLabel: 'miniPlayPause');

  /// First focusable category-sidebar item (set by LiveCategorySidebar).
  FocusNode? firstCategoryItemFocus;

  /// Currently-selected category tile's FocusNode (set by LiveCategorySidebar).
  FocusNode? selectedCategoryItemFocus;

  /// First focusable channel-list item (set by EpgTimeline / ChannelCell).
  FocusNode? firstChannelItemFocus;

  // ── Category long-press detection (Bug 1 fix) ──────────────────────────────
  Timer? _categoryLongPressTimer;
  bool _categoryLongPressFired = false;

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
      _categoryPanelFocus.onKeyEvent = _handleCategoryPanelKey;
      _previewPanelFocus.onKeyEvent = _handlePreviewPanelKey;
      _channelPanelFocus.onKeyEvent = _handleChannelPanelKey;
      _wireCrossPanelNav();
      if (_isRefreshing) {
        _doRefresh();
      } else {
        _restoreFromLastWatched();
      }
    });
  }

  // ── Cross-panel TV remote navigation graph ──────────────────────────────
  // Wires the fixed navigation spec for: Back, Category Search, Channel
  // Search, Refresh EPG, EPG Fullscreen, Watch Now, Mini-player Play/Pause.
  // Category/Channel list internal scrolling is handled by their own
  // FocusScope key handlers + per-item onArrowKey (see those widgets).
  void _wireCrossPanelNav() {
    backBtnFocus.onKeyEvent = TvNav.handler(down: categorySearchFocus);

    categorySearchFocus.onKeyEvent = TvNav.handler(
      up: backBtnFocus,
      onDown: () =>
          (firstCategoryItemFocus ?? categorySearchFocus).requestFocus(),
      onRight: () {
        if (firstChannelItemFocus != null) {
          firstChannelItemFocus!.requestFocus();
        }
      },
    );

    channelSearchFocus.onKeyEvent = TvNav.handler(
      up: watchNowFocus,
      onDown: () =>
          (firstChannelItemFocus ?? channelSearchFocus).requestFocus(),
      onLeft: () =>
          (selectedCategoryItemFocus ?? firstCategoryItemFocus)?.requestFocus(),
      right: refreshEpgFocus,
    );

    refreshEpgFocus.onKeyEvent = TvNav.handler(
      up: watchNowFocus,
      onDown: () => (firstChannelItemFocus ?? refreshEpgFocus).requestFocus(),
      left: channelSearchFocus,
      right: epgFullscreenFocus,
    );

    epgFullscreenFocus.onKeyEvent = TvNav.handler(
      up: watchNowFocus,
      onDown: () =>
          (firstChannelItemFocus ?? epgFullscreenFocus).requestFocus(),
      left: refreshEpgFocus,
    );

    watchNowFocus.onKeyEvent = TvNav.handler(
      up: backBtnFocus,
      down: channelSearchFocus,
      left: miniPlayPauseFocus,
    );

    miniPlayPauseFocus.onKeyEvent = TvNav.handler(
      up: backBtnFocus,
      down: channelSearchFocus,
      onLeft: () =>
          (selectedCategoryItemFocus ?? firstCategoryItemFocus)?.requestFocus(),
      right: watchNowFocus,
    );
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

  // ── Category panel key handler ────────────────────────────────────────────
  KeyEventResult _handleCategoryPanelKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      // ── Right → go to preview area ─────────────────────────────
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _previewPanelFocus.requestFocus();
        return KeyEventResult.handled;
      }

      // ── OK long-press detection (TV remote hide-category) ───────
      final isOk =
          event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter;
      if (isOk) {
        _categoryOkRepeatCount = 0;
        return KeyEventResult.ignored;
      }
    }

    if (event is KeyRepeatEvent) {
      final isOk =
          event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter;
      if (isOk) {
        _categoryOkRepeatCount++;
        if (_categoryOkRepeatCount == _kLongPressRepeatThreshold) {
          _showCategoryOptionsMenu();
        }
        return KeyEventResult.handled;
      }
    }

    if (event is KeyUpEvent) {
      final isOk =
          event.logicalKey == LogicalKeyboardKey.select ||
          event.logicalKey == LogicalKeyboardKey.enter;
      if (isOk) {
        _categoryOkRepeatCount = 0;
      }
    }

    return KeyEventResult.ignored;
  }

  // ── Preview panel key handler ─────────────────────────────────────────────
  // Fires when LiveInlinePlayer (compact) has focus.
  KeyEventResult _handlePreviewPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Left → back to categories
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _categoryPanelFocus.requestFocus();
      return KeyEventResult.handled;
    }

    final epgVis = ref.read(epgPanelVisibleProvider);

    // Down or Right → EPG channel list (when EPG is visible)
    if ((event.logicalKey == LogicalKeyboardKey.arrowDown ||
            event.logicalKey == LogicalKeyboardKey.arrowRight) &&
        epgVis &&
        !_epgFullscreen) {
      _channelPanelFocus.requestFocus();
      return KeyEventResult.handled;
    }

    // Back / Escape → home (when not maximized)
    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      final isMax = ref.read(livePlayerMaximizedProvider);
      if (isMax) {
        ref.read(livePlayerMaximizedProvider.notifier).state = false;
      } else {
        try {
          ref.read(livePlayerProvider.notifier).stop();
        } catch (_) {}
        context.go('/home');
      }
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  // ── Channel/EPG panel key handler ─────────────────────────────────────────
  // Fires when EPG timeline has focus.
  KeyEventResult _handleChannelPanelKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    // Left is handled by individual _ChannelCell (focusInDirection left)
    // Up from top → preview area
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      final epgVis = ref.read(epgPanelVisibleProvider);
      if (epgVis && !_epgFullscreen) {
        _previewPanelFocus.requestFocus();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  void _showCategoryOptionsMenu() {
    final cat = ref.read(selectedLiveCategoryProvider);
    if (cat == null || !mounted) return;

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Row(
          children: [
            const Icon(
              Icons.folder_outlined,
              color: AppTheme.primary,
              size: 20,
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                cat.categoryName,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 2,
              ),
            ),
          ],
        ),
        content: const Text(
          'What would you like to do with this category?',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton.icon(
            autofocus: true,
            icon: const Icon(Icons.visibility_off_outlined, size: 16),
            label: const Text('Hide Category'),
            style: TextButton.styleFrom(foregroundColor: AppTheme.error),
            onPressed: () {
              Navigator.pop(ctx);
              ref
                  .read(hiddenLiveCategoriesProvider.notifier)
                  .toggle(cat.categoryId);
            },
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
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

  // ── Cold-start + post-refresh restore ─────────────────────────────────────
  // Called after cache is ready. Restores last watched category + channel
  // and starts streaming immediately.
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

    // Load categories from cache — near-instant on restart
    List<XtreamCategory> cats;
    try {
      cats = await ref.read(liveCategoriesProvider.future);
    } catch (_) {
      return;
    }
    if (!mounted || _hasRestored || cats.isEmpty) return;
    _hasRestored = true;

    // ── Step 1: Restore category ──────────────────────────────────────────
    XtreamCategory? restoredCategory;
    if (last.categoryId != null) {
      restoredCategory = cats.cast<XtreamCategory?>().firstWhere(
        (c) => c?.categoryId == last.categoryId,
        orElse: () => null,
      );
      if (restoredCategory != null) {
        ref.read(liveFilterProvider.notifier).state = LiveFilter.all;
        ref.read(selectedLiveCategoryProvider.notifier).state =
            restoredCategory;
        // Wait for category filter + stream provider to propagate
        await Future.delayed(const Duration(milliseconds: 500));
        if (!mounted) return;
      }
    }

    // ── Step 2: Find the channel ──────────────────────────────────────────
    if (last.channelId == null) return;

    LiveStream? channel;

    // First try the filtered list (respects current category)
    final filtered = ref.read(filteredLiveStreamsProvider).value;
    channel = filtered?.firstWhereOrNull((s) => s.streamId == last.channelId);

    // Fallback: search all cached streams
    if (channel == null) {
      final allCached =
          CacheService.instance.loadLiveStreams(ignoreExpiry: true) ?? [];
      channel = allCached.firstWhereOrNull((s) => s.streamId == last.channelId);

      // If found in cache but not in filtered list, category may have been
      // "All Channels" — reset to null so all channels show
      if (channel != null && restoredCategory == null) {
        ref.read(liveFilterProvider.notifier).state = LiveFilter.all;
        ref.read(selectedLiveCategoryProvider.notifier).state = null;
        await Future.delayed(const Duration(milliseconds: 200));
        if (!mounted) return;
      }
    }

    if (channel == null || !mounted) return;

    // ── Step 3: Select channel + trigger scroll ───────────────────────────
    // Set scroll target BEFORE setting channel so EPG list scrolls correctly
    ref.read(liveScrollToChannelProvider.notifier).state = channel.streamId;

    // Setting selectedChannelProvider triggers the ref.listen in build()
    // which calls openChannel() and saves last watched automatically
    ref.read(selectedChannelProvider.notifier).state = channel;
    ref.read(epgCacheProvider.notifier).loadEpg(channel.streamId);

    // ── Step 4: Explicitly start streaming ───────────────────────────────
    // The ref.listen fires only on CHANGES. Since selectedChannelProvider
    // was null before this, it will fire. But we also call openChannel
    // directly here as a safety net in case the listener missed it
    // (e.g. if this runs before the first build completes).
    final playlist = ref.read(activePlaylistProvider);
    final url = playlist?.getChannelUrl(channel) ?? '';
    if (url.isNotEmpty) {
      ref.read(livePlayerProvider.notifier).openChannel(url);
    }
  }

  @override
  void dispose() {
    _channelInputTimer?.cancel();
    _keyboardFocus.dispose();
    _categoryPanelFocus.dispose();
    _channelPanelFocus.dispose();
    _categoryLongPressTimer?.cancel();
    _previewPanelFocus.dispose();
    backBtnFocus.dispose();
    categorySearchFocus.dispose();
    channelSearchFocus.dispose();
    refreshEpgFocus.dispose();
    epgFullscreenFocus.dispose();
    watchNowFocus.dispose();
    miniPlayPauseFocus.dispose();
    // Fire-and-forget — dispose() cannot be async.
    // _stopPlayer was already called in PopScope before navigate,
    // this is a safety net for cases where dispose fires without pop.
    unawaited(_stopPlayer());
    super.dispose();
  }

  /// Stops the inline live player safely.
  /// Called from both dispose() and PopScope back-navigation.
  /// Returns a Future so back-navigation can await it before routing away.
  Future<void> _stopPlayer() async {
    try {
      await ref.read(livePlayerProvider.notifier).stop();
    } catch (_) {}
  }

  // ── Build ─────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    // ── Auto-load channel in inline player when selection changes ──────────
    // This is the SINGLE central point that handles all channel changes:
    // from channel list, EPG timeline, player switch buttons, time-of-day
    // strip, channel guide — all trigger this listener.
    ref.listen<LiveStream?>(selectedChannelProvider, (prev, next) {
      if (next == null || next.streamId == prev?.streamId) return;

      final playlist = ref.read(activePlaylistProvider);
      final url = playlist?.getChannelUrl(next) ?? '';
      if (url.isEmpty) return;

      // Start streaming
      ref.read(livePlayerProvider.notifier).openChannel(url);
      ref.read(recentlyViewedLiveProvider.notifier).add(next.streamId);

      // Centrally save last watched (notifier checks rememberPosition internally)
      final category = ref.read(selectedLiveCategoryProvider);
      ref
          .read(lastWatchedLiveProvider.notifier)
          .save(categoryId: category?.categoryId, channelId: next.streamId);
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
      onKeyEvent: (KeyEvent event) {
        // Handles digit input (CH number overlay) and Escape (minimize player)
        _handleKeyEvent(event);
      },
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) async {
          if (didPop) return;
          if (isMaximized) {
            ref.read(livePlayerMaximizedProvider.notifier).state = false;
            return;
          }
          // Await stop so audio cuts before the route transition begins.
          await _stopPlayer();
          if (mounted) context.go('/home');
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
                      // ── WRAPPED: gives preview area its own focus scope ──────────
                      child: FocusScope(
                        node: _previewPanelFocus,
                        child: LiveInlinePlayer(
                          isMaximized: isMaximized,
                          watchNowFocusNode: watchNowFocus,
                          playPauseFocusNode: miniPlayPauseFocus,
                          categoryEntryFocus: () =>
                              selectedCategoryItemFocus ??
                              firstCategoryItemFocus,
                          channelSearchFocus: channelSearchFocus,
                          backFocusNode: backBtnFocus,
                          onMaximize: () =>
                              ref
                                      .read(
                                        livePlayerMaximizedProvider.notifier,
                                      )
                                      .state =
                                  true,
                          onMinimize: () =>
                              ref
                                      .read(
                                        livePlayerMaximizedProvider.notifier,
                                      )
                                      .state =
                                  false,
                        ),
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
          backFocusNode: backBtnFocus,
          onToggleEpg: () =>
              ref.read(epgPanelVisibleProvider.notifier).state = !epgVisible,
        ),
        Expanded(
          child: Row(
            children: [
              // ── WRAPPED HERE: Category Sidebar ─────────────────────
              FocusScope(
                node: _categoryPanelFocus,
                child: LiveCategorySidebar(
                  width: ref.watch(categorySidebarWidthProvider),
                  searchFocusNode: categorySearchFocus,
                  channelListEntryFocus: () => firstChannelItemFocus,
                  onFirstItemFocusReady: (node) =>
                      firstCategoryItemFocus = node,
                  onSelectedItemFocusReady: (node) =>
                      selectedCategoryItemFocus = node,
                ),
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
              Expanded(
                child: FocusScope(
                  node: _channelPanelFocus,
                  child: _buildMainContent(epgVisible),
                ),
              ),
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
    if (_epgFullscreen) {
      return EpgTimeline(
        isFullscreen: _epgFullscreen,
        onToggleFullscreen: () =>
            setState(() => _epgFullscreen = !_epgFullscreen),
        searchFocusNode: channelSearchFocus,
        refreshFocusNode: refreshEpgFocus,
        fullscreenFocusNode: epgFullscreenFocus,
        watchNowFocus: watchNowFocus,
        categoryEntryFocus: () =>
            selectedCategoryItemFocus ?? firstCategoryItemFocus,
        onFirstItemFocusReady: (node) => firstChannelItemFocus = node,
      );
    }

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
        Expanded(
          child: EpgTimeline(
            isFullscreen: _epgFullscreen,
            onToggleFullscreen: () =>
                setState(() => _epgFullscreen = !_epgFullscreen),
            searchFocusNode: channelSearchFocus,
            refreshFocusNode: refreshEpgFocus,
            fullscreenFocusNode: epgFullscreenFocus,
            watchNowFocus: watchNowFocus,
            categoryEntryFocus: () =>
                selectedCategoryItemFocus ?? firstCategoryItemFocus,
            onFirstItemFocusReady: (node) => firstChannelItemFocus = node,
          ),
        ),
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
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 280, minWidth: 160),
      child: AspectRatio(
        aspectRatio: 0.78,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 300),
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
          child: LayoutBuilder(
            builder: (_, constraints) {
              final ringSize = (constraints.maxWidth * 0.48).clamp(60.0, 110.0);
              final iconSize = (ringSize * 0.42).clamp(24.0, 46.0);
              final spinSize = ringSize + 14;
              return Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  const Spacer(),
                  SizedBox(
                    width: spinSize,
                    height: spinSize,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          width: ringSize,
                          height: ringSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppTheme.surfaceVariant,
                            border: Border.all(
                              color: AppTheme.divider,
                              width: 2,
                            ),
                          ),
                          child: Icon(
                            icon,
                            size: iconSize,
                            color: isLoading
                                ? AppTheme.textPrimary
                                : AppTheme.textMuted,
                          ),
                        ),
                        if (isLoading)
                          SizedBox(
                            width: spinSize,
                            height: spinSize,
                            child: const CircularProgressIndicator(
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
                  const Spacer(),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Text(
                      label,
                      textAlign: TextAlign.center,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: isLoading
                            ? AppTheme.textPrimary
                            : AppTheme.textMuted,
                        fontSize: 14,
                        fontWeight: isLoading
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        subtitle!,
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              );
            },
          ),
        ),
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
  final VoidCallback onToggleEpg;
  final FocusNode? backFocusNode;

  const _DesktopTopBar({
    required this.epgVisible,
    required this.onToggleEpg,
    this.backFocusNode,
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
            focusNode: backFocusNode,
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
  final FocusNode? focusNode;

  const _FocusableIconButton({
    required this.icon,
    required this.iconColor,
    required this.tooltip,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_FocusableIconButton> createState() => _FocusableIconButtonState();
}

class _FocusableIconButtonState extends State<_FocusableIconButton> {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      autoScroll: false,
      onActivate: widget.onTap,
      builder: (focused, _) => Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            border: focused
                ? Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.7),
                    width: 2,
                  )
                : null,
            color: focused
                ? AppTheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
          ),
          child: Icon(
            widget.icon,
            size: 16,
            color: focused ? AppTheme.primary : widget.iconColor,
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
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onActivate: widget.onTap,
      builder: (focused, pressed) => Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: widget.isActive || focused
                ? AppTheme.primary.withValues(alpha: 0.20)
                : pressed
                ? AppTheme.primary.withValues(alpha: 0.12)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: focused
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
            color: (widget.isActive || focused)
                ? AppTheme.primary
                : AppTheme.textSecondary,
          ),
        ),
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

// ── Extension ─────────────────────────────────────────────────────────────────
extension _IterableExt<T> on Iterable<T> {
  T? firstWhereOrNull(bool Function(T) test) {
    for (final e in this) {
      if (test(e)) return e;
    }
    return null;
  }
}
