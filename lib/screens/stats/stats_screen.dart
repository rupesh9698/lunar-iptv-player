import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../providers/app_providers.dart';
import '../../providers/behavior_providers.dart';
import '../../services/behavior_service.dart';

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  @override
  Widget build(BuildContext context) {
    ref.watch(behaviorRefreshProvider); // Rebuild on data change
    final flags = ref.watch(contentFlagsProvider);
    final playlist = ref.watch(activePlaylistProvider);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        context.go('/home');
      },
      child: Scaffold(
        backgroundColor: AppTheme.background,
        body: SafeArea(
          child: Column(
            children: [
              _buildTopBar(context, playlist?.name ?? ''),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: _DashboardBody(flags: flags),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context, String playlistName) {
    return Container(
      height: 52,
      color: AppTheme.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _FocusableIconBtn(
            icon: Icons.arrow_back_ios_new,
            tooltip: 'Back',
            color: AppTheme.textSecondary,
            onTap: () => context.go('/home'),
          ),
          const SizedBox(width: 8),
          const Icon(
            Icons.bar_chart_rounded,
            color: AppTheme.primary,
            size: 20,
          ),
          const SizedBox(width: 8),
          const Text(
            'My Stats',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: const Color(0xFF7B61FF).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: const Color(0xFF7B61FF).withValues(alpha: 0.3),
              ),
            ),
            child: const Text(
              'AI',
              style: TextStyle(
                color: Color(0xFF7B61FF),
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          if (playlistName.isNotEmpty) ...[
            const SizedBox(width: 10),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                playlistName,
                style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
              ),
            ),
          ],
          const Spacer(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// DASHBOARD BODY
// ─────────────────────────────────────────────────────────────────────────────
class _DashboardBody extends StatelessWidget {
  final ({bool hasLive, bool hasVod, bool hasSeries}) flags;
  const _DashboardBody({required this.flags});

  @override
  Widget build(BuildContext context) {
    final totalSecs = BehaviorService.instance.getTotalWatchSeconds();
    final byDay = BehaviorService.instance.getWatchTimeByDay(days: 7);
    final topContent = BehaviorService.instance.getTopContentByTime(topN: 5);
    final totalHours = totalSecs / 3600;
    final totalMins = totalSecs ~/ 60;

    // Conditional data based on playlist content flags
    final topGenres = (flags.hasVod || flags.hasSeries)
        ? BehaviorService.instance.getTopGenres(topN: 6)
        : <String>[];
    final topChannels = flags.hasLive
        ? BehaviorService.instance.getHourlyTopChannels(topN: 5)
        : <String>[];

    if (totalSecs == 0 && topChannels.isEmpty) return _EmptyState();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Summary Cards ────────────────────────────────────────────────────
        Row(
          children: [
            Expanded(
              child: _StatCard(
                icon: Icons.timer_outlined,
                label: 'Total Watch Time',
                value: totalHours >= 1
                    ? '${totalHours.toStringAsFixed(1)}h'
                    : '${totalMins}m',
                color: AppTheme.primary,
              ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.1),
            ),
            const SizedBox(width: 16),
            if (flags.hasLive) ...[
              Expanded(
                child:
                    _StatCard(
                          icon: Icons.tv_outlined,
                          label: 'Channels Watched',
                          value: '${topChannels.length}+',
                          color: const Color(0xFF22C55E),
                        )
                        .animate()
                        .fadeIn(delay: 60.ms, duration: 400.ms)
                        .slideY(begin: 0.1),
              ),
              const SizedBox(width: 16),
            ],
            if (flags.hasVod || flags.hasSeries) ...[
              Expanded(
                child:
                    _StatCard(
                          icon: Icons.category_outlined,
                          label: 'Top Genres',
                          value: '${topGenres.length}',
                          color: const Color(0xFF7B61FF),
                        )
                        .animate()
                        .fadeIn(delay: 60.ms, duration: 400.ms)
                        .slideY(begin: 0.1),
              ),
              const SizedBox(width: 16),
            ],
            Expanded(
              child:
                  _StatCard(
                        icon: Icons.play_circle_outline,
                        label: 'Items Watched',
                        value: '${topContent.length}+',
                        color: AppTheme.success,
                      )
                      .animate()
                      .fadeIn(delay: 120.ms, duration: 400.ms)
                      .slideY(begin: 0.1),
            ),
          ],
        ),

        const SizedBox(height: 28),

        // ── Watch Time Chart ────────────────────────────────────────────────
        if (byDay.any((d) => (d['seconds'] as int) > 0)) ...[
          const _SectionHeader(
            icon: Icons.bar_chart_rounded,
            label: 'Watch Time — Last 7 Days',
          ),
          const SizedBox(height: 16),
          _WatchTimeChart(byDay: byDay)
              .animate()
              .fadeIn(delay: 150.ms, duration: 500.ms)
              .slideY(begin: 0.08),
          const SizedBox(height: 28),
        ],

        // ── Live TV: Most Watched Channels (current hour) ───────────────────
        if (flags.hasLive && topChannels.isNotEmpty) ...[
          const _SectionHeader(
            icon: Icons.tv_outlined,
            label: 'Favourite Channels (This Hour)',
          ),
          const SizedBox(height: 12),
          _HourlyChannelList(channelIds: topChannels)
              .animate()
              .fadeIn(delay: 180.ms, duration: 500.ms)
              .slideY(begin: 0.08),
          const SizedBox(height: 28),
        ],

        // ── Genre Preferences (Movies + Series only) ────────────────────────
        if ((flags.hasVod || flags.hasSeries) && topGenres.isNotEmpty) ...[
          const _SectionHeader(
            icon: Icons.local_movies_outlined,
            label: 'Your Top Genres',
          ),
          const SizedBox(height: 16),
          _GenresChart(genres: topGenres)
              .animate()
              .fadeIn(delay: 200.ms, duration: 500.ms)
              .slideY(begin: 0.08),
          const SizedBox(height: 28),
        ],

        // ── Most Watched Content ────────────────────────────────────────────
        if (topContent.isNotEmpty) ...[
          _SectionHeader(
            icon: Icons.star_border_rounded,
            label: flags.hasLive && !flags.hasVod && !flags.hasSeries
                ? 'Most Watched Channels'
                : 'Most Watched Content',
          ),
          const SizedBox(height: 12),
          ...topContent.asMap().entries.map((e) {
            final rank = e.key + 1;
            final item = e.value;
            final secs = item['seconds'] as int;
            final name = item['name'] as String;
            final mins = secs ~/ 60;
            final display = mins >= 60
                ? '${(mins / 60).toStringAsFixed(1)}h'
                : '${mins}m';
            return _TopRow(
                  rank: rank,
                  name: name,
                  display: display,
                  secs: secs,
                  maxSecs: (topContent.first['seconds'] as int),
                )
                .animate()
                .fadeIn(
                  delay: Duration(milliseconds: 250 + e.key * 50),
                  duration: 350.ms,
                )
                .slideX(begin: 0.06);
          }),
          const SizedBox(height: 28),
        ],
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY STATE
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(40),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.10),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.bar_chart_rounded,
              color: AppTheme.primary,
              size: 36,
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'No data yet',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Watch some content and your personalised\nstats will appear here.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED SMALL WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final String label;
  const _SectionHeader({required this.icon, required this.label});

  @override
  Widget build(BuildContext context) => Row(
    children: [
      Container(
        width: 3,
        height: 16,
        decoration: BoxDecoration(
          color: AppTheme.primary,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
      const SizedBox(width: 8),
      Icon(icon, color: AppTheme.primary, size: 16),
      const SizedBox(width: 6),
      Text(
        label,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
    ],
  );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(20),
    decoration: BoxDecoration(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 20),
        ),
        const SizedBox(height: 12),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 28,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          label,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
      ],
    ),
  );
}

class _WatchTimeChart extends StatelessWidget {
  final List<Map<String, dynamic>> byDay;
  const _WatchTimeChart({required this.byDay});

  @override
  Widget build(BuildContext context) {
    final maxSecs = byDay.fold<int>(
      1,
      (m, d) => math.max(m, (d['seconds'] as int)),
    );
    final bars = byDay.asMap().entries.map((e) {
      final secs = (e.value['seconds'] as int).toDouble();
      return BarChartGroupData(
        x: e.key,
        barRods: [
          BarChartRodData(
            toY: secs,
            color: secs > 0 ? AppTheme.primary : AppTheme.divider,
            width: 26,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(6)),
          ),
        ],
      );
    }).toList();

    return Container(
      height: 200,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.divider),
      ),
      child: BarChart(
        BarChartData(
          maxY: maxSecs.toDouble() * 1.2,
          barGroups: bars,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            getDrawingHorizontalLine: (_) =>
                FlLine(color: AppTheme.divider, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 44,
                getTitlesWidget: (v, _) {
                  final mins = v ~/ 60;
                  if (v == 0) return const SizedBox.shrink();
                  return Text(
                    mins >= 60 ? '${(mins / 60).round()}h' : '${mins}m',
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                getTitlesWidget: (v, _) {
                  final idx = v.toInt();
                  if (idx < 0 || idx >= byDay.length) {
                    return const SizedBox.shrink();
                  }
                  return Text(
                    byDay[idx]['label'] as String,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  );
                },
              ),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipColor: (_) => AppTheme.surfaceVariant,
              getTooltipItem: (_, _, rod, _) {
                final secs = rod.toY.toInt();
                final mins = secs ~/ 60;
                final t = mins >= 60
                    ? '${(mins / 60).toStringAsFixed(1)}h'
                    : '${mins}m';
                return BarTooltipItem(
                  t,
                  const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _GenresChart extends StatelessWidget {
  final List<String> genres;
  const _GenresChart({required this.genres});

  static const _colors = [
    AppTheme.primary,
    Color(0xFF7B61FF),
    AppTheme.success,
    Color(0xFFF59E0B),
    AppTheme.error,
    Color(0xFF06B6D4),
  ];

  @override
  Widget build(BuildContext context) {
    final max = genres.length.toDouble();
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        children: genres.asMap().entries.map((e) {
          final frac = (max - e.key) / max;
          final color = _colors[e.key % _colors.length];
          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 110,
                  child: Text(
                    e.value,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: frac,
                      minHeight: 8,
                      backgroundColor: AppTheme.divider,
                      valueColor: AlwaysStoppedAnimation<Color>(color),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _TopRow extends StatelessWidget {
  final int rank;
  final String name;
  final String display;
  final int secs;
  final int maxSecs;
  const _TopRow({
    required this.rank,
    required this.name,
    required this.display,
    required this.secs,
    required this.maxSecs,
  });

  @override
  Widget build(BuildContext context) {
    final frac = maxSecs > 0 ? secs / maxSecs : 0.0;
    final colors = [
      const Color(0xFFFFD700),
      const Color(0xFFC0C0C0),
      const Color(0xFFCD7F32),
      AppTheme.textMuted,
      AppTheme.textMuted,
    ];
    final color = colors[(rank - 1).clamp(0, colors.length - 1)];

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                '#$rank',
                style: TextStyle(
                  color: color,
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name, // ← shows actual name
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 4,
                    backgroundColor: AppTheme.divider,
                    valueColor: AlwaysStoppedAnimation<Color>(color),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            display,
            style: TextStyle(
              color: color,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FocusableIconBtn extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  const _FocusableIconBtn({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
  });

  @override
  State<_FocusableIconBtn> createState() => _FocusableIconBtnState();
}

class _FocusableIconBtnState extends State<_FocusableIconBtn> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space)) {
          widget.onTap();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              padding: const EdgeInsets.all(6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                color: _focused
                    ? widget.color.withValues(alpha: 0.12)
                    : Colors.transparent,
                border: _focused
                    ? Border.all(color: widget.color.withValues(alpha: 0.5))
                    : null,
              ),
              child: Icon(
                widget.icon,
                color: _focused ? widget.color : AppTheme.textSecondary,
                size: 18,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HOURLY CHANNEL LIST — shows top channels at the current hour
// ─────────────────────────────────────────────────────────────────────────────
class _HourlyChannelList extends StatelessWidget {
  final List<String> channelIds;
  const _HourlyChannelList({required this.channelIds});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.divider),
      ),
      child: Column(
        children: channelIds.asMap().entries.map((e) {
          final rank = e.key + 1;
          final id = e.value;
          // Resolve display name from cache if possible
          final name = BehaviorService.instance
              .getContentName(id) // method added below
              .let((n) => n.isNotEmpty ? n : 'Channel $rank');

          return Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '#$rank',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const Icon(
                  Icons.tv_outlined,
                  color: AppTheme.textMuted,
                  size: 14,
                ),
              ],
            ),
          );
        }).toList(),
      ),
    );
  }
}

extension<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
