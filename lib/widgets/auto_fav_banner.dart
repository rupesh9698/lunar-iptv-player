import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../core/theme/app_theme.dart';
import '../core/utils/focus_utils.dart';
import '../services/behavior_service.dart';

/// One-time banner that appears when the user has watched
/// the same content ≥5 times without favouriting it.
/// Works for Live channels, Movies and Series.
class AutoFavBanner extends StatefulWidget {
  final String contentId;
  final String contentName;
  final VoidCallback onAddFav;
  final VoidCallback onDismiss;

  const AutoFavBanner({
    super.key,
    required this.contentId,
    required this.contentName,
    required this.onAddFav,
    required this.onDismiss,
  });

  /// Returns true when this banner should be shown for [id].
  static bool shouldShow(
    String id,
    Set<String> currentFavs, {
    int minViews = 5,
  }) {
    if (currentFavs.contains(id)) return false;
    return BehaviorService.instance.getWatchCount(id) >= minViews;
  }

  @override
  State<AutoFavBanner> createState() => _AutoFavBannerState();
}

class _AutoFavBannerState extends State<AutoFavBanner> {
  bool _dismissed = false;

  @override
  Widget build(BuildContext context) {
    if (_dismissed) return const SizedBox.shrink();

    return AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOutCubic,
          margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                const Color(0xFF7B61FF).withValues(alpha: 0.18),
                AppTheme.surface,
              ],
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
            ),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFF7B61FF).withValues(alpha: 0.35),
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF7B61FF).withValues(alpha: 0.12),
                blurRadius: 10,
              ),
            ],
          ),
          child: Row(
            children: [
              // Icon
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF7B61FF).withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.auto_awesome,
                  color: Color(0xFF7B61FF),
                  size: 16,
                ),
              ),
              const SizedBox(width: 10),

              // Text
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      'You seem to love this!',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Add "${widget.contentName}" to favourites?',
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 11,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),

              _BannerBtn(
                label: 'Add',
                isPrimary: true,
                onTap: () {
                  widget.onAddFav();
                  setState(() => _dismissed = true);
                },
              ),
              const SizedBox(width: 6),
              _BannerBtn(
                label: '✕',
                isPrimary: false,
                onTap: () {
                  widget.onDismiss();
                  setState(() => _dismissed = true);
                },
              ),
            ],
          ),
        )
        .animate()
        .fadeIn(duration: 350.ms)
        .slideY(begin: -0.15, curve: Curves.easeOutCubic);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BANNER BUTTON — TV remote + touch + cursor
// ─────────────────────────────────────────────────────────────────────────────
class _BannerBtn extends StatelessWidget {
  final String label;
  final bool isPrimary;
  final VoidCallback onTap;

  const _BannerBtn({
    required this.label,
    required this.isPrimary,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return TvFocusable(
      onActivate: onTap,
      builder: (focused, _) => AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding:
        const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isPrimary
              ? (focused
              ? const Color(0xFF7B61FF)
              : const Color(0xFF7B61FF).withValues(alpha: 0.85))
              : (focused
              ? AppTheme.surfaceVariant
              : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          border: isPrimary
              ? null
              : Border.all(
              color:
              focused ? AppTheme.textMuted : AppTheme.divider),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isPrimary ? Colors.white : AppTheme.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}