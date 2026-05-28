import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_player_provider.dart';
import '../../../providers/live_tv_provider.dart';

/// TV Guide panel — shown at the bottom of the maximized Live TV player.
/// • TV Guide button → minimize back to EPG screen
/// • Horizontal channel strip → select to switch stream
class PlayerChannelGuide extends ConsumerStatefulWidget {
  final VoidCallback onMinimize;
  final VoidCallback onClose;

  const PlayerChannelGuide({
    super.key,
    required this.onMinimize,
    required this.onClose,
  });

  @override
  ConsumerState<PlayerChannelGuide> createState() =>
      _PlayerChannelGuideState();
}

class _PlayerChannelGuideState extends ConsumerState<PlayerChannelGuide>
    with SingleTickerProviderStateMixin {
  final _scrollCtrl = ScrollController();
  int _focusedIndex = -1;
  late final AnimationController _animCtrl;
  late final Animation<Offset> _slideAnim;

  static const double _itemW = 84.0;
  static const double _itemGap = 10.0;

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animCtrl, curve: Curves.easeOutCubic));
    _animCtrl.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) => _initFocus());
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _initFocus() {
    final channels = ref.read(filteredLiveStreamsProvider).value ?? [];
    final current  = ref.read(selectedChannelProvider);
    if (current == null) return;
    final idx = channels.indexWhere((s) => s.streamId == current.streamId);
    if (idx < 0) return;
    setState(() => _focusedIndex = idx);
    _scrollToIndex(idx, animated: false);
  }

  void _scrollToIndex(int idx, {bool animated = true}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtrl.hasClients) return;
      final target = (idx * (_itemW + _itemGap))
          .clamp(0.0, _scrollCtrl.position.maxScrollExtent);
      if (animated) {
        _scrollCtrl.animateTo(target,
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOut);
      } else {
        _scrollCtrl.jumpTo(target);
      }
    });
  }

  Future<void> _selectChannel(int idx, LiveStream ch) async {
    setState(() => _focusedIndex = idx);

    ref.read(selectedChannelProvider.notifier).state = ch;
    ref.read(epgCacheProvider.notifier).loadEpg(ch.streamId);
    ref.read(recentlyViewedLiveProvider.notifier).add(ch.streamId);

    final service = ref.read(xtreamServiceProvider);
    if (service != null) {
      await ref
          .read(livePlayerProvider.notifier)
          .openChannel(service.getLiveUrl(ch.streamId));
    }

    // Close guide after selection so the player takes full focus
    await Future.delayed(const Duration(milliseconds: 600));
    if (mounted) widget.onClose();
  }

  @override
  Widget build(BuildContext context) {
    final channel      = ref.watch(selectedChannelProvider);
    final epgCache     = ref.watch(epgCacheProvider);
    final channelsVal  = ref.watch(filteredLiveStreamsProvider);
    final channels     = channelsVal.value ?? [];

    final epg     = channel != null ? (epgCache[channel.streamId] ?? []) : <EpgListing>[];
    final current = epg.isNotEmpty ? epg.first : null;
    final next    = epg.length > 1 ? epg[1] : null;

    return SlideTransition(
      position: _slideAnim,
      child: Focus(
        autofocus: true,
        onKeyEvent: (_, event) {
          if (event is! KeyDownEvent) return KeyEventResult.ignored;

          if (event.logicalKey == LogicalKeyboardKey.escape ||
              event.logicalKey == LogicalKeyboardKey.goBack) {
            widget.onClose();
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowLeft &&
              _focusedIndex > 0) {
            final ni = _focusedIndex - 1;
            setState(() => _focusedIndex = ni);
            _scrollToIndex(ni);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.arrowRight &&
              _focusedIndex < channels.length - 1) {
            final ni = _focusedIndex + 1;
            setState(() => _focusedIndex = ni);
            _scrollToIndex(ni);
            return KeyEventResult.handled;
          }
          if (event.logicalKey == LogicalKeyboardKey.select ||
              event.logicalKey == LogicalKeyboardKey.enter  ||
              event.logicalKey == LogicalKeyboardKey.space) {
            if (_focusedIndex >= 0 && _focusedIndex < channels.length) {
              _selectChannel(_focusedIndex, channels[_focusedIndex]);
            }
            return KeyEventResult.handled;
          }
          return KeyEventResult.ignored;
        },
        child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.transparent,
                Colors.black.withValues(alpha: 0.96),
              ],
              stops: const [0.0, 0.25],
            ),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── Controls row ──────────────────────────────────────
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Row(children: [
                    _GuideBtn(
                      icon: Icons.tv_outlined,
                      label: 'TV Guide',
                      active: true,
                      onTap: widget.onMinimize,
                    ),
                  ]),
                ),

                // ── Current program info ───────────────────────────────
                if (channel != null)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(channel.name,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis),

                        if (current != null) ...[
                          const SizedBox(height: 3),
                          Row(children: [
                            Text(current.decodedTitle,
                                style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                            const SizedBox(width: 10),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                '${DateFormat('HH:mm').format(current.startTime)} — '
                                    '${DateFormat('HH:mm').format(current.endTime)}',
                                style: const TextStyle(
                                    color: Colors.white54, fontSize: 11),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${current.endTime.difference(DateTime.now()).inMinutes.clamp(0, 9999)} min',
                              style: const TextStyle(
                                  color: Colors.white38, fontSize: 11),
                            ),
                          ]),
                        ],

                        if (next != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            '${DateFormat('HH:mm').format(next.startTime)} — '
                                '${next.decodedTitle}',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ],
                    ),
                  ),

                const SizedBox(height: 10),

                // ── Channel strip ──────────────────────────────────────
                SizedBox(
                  height: 88,
                  child: channels.isEmpty
                      ? const Center(
                      child: Text('No channels',
                          style: TextStyle(color: Colors.white38)))
                      : ListView.builder(
                    controller: _scrollCtrl,
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: channels.length,
                    itemExtent: _itemW + _itemGap,
                    itemBuilder: (_, i) {
                      final ch       = channels[i];
                      final isActive = channel?.streamId == ch.streamId;
                      final isFoc    = _focusedIndex == i;
                      return Padding(
                        padding: const EdgeInsets.only(right: _itemGap),
                        child: _ChannelItem(
                          channel: ch,
                          isCurrent: isActive,
                          isFocused: isFoc,
                          width: _itemW,
                          onTap: () => _selectChannel(i, ch),
                        ),
                      );
                    },
                  ),
                ),

                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GUIDE BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _GuideBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _GuideBtn({
    required this.icon, required this.label,
    this.active = false, required this.onTap,
  });

  @override
  State<_GuideBtn> createState() => _GuideBtnState();
}

class _GuideBtnState extends State<_GuideBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter  ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: (widget.active || _focused)
                  ? AppTheme.primary.withValues(alpha: 0.25)
                  : Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: (widget.active || _focused)
                    ? AppTheme.primary
                    : Colors.white.withValues(alpha: 0.2),
                width: (widget.active || _focused) ? 2 : 1,
              ),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(widget.icon,
                  color: (widget.active || _focused)
                      ? AppTheme.primary
                      : Colors.white70,
                  size: 16),
              const SizedBox(width: 6),
              Text(widget.label,
                  style: TextStyle(
                    color: (widget.active || _focused)
                        ? AppTheme.primary
                        : Colors.white70,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  )),
            ]),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL ITEM
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelItem extends StatefulWidget {
  final LiveStream channel;
  final bool isCurrent;
  final bool isFocused;
  final double width;
  final VoidCallback onTap;

  const _ChannelItem({
    required this.channel, required this.isCurrent,
    required this.isFocused, required this.width, required this.onTap,
  });

  @override
  State<_ChannelItem> createState() => _ChannelItemState();
}

class _ChannelItemState extends State<_ChannelItem> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final lit = widget.isCurrent || widget.isFocused || _hover;

    return GestureDetector(
      onTap: widget.onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit:  (_) => setState(() => _hover = false),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: widget.width,
          decoration: BoxDecoration(
            color: lit
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: widget.isCurrent
                  ? AppTheme.primary
                  : widget.isFocused
                  ? Colors.white.withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.12),
              width: (widget.isCurrent || widget.isFocused) ? 2 : 1,
            ),
          ),
          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
            // Logo
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                width: 52, height: 36,
                child: widget.channel.streamIcon?.isNotEmpty == true
                    ? CachedNetworkImage(
                  imageUrl: widget.channel.streamIcon!,
                  fit: BoxFit.contain,
                  placeholder: (_, _) =>
                  const Icon(Icons.tv, color: Colors.white30, size: 18),
                  errorWidget: (_, _, _) =>
                  const Icon(Icons.tv, color: Colors.white30, size: 18),
                )
                    : const Icon(Icons.tv, color: Colors.white30, size: 18),
              ),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                widget.channel.name,
                style: TextStyle(
                  color: widget.isCurrent ? Colors.white : Colors.white60,
                  fontSize: 9,
                  fontWeight: widget.isCurrent
                      ? FontWeight.w700
                      : FontWeight.w400,
                ),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
              ),
            ),
          ]),
        ),
      ),
    );
  }
}