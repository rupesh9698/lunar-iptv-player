import 'dart:async';
import 'package:lunar_iptv_player/widgets/app_network_image.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lunar_iptv_player/core/utils/focus_utils.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';

/// Moves remote focus into the channel column. With [preferSelected] the
/// playing channel's row is used when it is in the list, otherwise the first
/// visible row. Returns false when the list has no rows.
/// With [selectedOnly] nothing happens (false) unless the playing channel
/// is listed.
typedef EpgEntryFocus = bool Function({bool preferSelected, bool selectedOnly});

class EpgTimeline extends ConsumerStatefulWidget {
  final bool isFullscreen;
  final VoidCallback onToggleFullscreen;
  final FocusNode? searchFocusNode;
  final FocusNode? refreshFocusNode;
  final FocusNode? fullscreenFocusNode;

  /// Where Up from search / refresh / fullscreen goes (the screen's Back
  /// button — the "Watch Now" button above the guide was removed).
  final FocusNode? upFocus;

  /// Returns the currently-focused/selected category tile's FocusNode —
  /// used for "Left" from the first channel-list item.
  final FocusNode? Function()? categoryEntryFocus;

  /// Reports the first channel cell's FocusNode once built.
  final ValueChanged<FocusNode>? onFirstItemFocusReady;

  /// Reports the "enter the channel list" action (see [EpgEntryFocus]).
  final ValueChanged<EpgEntryFocus>? onEntryReady;

  const EpgTimeline({
    super.key,
    required this.isFullscreen,
    required this.onToggleFullscreen,
    this.searchFocusNode,
    this.refreshFocusNode,
    this.fullscreenFocusNode,
    this.upFocus,
    this.categoryEntryFocus,
    this.onFirstItemFocusReady,
    this.onEntryReady,
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

  // ── Programme cursor (TV remote) ─────────────────────────────────────
  // Right from a channel moves into its programmes: a highlighted show
  // that Left / Right step through (the timeline scrolls along, so
  // upcoming shows can be browsed), Up / Down keep the same time on the
  // neighbouring channel, OK plays the channel, Left on the current show
  // goes back to the channel name.
  final List<FocusNode> _progFocusNodes = [];
  final ValueNotifier<_GuideCursor?> _cursor = ValueNotifier(null);
  Map<String, List<EpgListing>> _epg = const {};
  DateTime _winStart = DateTime.now();
  DateTime _winEnd = DateTime.now();

  FocusNode _progNode(int index) {
    while (_progFocusNodes.length <= index) {
      _progFocusNodes.add(
        FocusNode(debugLabel: 'epgProg${_progFocusNodes.length}'),
      );
    }
    return _progFocusNodes[index];
  }

  List<_EpgSlot> _slotsFor(int row) => row < _streams.length
      ? _resolveEpgOverlaps(_epg[_streams[row].streamId] ?? const [])
      : const [];

  /// Right from channel [row]: highlight the show on now (or the first
  /// one in view if the timeline was scrolled ahead).
  void _enterGuide(int row) {
    var at = _now;
    if (_horizCtrl.hasClients) {
      final viewStart = _winStart.add(
        Duration(minutes: (_horizCtrl.offset / _pxPerHour * 60).round()),
      );
      if (viewStart.isAfter(at)) at = viewStart;
    }
    _cursor.value = _GuideCursor(row, at);
    _revealTime(at);
    _focusChannel(row, prog: true);
  }

  /// Steps the cursor to the next / previous show. Returns false when it
  /// can't go further back (already on the show airing now).
  bool _moveCursor(int row, DateTime at, int dir) {
    final slots = _slotsFor(row);
    _EpgSlot? cur;
    for (final sl in slots) {
      if (!sl.listing.startTime.isAfter(at) && sl.effectiveEnd.isAfter(at)) {
        cur = sl;
        break;
      }
    }
    DateTime target;
    if (dir > 0) {
      DateTime? next;
      for (final sl in slots) {
        if (sl.listing.startTime.isAfter(at)) {
          next = sl.listing.startTime;
          break;
        }
      }
      target = next ?? at.add(const Duration(minutes: 30));
      if (!target.isBefore(_winEnd)) return true; // end of the guide
    } else {
      final curStart = cur?.listing.startTime ?? at;
      if (!curStart.isAfter(_now)) return false; // on the live show
      DateTime? prev;
      for (final sl in slots) {
        if (sl.listing.startTime.isBefore(curStart)) {
          prev = sl.listing.startTime;
        }
      }
      target = prev ?? curStart.subtract(const Duration(minutes: 30));
      if (target.isBefore(_now)) target = _now;
    }
    _cursor.value = _GuideCursor(row, target);
    _revealTime(target);
    return true;
  }

  /// Scrolls the timeline so time [t] is comfortably in view.
  void _revealTime(DateTime t) {
    if (!_horizCtrl.hasClients) return;
    final pos = _horizCtrl.position;
    final x = t.difference(_winStart).inMinutes / 60.0 * _pxPerHour;
    if (x < pos.pixels + 12 || x > pos.pixels + pos.viewportDimension - 180) {
      _horizCtrl.animateTo(
        (x - 60).clamp(0.0, pos.maxScrollExtent),
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOut,
      );
    }
  }

  static bool _isOk(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.select ||
      k == LogicalKeyboardKey.enter ||
      k == LogicalKeyboardKey.numpadEnter ||
      k == LogicalKeyboardKey.gameButtonA;

  bool _okDown = false;

  KeyEventResult _onProgKey(int row, KeyEvent e) {
    final k = e.logicalKey;
    if (_isOk(k)) {
      // Act on release (like every other button), once per press.
      if (e is KeyDownEvent) _okDown = true;
      if (e is KeyUpEvent && _okDown) {
        _okDown = false;
        if (row < _streams.length) _onChannelTap(context, _streams[row]);
      }
      return KeyEventResult.handled;
    }
    if (e is KeyUpEvent) return KeyEventResult.ignored;
    final at = _cursor.value?.at ?? _now;
    if (k == LogicalKeyboardKey.arrowRight) {
      _moveCursor(row, at, 1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowLeft) {
      if (!_moveCursor(row, at, -1)) {
        // Back out of the guide onto the row's favourite heart.
        _cursor.value = null;
        final heart = _heartNode(row);
        if (heart.context != null) {
          heart.requestFocus();
        } else {
          _focusChannel(row);
        }
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      if (row == 0) {
        widget.searchFocusNode?.requestFocus();
      } else {
        _cursor.value = _GuideCursor(row - 1, at);
        _focusChannel(row - 1, prog: true);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (row + 1 < _streams.length) {
        _cursor.value = _GuideCursor(row + 1, at);
        _focusChannel(row + 1, prog: true);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  FocusNode _channelNode(int index) {
    while (_channelFocusNodes.length <= index) {
      _channelFocusNodes.add(FocusNode(debugLabel: 'epgChannel$index'));
    }
    return _channelFocusNodes[index];
  }

  // Favourite heart per row: a D-pad stop between the channel and its
  // programmes (channel → heart → guide).
  final List<FocusNode> _heartFocusNodes = [];

  FocusNode _heartNode(int index) {
    while (_heartFocusNodes.length <= index) {
      _heartFocusNodes.add(
        FocusNode(debugLabel: 'epgHeart${_heartFocusNodes.length}'),
      );
    }
    return _heartFocusNodes[index];
  }

  /// Keeps row [index] on screen with a row of context above / below.
  /// The programme cells have no auto-scroll of their own, so Up / Down in
  /// the guide used to walk off the bottom of the list.
  void _keepRowInView(int index) {
    if (!_leftCtrl.hasClients) return;
    final pos = _leftCtrl.position;
    final top = index * _rowH;
    final margin = pos.viewportDimension > _rowH * 4 ? _rowH : 0.0;
    double? target;
    if (top - margin < pos.pixels) {
      target = top - margin;
    } else if (top + _rowH + margin > pos.pixels + pos.viewportDimension) {
      target = top + _rowH + margin - pos.viewportDimension;
    }
    if (target == null) return;
    _leftCtrl.animateTo(
      target.clamp(0.0, pos.maxScrollExtent),
      duration: const Duration(milliseconds: 160),
      curve: Curves.easeOut,
    );
  }

  /// Moves remote focus to row [index]. If that row isn't built yet (it is
  /// beyond the ListView's cache extent — common when the D-pad is held
  /// down), first jump the list so the row gets built, then focus it on the
  /// next frame. Without this, focus silently stopped at the last built row.
  void _focusChannel(int index, {bool reveal = false, bool prog = false}) {
    final node = prog ? _progNode(index) : _channelNode(index);
    // Entering the list (not stepping row to row): bring a row that is out
    // of view into view first — a built-but-hidden row would take focus
    // off-screen.
    if (reveal && _leftCtrl.hasClients) {
      final pos = _leftCtrl.position;
      final top = index * _rowH;
      if (top < pos.pixels ||
          top + _rowH > pos.pixels + pos.viewportDimension) {
        _leftCtrl.jumpTo(
          (top - pos.viewportDimension * 0.3).clamp(0.0, pos.maxScrollExtent),
        );
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && node.context != null) node.requestFocus();
        });
        return;
      }
    }
    if (node.context != null) {
      node.requestFocus();
      // Channel cells and programme rows both rely on this: the cells'
      // own centre-on-focus didn't scroll the channel list.
      _keepRowInView(index);
      return;
    }
    if (_leftCtrl.hasClients) {
      final pos = _leftCtrl.position;
      final target = (index * _rowH - pos.viewportDimension * 0.3).clamp(
        0.0,
        pos.maxScrollExtent,
      );
      _leftCtrl.jumpTo(target);
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && node.context != null) node.requestFocus();
    });
  }

  /// Channels currently listed (set on every build).
  List<LiveStream> _streams = const [];

  bool _focusEntry({bool preferSelected = false, bool selectedOnly = false}) {
    if (!mounted || _streams.isEmpty) return false;
    var idx = -1;
    if (preferSelected) {
      final sel = ref.read(selectedChannelProvider);
      if (sel != null) {
        idx = _streams.indexWhere((c) => c.streamId == sel.streamId);
      }
    }
    if (idx < 0 && selectedOnly) return false;
    if (idx < 0) {
      // First row that is fully visible.
      idx = _leftCtrl.hasClients
          ? (_leftCtrl.offset / _rowH).ceil().clamp(0, _streams.length - 1)
          : 0;
    }
    _focusChannel(idx, reveal: true);
    return true;
  }

  // Channel column narrows on small screens so the timeline stays usable.
  double _chColW = 240.0;
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _jumpToNow();
      if (mounted) widget.onEntryReady?.call(_focusEntry);
    });
  }

  @override
  void dispose() {
    _leftCtrl.dispose();
    _rightCtrl.dispose();
    _horizCtrl.dispose();
    _clockTimer?.cancel();
    for (final n in [
      ..._channelFocusNodes,
      ..._progFocusNodes,
      ..._heartFocusNodes,
    ]) {
      n.dispose();
    }
    _cursor.dispose();
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
          upFocus: widget.upFocus,
          categoryEntryFocus: widget.categoryEntryFocus,
          enterChannels: () => _focusEntry(),
          onRefresh: () {
            ref.read(epgCacheProvider.notifier).clear();
            ref.invalidate(liveAllStreamsProvider);
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
                    onPressed: () => ref.invalidate(liveAllStreamsProvider),
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
    _streams = streams;
    _epg = epgCache;
    _winStart = windowStart;
    _winEnd = windowEnd;
    final nowOffsetPx = _now.isAfter(windowStart) && _now.isBefore(windowEnd)
        ? _now.difference(windowStart).inMinutes / 60.0 * _pxPerHour
        : -1.0;
    final favorites = ref.watch(liveFavoritesNotifierProvider);

    final showChanNum = ref.watch(showChannelNumberProvider);

    return LayoutBuilder(
      builder: (ctx, constraints) {
        final rightH = constraints.maxHeight - _headerH - 1;
        _chColW = (constraints.maxWidth * 0.42).clamp(150.0, 240.0);

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
                          heartFocusNode: _heartNode(i),
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
                              : () => _focusChannel(i - 1),
                          onDownNext: i < streams.length - 1
                              ? () => _focusChannel(i + 1)
                              : null,
                          onLeftToCategory: () =>
                              widget.categoryEntryFocus?.call()?.requestFocus(),
                          onRightToGuide: () => _enterGuide(i),
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
                                  rowIndex: i,
                                  focusNode: _progNode(i),
                                  cursor: _cursor,
                                  horizontal: _horizCtrl,
                                  onKey: (e) => _onProgKey(i, e),
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

  /// First click / OK previews the channel in the mini player; clicking or
  /// pressing OK again on the channel that is already playing (i.e. a
  /// double-click) opens it full screen — same as "Watch Now".
  void _onChannelTap(BuildContext ctx, LiveStream ch) {
    if (ref.read(selectedChannelProvider)?.streamId == ch.streamId) {
      ref.read(livePlayerMaximizedProvider.notifier).state = true;
      return;
    }
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
  final FocusNode? upFocus;
  final bool Function()? enterChannels;
  final FocusNode? Function()? categoryEntryFocus;

  const _EpgControlBar({
    required this.isFullscreen,
    required this.onToggleFullscreen,
    required this.onRefresh,
    this.searchFocusNode,
    this.refreshFocusNode,
    this.fullscreenFocusNode,
    this.upFocus,
    this.enterChannels,
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
    if (!(widget.enterChannels?.call() ?? false)) self.requestFocus();
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
                widget.upFocus?.requestFocus();
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
                widget.upFocus?.requestFocus();
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
      excludeChildFocus: false, // hosts the search TextField
      onActivate: () {
        setState(() => _searchOpen = !_searchOpen);
        if (!_searchOpen) {
          _searchCtrl.clear();
          ref.read(liveSearchQueryProvider.notifier).state = '';
        }
      },
      onArrowKey: (key) {
        if (key == LogicalKeyboardKey.arrowUp) {
          widget.upFocus?.requestFocus();
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
        width: _searchOpen
            ? (MediaQuery.sizeOf(context).width * 0.22).clamp(140.0, 220.0)
            : 34,
        height: 30,
        decoration: BoxDecoration(
          color: _searchOpen ? AppTheme.surfaceVariant : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        // Border painted on top (takes no layout space). As a layout border
        // it shrank the closed box below the 30 px icon → "overflowed by
        // 1 pixel" stripes whenever the button was focused.
        foregroundDecoration: BoxDecoration(
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
        child: LayoutBuilder(
          // While the box animates open/closed the width passes through
          // tiny values; only mount the TextField once there is room.
          builder: (context, box) => Row(
            children: [
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
              if (_searchOpen && box.maxWidth >= 100)
                Expanded(
                  child: TvTextFieldNav(
                    controller: _searchCtrl,
                    onUp: () => widget.upFocus?.requestFocus(),
                    onDown: () =>
                        _goFirstChannelOrSelf(widget.searchFocusNode!),
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
                        filled: false,
                      ),
                    ),
                  ),
                ),
            ],
          ),
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
  final VoidCallback? onRightToGuide;
  final FocusNode? heartFocusNode;

  const _ChannelCell({
    this.onRightToGuide,
    this.heartFocusNode,
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
  // The favourite heart is its own D-pad stop: Right from the channel moves
  // onto it, OK toggles, Left goes back (it used to be pointer-only).
  FocusNode? _ownHeart;
  FocusNode get _heart =>
      widget.heartFocusNode ??
      (_ownHeart ??= FocusNode(debugLabel: 'epgHeart'));
  bool _heartFocused = false;

  @override
  void dispose() {
    _ownHeart?.dispose();
    super.dispose();
  }

  void _toggleFavorite() {
    widget.onFavorite();
    final nowFav = !widget.isFavorite;
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(
            nowFav
                ? 'Added "${widget.channel.name}" to Favorites'
                : 'Removed "${widget.channel.name}" from Favorites',
          ),
          duration: const Duration(seconds: 2),
        ),
      );
  }

  KeyEventResult _vertical(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.arrowUp) {
      (widget.onUpAtTop ?? () {})();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowDown) {
      if (widget.onDownNext != null) widget.onDownNext!();
      return KeyEventResult.handled; // last item: No Action
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final hasNum =
        widget.showChannelNumber &&
        widget.channel.num.isNotEmpty &&
        widget.channel.num != '0';
    final focused = showFocusRing;
    final heartRing =
        _heartFocused &&
        FocusManager.instance.highlightMode == FocusHighlightMode.traditional;
    final rowLit = isTvHovered || focused || heartRing;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: 56,
      padding: const EdgeInsets.only(left: 10, right: 6),
      decoration: BoxDecoration(
        color: widget.isSelected
            ? AppTheme.selectedItem
            : rowLit
            ? AppTheme.surfaceVariant
            : AppTheme.epgFuture,
        // Focus ring on top of everything — on the playing channel's row
        // the old left-edge marker was invisible.
        border: const Border(
          bottom: BorderSide(color: AppTheme.epgBorder, width: 0.5),
        ),
      ),
      foregroundDecoration: focused
          ? BoxDecoration(
              border: Border.all(color: Colors.white, width: 2.5),
              borderRadius: BorderRadius.circular(4),
            )
          : null,
      child: Row(
        children: [
          Expanded(
            child: TvFocusable(
              focusNode: widget.focusNode,
              // Scrolling is done by the timeline (_keepRowInView).
              autoScroll: false,
              onActivate: widget.onTap,
              // Hold OK / Menu still toggles favourite too.
              onLongPress: _toggleFavorite,
              onFocusChange: setTvFocused,
              onArrowKey: (key) {
                if (key == LogicalKeyboardKey.arrowRight) {
                  // channel → heart → programmes.
                  _heart.requestFocus();
                  return KeyEventResult.handled;
                }
                if (key == LogicalKeyboardKey.arrowLeft) {
                  (widget.onLeftToCategory ?? () {})();
                  return KeyEventResult.handled;
                }
                return _vertical(key);
              },
              builder: (_, _) => Row(
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
                ],
              ),
            ),
          ),
          // ── Favourite heart (separate D-pad stop) ──────────────────────
          // Hidden (but still a D-pad stop) until the row is lit or the
          // channel is a favourite.
          IgnorePointer(
            ignoring: !(rowLit || widget.isFavorite),
            child: Opacity(
              opacity: (rowLit || widget.isFavorite) ? 1 : 0,
              child: TvFocusable(
                focusNode: _heart,
                autoScroll: false,
                onActivate: _toggleFavorite,
                onFocusChange: (f) => setState(() => _heartFocused = f),
                onArrowKey: (key) {
                  if (key == LogicalKeyboardKey.arrowLeft) {
                    widget.focusNode?.requestFocus();
                    return KeyEventResult.handled;
                  }
                  if (key == LogicalKeyboardKey.arrowRight) {
                    // On into the programmes.
                    widget.onRightToGuide?.call();
                    return KeyEventResult.handled;
                  }
                  return _vertical(key);
                },
                builder: (_, _) => AnimatedContainer(
                  duration: const Duration(milliseconds: 120),
                  padding: const EdgeInsets.all(5),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: heartRing
                        ? Colors.white.withValues(alpha: 0.14)
                        : Colors.transparent,
                    border: Border.all(
                      color: heartRing ? Colors.white : Colors.transparent,
                      width: 1.5,
                    ),
                  ),
                  child: Icon(
                    widget.isFavorite ? Icons.favorite : Icons.favorite_border,
                    size: 15,
                    color: widget.isFavorite
                        ? AppTheme.error
                        : heartRing
                        ? Colors.white
                        : AppTheme.textMuted,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _logo() {
    final icon = widget.channel.streamIcon;
    if (icon != null && icon.isNotEmpty) {
      // Disk-cached and decoded at logo size — hundreds of channel rows used
      // to download and decode full-size logos on every visit.
      return AppNetworkImage(
        url: icon,
        width: 40,
        height: 32,
        fit: BoxFit.contain,
        fallback: _placeholder(),
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
class _GuideCursor {
  final int row;
  final DateTime at;
  const _GuideCursor(this.row, this.at);
}

class _ProgramRow extends StatefulWidget {
  final int rowIndex;
  final FocusNode focusNode;
  final ValueListenable<_GuideCursor?> cursor;
  final ScrollController? horizontal;
  final KeyEventResult Function(KeyEvent e) onKey;
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
    required this.rowIndex,
    required this.focusNode,
    required this.cursor,
    this.horizontal,
    required this.onKey,
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
  bool _hasFocus = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.onEpgNeeded());
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _hasFocus = f),
      onKeyEvent: (_, e) => widget.onKey(e),
      child: ValueListenableBuilder<_GuideCursor?>(
        valueListenable: widget.cursor,
        builder: (context, c, _) => _row(
          _hasFocus && c != null && c.row == widget.rowIndex ? c.at : null,
        ),
      ),
    );
  }

  /// A row label kept at the timeline's visible left edge.
  Widget _pinnedLabel(Widget child) {
    final h = widget.horizontal;
    Widget at(double x) => Positioned(
      left: x + 10,
      top: 0,
      bottom: 0,
      child: Center(child: child),
    );
    if (h == null) return at(0);
    return AnimatedBuilder(
      animation: h,
      builder: (_, _) => at(h.hasClients ? h.offset : 0),
    );
  }

  Widget _row(DateTime? at) {
    final slots = _resolveEpgOverlaps(widget.epg);
    final hit =
        at != null &&
        slots.any(
          (sl) =>
              !sl.listing.startTime.isAfter(at) && sl.effectiveEnd.isAfter(at),
        );
    return Container(
      foregroundDecoration: _hasFocus && !hit
          ? BoxDecoration(border: Border.all(color: Colors.white, width: 2.5))
          : null,
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
            _pinnedLabel(
              const SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppTheme.textMuted,
                ),
              ),
            )
          else if (widget.epg.isEmpty)
            _pinnedLabel(
              const Text(
                'No EPG',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                ),
              ),
            )
          else
            ...slots.map((slot) {
              final lit =
                  at != null &&
                  !slot.listing.startTime.isAfter(at) &&
                  slot.effectiveEnd.isAfter(at);
              return _ShowBlock(
                highlighted: lit,
                // Every show sticks to the timeline's visible left edge,
                // so a show that began before the view keeps its outline
                // and title on screen instead of running under the
                // channel column.
                stickTo: widget.horizontal,
                epg: slot.listing,
                effectiveEnd: slot.effectiveEnd,
                windowStart: widget.windowStart,
                windowEnd: widget.windowEnd,
                pxPerHour: widget.pxPerHour,
                now: widget.now,
                onTap: widget.onTap,
              );
            }),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHOW BLOCK
// ─────────────────────────────────────────────────────────────────────────────
class _ShowBlock extends StatefulWidget {
  final bool highlighted; // under the remote's programme cursor
  final ScrollController? stickTo; // timeline scroll, for the sticky block
  final EpgListing epg;
  final DateTime effectiveEnd;
  final DateTime windowStart;
  final DateTime windowEnd;
  final double pxPerHour;
  final DateTime now;
  final VoidCallback onTap;

  const _ShowBlock({
    this.highlighted = false,
    this.stickTo,
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

    final block = MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          decoration: BoxDecoration(
            color: widget.highlighted
                ? AppTheme.selectedItem
                : _hovering
                ? AppTheme.surfaceVariant
                : bgColor,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: widget.highlighted
                  ? Colors.white
                  : isCurrent
                  ? AppTheme.primary.withValues(alpha: 0.6)
                  : AppTheme.epgBorder,
              width: widget.highlighted ? 2.5 : (isCurrent ? 1.5 : 0.5),
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
    );

    Widget place(double l, double w) => Positioned(
      left: l + 1,
      top: 3,
      bottom: 3,
      width: w > 2 ? w - 2 : w,
      child: block,
    );

    final stick = widget.stickTo;
    if (stick == null) return place(leftPx, widthPx);
    return AnimatedBuilder(
      animation: stick,
      builder: (_, _) {
        final view = stick.hasClients ? stick.offset : 0.0;
        final right = leftPx + widthPx;
        // Started before the visible part: start the block at the view's
        // left edge (keeping at least 60 px of it on screen).
        if (view <= leftPx || view >= right - 60) {
          return place(leftPx, widthPx);
        }
        return place(view, right - view);
      },
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
