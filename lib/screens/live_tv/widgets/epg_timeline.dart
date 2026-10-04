import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lunar_iptv_player/core/utils/focus_utils.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';

class EpgTimeline extends ConsumerStatefulWidget {
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final FocusNode? searchFocusNode;
  final FocusNode? refreshFocusNode;
  final FocusNode? fullscreenFocusNode;

  /// "Watch Now" button's FocusNode — Up from search/refresh/fullscreen.
  final FocusNode? watchNowFocus;

  /// Returns the currently-focused/selected category tile's FocusNode —
  /// used for "Left" from the first channel-list item.
  final FocusNode? Function()? categoryEntryFocus;

  /// Reports the first channel cell's FocusNode once built.
  final ValueChanged<FocusNode>? onFirstItemFocusReady;

  const EpgTimeline({
    super.key,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.searchFocusNode,
    this.refreshFocusNode,
    this.fullscreenFocusNode,
    this.watchNowFocus,
    this.categoryEntryFocus,
    this.onFirstItemFocusReady,
  });

  @override
  ConsumerState<EpgTimeline> createState() => _EpgTimelineState();
}

class _EpgTimelineState extends ConsumerState<EpgTimeline> {
  final _leftCtrl = ScrollController();
  final _rightCtrl = ScrollController();
  final _horizCtrl = ScrollController();
  bool _syncing = false;
  Timer? _clockTimer;
  DateTime _now = DateTime.now();

  // Per-channel-row focus nodes, indexed by position in the visible list.
  final List<FocusNode> _channelFocusNodes = [];

  FocusNode _channelNode(int index) {
    while (_channelFocusNodes.length <= index) {
      _channelFocusNodes.add(FocusNode(debugLabel: 'epgChannel$index'));
    }
    return _channelFocusNodes[index];
  }

  static const double _chColW = 240.0;
  static const double _rowH = 58.0;
  static const double _headerH = 40.0;
  static const double _pxPerHour = 240.0;

  @override
  void initState() {
    super.initState();
    _leftCtrl.addListener(_syncLeft);
    _rightCtrl.addListener(_syncRight);
    _clockTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _jumpToNow());
  }

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    _horizCtrl.dispose();
    _clockTimer?.cancel();
    for (final n in _channelFocusNodes) {
      n.dispose();
    }
    super.dispose();
  }

  void _syncLeft() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    if ((_rightCtrl.offset - _leftCtrl.offset).abs() < 0.5) return;
    _syncing = true;
    try {
      _rightCtrl.jumpTo(
        _leftCtrl.offset.clamp(0.0, _rightCtrl.position.maxScrollExtent),
      );
    } catch (_) {
    } finally {
      _syncing = false;
    }
  }

  void _syncRight() {
    if (_syncing) return;
    if (!_leftCtrl.hasClients || !_rightCtrl.hasClients) return;
    if ((_leftCtrl.offset - _rightCtrl.offset).abs() < 0.5) return;
    _syncing = true;
    try {
      _leftCtrl.jumpTo(
        _rightCtrl.offset.clamp(0.0, _leftCtrl.position.maxScrollExtent),
      );
    } catch (_) {
    } finally {
      _syncing = false;
    }
  }

  void _jumpToNow() {
    final windowStart = ref.read(epgWindowStartProvider);
    final hours = ref.read(epgHoursProvider);
    final elapsed = _now.difference(windowStart).inMinutes / 60.0;
    final offset = (elapsed * _pxPerHour - 80).clamp(0.0, _pxPerHour * hours);
    if (_horizCtrl.hasClients) {
      _horizCtrl.animateTo(
        offset,
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeInOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final windowStart = ref.watch(epgWindowStartProvider);
    final streamsAsync = ref.watch(filteredLiveStreamsProvider);
    final epgCache = ref.watch(epgCacheProvider);
    final selected = ref.watch(selectedChannelProvider);
    final hours = 12;
    final totalW = _pxPerHour * hours;
    final windowEnd = windowStart.add(const Duration(hours: 12));

    return Column(
      children: [
        // ── Controls bar ──────────────────────────────────────────
        _EpgControlBar(
          isFullscreen: widget.isFullscreen,
          onToggleFullscreen: widget.onToggleFullscreen,
          searchFocusNode: widget.searchFocusNode,
          refreshFocusNode: widget.refreshFocusNode,
          fullscreenFocusNode: widget.fullscreenFocusNode,
          watchNowFocus: widget.watchNowFocus,
          categoryEntryFocus: widget.categoryEntryFocus,
          firstChannelFocus: () =>
              _channelFocusNodes.isNotEmpty ? _channelFocusNodes[0] : null,
          onRefresh: () {
            ref.read(epgCacheProvider.notifier).clear();
            ref.invalidate(liveStreamsProvider);
          },
        ),

        const Divider(color: AppTheme.epgBorder, height: 1),

        // ── Grid ──────────────────────────────────────────────────
        Expanded(
          child: streamsAsync.when(
            data: (streams) => _buildGrid(
              streams,
              epgCache,
              selected,
              windowStart,
              windowEnd,
              totalW,
              hours,
            ),
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
                  const Icon(
                    Icons.error_outline,
                    color: AppTheme.error,
                    size: 36,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Could not load channels',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => ref.invalidate(liveStreamsProvider),
                    child: const Text('Retry'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Grid ───────────────────────────────────────────────────────────
  Widget _buildGrid(
    List<LiveStream> streams,
    Map<String, List<EpgListing>> epgCache,
    LiveStream? selected,
    DateTime windowStart,
    DateTime windowEnd,
    double totalW,
    int hours,
  ) {
    final nowOffsetPx = _now.isAfter(windowStart) && _now.isBefore(windowEnd)
        ? _now.difference(windowStart).inMinutes / 60.0 * _pxPerHour
        : -1.0;
    final favorites = ref.watch(liveFavoritesNotifierProvider);

    final showChanNum = ref.watch(showChannelNumberProvider);

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final rightH = constraints.maxHeight - _headerH - 1;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── LEFT: channel column ──────────────────────────────
            SizedBox(
              width: _chColW,
              child: Column(
                children: [
                  // Header cell
                  Container(
                    height: _headerH,
                    color: AppTheme.epgFuture,
                    alignment: Alignment.centerLeft,
                    padding: const EdgeInsets.only(left: 12),
                    child: const Text(
                      'CHANNELS',
                      style: TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1,
                      ),
                    ),
                  ),
                  Container(height: 1, color: AppTheme.epgBorder),
                  Expanded(
                    child: ListView.builder(
                      controller: _leftCtrl,
                      itemCount: streams.length,
                      itemExtent: _rowH,
                      physics: const ClampingScrollPhysics(),
                      itemBuilder: (_, i) {
                        final ch = streams[i];
                        if (i == 0) {
                          // Report first item's focus node once built.
                          WidgetsBinding.instance.addPostFrameCallback((_) {
                            if (mounted) {
                              widget.onFirstItemFocusReady?.call(
                                _channelNode(0),
                              );
                            }
                          });
                        }
                        return _ChannelCell(
                          key: ValueKey('ch_${ch.streamId}'),
                          focusNode: _channelNode(i),
                          channel: ch,
                          isSelected: selected?.streamId == ch.streamId,
                          isFavorite: favorites.contains(ch.streamId),
                          showChannelNumber: showChanNum,
                          onTap: () => _onChannelTap(ctx, ch),
                          onFavorite: () => ref
                              .read(liveFavoritesNotifierProvider.notifier)
                              .toggle(ch.streamId),
                          onUpAtTop: i == 0
                              ? () => widget.searchFocusNode?.requestFocus()
                              : () => _channelNode(i - 1).requestFocus(),
                          onDownNext: i < streams.length - 1
                              ? () => _channelNode(i + 1).requestFocus()
                              : null,
                          onLeftToCategory: () =>
                              widget.categoryEntryFocus?.call()?.requestFocus(),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),

            // Vertical separator
            Container(width: 1, color: AppTheme.epgBorder),

            // ── RIGHT: program timeline ───────────────────────────
            Expanded(
              child: SingleChildScrollView(
                controller: _horizCtrl,
                scrollDirection: Axis.horizontal,
                physics: const ClampingScrollPhysics(),
                child: SizedBox(
                  width: totalW,
                  height: constraints.maxHeight,
                  child: Stack(
                    children: [
                      Column(
                        children: [
                          _TimeHeader(
                            windowStart: windowStart,
                            hours: hours,
                            pxPerHour: _pxPerHour,
                            height: _headerH,
                          ),
                          Container(height: 1, color: AppTheme.epgBorder),
                          SizedBox(
                            height: rightH,
                            child: ListView.builder(
                              controller: _rightCtrl,
                              itemCount: streams.length,
                              itemExtent: _rowH,
                              physics: const ClampingScrollPhysics(),
                              itemBuilder: (ctx2, i) {
                                final ch = streams[i];
                                return _ProgramRow(
                                  key: ValueKey('prog_${ch.streamId}'),
                                  channel: ch,
                                  epg: epgCache[ch.streamId] ?? [],
                                  isEpgLoaded: epgCache.containsKey(
                                    ch.streamId,
                                  ),
                                  windowStart: windowStart,
                                  windowEnd: windowEnd,
                                  pxPerHour: _pxPerHour,
                                  totalW: totalW,
                                  now: _now,
                                  isSelected: selected?.streamId == ch.streamId,
                                  onTap: () => _onChannelTap(ctx2, ch),
                                  onEpgNeeded: () => ref
                                      .read(epgCacheProvider.notifier)
                                      .loadEpg(ch.streamId),
                                );
                              },
                            ),
                          ),
                        ],
                      ),

                      // Now line
                      if (nowOffsetPx >= 0)
                        Positioned(
                          left: nowOffsetPx,
                          top: 0,
                          bottom: 0,
                          child: _NowLine(headerH: _headerH, now: _now),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  void _onChannelTap(BuildContext ctx, LiveStream ch) {
    ref.read(selectedChannelProvider.notifier).state = ch;
    ref.read(epgCacheProvider.notifier).loadEpg(ch.streamId);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EPG CONTROLS BAR
// ─────────────────────────────────────────────────────────────────────────────
class _EpgControlBar extends ConsumerStatefulWidget {
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onRefresh;
  final FocusNode? searchFocusNode;
  final FocusNode? refreshFocusNode;
  final FocusNode? fullscreenFocusNode;
  final FocusNode? watchNowFocus;
  final FocusNode? Function()? firstChannelFocus;
  final FocusNode? Function()? categoryEntryFocus;

  const _EpgControlBar({
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.onRefresh,
    this.searchFocusNode,
    this.refreshFocusNode,
    this.fullscreenFocusNode,
    this.watchNowFocus,
    this.firstChannelFocus,
    this.categoryEntryFocus,
  });

  @override
  ConsumerState<_EpgControlBar> createState() => _EpgControlBarState();
}

class _EpgControlBarState extends ConsumerState<_EpgControlBar> {
  final _searchCtrl = TextEditingController();
  bool _searchOpen = false;

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  void _goFirstChannelOrSelf(FocusNode self) {
    (widget.firstChannelFocus?.call() ?? self).requestFocus();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: AppTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _buildInlineSearch(),
          const Spacer(),
          _buildIconBtn(
            focusNode: widget.refreshFocusNode,
            icon: Icons.refresh,
            tooltip: 'Refresh EPG',
            onTap: widget.onRefresh,
            onArrowKey: (key) {
              if (key == LogicalKeyboardKey.arrowUp) {
                widget.watchNowFocus?.requestFocus();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowDown) {
                _goFirstChannelOrSelf(widget.refreshFocusNode!);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowLeft) {
                widget.searchFocusNode?.requestFocus();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowRight) {
                widget.fullscreenFocusNode?.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored;
            },
          ),
          const SizedBox(width: 4),
          _buildIconBtn(
            focusNode: widget.fullscreenFocusNode,
            icon: widget.isFullscreen
                ? Icons.fullscreen_exit
                : Icons.fit_screen_outlined,
            tooltip: widget.isFullscreen
                ? 'Exit EPG Fullscreen'
                : 'EPG Fullscreen',
            onTap: widget.onToggleFullscreen,
            onArrowKey: (key) {
              if (key == LogicalKeyboardKey.arrowUp) {
                widget.watchNowFocus?.requestFocus();
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowDown) {
                _goFirstChannelOrSelf(widget.fullscreenFocusNode!);
                return KeyEventResult.handled;
              }
              if (key == LogicalKeyboardKey.arrowLeft) {
                widget.refreshFocusNode?.requestFocus();
                return KeyEventResult.handled;
              }
              return KeyEventResult.ignored; // Right = No Action
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInlineSearch() {
    return TvFocusable(
      focusNode: widget.searchFocusNode,
      autoScroll: false,
      onActivate: () {
        setState(() => _searchOpen = !_searchOpen);
        if (!_searchOpen) {
          _searchCtrl.clear();
          ref.read(liveSearchQueryProvider.notifier).state = '';
        }
      },
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          widget.watchNowFocus?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          _goFirstChannelOrSelf(widget.searchFocusNode!);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          widget.categoryEntryFocus?.call()?.requestFocus();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          widget.refreshFocusNode?.requestFocus();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeInOut,
        width: _searchOpen ? 220 : 32,
        height: 30,
        decoration: BoxDecoration(
          color: _searchOpen ? AppTheme.surfaceVariant : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: _searchOpen
              ? Border.all(color: AppTheme.divider)
              : focused
              ? Border.all(
                  color: Colors.white.withValues(alpha: 0.55),
                  width: 1.5,
                )
              : null,
        ),
        clipBehavior: Clip.hardEdge,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Use flexible so it never overflows at fractional pixel sizes
            SizedBox(
              width: 30,
              height: 30,
              child: Center(
                child: Icon(
                  _searchOpen ? Icons.close : Icons.search,
                  size: 15,
                  color: _searchOpen || focused
                      ? AppTheme.primary
                      : AppTheme.textSecondary,
                ),
              ),
            ),
            if (_searchOpen)
              Expanded(
                child: TextField(
                  controller: _searchCtrl,
                  autofocus: true,
                  onChanged: (v) =>
                      ref.read(liveSearchQueryProvider.notifier).state = v,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                  ),
                  decoration: const InputDecoration(
                    hintText: 'Search channels...',
                    hintStyle: TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 12,
                    ),
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
      ),
    );
  }

  Widget _buildIconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    FocusNode? focusNode,
    KeyEventResult Function(LogicalKeyboardKey)? onArrowKey,
  }) {
    return _EpgBarBtn(
      icon: icon,
      tooltip: tooltip,
      onTap: onTap,
      focusNode: focusNode,
      onArrowKey: onArrowKey,
    );
  }
}

// Focusable EPG bar button — TV remote + mouse + touch
class _EpgBarBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final FocusNode? focusNode;
  final KeyEventResult Function(LogicalKeyboardKey)? onArrowKey;

  const _EpgBarBtn({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.focusNode,
    this.onArrowKey,
  });

  @override
  State<_EpgBarBtn> createState() => _EpgBarBtnState();
}

class _EpgBarBtnState extends State<_EpgBarBtn> {
  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      focusNode: widget.focusNode,
      autoScroll: false,
      onActivate: widget.onTap,
      onArrowKey: widget.onArrowKey != null
          ? (key) => widget.onArrowKey!(key)
          : null,
      builder: (focused, _) => Tooltip(
        message: widget.tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: focused
                ? AppTheme.primary.withValues(alpha: 0.15)
                : AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(6),
            border: focused
                ? Border.all(
                    color: AppTheme.primary.withValues(alpha: 0.7),
                    width: 1.5,
                  )
                : Border.all(color: AppTheme.divider),
          ),
          child: Icon(
            widget.icon,
            size: 15,
            color: focused ? AppTheme.primary : AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL CELL (left column, clickable)
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelCell extends StatefulWidget {
  final LiveStream channel;
  final bool isSelected;
  final bool isFavorite;
  final bool showChannelNumber;
  final VoidCallback onTap;
  final VoidCallback onFavorite;
  final FocusNode? focusNode;
  final VoidCallback? onUpAtTop;
  final VoidCallback? onDownNext;
  final VoidCallback? onLeftToCategory;

  const _ChannelCell({
    super.key,
    required this.channel,
    required this.isSelected,
    required this.onTap,
    required this.isFavorite,
    required this.onFavorite,
    this.showChannelNumber = true,
    this.focusNode,
    this.onUpAtTop,
    this.onDownNext,
    this.onLeftToCategory,
  });

  @override
  State<_ChannelCell> createState() => _ChannelCellState();
}

class _ChannelCellState extends State<_ChannelCell> with TvFocusMixin {
  @override
  Widget build(BuildContext context) {
    final hasNum =
        widget.showChannelNumber &&
        widget.channel.num.isNotEmpty &&
        widget.channel.num != '0';

    return TvFocusable(
      focusNode: widget.focusNode,
      autoScroll: true,
      scrollAlignment: 0.3,
      onActivate: widget.onTap,
      onFocusChange: setTvFocused,
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          (widget.onUpAtTop ?? () {})();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          if (widget.onDownNext != null) widget.onDownNext!();
          return KeyEventResult.handled; // last item: No Action
        }
        if (key == LogicalKeyboardKey.arrowLeft) {
          (widget.onLeftToCategory ?? () {})();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: widget.isSelected
              ? AppTheme.selectedItem
              : (isTvHovered || focused)
              ? AppTheme.surfaceVariant
              : AppTheme.epgFuture,
          border: Border(
            bottom: const BorderSide(color: AppTheme.epgBorder, width: 0.5),
            left: focused && !widget.isSelected
                ? const BorderSide(color: AppTheme.primary, width: 2.5)
                : BorderSide.none,
          ),
        ),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 200),
              width: 3,
              height: 36,
              decoration: BoxDecoration(
                color: widget.isSelected
                    ? AppTheme.primary
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(width: 40, height: 32, child: _logo()),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (hasNum)
                    Text(
                      'CH ${widget.channel.num}',
                      style: const TextStyle(
                        color: AppTheme.textMuted,
                        fontSize: 8,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  Text(
                    widget.channel.name,
                    style: TextStyle(
                      color: widget.isSelected
                          ? AppTheme.textPrimary
                          : AppTheme.textSecondary,
                      fontSize: 11,
                      fontWeight: widget.isSelected
                          ? FontWeight.w600
                          : FontWeight.w400,
                    ),
                    maxLines: hasNum ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (isTvHovered || focused || widget.isFavorite)
              GestureDetector(
                onTap: widget.onFavorite,
                child: Icon(
                  widget.isFavorite ? Icons.favorite : Icons.favorite_border,
                  size: 14,
                  color: widget.isFavorite
                      ? AppTheme.error
                      : AppTheme.textMuted,
                ),
              ),
            if (isTvHovered || focused || widget.isSelected)
              Icon(
                Icons.play_circle_outline,
                size: 16,
                color: widget.isSelected
                    ? AppTheme.primary
                    : AppTheme.textMuted,
              ),
          ],
        ),
      ),
    );
  }

  Widget _logo() {
    final icon = widget.channel.streamIcon;
    if (icon != null && icon.isNotEmpty) {
      return Image.network(
        icon,
        fit: BoxFit.contain,
        errorBuilder: (_, _, _) => _placeholder(),
      );
    }
    return _placeholder();
  }

  Widget _placeholder() => Container(
    color: AppTheme.surfaceVariant,
    child: const Center(
      child: Icon(Icons.tv, color: AppTheme.textMuted, size: 16),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// TIME HEADER
// ─────────────────────────────────────────────────────────────────────────────
class _TimeHeader extends StatelessWidget {
  final DateTime windowStart;
  final int hours;
  final double pxPerHour;
  final double height;

  const _TimeHeader({
    required this.windowStart,
    required this.hours,
    required this.pxPerHour,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    final slots = hours * 2; // 30-min slots
    return SizedBox(
      height: height,
      child: Row(
        children: List.generate(slots, (i) {
          final slotTime = windowStart.add(Duration(minutes: i * 30));
          return Container(
            width: pxPerHour / 2,
            decoration: const BoxDecoration(
              color: AppTheme.epgFuture,
              border: Border(
                right: BorderSide(color: AppTheme.epgBorder, width: 0.5),
              ),
            ),
            padding: const EdgeInsets.only(left: 8),
            alignment: Alignment.centerLeft,
            child: Text(
              DateFormat('HH:mm').format(slotTime),
              style: const TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w500,
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Holds an EPG entry with a possibly-truncated effective end time
/// to prevent visual overlap with the next entry.
class _EpgSlot {
  final EpgListing listing;
  final DateTime effectiveEnd;
  const _EpgSlot(this.listing, this.effectiveEnd);
}

/// Sorts EPG by start time and clips each entry's end to the start of the next entry, eliminating visual overlaps.
List<_EpgSlot> _resolveEpgOverlaps(List<EpgListing> raw) {
  if (raw.isEmpty) return [];
  final sorted = [...raw]..sort((a, b) => a.startTime.compareTo(b.startTime));

  final result = <_EpgSlot>[];
  for (int i = 0; i < sorted.length; i++) {
    final curr = sorted[i];
    final nextStart = i + 1 < sorted.length ? sorted[i + 1].startTime : null;
    // Truncate end at next entry's start if they would overlap
    final effective = nextStart != null && nextStart.isBefore(curr.endTime)
        ? nextStart
        : curr.endTime;
    if (effective.isAfter(curr.startTime)) {
      result.add(_EpgSlot(curr, effective));
    }
  }
  return result;
}

// ─────────────────────────────────────────────────────────────────────────────
// PROGRAM ROW (shows for one channel)
// ─────────────────────────────────────────────────────────────────────────────
class _ProgramRow extends StatefulWidget {
  final LiveStream channel;
  final List<EpgListing> epg;
  final bool isEpgLoaded;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerHour;
  final double totalW;
  final DateTime now;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onEpgNeeded;

  const _ProgramRow({
    super.key,
    required this.channel,
    required this.epg,
    required this.isEpgLoaded,
    required this.windowStart,
    required this.windowEnd,
    required this.pxPerHour,
    required this.totalW,
    required this.now,
    required this.isSelected,
    required this.onTap,
    required this.onEpgNeeded,
  });

  @override
  State<_ProgramRow> createState() => _ProgramRowState();
}

class _ProgramRowState extends State<_ProgramRow> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onEpgNeeded());
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 56,
      decoration: BoxDecoration(
        color: widget.isSelected
            ? AppTheme.selectedItem.withValues(alpha: 0.4)
            : AppTheme.epgFuture,
        border: const Border(
          bottom: BorderSide(color: AppTheme.epgBorder, width: 0.5),
        ),
      ),
      child: Stack(
        clipBehavior: Clip.hardEdge,
        children: [
          // Tappable background
          Positioned.fill(
            child: GestureDetector(
              onTap: widget.onTap,
              child: Container(color: Colors.transparent),
            ),
          ),

          // Program blocks OR loading/empty states
          if (!widget.isEpgLoaded)
            const Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: AppTheme.textMuted,
                  ),
                ),
              ),
            )
          else if (widget.epg.isEmpty)
            const Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: Text(
                  'No EPG',
                  style: TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 10,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
            )
          else
            ..._resolveEpgOverlaps(widget.epg).map(
              (slot) => _ShowBlock(
                epg: slot.listing,
                effectiveEnd: slot.effectiveEnd,
                windowStart: widget.windowStart,
                windowEnd: widget.windowEnd,
                pxPerHour: widget.pxPerHour,
                now: widget.now,
                onTap: widget.onTap,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHOW BLOCK
// ─────────────────────────────────────────────────────────────────────────────
class _ShowBlock extends StatefulWidget {
  final EpgListing epg;
  final DateTime effectiveEnd;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerHour;
  final DateTime now;
  final VoidCallback onTap;

  const _ShowBlock({
    required this.epg,
    required this.effectiveEnd,
    required this.windowStart,
    required this.windowEnd,
    required this.pxPerHour,
    required this.now,
    required this.onTap,
  });

  @override
  State<_ShowBlock> createState() => _ShowBlockState();
}

class _ShowBlockState extends State<_ShowBlock> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final start = widget.epg.startTime;
    final end = widget.effectiveEnd;

    if (end.isBefore(widget.windowStart) || start.isAfter(widget.windowEnd)) {
      return const SizedBox.shrink();
    }

    // Clamp to window
    final cStart = start.isBefore(widget.windowStart)
        ? widget.windowStart
        : start;
    final cEnd = end.isAfter(widget.windowEnd) ? widget.windowEnd : end;

    if (!cEnd.isAfter(cStart)) return const SizedBox.shrink();

    final leftPx =
        cStart.difference(widget.windowStart).inMinutes /
        60.0 *
        widget.pxPerHour;
    final widthPx = cEnd.difference(cStart).inMinutes / 60.0 * widget.pxPerHour;

    if (widthPx < 2) return const SizedBox.shrink();

    final isPast = end.isBefore(widget.now);
    final isCurrent = start.isBefore(widget.now) && end.isAfter(widget.now);

    Color bgColor = isCurrent
        ? AppTheme.epgCurrent
        : isPast
        ? AppTheme.epgPast
        : AppTheme.epgFuture;

    return Positioned(
      left: leftPx + 1,
      top: 3,
      bottom: 3,
      width: widthPx > 2 ? widthPx - 2 : widthPx,
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            decoration: BoxDecoration(
              color: _hovering ? AppTheme.surfaceVariant : bgColor,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(
                color: isCurrent
                    ? AppTheme.primary.withValues(alpha: 0.6)
                    : AppTheme.epgBorder,
                width: isCurrent ? 1.5 : 0.5,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Row(
                  children: [
                    if (isCurrent)
                      Padding(
                        padding: const EdgeInsets.only(right: 4),
                        child: Icon(
                          Icons.play_arrow,
                          size: 10,
                          color: AppTheme.primary,
                        ),
                      ),
                    Expanded(
                      child: Text(
                        widget.epg.decodedTitle.isEmpty
                            ? 'Unknown'
                            : widget.epg.decodedTitle,
                        style: TextStyle(
                          color: isPast
                              ? AppTheme.textMuted
                              : isCurrent
                              ? AppTheme.textPrimary
                              : AppTheme.textSecondary,
                          fontSize: 11,
                          fontWeight: isCurrent
                              ? FontWeight.w600
                              : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                if (widthPx > 80) ...[
                  const SizedBox(height: 2),
                  Text(
                    '${DateFormat('HH:mm').format(start)}'
                    ' – ${DateFormat('HH:mm').format(end)}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 9,
                    ),
                  ),
                ],
                if (isCurrent) ...[
                  const SizedBox(height: 3),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: widget.epg.progress,
                      minHeight: 2,
                      backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                      valueColor: const AlwaysStoppedAnimation<Color>(
                        AppTheme.primary,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NOW LINE
// ─────────────────────────────────────────────────────────────────────────────
class _NowLine extends StatelessWidget {
  final double headerH;
  final DateTime now;

  const _NowLine({required this.headerH, required this.now});

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Container(width: 2, color: AppTheme.timelineLine),
        Positioned(
          top: 4,
          left: -20,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            decoration: BoxDecoration(
              color: AppTheme.timelineLine,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              DateFormat('HH:mm').format(now),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
        Positioned(
          top: headerH - 10,
          left: -5,
          child: CustomPaint(
            size: const Size(12, 10),
            painter: _TrianglePainter(AppTheme.timelineLine),
          ),
        ),
      ],
    );
  }
}

class _TrianglePainter extends CustomPainter {
  final Color color;
  const _TrianglePainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawPath(
      Path()
        ..moveTo(size.width / 2, size.height)
        ..lineTo(0, 0)
        ..lineTo(size.width, 0)
        ..close(),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_) => false;
}
