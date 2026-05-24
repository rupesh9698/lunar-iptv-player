import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/live_tv_provider.dart';
import '../live_tv_screen.dart';

class ChannelInfoPanel extends ConsumerWidget {
  final double width;
  const ChannelInfoPanel({super.key, required this.width});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channel  = ref.watch(selectedChannelProvider);
    final epgCache = ref.watch(epgCacheProvider);
    final favorites= ref.watch(liveFavoritesNotifierProvider);

    return SizedBox(
      width: width,
      child: Container(
        color: AppTheme.surface,
        child: channel == null
            ? _buildEmpty()
            : _buildInfo(
          context,
          ref,
          channel,
          epgCache[channel.streamId] ?? [],
          favorites.contains(channel.streamId),
        ),
      ),
    );
  }

  Widget _buildEmpty() {
    return const Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.tv_outlined,
              color: AppTheme.textMuted, size: 48),
          SizedBox(height: 12),
          Text(
            'Select a channel\nto see info',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildInfo(
      BuildContext context,
      WidgetRef ref,
      LiveStream channel,
      List<EpgListing> epg,
      bool isFavorite,
      ) {
    final current = epg.isNotEmpty ? epg.first : null;
    final next    = epg.length > 1 ? epg[1] : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Channel Logo + Name ──────────────────────────────
          _buildChannelHeader(
              context, ref, channel, isFavorite),

          const Divider(color: AppTheme.divider, height: 1),

          // ── Now Playing ──────────────────────────────────────
          if (current != null)
            _buildNowPlaying(current)
          else
            _buildNoEpg(),

          const Divider(color: AppTheme.divider, height: 1),

          // ── Up Next ──────────────────────────────────────────
          if (next != null) _buildUpNext(next),

          const SizedBox(height: 8),

          // ── Actions ──────────────────────────────────────────
          _buildActions(context, ref, channel),
        ],
      ),
    );
  }

  Widget _buildChannelHeader(
      BuildContext context,
      WidgetRef ref,
      LiveStream channel,
      bool isFavorite,
      ) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Channel logo
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Container(
                  width: 56,
                  height: 44,
                  color: AppTheme.surfaceVariant,
                  child: channel.streamIcon != null
                      ? CachedNetworkImage(
                    imageUrl: channel.streamIcon!,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => const Icon(
                        Icons.tv,
                        color: AppTheme.textMuted),
                    errorWidget: (_, _, _) =>
                    const Icon(Icons.tv,
                        color: AppTheme.textMuted),
                  )
                      : const Icon(Icons.tv,
                      color: AppTheme.textMuted),
                ),
              ),
              const SizedBox(width: 10),

              // Name + category
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      channel.name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (channel.categoryId != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        channel.categoryId!,
                        style: const TextStyle(
                          color: AppTheme.textMuted,
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Favorite
              GestureDetector(
                onTap: () => ref
                    .read(liveFavoritesNotifierProvider.notifier)
                    .toggle(channel.streamId),
                child: Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: isFavorite
                        ? AppTheme.error.withValues(alpha: 0.1)
                        : AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    isFavorite
                        ? Icons.favorite
                        : Icons.favorite_border,
                    color: isFavorite
                        ? AppTheme.error
                        : AppTheme.textMuted,
                    size: 16,
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // LIVE badge
          Row(
            children: [
              _LiveBadge(),
              const SizedBox(width: 8),
              // Channel number
              if (channel.num.isNotEmpty &&
                  channel.num != '0')
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceVariant,
                    borderRadius: BorderRadius.circular(4),
                    border:
                    Border.all(color: AppTheme.divider),
                  ),
                  child: Text(
                    'CH ${channel.num}',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildNowPlaying(EpgListing show) {
    final timeStr = '${DateFormat('HH:mm').format(show.startTime)} '
        '– ${DateFormat('HH:mm').format(show.endTime)}';
    final remaining = show.endTime
        .difference(DateTime.now())
        .inMinutes;

    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'NOW PLAYING',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 8),

          // Show title + Record badge
          Row(
            children: [
              Expanded(
                child: Text(
                  show.decodedTitle,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Time + progress
          Row(
            children: [
              Text(
                timeStr,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                ),
              ),
              const Spacer(),
              Text(
                '${remaining > 0 ? remaining : 0} min',
                style: const TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 11,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: show.progress,
              minHeight: 4,
              backgroundColor:
              AppTheme.primary.withValues(alpha: 0.15),
              valueColor: const AlwaysStoppedAnimation<Color>(
                  AppTheme.primary),
            ),
          ),
          const SizedBox(height: 8),

          // Description
          if (show.decodedDescription.isNotEmpty)
            Text(
              show.decodedDescription,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                height: 1.4,
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
        ],
      ),
    );
  }

  Widget _buildUpNext(EpgListing show) {
    final timeStr = '${DateFormat('HH:mm').format(show.startTime)} '
        '– ${DateFormat('HH:mm').format(show.endTime)}';

    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'UP NEXT',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            show.decodedTitle,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            timeStr,
            style: const TextStyle(
              color: AppTheme.textMuted,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoEpg() {
    return const Padding(
      padding: EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'NOW PLAYING',
            style: TextStyle(
              color: AppTheme.textMuted,
              fontSize: 9,
              fontWeight: FontWeight.w700,
              letterSpacing: 1,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'No EPG information',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActions(
      BuildContext context,
      WidgetRef ref,
      LiveStream channel,
      ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: () => playChannel(context, ref, channel),
          icon: const Icon(Icons.play_arrow, size: 20),
          label: const Text('Watch Now'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 12),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
class _LiveBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.error,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 5,
            height: 5,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 4),
          const Text(
            'LIVE',
            style: TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ],
      ),
    );
  }
}