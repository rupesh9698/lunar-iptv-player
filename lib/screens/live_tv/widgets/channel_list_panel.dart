import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/app_providers.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/storage_service.dart';
import '../live_tv_screen.dart';

class ChannelListPanel extends ConsumerStatefulWidget {
  const ChannelListPanel({super.key});

  @override
  ConsumerState<ChannelListPanel> createState() => _ChannelListPanelState();
}

class _ChannelListPanelState extends ConsumerState<ChannelListPanel> {
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    // Handle scroll trigger that was set before this widget rendered
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkPendingScroll());
  }

  void _checkPendingScroll() {
    final targetId = ref.read(liveScrollToChannelProvider);
    if (targetId == null) return;
    final streams = ref.read(filteredLiveStreamsProvider).value;
    if (streams == null) return; // ref.listen in build() handles deferred case
    final idx = streams.indexWhere((s) => s.streamId == targetId);
    if (idx < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          idx * 68.0,
          duration: const Duration(milliseconds: 500),
          curve: Curves.easeInOut,
        );
      }
      ref.read(selectedChannelProvider.notifier).state = streams[idx];
      ref.read(liveScrollToChannelProvider.notifier).state = null;
    });
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // ── Scroll to channel when trigger fires (streams already loaded) ─────────────
    ref.listen<String?>(liveScrollToChannelProvider, (_, targetId) {
      if (targetId == null) return;
      final streams = ref.read(filteredLiveStreamsProvider).value;
      if (streams == null) return; // streams listener below will handle it
      final idx = streams.indexWhere((s) => s.streamId == targetId);
      if (idx < 0) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_scrollCtrl.hasClients) {
          _scrollCtrl.animateTo(
            idx * 68.0,
            duration: const Duration(milliseconds: 500),
            curve: Curves.easeInOut,
          );
        }
        ref.read(selectedChannelProvider.notifier).state = streams[idx];
        ref.read(liveScrollToChannelProvider.notifier).state = null;
      });
    });

    // ── Scroll to channel when streams finish loading (trigger was set first) ──────
    ref.listen<AsyncValue<List<LiveStream>>>(filteredLiveStreamsProvider, (
      _,
      next,
    ) {
      final targetId = ref.read(liveScrollToChannelProvider);
      if (targetId == null) return;
      next.whenData((streams) {
        final idx = streams.indexWhere((s) => s.streamId == targetId);
        if (idx < 0) return;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          if (_scrollCtrl.hasClients) {
            _scrollCtrl.animateTo(
              idx * 68.0,
              duration: const Duration(milliseconds: 500),
              curve: Curves.easeInOut,
            );
          }
          ref.read(selectedChannelProvider.notifier).state = streams[idx];
          ref.read(liveScrollToChannelProvider.notifier).state = null;
        });
      });
    });

    final streamsAsync = ref.watch(filteredLiveStreamsProvider);
    final selected = ref.watch(selectedChannelProvider);
    final epgCache = ref.watch(epgCacheProvider);
    final favorites = ref.watch(liveFavoritesNotifierProvider);
    final showChannelNumber = ref.watch(showChannelNumberProvider);

    return Container(
      color: AppTheme.background,
      child: streamsAsync.when(
        data: (streams) {
          if (streams.isEmpty) {
            return const Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.tv_off, color: AppTheme.textMuted, size: 48),
                  SizedBox(height: 12),
                  Text(
                    'No channels found',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                ],
              ),
            );
          }
          return ListView.builder(
            controller: _scrollCtrl,
            itemCount: streams.length,
            itemExtent: 68,
            itemBuilder: (ctx, i) {
              final channel = streams[i];
              final isFav = favorites.contains(channel.streamId);
              final epg = epgCache[channel.streamId] ?? [];
              final current = epg.isNotEmpty ? epg.first : null;

              return _ChannelTile(
                channel: channel,
                isSelected: selected?.streamId == channel.streamId,
                isFavorite: isFav,
                currentShow: current,
                showChannelNumber: showChannelNumber,
                onTap: () {
                  ref.read(selectedChannelProvider.notifier).state = channel;
                  ref.read(epgCacheProvider.notifier).loadEpg(channel.streamId);
                  // Save last watched for Remember Watch Position
                  final rememberPos =
                      StorageService.instance.getSetting(
                            AppConstants.rememberPositionKey,
                            true,
                          )
                          as bool;
                  if (rememberPos) {
                    final category = ref.read(selectedLiveCategoryProvider);
                    ref
                        .read(lastWatchedLiveProvider.notifier)
                        .save(
                          categoryId: category?.categoryId,
                          channelId: channel.streamId,
                        );
                  }
                },
                onPlay: () => playChannel(ctx, ref, channel),
                onFavorite: () => ref
                    .read(liveFavoritesNotifierProvider.notifier)
                    .toggle(channel.streamId),
                onVisible: () {
                  ref.read(epgCacheProvider.notifier).loadEpg(channel.streamId);
                },
              );
            },
          );
        },
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
              const Text(
                'Failed to load channels',
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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNEL TILE — touch · mouse · keyboard · TV remote
// ─────────────────────────────────────────────────────────────────────────────
class _ChannelTile extends StatefulWidget {
  final LiveStream channel;
  final bool isSelected;
  final bool isFavorite;
  final EpgListing? currentShow;
  final bool showChannelNumber;
  final VoidCallback onTap;
  final VoidCallback onPlay;
  final VoidCallback onFavorite;
  final VoidCallback onVisible;

  const _ChannelTile({
    required this.channel,
    required this.isSelected,
    required this.isFavorite,
    required this.currentShow,
    required this.showChannelNumber,
    required this.onTap,
    required this.onPlay,
    required this.onFavorite,
    required this.onVisible,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _hovering = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onVisible();
    });
  }

  @override
  Widget build(BuildContext context) {
    final show = widget.currentShow;
    final progress = show?.progress ?? 0.0;
    final hasNum =
        widget.showChannelNumber &&
        widget.channel.num.isNotEmpty &&
        widget.channel.num != '0';

    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() {
          _hovering = false;
          _pressed = false;
        }),
        child: GestureDetector(
          onTap: widget.onTap,
          onDoubleTap: widget.onPlay,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            decoration: BoxDecoration(
              color: widget.isSelected
                  ? AppTheme.selectedItem
                  : _pressed
                  ? AppTheme.surfaceVariant.withValues(alpha: 0.9)
                  : _hovering || _focused
                  ? AppTheme.surfaceVariant
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(10),
              border: widget.isSelected
                  ? Border.all(color: AppTheme.primary.withValues(alpha: 0.4))
                  : _focused
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.35),
                      width: 1.5,
                    )
                  : Border.all(color: Colors.transparent),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(
              children: [
                // ── Channel Logo ─────────────────────────────────
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    width: 52,
                    height: 40,
                    color: AppTheme.surfaceVariant,
                    child:
                        widget.channel.streamIcon != null &&
                            widget.channel.streamIcon!.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: widget.channel.streamIcon!,
                            fit: BoxFit.contain,
                            placeholder: (_, _) => const Center(
                              child: Icon(
                                Icons.tv,
                                color: AppTheme.textMuted,
                                size: 20,
                              ),
                            ),
                            errorWidget: (_, _, _) => const Center(
                              child: Icon(
                                Icons.tv,
                                color: AppTheme.textMuted,
                                size: 20,
                              ),
                            ),
                          )
                        : const Center(
                            child: Icon(
                              Icons.tv,
                              color: AppTheme.textMuted,
                              size: 20,
                            ),
                          ),
                  ),
                ),

                const SizedBox(width: 10),

                // ── Channel Info ──────────────────────────────────
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Row(
                        children: [
                          if (hasNum)
                            Container(
                              margin: const EdgeInsets.only(right: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.surfaceVariant,
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(color: AppTheme.divider),
                              ),
                              child: Text(
                                widget.channel.num,
                                style: const TextStyle(
                                  color: AppTheme.textMuted,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                          Expanded(
                            child: Text(
                              widget.channel.name,
                              style: TextStyle(
                                color: widget.isSelected
                                    ? AppTheme.textPrimary
                                    : AppTheme.textSecondary,
                                fontSize: 13,
                                fontWeight: widget.isSelected
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          // LIVE badge
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: AppTheme.error.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 5,
                                  height: 5,
                                  decoration: const BoxDecoration(
                                    color: AppTheme.error,
                                    shape: BoxShape.circle,
                                  ),
                                ),
                                const SizedBox(width: 3),
                                const Text(
                                  'LIVE',
                                  style: TextStyle(
                                    color: AppTheme.error,
                                    fontSize: 9,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),

                      if (show != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          show.decodedTitle,
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: progress,
                            minHeight: 2,
                            backgroundColor: AppTheme.divider,
                            valueColor: const AlwaysStoppedAnimation<Color>(
                              AppTheme.primary,
                            ),
                          ),
                        ),
                      ] else ...[
                        const SizedBox(height: 3),
                        const Text(
                          '─',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),

                const SizedBox(width: 6),

                // ── Right Buttons ─────────────────────────────────
                Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    AnimatedOpacity(
                      opacity: (_hovering || widget.isSelected || _focused)
                          ? 1.0
                          : 0.0,
                      duration: const Duration(milliseconds: 150),
                      child: GestureDetector(
                        onTap: widget.onPlay,
                        child: Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.play_arrow,
                            color: AppTheme.primary,
                            size: 16,
                          ),
                        ),
                      ),
                    ),
                    GestureDetector(
                      onTap: widget.onFavorite,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(
                          widget.isFavorite
                              ? Icons.favorite
                              : Icons.favorite_border,
                          color: widget.isFavorite
                              ? const Color(0xFFEF4444)
                              : AppTheme.textMuted,
                          size: 15,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
