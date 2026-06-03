import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lunar_iptv_player/providers/behavior_providers.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';
import 'package:lunar_iptv_player/widgets/for_you_section.dart';

import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/movies_provider.dart';
import '../../services/cache_service.dart';
import '../../widgets/app_network_image.dart';
import 'widgets/movie_detail_panel.dart';

class MoviesScreen extends ConsumerStatefulWidget {
  const MoviesScreen({super.key});

  @override
  ConsumerState<MoviesScreen> createState() => _MoviesScreenState();
}

class _MoviesScreenState extends ConsumerState<MoviesScreen> {
  double _sidebarWidth = 220;
  static const _sidebarMin = 160.0;
  static const _sidebarMax = 320.0;

  bool _isRefreshing = false;
  bool _hasCache = false;

  @override
  void initState() {
    super.initState();
    // Ensure correct playlist context (guards against stale _playlistId = 'default')
    final activeId = StorageService.instance.getActivePlaylistId();
    if (activeId != null) CacheService.instance.setActivePlaylist(activeId);

    final cache = CacheService.instance;
    final streams = cache.loadVodStreams(ignoreExpiry: true);
    _hasCache = streams?.isNotEmpty ?? false;
    _isRefreshing = !_hasCache || cache.isVodStale();
    if (_isRefreshing) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _doRefresh());
    }
  }

  Future<void> _doRefresh() async {
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
    for (int i = 0; i < 3 && !success; i++) {
      if (i > 0) await Future.delayed(const Duration(seconds: 5));
      try {
        final cats = await service.getVodCategories().timeout(
          const Duration(seconds: 30),
        );
        final streams = await service.getVodStreams().timeout(
          const Duration(seconds: 90),
        );
        await CacheService.instance.saveVodCategories(cats);
        await CacheService.instance.saveVodStreams(streams);
        ref.invalidate(vodCategoriesProvider);
        ref.invalidate(vodStreamsProvider);
        success = true;
      } catch (_) {}
    }
    if (!mounted) return;
    if (!success && !_hasCache) {
      context.go('/home');
    } else {
      setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isRefreshing) {
      return _VodScanScreen(
        label: 'Movies',
        icon: Icons.video_library_outlined,
        hasOldCache: _hasCache,
        lastUpdate: CacheService.instance.lastUpdatedVod(),
        statusText: _hasCache
            ? 'Refreshing Movies library...'
            : 'Fetching Movies for the first time...',
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        context.go('/home');
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _TopBar(),
              Expanded(
                child: Row(
                  children: [
                    _VodCategorySidebar(width: _sidebarWidth),
                    _ResizableDivider(
                      onDrag: (dx) => setState(() {
                        _sidebarWidth = (_sidebarWidth + dx).clamp(
                          _sidebarMin,
                          _sidebarMax,
                        );
                      }),
                    ),
                    Expanded(child: _MoviesContent()),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _TopBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref.watch(selectedVodCategoryProvider);
    final streamsAsync = ref.watch(vodStreamsProvider);
    final count = streamsAsync.whenData((s) => s.length).value ?? 0;

    return Container(
      height: 52,
      color: AppTheme.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            onPressed: () => context.go('/home'),
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: AppTheme.textSecondary,
              size: 16,
            ),
            tooltip: 'Back',
          ),
          const Icon(Icons.movie_outlined, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          const Text(
            'Movies',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (category != null) ...[
            const Icon(
              Icons.chevron_right,
              color: AppTheme.textMuted,
              size: 16,
            ),
            Flexible(
              child: Text(
                category.categoryName,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
          if (count > 0) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                '$count',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
            ),
          ],
          const Spacer(),
          // Sort dropdown
          _SortDropdown(),
          const SizedBox(width: 8),
          // Search
          _SearchButton(),
          const SizedBox(width: 8),
          // Refresh
          IconButton(
            onPressed: () => ref.invalidate(vodStreamsProvider),
            icon: const Icon(
              Icons.refresh,
              color: AppTheme.textSecondary,
              size: 20,
            ),
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

class _SortDropdown extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sort = ref.watch(vodSortProvider);
    return DropdownButton<VodSortBy>(
      value: sort,
      underline: const SizedBox.shrink(),
      dropdownColor: AppTheme.surface,
      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      items: [
        DropdownMenuItem<VodSortBy>(
          value: VodSortBy.nameAZ,
          child: Text('A–Z'),
        ),
        DropdownMenuItem<VodSortBy>(
          value: VodSortBy.nameZA,
          child: Text('Z–A'),
        ),
        DropdownMenuItem<VodSortBy>(
          value: VodSortBy.ratingHighLow,
          child: Text('Top Rated'),
        ),
        DropdownMenuItem<VodSortBy>(
          value: VodSortBy.recentlyAdded,
          child: Text('Recently Added'),
        ),
        DropdownMenuItem<VodSortBy>(
          value: VodSortBy.defaultOrder,
          child: Text('Default'),
        ),
      ],
      onChanged: (v) {
        if (v != null) ref.read(vodSortProvider.notifier).state = v;
      },
    );
  }
}

class _SearchButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SearchButton> createState() => _SearchButtonState();
}

class _SearchButtonState extends ConsumerState<_SearchButton> {
  bool _open = false;
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_open) {
      return IconButton(
        onPressed: () => setState(() => _open = true),
        icon: const Icon(Icons.search, color: AppTheme.textSecondary, size: 20),
      );
    }
    return SizedBox(
      width: 220,
      height: 36,
      child: TextField(
        controller: _ctrl,
        autofocus: true,
        onChanged: (v) => ref.read(vodSearchQueryProvider.notifier).state = v,
        onSubmitted: (_) => setState(() => _open = false),
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search movies...',
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: AppTheme.textMuted,
          ),
          suffixIcon: IconButton(
            onPressed: () {
              _ctrl.clear();
              ref.read(vodSearchQueryProvider.notifier).state = '';
              setState(() => _open = false);
            },
            icon: const Icon(Icons.close, size: 16, color: AppTheme.textMuted),
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          isDense: true,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CATEGORY SIDEBAR — complete, fully scrollable
// ─────────────────────────────────────────────────────────────────────────────
class _VodCategorySidebar extends ConsumerStatefulWidget {
  final double width;
  const _VodCategorySidebar({required this.width});

  @override
  ConsumerState<_VodCategorySidebar> createState() =>
      _VodCategorySidebarState();
}

class _VodCategorySidebarState extends ConsumerState<_VodCategorySidebar> {
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showSearch = false;

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    super.dispose();
  }

  // ── Header ────────────────────────────────────────────────────────
  Widget _buildHeader() {
    return Container(
      height: 52,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.divider)),
      ),
      child: Row(
        children: [
          const Icon(Icons.menu, color: AppTheme.textMuted, size: 16),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'Categories',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            onPressed: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchCtrl.clear();
                _query = '';
              }
            }),
            icon: Icon(
              _showSearch ? Icons.close : Icons.search,
              size: 15,
              color: _showSearch ? AppTheme.primary : AppTheme.textMuted,
            ),
          ),
        ],
      ),
    );
  }

  // ── Search field ──────────────────────────────────────────────────
  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v.toLowerCase().trim()),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Search genres...',
            prefixIcon: Icon(Icons.search, size: 14, color: AppTheme.textMuted),
            contentPadding: EdgeInsets.symmetric(vertical: 8),
            isDense: true,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(vodCategoriesProvider);
    final selected = ref.watch(selectedVodCategoryProvider);
    final streamsAsync = ref.watch(vodStreamsProvider);
    final filter = ref.watch(vodFilterProvider);
    final favorites = ref.watch(vodFavoritesProvider);
    final recentIds = ref.watch(recentlyViewedVodProvider);

    // Count per category
    final countMap = <String, int>{};
    streamsAsync.whenData((streams) {
      for (final s in streams) {
        final id = s.categoryId ?? '';
        countMap[id] = (countMap[id] ?? 0) + 1;
      }
    });
    final totalCount = streamsAsync.whenData((s) => s.length).value ?? 0;

    return SizedBox(
      width: widget.width,
      child: Container(
        color: AppTheme.sidebarBg,
        child: Column(
          children: [
            _buildHeader(), if (_showSearch) _buildSearchField(),

            // ── Entire list scrollable ─────────────────────────────────
            Expanded(
              child: categoriesAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (_, _) => Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: AppTheme.error,
                        size: 32,
                      ),
                      const SizedBox(height: 8),
                      TextButton(
                        onPressed: () => ref.invalidate(vodCategoriesProvider),
                        child: const Text('Retry'),
                      ),
                    ],
                  ),
                ),
                data: (cats) {
                  final filtered = _query.isEmpty
                      ? cats
                      : cats
                            .where(
                              (c) =>
                                  c.categoryName.toLowerCase().contains(_query),
                            )
                            .toList();

                  return ListView(
                    controller: _scrollCtrl,
                    padding: EdgeInsets.zero,
                    children: [
                      // All Movies
                      _SidebarTile(
                        icon: Icons.movie_rounded,
                        iconColor: AppTheme.primary,
                        label: 'All Movies',
                        count: totalCount,
                        isSelected: filter == VodFilter.all && selected == null,
                        onTap: () {
                          ref.read(vodFilterProvider.notifier).state =
                              VodFilter.all;
                          ref.read(selectedVodCategoryProvider.notifier).state =
                              null;
                        },
                      ),

                      // Favorites
                      _SidebarTile(
                        icon: Icons.star_rounded,
                        iconColor: const Color(0xFFFBBF24),
                        label: 'Favorites',
                        count: favorites.length,
                        isSelected: filter == VodFilter.favorites,
                        onTap: () {
                          ref.read(vodFilterProvider.notifier).state =
                              VodFilter.favorites;
                          ref.read(selectedVodCategoryProvider.notifier).state =
                              null;
                        },
                      ),

                      // Recently Viewed
                      _SidebarTile(
                        icon: Icons.history,
                        iconColor: AppTheme.primary,
                        label: 'Recently Viewed',
                        count: recentIds.length,
                        isSelected: filter == VodFilter.recent,
                        onTap: () {
                          ref.read(vodFilterProvider.notifier).state =
                              VodFilter.recent;
                          ref.read(selectedVodCategoryProvider.notifier).state =
                              null;
                        },
                      ),

                      // Recently Added (sort shortcut — not a filter)
                      // Recently Added — top 100 by added timestamp across ALL categories
                      _SidebarTile(
                        icon: Icons.schedule_rounded,
                        iconColor: AppTheme.accent,
                        label: 'Recently Added',
                        isSelected: filter == VodFilter.recentlyAdded,
                        onTap: () {
                          ref.read(vodFilterProvider.notifier).state =
                              VodFilter.recentlyAdded;
                          ref.read(selectedVodCategoryProvider.notifier).state =
                              null;
                          ref.read(vodSortProvider.notifier).state =
                              VodSortBy.defaultOrder;
                        },
                      ),

                      // Genres label
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
                        child: Row(
                          children: [
                            const Text(
                              'GENRES',
                              style: TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                            const Spacer(),
                            Text(
                              '${filtered.length}',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Category items
                      ...filtered.map(
                        (cat) => _SidebarCategoryItem(
                          category: cat,
                          isSelected: selected?.categoryId == cat.categoryId,
                          count: countMap[cat.categoryId] ?? 0,
                          onTap: () {
                            ref.read(vodFilterProvider.notifier).state =
                                VodFilter.all;
                            final newCat =
                                selected?.categoryId == cat.categoryId
                                ? null
                                : cat;
                            ref
                                    .read(selectedVodCategoryProvider.notifier)
                                    .state =
                                newCat;
                          },
                        ),
                      ),

                      const SizedBox(height: 16),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MOVIES CONTENT (grid + detail panel)
// ─────────────────────────────────────────────────────────────────────────────
class _MoviesContent extends ConsumerStatefulWidget {
  @override
  ConsumerState<_MoviesContent> createState() => _MoviesContentState();
}

class _MoviesContentState extends ConsumerState<_MoviesContent> {
  double _detailWidth = 320;
  static const _detailMin = 260.0;
  static const _detailMax = 480.0;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedVodStreamProvider);

    return Row(
      children: [
        // Movies grid
        Expanded(child: _MoviesGrid()),

        // Detail panel
        if (selected != null) ...[
          _ResizableDivider(
            onDrag: (dx) => setState(() {
              _detailWidth = (_detailWidth - dx).clamp(_detailMin, _detailMax);
            }),
          ),
          SizedBox(
            width: _detailWidth,
            child: MovieDetailPanel(movie: selected),
          ),
        ],
      ],
    );
  }
}

class _MoviesGrid extends ConsumerStatefulWidget {
  @override
  ConsumerState<_MoviesGrid> createState() => _MoviesGridState();
}

class _MoviesGridState extends ConsumerState<_MoviesGrid> {
  int _displayLimit = 30;
  final ScrollController _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();

    @override
    void initState() {
      super.initState();
      _scrollCtrl.addListener(_onScroll);
    }
  }

  void _onScroll() {
    if (!mounted) return;
    final pos = _scrollCtrl.position;
    if (pos.pixels > pos.maxScrollExtent - 600) {
      setState(() => _displayLimit = (_displayLimit + 30).clamp(0, 5000));
    }
  }

  @override
  void dispose() {
    _scrollCtrl.removeListener(_onScroll);
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final streamsAsync = ref.watch(sortedVodStreamsProvider);
    final forYouAsync = ref.watch(forYouVodProvider);

    return streamsAsync.when(
      loading: () => const Center(
        child: CircularProgressIndicator(
          color: AppTheme.primary,
          strokeWidth: 2,
        ),
      ),
      error: (e, _) => Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.error, size: 40),
            const SizedBox(height: 12),
            Text('$e', style: const TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            ElevatedButton.icon(
              onPressed: () => ref.invalidate(vodStreamsProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (streams) {
        if (streams.isEmpty) {
          return const Center(
            child: Text(
              'No movies found',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          );
        }

        // Get For You movies — safely falls back to empty list
        final forYouMovies = forYouAsync.valueOrNull ?? [];

        return CustomScrollView(
          controller: _scrollCtrl,
          slivers: [
            // ── For You Section ─────────────────────────────────────────────
            if (forYouMovies.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
                  child: ForYouSection(
                    label: 'Recommended for You',
                    items: forYouMovies
                        .map(
                          (m) => (
                            id: m.streamId,
                            name: m.name,
                            imageUrl: m.streamIcon,
                            rating: m.ratingValue,
                          ),
                        )
                        .toList(),
                    onTap: (id) {
                      final movie = forYouMovies.firstWhere(
                        (m) => m.streamId == id,
                        orElse: () => forYouMovies.first,
                      );
                      ref.read(selectedVodStreamProvider.notifier).state =
                          movie;
                      BehaviorService.instance.recordOpen(id);
                    },
                  ),
                ),
              ),

            // ── Movies Grid ─────────────────────────────────────────────────
            SliverPadding(
              padding: const EdgeInsets.all(12),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 160,
                  childAspectRatio: 0.67,
                  crossAxisSpacing: 10,
                  mainAxisSpacing: 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => RepaintBoundary(
                    child: _MoviePosterCard(movie: streams[i]),
                  ),
                  childCount: streams.length.clamp(0, _displayLimit),
                  // Reuse widgets when scrolling for memory efficiency
                  addRepaintBoundaries: false,
                  addAutomaticKeepAlives: false,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MoviePosterCard extends ConsumerStatefulWidget {
  final VodStream movie;
  const _MoviePosterCard({required this.movie});

  @override
  ConsumerState<_MoviePosterCard> createState() => _MoviePosterCardState();
}

class _MoviePosterCardState extends ConsumerState<_MoviePosterCard> {
  bool _hover = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedVodStreamProvider);
    final isSelected = selected?.streamId == widget.movie.streamId;

    return RepaintBoundary(
      // ← isolates repaints for grid performance
      child: Focus(
        onFocusChange: (f) => setState(() => _focused = f),
        onKeyEvent: (_, event) {
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space)) {
            ref.read(selectedVodStreamProvider.notifier).state = widget.movie;
            return KeyEventResult.handled;
          }
          if (event is KeyDownEvent &&
              event.logicalKey == LogicalKeyboardKey.arrowLeft) {
            FocusScope.of(context).focusInDirection(TraversalDirection.left);
            return KeyEventResult.handled;
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
            onTap: () {
              // Record as search click if user is currently searching
              final query = ref.read(vodSearchQueryProvider);
              if (query.isNotEmpty) {
                BehaviorService.instance.recordSearchClick(
                  widget.movie.streamId,
                );
              }
              // Also record general open count
              BehaviorService.instance.recordOpen(widget.movie.streamId);
              ref.read(selectedVodStreamProvider.notifier).state = widget.movie;
            },
            onTapDown: (_) => setState(() => _pressed = true),
            onTapUp: (_) => setState(() => _pressed = false),
            onTapCancel: () => setState(() => _pressed = false),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primary
                      : (_focused)
                      ? Colors.white.withValues(alpha: 0.6)
                      : (_hover)
                      ? AppTheme.primary.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: (isSelected || _focused) ? 2.5 : 1.5,
                ),
                boxShadow: (isSelected || _focused)
                    ? [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.25),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: AnimatedScale(
                scale: _pressed
                    ? 0.96
                    : (_hover || _focused)
                    ? 1.02
                    : 1.0,
                duration: const Duration(milliseconds: 150),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      PosterImage(
                        url: widget.movie.streamIcon,
                        rating: widget.movie.ratingValue > 0
                            ? widget.movie.ratingValue
                            : null,
                      ),
                      Positioned(
                        bottom: 0,
                        left: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.fromLTRB(6, 16, 6, 6),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                Colors.transparent,
                                Colors.black.withValues(alpha: 0.9),
                              ],
                            ),
                          ),
                          child: Text(
                            widget.movie.name,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED SIDEBAR WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _SidebarTile extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.count = 0,
  });

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hover = false, _focused = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            setState(() => _pressed = true);
            widget.onTap();
            return KeyEventResult.handled;
          }
          // RIGHT → jump to movie grid
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            FocusScope.of(context).focusInDirection(TraversalDirection.right);
            return KeyEventResult.handled;
          }
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.selectedItem
                  : _pressed
                  ? AppTheme.surface.withValues(alpha: 0.8)
                  : (_hover || _focused)
                  ? AppTheme.surface
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: _focused && !widget.isSelected
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 1.5,
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(widget.icon, size: 15, color: widget.iconColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.label,
                    style: TextStyle(
                      color: widget.isSelected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: widget.isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                  ),
                ),
                if (widget.count > 0)
                  Text(
                    '${widget.count}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SidebarCategoryItem extends StatefulWidget {
  final XtreamCategory category;
  final bool isSelected;
  final int count;
  final VoidCallback onTap;

  const _SidebarCategoryItem({
    required this.category,
    required this.isSelected,
    required this.count,
    required this.onTap,
  });

  @override
  State<_SidebarCategoryItem> createState() => _SidebarCategoryItemState();
}

class _SidebarCategoryItemState extends State<_SidebarCategoryItem> {
  bool _hover = false, _focused = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space) {
            setState(() => _pressed = true);
            widget.onTap();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
            FocusScope.of(context).focusInDirection(TraversalDirection.right);
            return KeyEventResult.handled;
          }
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
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.selectedItem
                  : _pressed
                  ? AppTheme.surface.withValues(alpha: 0.8)
                  : (_hover || _focused)
                  ? AppTheme.surface
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: widget.isSelected
                  ? const Border(
                      left: BorderSide(color: AppTheme.primary, width: 2),
                    )
                  : _focused
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.3),
                      width: 1.5,
                    )
                  : null,
            ),
            child: Row(
              children: [
                Icon(
                  Icons.folder_outlined,
                  size: 14,
                  color: widget.isSelected
                      ? AppTheme.primary
                      : AppTheme.textMuted,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.category.categoryName,
                    style: TextStyle(
                      color: widget.isSelected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: widget.isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.count > 0)
                  Text(
                    '${widget.count}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESIZABLE DIVIDER — larger touch target for mobile
// ─────────────────────────────────────────────────────────────────────────────
class _ResizableDivider extends StatefulWidget {
  final ValueChanged<double> onDrag;

  const _ResizableDivider({required this.onDrag});

  @override
  State<_ResizableDivider> createState() => _ResizableDividerState();
}

class _ResizableDividerState extends State<_ResizableDivider> {
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        child: Container(
          // ── Larger touch target (24px) keeps visual thin (4px) ────
          width: 24,
          height: double.infinity,
          color: Colors.transparent,
          alignment: Alignment.center,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            width: _dragging ? 3 : 2,
            height: double.infinity,
            color: _dragging ? AppTheme.primary : AppTheme.divider,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// VOD SCAN SCREEN — shown while fetching stale/new Movies or Series data
// ─────────────────────────────────────────────────────────────────────────────
class _VodScanScreen extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool hasOldCache;
  final DateTime? lastUpdate;
  final String statusText;

  const _VodScanScreen({
    required this.label,
    required this.icon,
    required this.hasOldCache,
    required this.statusText,
    this.lastUpdate,
  });

  @override
  State<_VodScanScreen> createState() => _VodScanScreenState();
}

class _VodScanScreenState extends State<_VodScanScreen> {
  DateTime _now = DateTime.now();
  late final Timer _timer;

  @override
  void initState() {
    super.initState();
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
    final subtitle = widget.hasOldCache && widget.lastUpdate != null
        ? 'Last update: ${_ago(widget.lastUpdate!)}'
        : null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ────────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 20),
              child: Row(
                children: [
                  Row(
                    children: [
                      SizedBox(
                        width: 40,
                        height: 40,
                        child: Image.asset(
                          'assets/images/logo.png',
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
                          letterSpacing: 1.5,
                        ),
                      ),
                    ],
                  ),
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

            // ── Single card ────────────────────────────────────────────
            Expanded(
              child: Center(
                child: _ScanCard(
                  label: widget.label,
                  icon: widget.icon,
                  isLoading: true,
                  subtitle: subtitle,
                ),
              ),
            ),

            // ── Status text ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(32, 0, 32, 28),
              child: Text(
                widget.statusText,
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
    return '${d.inDays}d ago';
  }
}

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
