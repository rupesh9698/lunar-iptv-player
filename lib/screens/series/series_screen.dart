import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/series_provider.dart';
import '../../services/cache_service.dart';
import '../../widgets/app_network_image.dart';
import 'widgets/series_detail_panel.dart';

class SeriesScreen extends ConsumerStatefulWidget {
  const SeriesScreen({super.key});

  @override
  ConsumerState<SeriesScreen> createState() => _SeriesScreenState();
}

class _SeriesScreenState extends ConsumerState<SeriesScreen> {
  double _sidebarWidth = 220;
  static const _sidebarMin = 160.0;
  static const _sidebarMax = 320.0;

  bool _isRefreshing = false;
  bool _hasCache = false;

  @override
  void initState() {
    super.initState();
    final activeId = StorageService.instance.getActivePlaylistId();
    if (activeId != null) CacheService.instance.setActivePlaylist(activeId);

    final cache = CacheService.instance;
    final list = cache.loadSeriesList(ignoreExpiry: true);
    _hasCache = list?.isNotEmpty ?? false;
    _isRefreshing = !_hasCache || cache.isSeriesStale();
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
        final cats = await service.getSeriesCategories().timeout(
          const Duration(seconds: 30),
        );
        final series = await service.getSeries().timeout(
          const Duration(seconds: 90),
        );
        await CacheService.instance.saveSeriesCategories(cats);
        await CacheService.instance.saveSeriesList(series);
        ref.invalidate(seriesCategoriesProvider);
        ref.invalidate(seriesListProvider);
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
      return _SeriesScanScreen(
        hasOldCache: _hasCache,
        lastUpdate: CacheService.instance.lastUpdatedSeries(),
        statusText: _hasCache
            ? 'Refreshing Series library...'
            : 'Fetching Series for the first time...',
      );
    }

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (_, _) =>
          context.canPop() ? context.pop() : context.go('/home'),
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _SeriesTopBar(),
              Expanded(
                child: Row(
                  children: [
                    _SeriesCategorySidebar(width: _sidebarWidth),
                    _ResizableDivider(
                      onDrag: (dx) => setState(() {
                        _sidebarWidth = (_sidebarWidth + dx).clamp(
                          _sidebarMin,
                          _sidebarMax,
                        );
                      }),
                    ),
                    Expanded(child: _SeriesContent()),
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
class _SeriesTopBar extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final category = ref.watch(selectedSeriesCategoryProvider);
    final seriesAsync = ref.watch(seriesListProvider);
    final count = seriesAsync.whenData((s) => s.length).value ?? 0;

    return Container(
      height: 52,
      color: AppTheme.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          IconButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/home'),
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: AppTheme.textSecondary,
              size: 18,
            ),
          ),
          const Icon(
            Icons.theaters_outlined,
            color: AppTheme.primary,
            size: 20,
          ),
          const SizedBox(width: 8),
          const Text(
            'Series',
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
          _SeriesSearchButton(),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => ref.invalidate(seriesListProvider),
            icon: const Icon(
              Icons.refresh,
              color: AppTheme.textSecondary,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }
}

class _SeriesSearchButton extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SeriesSearchButton> createState() =>
      _SeriesSearchButtonState();
}

class _SeriesSearchButtonState extends ConsumerState<_SeriesSearchButton> {
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
        onChanged: (v) =>
            ref.read(seriesSearchQueryProvider.notifier).state = v,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
        decoration: InputDecoration(
          hintText: 'Search series...',
          prefixIcon: const Icon(
            Icons.search,
            size: 16,
            color: AppTheme.textMuted,
          ),
          suffixIcon: IconButton(
            onPressed: () {
              _ctrl.clear();
              ref.read(seriesSearchQueryProvider.notifier).state = '';
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
// CATEGORY SIDEBAR
// ─────────────────────────────────────────────────────────────────────────────
class _SeriesCategorySidebar extends ConsumerStatefulWidget {
  final double width;
  const _SeriesCategorySidebar({required this.width});

  @override
  ConsumerState<_SeriesCategorySidebar> createState() =>
      _SeriesCategorySidebarState();
}

class _SeriesCategorySidebarState
    extends ConsumerState<_SeriesCategorySidebar> {
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
    final categoriesAsync = ref.watch(seriesCategoriesProvider);
    final selected = ref.watch(selectedSeriesCategoryProvider);
    final seriesAsync = ref.watch(seriesListProvider);
    final filter = ref.watch(seriesFilterProvider);
    final favorites = ref.watch(seriesFavoritesProvider);
    final recentIds = ref.watch(recentlyViewedSeriesProvider);

    final countMap = <String, int>{};
    seriesAsync.whenData((list) {
      for (final s in list) {
        final id = s.categoryId ?? '';
        countMap[id] = (countMap[id] ?? 0) + 1;
      }
    });
    final totalCount = seriesAsync.whenData((s) => s.length).value ?? 0;

    return SizedBox(
      width: widget.width,
      child: Container(
        color: AppTheme.sidebarBg,
        child: Column(
          children: [
            _buildHeader(),
            if (_showSearch) _buildSearchField(),
            Expanded(
              child: categoriesAsync.when(
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (_, _) => Center(
                  child: TextButton.icon(
                    onPressed: () => ref.invalidate(seriesCategoriesProvider),
                    icon: const Icon(Icons.refresh),
                    label: const Text('Retry'),
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
                      // All Series
                      _SeriesSidebarTile(
                        icon: Icons.theaters_rounded,
                        iconColor: AppTheme.primary,
                        label: 'All Series',
                        count: totalCount,
                        isSelected:
                            filter == SeriesFilter.all && selected == null,
                        onTap: () {
                          ref.read(seriesFilterProvider.notifier).state =
                              SeriesFilter.all;
                          ref
                                  .read(selectedSeriesCategoryProvider.notifier)
                                  .state =
                              null;
                        },
                      ),

                      // Favorites
                      _SeriesSidebarTile(
                        icon: Icons.star_rounded,
                        iconColor: const Color(0xFFFBBF24),
                        label: 'Favorites',
                        count: favorites.length,
                        isSelected: filter == SeriesFilter.favorites,
                        onTap: () {
                          ref.read(seriesFilterProvider.notifier).state =
                              SeriesFilter.favorites;
                          ref
                                  .read(selectedSeriesCategoryProvider.notifier)
                                  .state =
                              null;
                        },
                      ),

                      // Recently Viewed
                      _SeriesSidebarTile(
                        icon: Icons.history,
                        iconColor: AppTheme.primary,
                        label: 'Recently Viewed',
                        count: recentIds.length,
                        isSelected: filter == SeriesFilter.recent,
                        onTap: () {
                          ref.read(seriesFilterProvider.notifier).state =
                              SeriesFilter.recent;
                          ref
                                  .read(selectedSeriesCategoryProvider.notifier)
                                  .state =
                              null;
                        },
                      ),

                      // Recently Added — top 100 series by release date
                      _SeriesSidebarTile(
                        icon: Icons.schedule_rounded,
                        iconColor: AppTheme.accent,
                        label: 'Recently Added',
                        isSelected: filter == SeriesFilter.recentlyAdded,
                        onTap: () {
                          ref.read(seriesFilterProvider.notifier).state =
                              SeriesFilter.recentlyAdded;
                          ref
                                  .read(selectedSeriesCategoryProvider.notifier)
                                  .state =
                              null;
                        },
                      ),

                      const Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 4,
                        ),
                        child: Divider(color: AppTheme.divider, height: 1),
                      ),
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
                      ...filtered.map(
                        (cat) => _SeriesCatItem(
                          category: cat,
                          isSelected: selected?.categoryId == cat.categoryId,
                          count: countMap[cat.categoryId] ?? 0,
                          onTap: () {
                            ref.read(seriesFilterProvider.notifier).state =
                                SeriesFilter.all;
                            final newCat =
                                selected?.categoryId == cat.categoryId
                                ? null
                                : cat;
                            ref
                                    .read(
                                      selectedSeriesCategoryProvider.notifier,
                                    )
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

// Sidebar tiles for series screen
class _SeriesSidebarTile extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final int count;
  final bool isSelected;
  final VoidCallback onTap;

  const _SeriesSidebarTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.count = 0,
  });

  @override
  State<_SeriesSidebarTile> createState() => _SeriesSidebarTileState();
}

class _SeriesSidebarTileState extends State<_SeriesSidebarTile> {
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

class _SeriesCatItem extends StatefulWidget {
  final XtreamCategory category;
  final bool isSelected;
  final int count;
  final VoidCallback onTap;

  const _SeriesCatItem({
    required this.category,
    required this.isSelected,
    required this.count,
    required this.onTap,
  });

  @override
  State<_SeriesCatItem> createState() => _SeriesCatItemState();
}

class _SeriesCatItemState extends State<_SeriesCatItem> {
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
// SERIES CONTENT
// ─────────────────────────────────────────────────────────────────────────────
class _SeriesContent extends ConsumerStatefulWidget {
  @override
  ConsumerState<_SeriesContent> createState() => _SeriesContentState();
}

class _SeriesContentState extends ConsumerState<_SeriesContent> {
  double _detailWidth = 340;
  static const _detailMin = 280.0;
  static const _detailMax = 500.0;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedSeriesStreamProvider);

    return Row(
      children: [
        Expanded(child: _SeriesGrid()),
        if (selected != null) ...[
          _ResizableDivider(
            onDrag: (dx) => setState(() {
              _detailWidth = (_detailWidth - dx).clamp(_detailMin, _detailMax);
            }),
          ),
          SizedBox(width: _detailWidth, child: const SeriesDetailPanel()),
        ],
      ],
    );
  }
}

class _SeriesGrid extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seriesAsync = ref.watch(sortedSeriesListProvider);

    return seriesAsync.when(
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
            TextButton.icon(
              onPressed: () => ref.invalidate(seriesListProvider),
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
      data: (seriesList) {
        if (seriesList.isEmpty) {
          return const Center(
            child: Text(
              'No series found',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          );
        }
        return GridView.builder(
          padding: const EdgeInsets.all(12),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 160,
            childAspectRatio: 0.67,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
          ),
          itemCount: seriesList.length,
          itemBuilder: (ctx, i) => _SeriesPosterCard(series: seriesList[i]),
        );
      },
    );
  }
}

class _SeriesPosterCard extends ConsumerStatefulWidget {
  final Series series;
  const _SeriesPosterCard({required this.series});

  @override
  ConsumerState<_SeriesPosterCard> createState() => _SeriesPosterCardState();
}

class _SeriesPosterCardState extends ConsumerState<_SeriesPosterCard> {
  bool _hover = false, _focused = false, _pressed = false;

  @override
  Widget build(BuildContext context) {
    final selected = ref.watch(selectedSeriesStreamProvider);
    final isSelected = selected?.seriesId == widget.series.seriesId;

    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          setState(() => _pressed = true);
          ref.read(selectedSeriesStreamProvider.notifier).state = widget.series;
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
          onTap: () => ref.read(selectedSeriesStreamProvider.notifier).state =
              widget.series,
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
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primary
                      : (_hover || _focused)
                      ? AppTheme.primary.withValues(alpha: 0.4)
                      : Colors.transparent,
                  width: isSelected ? 2 : 1.5,
                ),
                boxShadow: isSelected
                    ? [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.25),
                          blurRadius: 8,
                          spreadRadius: 1,
                        ),
                      ]
                    : null,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    PosterImage(
                      url: widget.series.cover,
                      rating: widget.series.ratingValue > 0
                          ? widget.series.ratingValue
                          : null,
                    ),
                    if (_focused && !isSelected)
                      Container(
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.45),
                            width: 2,
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
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
                          widget.series.name,
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESIZABLE DIVIDER (same as movies_screen)
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
// SERIES SCAN SCREEN
// ─────────────────────────────────────────────────────────────────────────────
class _SeriesScanScreen extends StatefulWidget {
  final bool hasOldCache;
  final DateTime? lastUpdate;
  final String statusText;

  const _SeriesScanScreen({
    required this.hasOldCache,
    required this.statusText,
    this.lastUpdate,
  });

  @override
  State<_SeriesScanScreen> createState() => _SeriesScanScreenState();
}

class _SeriesScanScreenState extends State<_SeriesScanScreen> {
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
            Expanded(
              child: Center(
                child: _SeriesScanCard(isLoading: true, subtitle: subtitle),
              ),
            ),
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

class _SeriesScanCard extends StatelessWidget {
  final bool isLoading;
  final String? subtitle;
  const _SeriesScanCard({this.isLoading = false, this.subtitle});

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
                  child: const Icon(
                    Icons.theaters_outlined,
                    size: 40,
                    color: AppTheme.textPrimary,
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
          const Text(
            'Series',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
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
