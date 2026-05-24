import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';

class EpgTimeline extends ConsumerStatefulWidget {
  const EpgTimeline({super.key});

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
                        return _ChannelCell(
                          key: ValueKey('ch_${ch.streamId}'),
                          channel: ch,
                          isSelected: selected?.streamId == ch.streamId,
                          isFavorite: favorites.contains(ch.streamId),
                          showChannelNumber: showChanNum,
                          onTap: () => _onChannelTap(ctx, ch),
                          onFavorite: () => ref
                              .read(liveFavoritesNotifierProvider.notifier)
                              .toggle(ch.streamId),
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
  final VoidCallback onRefresh;
  const _EpgControlBar({required this.onRefresh});

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

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      color: AppTheme.surface,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          _buildInlineSearch(),
          const SizedBox(width: 6),
          _buildIconBtn(
            icon: Icons.refresh,
            tooltip: 'Refresh EPG',
            onTap: widget.onRefresh,
          ),
        ],
      ),
    );
  }

  Widget _buildInlineSearch() {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeInOut,
      width: _searchOpen ? 220 : 32,
      height: 30,
      decoration: BoxDecoration(
        color: _searchOpen ? AppTheme.surfaceVariant : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
        border: _searchOpen ? Border.all(color: AppTheme.divider) : null,
      ),
      clipBehavior: Clip.hardEdge,
      child: Row(
        children: [
          // Search icon / close button
          GestureDetector(
            onTap: () {
              setState(() => _searchOpen = !_searchOpen);
              if (!_searchOpen) {
                _searchCtrl.clear();
                // Clear EPG search query
                ref.read(liveSearchQueryProvider.notifier).state = '';
              }
            },
            child: SizedBox(
              width: 32,
              height: 30,
              child: Icon(
                _searchOpen ? Icons.close : Icons.search,
                size: 16,
                color: _searchOpen ? AppTheme.primary : AppTheme.textSecondary,
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
                  hintStyle: TextStyle(color: AppTheme.textMuted, fontSize: 12),
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

  Widget _buildIconBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppTheme.divider),
          ),
          child: Icon(icon, size: 15, color: AppTheme.textSecondary),
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

  const _ChannelCell({
    super.key,
    required this.channel,
    required this.isSelected,
    required this.onTap,
    required this.isFavorite,
    required this.onFavorite,
    this.showChannelNumber = true,
  });

  @override
  State<_ChannelCell> createState() => _ChannelCellState();
}

class _ChannelCellState extends State<_ChannelCell> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    final hasNum =
        widget.showChannelNumber &&
        widget.channel.num.isNotEmpty &&
        widget.channel.num != '0';

    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.selectedItem
                : _hovering
                ? AppTheme.surfaceVariant
                : AppTheme.epgFuture,
            border: const Border(
              bottom: BorderSide(color: AppTheme.epgBorder, width: 0.5),
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
              if (_hovering || widget.isFavorite)
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
              if (_hovering || widget.isSelected)
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
