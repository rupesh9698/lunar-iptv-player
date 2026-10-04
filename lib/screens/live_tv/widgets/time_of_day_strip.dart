import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/utils/focus_utils.dart';
import '../../../models/xtream_models.dart';
import '../../../providers/live_tv_provider.dart';
import '../../../services/behavior_service.dart';

/// Horizontal strip shown at the top of the Live TV channel list when
/// the user has enough hourly-usage data.
/// Shows: greeting label + channels they usually watch at this hour.
class TimeOfDayStrip extends ConsumerWidget {
  const TimeOfDayStrip({super.key});

  static String _greeting() {
    final h = DateTime.now().hour;
    if (h < 12) return 'Good Morning';
    if (h < 17) return 'Good Afternoon';
    if (h < 21) return 'Good Evening';
    return 'Good Night';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final channels = ref.watch(timeOfDayChannelsProvider);
    if (channels.isEmpty) return const SizedBox.shrink();

    final hour = DateTime.now().hour;
    final label = DateFormat('h a').format(DateTime(0, 1, 1, hour));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 14,
                decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 7),
              Text(
                '${_greeting()} · Your $label Picks',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: const Color(0xFF7B61FF).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: const Color(0xFF7B61FF).withValues(alpha: 0.3),
                  ),
                ),
                child: const Text(
                  'AI',
                  style: TextStyle(
                    color: Color(0xFF7B61FF),
                    fontSize: 8,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Channel chips ───────────────────────────────────────────────────
        SizedBox(
          height: 64,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.only(left: 12, right: 4),
            itemCount: channels.length,
            itemBuilder: (ctx, i) => Padding(
              padding: const EdgeInsets.only(right: 8, bottom: 4),
              child: _TimeOfDayChip(
                key: ValueKey('tod_${channels[i].streamId}'),
                channel: channels[i],
                index: i,
              ),
            ),
          ),
        ),

        const Divider(color: AppTheme.divider, height: 1),
      ],
    ).animate().fadeIn(duration: 400.ms).slideY(begin: -0.06);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHIP
// ─────────────────────────────────────────────────────────────────────────────
class _TimeOfDayChip extends ConsumerStatefulWidget {
  final LiveStream channel;
  final int index;
  const _TimeOfDayChip({super.key, required this.channel, required this.index});

  @override
  ConsumerState<_TimeOfDayChip> createState() => _TimeOfDayChipState();
}

class _TimeOfDayChipState extends ConsumerState<_TimeOfDayChip>
    with TvFocusMixin {
  @override
  Widget build(BuildContext context) {
    final isSelected =
        ref.watch(selectedChannelProvider)?.streamId == widget.channel.streamId;

    return TvFocusable(
          onActivate: _select,
          onFocusChange: setTvFocused,
          builder: (focused, pressed) => AnimatedScale(
            scale: pressed
                ? 0.93
                : focused
                ? 1.05
                : 1.0,
            duration: const Duration(milliseconds: 130),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 52,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.selectedItem
                    : focused
                    ? AppTheme.surfaceVariant
                    : AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primary
                      : focused
                      ? Colors.white.withValues(alpha: 0.55)
                      : AppTheme.divider,
                  width: (isSelected || focused) ? 1.5 : 1,
                ),
                boxShadow: (isSelected || focused)
                    ? [
                        BoxShadow(
                          color: AppTheme.primary.withValues(alpha: 0.20),
                          blurRadius: 8,
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      width: 36,
                      height: 28,
                      child: widget.channel.streamIcon?.isNotEmpty == true
                          ? CachedNetworkImage(
                              imageUrl: widget.channel.streamIcon!,
                              fit: BoxFit.contain,
                              placeholder: (_, _) => const Icon(
                                Icons.tv,
                                color: AppTheme.textMuted,
                                size: 16,
                              ),
                              errorWidget: (_, _, _) => const Icon(
                                Icons.tv,
                                color: AppTheme.textMuted,
                                size: 16,
                              ),
                            )
                          : const Icon(
                              Icons.tv,
                              color: AppTheme.textMuted,
                              size: 16,
                            ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 100),
                    child: Text(
                      widget.channel.name,
                      style: TextStyle(
                        color: isSelected
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 12,
                        fontWeight: isSelected
                            ? FontWeight.w600
                            : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(
          delay: Duration(milliseconds: widget.index * 50),
          duration: 300.ms,
        )
        .slideX(begin: 0.1, curve: Curves.easeOutCubic);
  }

  void _select() {
    ref.read(selectedChannelProvider.notifier).state = widget.channel;
    ref.read(epgCacheProvider.notifier).loadEpg(widget.channel.streamId);
    ref.read(recentlyViewedLiveProvider.notifier).add(widget.channel.streamId);
    BehaviorService.instance.recordHourlyChannelView(
      widget.channel.streamId,
      name: widget.channel.name,
    );
  }
}
