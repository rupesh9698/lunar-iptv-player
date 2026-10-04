import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/time_of_day_strip.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/focus_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/storage_service.dart';
import '../../../services/behavior_service.dart';

class LiveCategorySidebar extends ConsumerStatefulWidget {
  final double width;
  final FocusNode? searchFocusNode;
  /// Returns the focus node of the first focusable item in the channel
  /// list panel (EPG), used for "arrow-right" from a category tile.
  final FocusNode? Function()? channelListEntryFocus;
  /// Called once the first category-list item's FocusNode is created so
  /// the parent screen can route "arrow-up at top of list" to it.
  final ValueChanged<FocusNode>? onFirstItemFocusReady;
  /// Called whenever the focus node belonging to the *currently selected*
  /// category tile changes, so other widgets (mini-player, channel search)
  /// can jump straight to it on "arrow-left".
  final ValueChanged<FocusNode>? onSelectedItemFocusReady;

  const LiveCategorySidebar({
    super.key,
    required this.width,
    this.searchFocusNode,
    this.channelListEntryFocus,
    this.onFirstItemFocusReady,
    this.onSelectedItemFocusReady,
  });

  @override
  ConsumerState<LiveCategorySidebar> createState() =>
      _LiveCategorySidebarState();
}

class _LiveCategorySidebarState extends ConsumerState<LiveCategorySidebar> {
  final _scrollCtrl = ScrollController();
  final _searchCtrl = TextEditingController();
  String _query = '';
  bool _showSearch = false;
  final Map<String, GlobalKey> _catKeys = {};
  final Map<String, int> _catIndexMap = {};

  // Ordered focus nodes for the whole list:
  // 0=All Channels, 1=Favorites, 2=Recently Viewed, 3..n=category tiles.
  final List<FocusNode> _itemFocusNodes = [];

  FocusNode _nodeFor(int index) {
    while (_itemFocusNodes.length <= index) {
      _itemFocusNodes.add(FocusNode(debugLabel: 'catItem$index'));
    }
    return _itemFocusNodes[index];
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    _searchCtrl.dispose();
    _catKeys.clear();
    for (final n in _itemFocusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(smartLiveCategoriesProvider);
    final selected = ref.watch(selectedLiveCategoryProvider);
    final hiddenCats = ref.watch(hiddenLiveCategoriesProvider);
    final filter = ref.watch(liveFilterProvider);
    final favorites = ref.watch(liveFavoritesNotifierProvider);
    final recentIds = ref.watch(recentlyViewedLiveProvider);
    final parentalLocked = ref.watch(parentalLockedLiveCategoriesProvider);
    final parentalEnabled = StorageService.instance.isParentalEnabled();

    // Count per category from ALL streams (not category-filtered)
    final allStreams = ref.watch(liveAllStreamsProvider).value ?? [];
    final countMap = <String, int>{};
    for (final s in allStreams) {
      final id = s.categoryId ?? '';
      countMap[id] = (countMap[id] ?? 0) + 1;
    }

    // Restore scroll to previously selected category after rebuild/cold start
    ref.listen<XtreamCategory?>(selectedLiveCategoryProvider, (prev, next) {
      if (next != null && next.categoryId != prev?.categoryId) {
        // Small delay to let the list fully layout first
        Future.delayed(const Duration(milliseconds: 120), () {
          if (mounted) _scrollToCategory(next.categoryId);
        });
      }
    });

    // On first build, scroll to currently selected category
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final sel = ref.read(selectedLiveCategoryProvider);
      if (sel != null) _scrollToCategory(sel.categoryId);
    });

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
                data: (cats) {
                  final filtered = cats.where((c) {
                    if (hiddenCats.contains(c.categoryId)) return false;
                    if (_query.isNotEmpty &&
                        !c.categoryName.toLowerCase().contains(
                          _query.toLowerCase(),
                        )) {
                      return false;
                    }
                    return true;
                  }).toList();

                  // Build index map for reliable scroll positioning
                  _catIndexMap.clear();
                  for (int i = 0; i < filtered.length; i++) {
                    _catIndexMap[filtered[i].categoryId] = i;
                  }

                  // Report focus nodes to parent for cross-panel jumps.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    widget.onFirstItemFocusReady?.call(_nodeFor(0));
                    int selectedIdx = 0;
                    if (filter == LiveFilter.favorites) {
                      selectedIdx = 1;
                    } else if (filter == LiveFilter.recent) {
                      selectedIdx = 2;
                    } else if (filter == LiveFilter.all && selected != null) {
                      final ci = _catIndexMap[selected.categoryId];
                      if (ci != null) selectedIdx = 3 + ci;
                    }
                    widget.onSelectedItemFocusReady
                        ?.call(_nodeFor(selectedIdx));
                  });

                  return ListView(
                    controller: _scrollCtrl,
                    padding: EdgeInsets.zero,
                    children: [
                      const TimeOfDayStrip(),
                      // ── All Channels ──────────────────────────────────
                      _SidebarTile(
                        focusNode: _nodeFor(0),
                        onUpAtTop: () =>
                            widget.searchFocusNode?.requestFocus(),
                        onDownNext: () => _nodeFor(1).requestFocus(),
                        onRightToChannels: () =>
                            widget.channelListEntryFocus?.call()
                                ?.requestFocus(),
                        icon: Icons.all_inclusive,
                        iconColor: AppTheme.primary,
                        label: 'All Channels',
                        count: allStreams.length,
                        isSelected:
                        filter == LiveFilter.all && selected == null,
                        onTap: () {
                          ref.read(liveFilterProvider.notifier).state =
                              LiveFilter.all;
                          ref
                              .read(selectedLiveCategoryProvider.notifier)
                              .state =
                          null;
                        },
                      ),

                      // ── Favorites ─────────────────────────────────────
                      _SidebarTile(
                        focusNode: _nodeFor(1),
                        onUpAtTop: () => _nodeFor(0).requestFocus(),
                        onDownNext: () => _nodeFor(2).requestFocus(),
                        onRightToChannels: () =>
                            widget.channelListEntryFocus?.call()
                                ?.requestFocus(),
                        icon: Icons.star_rounded,
                        iconColor: const Color(0xFFFBBF24),
                        label: 'Favorites',
                        count: favorites.length,
                        isSelected: filter == LiveFilter.favorites,
                        onTap: () {
                          ref.read(liveFilterProvider.notifier).state =
                              LiveFilter.favorites;
                          ref
                              .read(selectedLiveCategoryProvider.notifier)
                              .state =
                          null;
                        },
                      ),

                      // ── Recently Viewed ───────────────────────────────
                      _SidebarTile(
                        focusNode: _nodeFor(2),
                        onUpAtTop: () => _nodeFor(1).requestFocus(),
                        onDownNext: () => _nodeFor(3).requestFocus(),
                        onRightToChannels: () =>
                            widget.channelListEntryFocus?.call()
                                ?.requestFocus(),
                        icon: Icons.history,
                        iconColor: AppTheme.primary,
                        label: 'Recently Viewed',
                        count: recentIds.length,
                        isSelected: filter == LiveFilter.recent,
                        onTap: () {
                          ref.read(liveFilterProvider.notifier).state =
                              LiveFilter.recent;
                          ref
                              .read(selectedLiveCategoryProvider.notifier)
                              .state =
                          null;
                        },
                        trailing: recentIds.isNotEmpty
                            ? GestureDetector(
                          onTap: () {
                            ref
                                .read(recentlyViewedLiveProvider.notifier)
                                .clear();
                            if (ref.read(liveFilterProvider) ==
                                LiveFilter.recent) {
                              ref
                                  .read(liveFilterProvider.notifier)
                                  .state =
                                  LiveFilter.all;
                            }
                          },
                          child: const Padding(
                            padding: EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_outline,
                              size: 14,
                              color: AppTheme.textMuted,
                            ),
                          ),
                        )
                            : null,
                      ),

                      // ── Divider + CATEGORIES label ────────────────────
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
                              'CATEGORIES',
                              style: TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1,
                              ),
                            ),
                            const SizedBox(width: 6),
                            // AI sorted badge — visible only when behavior data exists
                            if (filtered.any(
                              (c) =>
                                  BehaviorService.instance.getCategoryTaps(
                                    c.categoryId,
                                  ) >
                                  0,
                            ))
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                  vertical: 1,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(
                                    0xFF7B61FF,
                                  ).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(3),
                                  border: Border.all(
                                    color: const Color(
                                      0xFF7B61FF,
                                    ).withValues(alpha: 0.3),
                                  ),
                                ),
                                child: const Text(
                                  'AI',
                                  style: TextStyle(
                                    color: Color(0xFF7B61FF),
                                    fontSize: 7,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            const Spacer(),
                            Text(
                              '${cats.length}',
                              style: const TextStyle(
                                color: AppTheme.textMuted,
                                fontSize: 9,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // Build index map for reliable scroll positioning
                      // _catIndexMap.clear();
                      // for (int i = 0; i < filtered.length; i++) {
                      //   _catIndexMap[filtered[i].categoryId] = i;
                      // }

                      // ── Category items ────────────────────────────────
                      ...filtered.asMap().entries.map((e) {
                        final i = e.key;
                        final cat = e.value;
                        final globalIdx = 3 + i; // after 3 pinned tiles
                        _catKeys.putIfAbsent(cat.categoryId, () => GlobalKey());
                        return RepaintBoundary(
                          key: _catKeys[cat.categoryId],
                          child:
                          _CategoryTile(
                            focusNode: _nodeFor(globalIdx),
                            onUpAtTop: () => (i == 0
                                ? _nodeFor(2) // Recently Viewed
                                : _nodeFor(globalIdx - 1))
                                .requestFocus(),
                            onDownNext: i < filtered.length - 1
                                ? () => _nodeFor(globalIdx + 1)
                                .requestFocus()
                                : null, // last item: Down = no action
                            onRightToChannels: () => widget
                                .channelListEntryFocus
                                ?.call()
                                ?.requestFocus(),
                            category: cat,
                            isSelected:
                            filter == LiveFilter.all &&
                                selected?.categoryId == cat.categoryId,
                            count: countMap[cat.categoryId] ?? 0,
                            isLocked:
                            parentalEnabled &&
                                parentalLocked.contains(cat.categoryId),
                            onTap: () =>
                                _onCategoryTap(context, cat, selected),
                            onLongPress: () =>
                                _showHideDialog(context, cat, selected),
                          ).animate().fadeIn(
                            delay: Duration(milliseconds: i * 18),
                            duration: 250.ms,
                          ),
                        );
                      }),

                      const SizedBox(height: 16),
                    ],
                  );
                },
                loading: () => const Center(
                  child: CircularProgressIndicator(
                    color: AppTheme.primary,
                    strokeWidth: 2,
                  ),
                ),
                error: (e, _) => Center(
                  child: Text(
                    'Error',
                    style: const TextStyle(color: AppTheme.error, fontSize: 12),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
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
          TvFocusable(
            focusNode: widget.searchFocusNode,
            autoScroll: false,
            onActivate: () => setState(() {
              _showSearch = !_showSearch;
              if (!_showSearch) {
                _searchCtrl.clear();
                _query = '';
              }
            }),
            onArrowKey: (key) {
              if (key == LogicalKeyboardKey.arrowDown) {
                _nodeFor(0).requestFocus(); // first item = All Channels
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowRight) {
                widget.channelListEntryFocus?.call()?.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
            builder: (focused, _) => AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(6),
                border: focused
                    ? Border.all(
                    color: Colors.white.withValues(alpha: 0.55),
                    width: 1.5)
                    : null,
              ),
              child: Icon(
                _showSearch ? Icons.close : Icons.search,
                size: 15,
                color: focused
                    ? AppTheme.primary
                    : _showSearch
                    ? AppTheme.primary
                    : AppTheme.textMuted,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: SizedBox(
        height: 36,
        child: TextField(
          controller: _searchCtrl,
          autofocus: true,
          onChanged: (v) => setState(() => _query = v),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          decoration: const InputDecoration(
            hintText: 'Search categories...',
            hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
            prefixIcon: Icon(Icons.search, size: 14, color: AppTheme.textMuted),
            contentPadding: EdgeInsets.symmetric(vertical: 8),
            isDense: true,
          ),
        ),
      ),
    );
  }

  void _scrollToCategory(String categoryId) {
    final key = _catKeys[categoryId];
    if (key?.currentContext == null) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final ctx = key?.currentContext;
      if (ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        alignment: 0.5, // 0.5 = exact center of viewport
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeOutCubic,
      );
    });
  }

  Future<void> _showHideDialog(
    BuildContext context,
    XtreamCategory cat,
    XtreamCategory? selected,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Hide Category'),
        content: Text(
          'Hide "${cat.categoryName}"?\n\n'
          'You can restore it in Settings → Content & EPG.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Hide'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      ref.read(hiddenLiveCategoriesProvider.notifier).toggle(cat.categoryId);
      if (selected?.categoryId == cat.categoryId) {
        ref.read(selectedLiveCategoryProvider.notifier).state = null;
      }
    }
  }

  Future<void> _onCategoryTap(
    BuildContext context,
    XtreamCategory cat,
    XtreamCategory? selected,
  ) async {
    final isParentalEnabled = StorageService.instance.isParentalEnabled();
    final isLocked = ref
        .read(parentalLockedLiveCategoriesProvider)
        .contains(cat.categoryId);
    final isSessionUnlocked = ref
        .read(parentalSessionUnlockedProvider)
        .contains(cat.categoryId);

    if (isParentalEnabled && isLocked && !isSessionUnlocked) {
      final ok = await _showPinDialog(context);
      if (!ok || !mounted) return;
      ref
          .read(parentalSessionUnlockedProvider.notifier)
          .update((s) => {...s, cat.categoryId});
    }

    if (!mounted) return;
    final isSameAndAll =
        selected?.categoryId == cat.categoryId &&
        ref.read(liveFilterProvider) == LiveFilter.all;
    ref.read(liveFilterProvider.notifier).state = LiveFilter.all;
    ref.read(selectedLiveCategoryProvider.notifier).state = isSameAndAll
        ? null
        : cat;

    // Record tap for smart category ordering (AI feature)
    BehaviorService.instance.recordCategoryTap(cat.categoryId);

    // Scroll selected category to center of viewport
    _scrollToCategory(cat.categoryId);
  }

  Future<bool> _showPinDialog(BuildContext context) async {
    final pin = StorageService.instance.getParentalPin();
    if (pin == null || pin.isEmpty) return true;

    final controller = TextEditingController();
    bool? result;
    try {
      result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: AppTheme.error, size: 20),
              SizedBox(width: 8),
              Text('Parental Control'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter PIN to access this category',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: '••••',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, controller.text == pin),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, controller.text == pin),
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }

    if ((result == null || result == false) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Incorrect PIN'),
          backgroundColor: AppTheme.error,
          duration: Duration(seconds: 2),
        ),
      );
    }
    return result ?? false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SIDEBAR TILE — pinned items (All, Favorites, Recently Viewed)
// touch · mouse · keyboard · TV remote
// ─────────────────────────────────────────────────────────────────────────────
class _SidebarTile extends StatefulWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final int? count;
  final bool isSelected;
  final VoidCallback onTap;
  final Widget? trailing;
  final FocusNode? focusNode;
  final VoidCallback? onUpAtTop;
  final VoidCallback? onDownNext;
  final VoidCallback? onRightToChannels;

  const _SidebarTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.count,
    this.trailing,
    this.focusNode,
    this.onUpAtTop,
    this.onDownNext,
    this.onRightToChannels,
  });

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> with TvFocusMixin {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      onActivate: widget.onTap,
      onFocusChange: setTvFocused,
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          (widget.onUpAtTop ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          (widget.onDownNext ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          (widget.onRightToChannels ?? () {})();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (focused, pressed) {
        final lit = isTvHovered || focused;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding:
          const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.selectedItem
                : pressed
                ? AppTheme.surface.withValues(alpha: 0.8)
                : lit
                ? AppTheme.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.isSelected
                ? Border.all(
                color: AppTheme.primary.withValues(alpha: 0.25))
                : focused
                ? Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.5)
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
              if (widget.count != null && widget.count! > 0)
                Text('${widget.count}',
                    style: const TextStyle(
                        color: AppTheme.textMuted, fontSize: 10)),
              if (widget.trailing != null) widget.trailing!,
            ],
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CATEGORY TILE — long press to hide, lock icon when parental-protected
// touch · mouse · keyboard · TV remote
// ─────────────────────────────────────────────────────────────────────────────
class _CategoryTile extends StatefulWidget {
  final XtreamCategory category;
  final bool isSelected;
  final int count;
  final bool isLocked;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final FocusNode? focusNode;
  final VoidCallback? onUpAtTop;
  final VoidCallback? onDownNext;
  final VoidCallback? onRightToChannels;

  const _CategoryTile({
    required this.category,
    required this.isSelected,
    required this.count,
    required this.onTap,
    required this.onLongPress,
    this.isLocked = false,
    this.focusNode,
    this.onUpAtTop,
    this.onDownNext,
    this.onRightToChannels,
  });

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> with TvFocusMixin {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      onActivate: widget.onTap,
      onLongPress: widget.onLongPress,
      onFocusChange: setTvFocused,
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          (widget.onUpAtTop ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          if (widget.onDownNext != null) {
            widget.onDownNext!();
          }
          // last item: no onDownNext provided → No Action (per spec)
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          (widget.onRightToChannels ?? () {})();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (focused, pressed) {
        final lit = isTvHovered || focused;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.selectedItem
                : pressed
                ? AppTheme.surface.withValues(alpha: 0.8)
                : lit
                ? AppTheme.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: widget.isSelected
                ? const Border(
                left: BorderSide(color: AppTheme.primary, width: 2))
                : focused
                ? Border.all(
                color: Colors.white.withValues(alpha: 0.55),
                width: 1.5)
                : null,
          ),
          child: Row(
            children: [
              Icon(Icons.folder_outlined,
                  size: 14,
                  color: widget.isSelected
                      ? AppTheme.primary
                      : AppTheme.textMuted),
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
              if (widget.isLocked)
                const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.lock_rounded,
                      size: 11, color: AppTheme.error),
                ),
              if (widget.count > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 4),
                  child: Text('${widget.count}',
                      style: const TextStyle(
                          color: AppTheme.textMuted, fontSize: 10)),
                ),
              AnimatedOpacity(
                opacity: lit ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 150),
                child: const Padding(
                  padding: EdgeInsets.only(left: 4),
                  child: Icon(Icons.more_vert,
                      size: 11, color: AppTheme.textMuted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}