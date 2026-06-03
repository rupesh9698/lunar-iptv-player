import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/theme/app_theme.dart';
import '../providers/behavior_providers.dart';

/// Horizontal "Continue Watching" row shown on the home screen.
/// Fully keyboard / TV-remote / touch / cursor navigable.
class ContinueWatchingRow extends ConsumerWidget {
  const ContinueWatchingRow({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Defensive: if provider throws, show nothing
    List<Map<String, dynamic>> items;
    try {
      items = ref.watch(continueWatchingProvider);
    } catch (_) {
      return const SizedBox.shrink();
    }

    if (items.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── Header ─────────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Container(
                width: 3,
                height: 18,
                decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 8),
              const Text(
                'Continue Watching',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 10),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceVariant,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${items.length}',
                  style: const TextStyle(
                    color: AppTheme.textMuted,
                    fontSize: 11,
                  ),
                ),
              ),
              const Spacer(),
              _ClearAllButton(
                onTap: () =>
                    ref.read(continueWatchingProvider.notifier).clearAll(),
              ),
            ],
          ),
        ),

        // ── Horizontal card list ────────────────────────────────────────────
        SizedBox(
          height: 132,
          child: ListView.builder(
            scrollDirection: Axis.horizontal,
            itemCount: items.length,
            itemBuilder: (ctx, i) => Padding(
              padding: EdgeInsets.only(right: i < items.length - 1 ? 12 : 0),
              child: SizedBox(
                width: 212,
                child: _ContinueCard(
                  key: ValueKey('cw_${items[i]['id']}'),
                  item: items[i],
                  index: i,
                  onRemove: () => ref
                      .read(continueWatchingProvider.notifier)
                      .clear(items[i]['id'] as String),
                ),
              ),
            ),
          ),
        ),
      ],
    ).animate().fadeIn(duration: 400.ms).slideY(begin: 0.08);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CLEAR-ALL BUTTON
// ─────────────────────────────────────────────────────────────────────────────
class _ClearAllButton extends StatefulWidget {
  final VoidCallback onTap;
  const _ClearAllButton({required this.onTap});

  @override
  State<_ClearAllButton> createState() => _ClearAllButtonState();
}

class _ClearAllButtonState extends State<_ClearAllButton> {
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
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            decoration: BoxDecoration(
              color: _focused
                  ? AppTheme.error.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border: _focused
                  ? Border.all(color: AppTheme.error.withValues(alpha: 0.4))
                  : null,
            ),
            child: Text(
              'Clear all',
              style: TextStyle(
                color: _focused ? AppTheme.error : AppTheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONTINUE WATCHING CARD
// ─────────────────────────────────────────────────────────────────────────────
class _ContinueCard extends StatefulWidget {
  final Map<String, dynamic> item;
  final int index;
  final VoidCallback onRemove;

  const _ContinueCard({
    super.key,
    required this.item,
    required this.index,
    required this.onRemove,
  });

  @override
  State<_ContinueCard> createState() => _ContinueCardState();
}

class _ContinueCardState extends State<_ContinueCard> {
  bool _hover = false;
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final title = item['title'] as String? ?? '';
    final imageUrl = item['imageUrl'] as String?;
    final progress = ((item['progress'] as num?)?.toDouble() ?? 0.0).clamp(
      0.0,
      1.0,
    );
    final type = item['type'] as String? ?? 'movie';
    final position = (item['position'] as num?)?.toDouble() ?? 0.0;
    final duration = (item['duration'] as num?)?.toDouble() ?? 0.0;

    final remaining = duration > 0
        ? Duration(seconds: (duration - position).round())
        : null;

    final Color typeBadgeColor;
    final String typeBadgeLabel;
    switch (type) {
      case 'series':
      case 'episode':
        typeBadgeColor = const Color(0xFF22C55E);
        typeBadgeLabel = 'SERIES';
      default:
        typeBadgeColor = AppTheme.primary;
        typeBadgeLabel = 'MOVIE';
    }

    return Focus(
          onFocusChange: (f) => setState(() => _focused = f),
          onKeyEvent: (_, event) {
            if (event is KeyDownEvent) {
              if (event.logicalKey == LogicalKeyboardKey.select ||
                  event.logicalKey == LogicalKeyboardKey.enter ||
                  event.logicalKey == LogicalKeyboardKey.space) {
                setState(() => _pressed = true);
                _navigate(context);
                return KeyEventResult.handled;
              }
              // Delete key removes the item
              if (event.logicalKey == LogicalKeyboardKey.delete ||
                  event.logicalKey == LogicalKeyboardKey.backspace) {
                widget.onRemove();
                return KeyEventResult.handled;
              }
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
              onTap: () => _navigate(context),
              onTapDown: (_) => setState(() => _pressed = true),
              onTapUp: (_) => setState(() => _pressed = false),
              onTapCancel: () => setState(() => _pressed = false),
              child: AnimatedScale(
                scale: _pressed
                    ? 0.95
                    : (_hover || _focused)
                    ? 1.03
                    : 1.0,
                duration: const Duration(milliseconds: 150),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: _focused
                        ? Border.all(
                            color: Colors.white.withValues(alpha: 0.70),
                            width: 2.5,
                          )
                        : Border.all(color: Colors.transparent, width: 2.5),
                    boxShadow: (_focused || _hover)
                        ? [
                            BoxShadow(
                              color: AppTheme.primary.withValues(alpha: 0.25),
                              blurRadius: 14,
                              spreadRadius: 1,
                            ),
                          ]
                        : null,
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // ── Backdrop ───────────────────────────────────────────
                        imageUrl != null && imageUrl.isNotEmpty
                            ? CachedNetworkImage(
                                imageUrl: imageUrl,
                                fit: BoxFit.cover,
                                placeholder: (_, _) => _Placeholder(type: type),
                                errorWidget: (_, _, _) =>
                                    _Placeholder(type: type),
                              )
                            : _Placeholder(type: type),

                        // ── Bottom gradient ────────────────────────────────────
                        Positioned.fill(
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.transparent,
                                  Colors.black.withValues(alpha: 0.80),
                                ],
                                stops: const [0.35, 1.0],
                              ),
                            ),
                          ),
                        ),

                        // ── Type badge ─────────────────────────────────────────
                        Positioned(
                          top: 8,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: typeBadgeColor.withValues(alpha: 0.88),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              typeBadgeLabel,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 8,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),

                        // ── Remove button ──────────────────────────────────────
                        Positioned(
                          top: 6,
                          right: 6,
                          child: AnimatedOpacity(
                            opacity: (_hover || _focused) ? 1.0 : 0.0,
                            duration: const Duration(milliseconds: 150),
                            child: GestureDetector(
                              onTap: widget.onRemove,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.70),
                                  shape: BoxShape.circle,
                                ),
                                child: const Icon(
                                  Icons.close,
                                  color: Colors.white,
                                  size: 11,
                                ),
                              ),
                            ),
                          ),
                        ),

                        // ── Title + remaining ──────────────────────────────────
                        Positioned(
                          bottom: 18,
                          left: 8,
                          right: 8,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w600,
                                  shadows: [
                                    Shadow(color: Colors.black, blurRadius: 4),
                                  ],
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              if (remaining != null &&
                                  remaining.inSeconds > 0) ...[
                                const SizedBox(height: 2),
                                Text(
                                  '${_fmt(remaining)} remaining',
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 9,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),

                        // ── Progress bar ───────────────────────────────────────
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: SizedBox(
                            height: 3.5,
                            child: LinearProgressIndicator(
                              value: progress,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.18,
                              ),
                              valueColor: AlwaysStoppedAnimation<Color>(
                                AppTheme.primary,
                              ),
                            ),
                          ),
                        ),

                        // ── Hover/focus play overlay ───────────────────────────
                        if (_hover || _focused)
                          Center(
                                child: Container(
                                  padding: const EdgeInsets.all(10),
                                  decoration: BoxDecoration(
                                    color: AppTheme.primary.withValues(
                                      alpha: 0.88,
                                    ),
                                    shape: BoxShape.circle,
                                    boxShadow: [
                                      BoxShadow(
                                        color: AppTheme.primary.withValues(
                                          alpha: 0.4,
                                        ),
                                        blurRadius: 12,
                                      ),
                                    ],
                                  ),
                                  child: const Icon(
                                    Icons.play_arrow_rounded,
                                    color: Colors.white,
                                    size: 22,
                                  ),
                                ),
                              )
                              .animate()
                              .fadeIn(duration: 120.ms)
                              .scale(
                                begin: const Offset(0.75, 0.75),
                                duration: 150.ms,
                                curve: Curves.easeOutBack,
                              ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        )
        .animate()
        .fadeIn(
          delay: Duration(milliseconds: widget.index * 55),
          duration: 350.ms,
        )
        .slideX(begin: 0.12, curve: Curves.easeOutCubic);
  }

  void _navigate(BuildContext context) {
    final id = widget.item['id'] as String? ?? '';
    final url = widget.item['url'] as String? ?? '';
    final title = widget.item['title'] as String? ?? '';
    final imageUrl = widget.item['imageUrl'] as String?;
    final type = widget.item['type'] as String? ?? 'movie';
    final position = (widget.item['position'] as num?)?.toDouble() ?? 0.0;

    // Guard: URL must be present — if missing, cannot resume
    if (url.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Cannot resume — no URL stored. Open from Movies/Series instead.',
          ),
          behavior: SnackBarBehavior.floating,
        ),
      );
      return;
    }

    context.push(
      '/player',
      extra: {
        'title': title,
        'url': url,
        'imageUrl': imageUrl,
        'type': type,
        'id': id,
        'startPosition': position,
      },
    );
  }

  static String _fmt(Duration d) {
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLACEHOLDER
// ─────────────────────────────────────────────────────────────────────────────
class _Placeholder extends StatelessWidget {
  final String type;
  const _Placeholder({required this.type});

  @override
  Widget build(BuildContext context) => Container(
    color: AppTheme.surfaceVariant,
    child: Center(
      child: Icon(
        type == 'series' ? Icons.theaters_outlined : Icons.movie_outlined,
        color: AppTheme.textMuted,
        size: 32,
      ),
    ),
  );
}
