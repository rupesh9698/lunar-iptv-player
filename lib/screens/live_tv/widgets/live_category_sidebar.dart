import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/time_of_day_strip.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/storage_service.dart';

class LiveCategorySidebar extends ConsumerStatefulWidget {
  final double width;
  const LiveCategorySidebar({super.key, required this.width});

  @override
  ConsumerState<LiveCategorySidebar> createState() =>
      _LiveCategorySidebarState();
}

class _LiveCategorySidebarState extends ConsumerState<LiveCategorySidebar> {
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

  @override
  Widget build(BuildContext context) {
    final categoriesAsync = ref.watch(liveCategoriesProvider);
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

                  return ListView(
                    controller: _scrollCtrl,
                    padding: EdgeInsets.zero,
                    children: [
                      const TimeOfDayStrip(),
                      // ── All Channels ──────────────────────────────────
                      _SidebarTile(
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

                      // ── Category items ────────────────────────────────
                      ...filtered.asMap().entries.map((e) {
                        final i = e.key;
                        final cat = e.value;
                        return _CategoryTile(
                          category: cat,
                          isSelected:
                              filter == LiveFilter.all &&
                              selected?.categoryId == cat.categoryId,
                          count: countMap[cat.categoryId] ?? 0,
                          isLocked:
                              parentalEnabled &&
                              parentalLocked.contains(cat.categoryId),
                          onTap: () => _onCategoryTap(context, cat, selected),
                          onLongPress: () =>
                              _showHideDialog(context, cat, selected),
                        ).animate().fadeIn(
                          delay: Duration(milliseconds: i * 18),
                          duration: 250.ms,
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
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              onTap: () => setState(() {
                _showSearch = !_showSearch;
                if (!_showSearch) {
                  _searchCtrl.clear();
                  _query = '';
                }
              }),
              child: Icon(
                _showSearch ? Icons.close : Icons.search,
                size: 15,
                color: _showSearch ? AppTheme.primary : AppTheme.textMuted,
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

  const _SidebarTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.isSelected,
    required this.onTap,
    this.count,
    this.trailing,
  });

  @override
  State<_SidebarTile> createState() => _SidebarTileState();
}

class _SidebarTileState extends State<_SidebarTile> {
  bool _hover = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _showFocusRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlight);
  }

  void _onHighlight(FocusHighlightMode _) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA) {
            setState(() => _pressed = true);
            widget.onTap();
            return KeyEventResult.handled;
          }
          // Right arrow — let scope node handle cross-panel navigation
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
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.selectedItem
                  : _pressed
                  ? AppTheme.surface.withValues(alpha: 0.8)
                  : (_hover || _showFocusRing) // ← was: _focused
                  ? AppTheme.surface
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: widget.isSelected
                  ? Border.all(color: AppTheme.primary.withValues(alpha: 0.25))
                  : _showFocusRing // ← was: _focused
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
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
                if (widget.count != null && widget.count! > 0)
                  Text(
                    '${widget.count}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                if (widget.trailing != null) widget.trailing!,
              ],
            ),
          ),
        ),
      ),
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

  const _CategoryTile({
    required this.category,
    required this.isSelected,
    required this.count,
    required this.onTap,
    required this.onLongPress,
    this.isLocked = false,
  });

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _hover = false;
  bool _focused = false;
  bool _pressed = false;

  bool get _showFocusRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlight);
  }

  void _onHighlight(FocusHighlightMode _) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlight);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent) {
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter ||
              event.logicalKey == LogicalKeyboardKey.space ||
              event.logicalKey == LogicalKeyboardKey.gameButtonA) {
            setState(() => _pressed = true);
            widget.onTap();
            return KeyEventResult.handled;
          }
          // Right arrow: cross-panel navigation handled by _categoryPanelFocus.onKeyEvent
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
          onLongPress: widget.onLongPress,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.selectedItem
                  : _pressed
                  ? AppTheme.surface.withValues(alpha: 0.8)
                  : (_hover || _showFocusRing) // ← was: _focused
                  ? AppTheme.surface
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: widget.isSelected
                  ? const Border(
                      left: BorderSide(color: AppTheme.primary, width: 2),
                    )
                  : _showFocusRing // ← was: _focused
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
                if (widget.isLocked)
                  const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.lock_rounded,
                      size: 11,
                      color: AppTheme.error,
                    ),
                  ),
                if (widget.count > 0)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: Text(
                      '${widget.count}',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 10,
                      ),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: (_hover || _showFocusRing)
                      ? 1.0
                      : 0.0, // ← was _focused
                  duration: const Duration(milliseconds: 150),
                  child: const Padding(
                    padding: EdgeInsets.only(left: 4),
                    child: Icon(
                      Icons.more_vert,
                      size: 11,
                      color: AppTheme.textMuted,
                    ),
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
