import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/theme/app_theme.dart';
import '../../core/utils/focus_utils.dart';
import '../../providers/app_providers.dart';
import '../../services/behavior_service.dart';

const _liveColor = Color(0xFFFF5A7A);
const _movieColor = Color(0xFF4F8DFF);
const _seriesColor = Color(0xFFB57BFF);
const _accent = Color(0xFF22C55E);
const _amber = Color(0xFFF59E0B);

class StatsScreen extends ConsumerStatefulWidget {
  const StatsScreen({super.key});

  @override
  ConsumerState<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends ConsumerState<StatsScreen> {
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    // While something plays (e.g. Live TV in the mini player), today's
    // figures keep growing: refresh every 20 s. Saved changes (a session
    // ending, a new day...) arrive through BehaviorService.changes.
    _tick = Timer.periodic(const Duration(seconds: 20), (_) {
      if (mounted && BehaviorService.instance.isWatching) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
                // D-pad scrollable (the dashboard has no focusable content).
                child: TvScrollView(
                  padding: EdgeInsets.all(
                    MediaQuery.sizeOf(context).width < 840 ? 14 : 24,
                  ),
                  child: ValueListenableBuilder<int>(
                    valueListenable: BehaviorService.instance.changes,
                    builder: (context, _, _) =>
                        _DashboardBody(data: _StatsData.read(flags)),
                  ),
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
            autofocus: true,
            icon: Icons.arrow_back_ios_new,
            tooltip: 'Back',
            color: AppTheme.textSecondary,
            onTap: () => context.go('/home'),
          ),
          const SizedBox(width: 8),
          const Icon(Icons.insights_rounded, color: AppTheme.primary, size: 20),
          const SizedBox(width: 8),
          const Text(
            'My Stats',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (playlistName.isNotEmpty) ...[
            const SizedBox(width: 10),
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  playlistName,
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ],
          const Spacer(),
          if (BehaviorService.instance.isWatching) const _LivePill(),
        ],
      ),
    );
  }
}

/// "Updating live" marker while a session is running.
class _LivePill extends StatelessWidget {
  const _LivePill();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: _accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(20),
    ),
    child: const Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.circle, size: 8, color: _accent),
        SizedBox(width: 6),
        Text(
          'Updating live',
          style: TextStyle(
            color: _accent,
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// DATA
// ─────────────────────────────────────────────────────────────────────────────
class _StatsData {
  final ({bool hasLive, bool hasVod, bool hasSeries}) flags;
  final int totalSecs;
  final List<Map<String, dynamic>> last14;
  final List<Map<String, dynamic>> last28;
  final Map<String, int> byType;
  final List<int> byHour;
  final int streak;
  final List<Map<String, dynamic>> topContent;
  final List<MapEntry<String, int>> genres;
  final List<String> channelsNow;

  _StatsData({
    required this.flags,
    required this.totalSecs,
    required this.last14,
    required this.last28,
    required this.byType,
    required this.byHour,
    required this.streak,
    required this.topContent,
    required this.genres,
    required this.channelsNow,
  });

  static _StatsData read(({bool hasLive, bool hasVod, bool hasSeries}) flags) {
    final b = BehaviorService.instance;
    return _StatsData(
      flags: flags,
      totalSecs: b.getTotalWatchSeconds() + b.getActiveSeconds(),
      last14: b.getWatchTimeByDay(days: 14),
      last28: b.getWatchTimeByDay(days: 28),
      byType: b.getWatchByType(),
      byHour: b.getWatchByHour(),
      streak: b.getStreakDays(),
      topContent: b.getTopContentByTime(topN: 6),
      genres: (flags.hasVod || flags.hasSeries)
          ? b.getGenreCounts(topN: 6)
          : const [],
      channelsNow: flags.hasLive ? b.getHourlyTopChannels(topN: 5) : const [],
    );
  }

  int _sum(Iterable<Map<String, dynamic>> days) =>
      days.fold(0, (s, d) => s + (d['seconds'] as int));

  int get thisWeek => _sum(last14.skip(7));
  int get lastWeek => _sum(last14.take(7));
  int get dailyAverage => thisWeek ~/ 7;

  /// Percent change this week vs last week (null when last week was empty).
  int? get weekChange =>
      lastWeek == 0 ? null : ((thisWeek - lastWeek) * 100 / lastWeek).round();

  bool get isEmpty =>
      totalSecs == 0 && channelsNow.isEmpty && topContent.isEmpty;
}

String _fmt(int secs) {
  if (secs < 60) return secs > 0 ? '<1m' : '0m';
  final m = secs ~/ 60;
  if (m < 60) return '${m}m';
  final h = m ~/ 60;
  final r = m % 60;
  return r == 0 ? '${h}h' : '${h}h ${r}m';
}

String _hourLabel(int h) {
  final ampm = h < 12 ? 'AM' : 'PM';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12 $ampm';
}

// ─────────────────────────────────────────────────────────────────────────────
// DASHBOARD BODY
// ─────────────────────────────────────────────────────────────────────────────
class _DashboardBody extends StatelessWidget {
  final _StatsData data;
  const _DashboardBody({required this.data});

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const _EmptyState();
    // The app always runs in landscape: two columns from phones to TVs.
    final size = MediaQuery.sizeOf(context);
    final twoCols = size.width >= 620;
    final gap = size.width < 900 ? 14.0 : 20.0;
    // Chart rows: both panels share one height, scaled to the screen.
    final rowH = (size.height * 0.55).clamp(230.0, 320.0);

    final insights = _insights(data);
    final change = data.weekChange;

    /// Two panels side by side. With [height] both get exactly that height
    /// (charts fill it); without, they match the taller one (lists).
    Widget pair(Widget a, Widget? b, {double? height}) {
      if (b == null) {
        return height == null ? a : SizedBox(height: height, child: a);
      }
      if (!twoCols) {
        return Column(
          children: [
            height == null ? a : SizedBox(height: height, child: a),
            SizedBox(height: gap),
            height == null ? b : SizedBox(height: height, child: b),
          ],
        );
      }
      final row = Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(flex: 3, child: a),
          SizedBox(width: gap),
          Expanded(flex: 2, child: b),
        ],
      );
      // Charts use LayoutBuilder (no intrinsic sizes): fixed height for
      // them, IntrinsicHeight only for plain lists.
      return height != null
          ? SizedBox(height: height, child: row)
          : IntrinsicHeight(child: row);
    }

    final hasTypes = data.byType.values.any((v) => v > 0);
    final hasHours = data.byHour.any((v) => v > 0);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // ── Headline numbers ──────────────────────────────────────────────
        LayoutBuilder(
          builder: (context, box) {
            final perRow = box.maxWidth >= 560 ? 4 : 2;
            final cardW = (box.maxWidth - gap * (perRow - 1)) / perRow;
            final cards = [
              _StatCard(
                icon: Icons.timer_outlined,
                label: 'Total watch time',
                value: _fmt(data.totalSecs),
                color: AppTheme.primary,
                badge: 'All time',
                badgeColor: AppTheme.textMuted,
              ),
              _StatCard(
                icon: Icons.date_range_rounded,
                label: 'This week',
                value: _fmt(data.thisWeek),
                color: _movieColor,
                badge: change == null
                    ? 'Last 7 days'
                    : '${change >= 0 ? '+' : ''}$change% vs last week',
                badgeColor: change == null
                    ? AppTheme.textMuted
                    : change >= 0
                    ? _accent
                    : AppTheme.error,
              ),
              _StatCard(
                icon: Icons.av_timer_rounded,
                label: 'Daily average',
                value: _fmt(data.dailyAverage),
                color: _seriesColor,
                badge: 'Over the last 7 days',
                badgeColor: AppTheme.textMuted,
              ),
              _StatCard(
                icon: Icons.local_fire_department_rounded,
                label: data.streak == 1 ? 'Day streak' : 'Days in a row',
                value: '${data.streak}',
                color: _amber,
                badge: data.streak == 0
                    ? 'Watch today to start one'
                    : 'Keep it going',
                badgeColor: AppTheme.textMuted,
              ),
            ];
            return Wrap(
              spacing: gap,
              runSpacing: gap,
              children: [
                for (var i = 0; i < cards.length; i++)
                  SizedBox(
                    width: cardW,
                    child: cards[i]
                        .animate()
                        .fadeIn(delay: (60 * i).ms, duration: 380.ms)
                        .slideY(begin: 0.08),
                  ),
              ],
            );
          },
        ),

        // ── Insights ──────────────────────────────────────────────────────
        if (insights.isNotEmpty) ...[
          SizedBox(height: gap),
          _Panel(
            title: 'Insights',
            icon: Icons.auto_awesome_rounded,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final (icon, text) in insights)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Row(
                      children: [
                        Icon(icon, size: 18, color: AppTheme.primary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            text,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ).animate().fadeIn(delay: 120.ms, duration: 400.ms),
        ],

        SizedBox(height: gap),

        // ── Watch time over time + what you watch ─────────────────────────
        pair(
          _Panel(
            title: 'Watch time, last 14 days',
            icon: Icons.bar_chart_rounded,
            fill: true,
            child: _DaysChart(days: data.last14),
          ),
          hasTypes
              ? _Panel(
                  title: 'What you watch',
                  icon: Icons.donut_large_rounded,
                  fill: true,
                  child: _TypeDonut(byType: data.byType),
                )
              : null,
          height: rowH,
        ).animate().fadeIn(delay: 160.ms, duration: 450.ms),

        if (hasHours || data.genres.isNotEmpty) ...[
          SizedBox(height: gap),
          pair(
            hasHours
                ? _Panel(
                    title: 'When you watch',
                    icon: Icons.schedule_rounded,
                    fill: true,
                    child: _HoursChart(hours: data.byHour),
                  )
                : _Panel(
                    title: 'Your top genres',
                    icon: Icons.local_movies_outlined,
                    fill: true,
                    child: _GenreBars(genres: data.genres),
                  ),
            hasHours && data.genres.isNotEmpty
                ? _Panel(
                    title: 'Your top genres',
                    icon: Icons.local_movies_outlined,
                    fill: true,
                    child: _GenreBars(genres: data.genres),
                  )
                : null,
            // Tall enough for every genre row.
            height: math.max(rowH * 0.85, 76.0 + data.genres.length * 30),
          ).animate().fadeIn(delay: 200.ms, duration: 450.ms),
        ],

        if (data.topContent.isNotEmpty || data.channelsNow.isNotEmpty) ...[
          SizedBox(height: gap),
          pair(
            data.topContent.isNotEmpty
                ? _Panel(
                    title: 'Most watched',
                    icon: Icons.emoji_events_outlined,
                    child: Column(
                      children: [
                        for (var i = 0; i < data.topContent.length; i++)
                          _TopRow(
                            rank: i + 1,
                            item: data.topContent[i],
                            maxSecs: data.topContent.first['seconds'] as int,
                          ),
                      ],
                    ),
                  )
                : _Panel(
                    title: 'Channels you watch at this hour',
                    icon: Icons.tv_outlined,
                    child: _HourlyChannelList(channelIds: data.channelsNow),
                  ),
            data.topContent.isNotEmpty && data.channelsNow.isNotEmpty
                ? _Panel(
                    title: 'Usual at this hour',
                    icon: Icons.tv_outlined,
                    child: _HourlyChannelList(channelIds: data.channelsNow),
                  )
                : null,
          ).animate().fadeIn(delay: 240.ms, duration: 450.ms),
        ],
        const SizedBox(height: 12),
      ],
    );
  }

  /// A few plain-language observations.
  static List<(IconData, String)> _insights(_StatsData d) {
    final out = <(IconData, String)>[];

    // When.
    final hours = d.byHour;
    final total = hours.fold(0, (a, b) => a + b);
    if (total > 0) {
      final peak = hours.indexOf(hours.reduce(math.max));
      final part = peak < 5
          ? 'late at night'
          : peak < 12
          ? 'in the morning'
          : peak < 17
          ? 'in the afternoon'
          : peak < 21
          ? 'in the evening'
          : 'at night';
      out.add((
        Icons.schedule_rounded,
        'You watch most $part, around ${_hourLabel(peak)}.',
      ));
    }

    // What.
    final types = d.byType;
    final tTotal = types.values.fold(0, (a, b) => a + b);
    if (tTotal > 0) {
      final top = types.entries.reduce((a, b) => a.value >= b.value ? a : b);
      final pct = (top.value * 100 / tTotal).round();
      final name = switch (top.key) {
        'live' => 'Live TV',
        'movie' => 'movies',
        'series' => 'series',
        _ => top.key,
      };
      out.add((
        Icons.donut_large_rounded,
        pct >= 99
            ? 'All of your watch time is $name.'
            : '$pct% of your watch time is $name.',
      ));
    }

    // Busiest weekday (last 4 weeks).
    final byWeekday = List.filled(7, 0);
    for (final day in d.last28) {
      final date = DateTime.tryParse(day['date'] as String);
      if (date != null) byWeekday[date.weekday - 1] += day['seconds'] as int;
    }
    if (byWeekday.any((s) => s > 0)) {
      const names = [
        'Mondays',
        'Tuesdays',
        'Wednesdays',
        'Thursdays',
        'Fridays',
        'Saturdays',
        'Sundays',
      ];
      final best = byWeekday.indexOf(byWeekday.reduce(math.max));
      out.add((Icons.event_rounded, '${names[best]} are your biggest day.'));
    }

    // Trend.
    final c = d.weekChange;
    if (c != null && c.abs() >= 10) {
      out.add((
        c > 0 ? Icons.trending_up_rounded : Icons.trending_down_rounded,
        c > 0
            ? "You're watching $c% more than last week."
            : "You're watching ${c.abs()}% less than last week.",
      ));
    }

    // Streak.
    if (d.streak >= 3) {
      out.add((
        Icons.local_fire_department_rounded,
        "${d.streak} days in a row. Nice run!",
      ));
    }
    return out;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EMPTY STATE
// ─────────────────────────────────────────────────────────────────────────────
class _EmptyState extends StatelessWidget {
  const _EmptyState();

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
              Icons.insights_rounded,
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
            'Watch something and your stats will show up here,\n'
            'updating as you watch.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// BUILDING BLOCKS
// ─────────────────────────────────────────────────────────────────────────────
class _Panel extends StatelessWidget {
  final String title;
  final IconData icon;
  final Widget child;

  /// Child takes all the height the panel is given (charts).
  final bool fill;
  const _Panel({
    required this.title,
    required this.icon,
    required this.child,
    this.fill = false,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
    decoration: BoxDecoration(
      color: AppTheme.surface,
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, color: AppTheme.primary, size: 17),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        fill ? Expanded(child: child) : child,
      ],
    ),
  );
}

class _StatCard extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final Color color;
  final String? badge;
  final Color? badgeColor;
  const _StatCard({
    required this.icon,
    required this.label,
    required this.value,
    required this.color,
    this.badge,
    this.badgeColor,
  });

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Color.alphaBlend(color.withValues(alpha: 0.10), AppTheme.surface),
          AppTheme.surface,
        ],
      ),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: AppTheme.divider),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: 36,
          height: 36,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: color, size: 19),
        ),
        const SizedBox(height: 12),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: AppTheme.textMuted, fontSize: 12),
        ),
        if (badge != null) ...[
          const SizedBox(height: 6),
          Text(
            badge!,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: badgeColor ?? _accent,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ],
    ),
  );
}

class _DaysChart extends StatelessWidget {
  final List<Map<String, dynamic>> days;
  const _DaysChart({required this.days});

  @override
  Widget build(BuildContext context) {
    final maxSecs = days.fold<int>(
      60,
      (m, d) => math.max(m, d['seconds'] as int),
    );
    final today = days.length - 1;
    // Round grid steps: 15 min, 30 min, 1 h, 2 h, 3 h...
    const steps = [900, 1800, 3600, 7200, 10800, 21600];
    final step = steps
        .firstWhere((s) => maxSecs / s <= 4, orElse: () => 43200)
        .toDouble();
    return BarChart(
      BarChartData(
        maxY: maxSecs * 1.15,
        alignment: BarChartAlignment.spaceAround,
        barGroups: [
          for (var i = 0; i < days.length; i++)
            BarChartGroupData(
              x: i,
              barRods: [
                BarChartRodData(
                  toY: (days[i]['seconds'] as int).toDouble(),
                  width: 14,
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(5),
                  ),
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: i == today
                        ? [_accent.withValues(alpha: 0.6), _accent]
                        : [
                            AppTheme.primary.withValues(alpha: 0.45),
                            AppTheme.primary,
                          ],
                  ),
                  backDrawRodData: BackgroundBarChartRodData(
                    show: true,
                    toY: maxSecs * 1.15,
                    color: Colors.white.withValues(alpha: 0.03),
                  ),
                ),
              ],
            ),
        ],
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: step,
          getDrawingHorizontalLine: (_) =>
              const FlLine(color: AppTheme.divider, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              interval: step,
              getTitlesWidget: (v, meta) {
                if (v == 0 || v == meta.max) return const SizedBox.shrink();
                return Text(
                  _fmt(v.toInt()),
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
                final i = v.toInt();
                if (i < 0 || i >= days.length) return const SizedBox.shrink();
                // Every other label on the 14-day chart, plus today.
                if (i != today && (today - i).isOdd) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    i == today ? 'Today' : days[i]['label'] as String,
                    style: TextStyle(
                      color: i == today ? _accent : AppTheme.textSecondary,
                      fontSize: 10.5,
                      fontWeight: i == today
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
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
            getTooltipItem: (_, _, rod, _) => BarTooltipItem(
              _fmt(rod.toY.toInt()),
              const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HoursChart extends StatelessWidget {
  final List<int> hours;
  const _HoursChart({required this.hours});

  @override
  Widget build(BuildContext context) {
    final maxSecs = math.max(60, hours.reduce(math.max));
    final peak = hours.indexOf(hours.reduce(math.max));
    return LayoutBuilder(
      builder: (context, box) =>
          _chart((box.maxWidth / 24 * 0.42).clamp(4.0, 14.0), maxSecs, peak),
    );
  }

  Widget _chart(double barW, int maxSecs, int peak) {
    Color colorFor(int h) => h < 5 || h >= 21
        ? _seriesColor
        : h < 12
        ? _amber
        : h < 17
        ? _movieColor
        : _liveColor;
    return BarChart(
      BarChartData(
        maxY: maxSecs * 1.1,
        alignment: BarChartAlignment.spaceBetween,
        barGroups: [
          for (var h = 0; h < 24; h++)
            BarChartGroupData(
              x: h,
              barRods: [
                BarChartRodData(
                  toY: hours[h].toDouble(),
                  width: barW,
                  borderRadius: BorderRadius.circular(3),
                  color: colorFor(h).withValues(alpha: h == peak ? 1 : 0.65),
                ),
              ],
            ),
        ],
        gridData: const FlGridData(show: false),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (v, _) {
                final h = v.toInt();
                if (h % 6 != 0) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    _hourLabel(h),
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => AppTheme.surfaceVariant,
            getTooltipItem: (group, _, rod, _) => BarTooltipItem(
              '${_hourLabel(group.x)}\n${_fmt(rod.toY.toInt())}',
              const TextStyle(
                color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TypeDonut extends StatelessWidget {
  final Map<String, int> byType;
  const _TypeDonut({required this.byType});

  @override
  Widget build(BuildContext context) {
    final entries = [
      ('Live TV', byType['live'] ?? 0, _liveColor),
      ('Movies', byType['movie'] ?? 0, _movieColor),
      ('Series', byType['series'] ?? 0, _seriesColor),
    ].where((e) => e.$2 > 0).toList();
    final total = entries.fold(0, (a, e) => a + e.$2);
    return LayoutBuilder(
      builder: (context, box) {
        // As big as the panel allows, legend beside it.
        final d = math
            .min(box.maxHeight, box.maxWidth * 0.48)
            .clamp(90.0, 170.0);
        final ring = d * 0.13;
        final legend = Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final e in entries)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: e.$3,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    SizedBox(
                      width: 62,
                      child: Text(
                        e.$1,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Text(
                      '${(e.$2 * 100 / total).round()}%',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        );
        return Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: d,
                height: d,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    PieChart(
                      PieChartData(
                        sectionsSpace: 3,
                        centerSpaceRadius: d / 2 - ring,
                        startDegreeOffset: -90,
                        sections: [
                          for (final e in entries)
                            PieChartSectionData(
                              value: e.$2.toDouble(),
                              color: e.$3,
                              radius: ring,
                              showTitle: false,
                            ),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _fmt(total),
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: (d * 0.11).clamp(12.0, 18.0),
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const Text(
                          'in total',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 10,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              SizedBox(width: (box.maxWidth * 0.06).clamp(14.0, 32.0)),
              Flexible(child: legend),
            ],
          ),
        );
      },
    );
  }
}

class _GenreBars extends StatelessWidget {
  final List<MapEntry<String, int>> genres;
  const _GenreBars({required this.genres});

  static const _colors = [
    AppTheme.primary,
    _seriesColor,
    _accent,
    _amber,
    _liveColor,
    Color(0xFF06B6D4),
  ];

  @override
  Widget build(BuildContext context) {
    final max = genres.first.value.toDouble();
    return Column(
      children: [
        for (var i = 0; i < genres.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                SizedBox(
                  width: 100,
                  child: Text(
                    genres[i].key,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: genres[i].value / max,
                      minHeight: 8,
                      backgroundColor: AppTheme.divider,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _colors[i % _colors.length],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                SizedBox(
                  width: 28,
                  child: Text(
                    '${genres[i].value}',
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      color: AppTheme.textMuted,
                      fontSize: 11,
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _TopRow extends StatelessWidget {
  final int rank;
  final Map<String, dynamic> item;
  final int maxSecs;
  const _TopRow({
    required this.rank,
    required this.item,
    required this.maxSecs,
  });

  @override
  Widget build(BuildContext context) {
    final secs = item['seconds'] as int;
    final frac = maxSecs > 0 ? secs / maxSecs : 0.0;
    const medals = [Color(0xFFFFD166), Color(0xFFC0C7D0), Color(0xFFD7965B)];
    final color = rank <= 3 ? medals[rank - 1] : AppTheme.textMuted;
    final (icon, typeColor) = switch (item['type'] as String?) {
      'live' => (Icons.live_tv_rounded, _liveColor),
      'movie' => (Icons.movie_outlined, _movieColor),
      'series' => (Icons.video_library_outlined, _seriesColor),
      _ => (Icons.play_circle_outline, AppTheme.textMuted),
    };

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          SizedBox(
            width: 26,
            child: Text(
              '$rank',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: color,
                fontSize: 15,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Icon(icon, size: 16, color: typeColor),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['name'] as String,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 5),
                ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: frac,
                    minHeight: 4,
                    backgroundColor: AppTheme.divider,
                    valueColor: AlwaysStoppedAnimation<Color>(typeColor),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _fmt(secs),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _FocusableIconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback onTap;
  final bool autofocus;
  const _FocusableIconBtn({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      autofocus: autofocus,
      autoScroll: false,
      onActivate: onTap,
      builder: (focused, _) => Tooltip(
        message: tooltip,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8),
            color: focused ? color.withValues(alpha: 0.12) : Colors.transparent,
            border: focused
                ? Border.all(color: color.withValues(alpha: 0.5))
                : null,
          ),
          child: Icon(
            icon,
            color: focused ? color : AppTheme.textSecondary,
            size: 18,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHANNELS USUALLY WATCHED AT THIS HOUR
// ─────────────────────────────────────────────────────────────────────────────
class _HourlyChannelList extends StatelessWidget {
  final List<String> channelIds;
  const _HourlyChannelList({required this.channelIds});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        for (var i = 0; i < channelIds.length; i++)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              children: [
                Container(
                  width: 26,
                  height: 26,
                  decoration: BoxDecoration(
                    color: _liveColor.withValues(alpha: 0.12),
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '${i + 1}',
                      style: const TextStyle(
                        color: _liveColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    () {
                      final n = BehaviorService.instance.getContentName(
                        channelIds[i],
                      );
                      return n.isNotEmpty ? n : 'Channel ${i + 1}';
                    }(),
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// Fake data for previews / widget tests.
@visibleForTesting
Widget debugStatsBody() => _DashboardBody(
  data: _StatsData(
    flags: (hasLive: true, hasVod: true, hasSeries: true),
    totalSecs: 61 * 3600 + 25 * 60,
    last14: [
      for (var i = 13; i >= 0; i--)
        {
          'date': _iso(DateTime.now().subtract(Duration(days: i))),
          'label': const [
            'Mon',
            'Tue',
            'Wed',
            'Thu',
            'Fri',
            'Sat',
            'Sun',
          ][DateTime.now().subtract(Duration(days: i)).weekday - 1],
          'seconds': [
            3600, 5400, 0, 2700, 7200, 10800, 9000, //
            4200, 6000, 1800, 3000, 8400, 12600, 5100,
          ][13 - i],
        },
    ],
    last28: const [],
    byType: const {'live': 30 * 3600, 'movie': 21 * 3600, 'series': 10 * 3600},
    byHour: [
      for (var h = 0; h < 24; h++)
        (h >= 18 && h <= 23)
            ? 9000 - (h - 21).abs() * 1500
            : (h >= 7 && h <= 9 ? 1200 : 300),
    ],
    streak: 6,
    topContent: const [
      {'name': 'Star Sports 1 HD', 'seconds': 40000, 'type': 'live'},
      {'name': 'Interstellar (2014)', 'seconds': 10000, 'type': 'movie'},
      {'name': 'Dark · S1E3', 'seconds': 8000, 'type': 'series'},
      {'name': 'Aaj Tak', 'seconds': 6000, 'type': 'live'},
    ],
    genres: const [
      MapEntry('Sci-Fi', 14),
      MapEntry('Thriller', 9),
      MapEntry('Drama', 6),
      MapEntry('Comedy', 3),
    ],
    channelsNow: const [],
  ),
);

String _iso(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
