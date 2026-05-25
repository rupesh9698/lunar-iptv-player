import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:shimmer/shimmer.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../core/theme/app_theme.dart';
import '../models/xtream_models.dart';

// ============================================================
// POSTER CARD (for Movies, Series, and Live)
// ============================================================
class PosterCard extends StatefulWidget {
  final String title;
  final String? imageUrl;
  final String? subtitle;
  final double? rating;
  final bool isFavorite;
  final VoidCallback? onTap;
  final VoidCallback? onFavorite;
  final Widget? badge;
  final bool showNumber;
  final String? number;

  const PosterCard({
    super.key,
    required this.title,
    this.imageUrl,
    this.subtitle,
    this.rating,
    this.isFavorite = false,
    this.onTap,
    this.onFavorite,
    this.badge,
    this.showNumber = false,
    this.number,
  });

  @override
  State<PosterCard> createState() => _PosterCardState();
}

class _PosterCardState extends State<PosterCard> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            boxShadow: _hovered ? AppTheme.primaryShadow : AppTheme.cardShadow,
          ),
          child: AnimatedScale(
            scale: _hovered ? 1.04 : 1.0,
            duration: const Duration(milliseconds: 200),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // Poster image
                  _buildImage(),

                  // Gradient overlay
                  const DecoratedBox(
                    decoration: BoxDecoration(gradient: AppTheme.darkOverlay),
                  ),

                  // Rating badge
                  if (widget.rating != null && widget.rating! > 0)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: _RatingBadge(rating: widget.rating!),
                    ),

                  // Channel number
                  if (widget.showNumber && widget.number != null)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.7),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Text(
                          widget.number!,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),

                  // Custom badge
                  if (widget.badge != null)
                    Positioned(top: 8, left: 8, child: widget.badge!),

                  // Favorite button
                  if (widget.onFavorite != null)
                    Positioned(
                      bottom: 8,
                      right: 8,
                      child: GestureDetector(
                        onTap: widget.onFavorite,
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.7),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.isFavorite
                                ? Icons.favorite
                                : Icons.favorite_border,
                            color: widget.isFavorite
                                ? Colors.red
                                : AppTheme.textSecondary,
                            size: 16,
                          ),
                        ),
                      ),
                    ),

                  // Title at bottom
                  Positioned(
                    bottom: 0,
                    left: 0,
                    right: 0,
                    child: Padding(
                      padding: const EdgeInsets.all(10),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            widget.title,
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                          if (widget.subtitle != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              widget.subtitle!,
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    ).animate().fadeIn(duration: 300.ms).slideY(begin: 0.05, end: 0);
  }

  Widget _buildImage() {
    if (widget.imageUrl == null || widget.imageUrl!.isEmpty) {
      return Container(
        color: AppTheme.surfaceVariant,
        child: const Center(
          child: Icon(Icons.movie, color: AppTheme.textMuted, size: 40),
        ),
      );
    }
    return CachedNetworkImage(
      imageUrl: widget.imageUrl!,
      fit: BoxFit.cover,
      placeholder: (context, url) => _shimmerPlaceholder(),
      errorWidget: (context, url, error) => Container(
        color: AppTheme.surfaceVariant,
        child: const Center(
          child: Icon(Icons.broken_image, color: AppTheme.textMuted, size: 40),
        ),
      ),
    );
  }

  Widget _shimmerPlaceholder() => Shimmer.fromColors(
    baseColor: AppTheme.surfaceVariant,
    highlightColor: AppTheme.card,
    child: Container(color: AppTheme.surfaceVariant),
  );
}

class _RatingBadge extends StatelessWidget {
  final double rating;
  const _RatingBadge({required this.rating});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.amber.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star, color: Colors.white, size: 10),
          const SizedBox(width: 2),
          Text(
            rating.toStringAsFixed(1),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// CHANNEL LIST TILE (for Live TV list view)
// ============================================================
class ChannelListTile extends StatelessWidget {
  final LiveStream channel;
  final bool isSelected;
  final String? currentShow;
  final double? progress;
  final VoidCallback? onTap;
  final VoidCallback? onFavorite;

  const ChannelListTile({
    super.key,
    required this.channel,
    this.isSelected = false,
    this.currentShow,
    this.progress,
    this.onTap,
    this.onFavorite,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: isSelected ? AppTheme.selectedItem : AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isSelected
                ? AppTheme.primary.withValues(alpha: 0.5)
                : AppTheme.divider,
            width: 1,
          ),
        ),
        child: Row(
          children: [
            // Channel logo
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: SizedBox(
                width: 54,
                height: 40,
                child:
                    channel.streamIcon != null && channel.streamIcon!.isNotEmpty
                    ? CachedNetworkImage(
                        imageUrl: channel.streamIcon!,
                        fit: BoxFit.contain,
                        placeholder: (_, _) => _logoPlaceholder(),
                        errorWidget: (_, _, _) => _logoPlaceholder(),
                      )
                    : _logoPlaceholder(),
              ),
            ),
            const SizedBox(width: 12),

            // Channel info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    channel.name,
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (currentShow != null) ...[
                    const SizedBox(height: 4),
                    Text(
                      currentShow!,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (progress != null) ...[
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: progress,
                          backgroundColor: AppTheme.divider,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppTheme.primary,
                          ),
                          minHeight: 3,
                        ),
                      ),
                    ],
                  ],
                ],
              ),
            ),

            // Favorite button
            if (onFavorite != null)
              IconButton(
                onPressed: onFavorite,
                icon: Icon(
                  channel.isFavorite ? Icons.favorite : Icons.favorite_border,
                  color: channel.isFavorite ? Colors.red : AppTheme.textMuted,
                  size: 20,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
          ],
        ),
      ),
    );
  }

  Widget _logoPlaceholder() => Container(
    color: AppTheme.surfaceVariant,
    child: const Center(
      child: Icon(Icons.tv, color: AppTheme.textMuted, size: 20),
    ),
  );
}

// ============================================================
// SHIMMER GRID (loading state)
// ============================================================
class ShimmerGrid extends StatelessWidget {
  final int count;
  final double aspectRatio;

  const ShimmerGrid({super.key, this.count = 12, this.aspectRatio = 2 / 3});

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: _crossAxisCount(context),
        childAspectRatio: aspectRatio,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: count,
      itemBuilder: (_, _) => Shimmer.fromColors(
        baseColor: AppTheme.surfaceVariant,
        highlightColor: AppTheme.card,
        child: Container(
          decoration: BoxDecoration(
            color: AppTheme.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  int _crossAxisCount(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    if (w > 1200) return 6;
    if (w > 900) return 5;
    if (w > 600) return 4;
    if (w > 400) return 3;
    return 2;
  }
}

// ============================================================
// CATEGORY SIDEBAR
// ============================================================
class CategorySidebar extends StatelessWidget {
  final List<XtreamCategory> categories;
  final XtreamCategory? selected;
  final ValueChanged<XtreamCategory?> onSelect;
  final String allLabel;

  const CategorySidebar({
    super.key,
    required this.categories,
    required this.selected,
    required this.onSelect,
    this.allLabel = 'All',
  });

  @override
  Widget build(BuildContext context) {
    final visible = categories.where((c) => !c.isHidden).toList();

    return Container(
      width: 200,
      color: AppTheme.sidebarBg,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: [
          _SidebarItem(
            label: allLabel,
            icon: Icons.apps_rounded,
            isSelected: selected == null,
            onTap: () => onSelect(null),
          ),
          _SidebarItem(
            label: 'Favorites',
            icon: Icons.favorite,
            isSelected: false,
            onTap: () {},
          ),
          _SidebarItem(
            label: 'Recently Watched',
            icon: Icons.history,
            isSelected: false,
            onTap: () {},
          ),
          _SidebarItem(
            label: 'Recently Added',
            icon: Icons.fiber_new_rounded,
            isSelected: false,
            onTap: () {},
          ),
          if (visible.isNotEmpty) ...[
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Divider(color: AppTheme.divider, height: 1),
            ),
            ...visible.map(
              (cat) => _SidebarItem(
                label: cat.categoryName,
                icon: Icons.folder_outlined,
                isSelected: selected?.categoryId == cat.categoryId,
                onTap: () => onSelect(cat),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.label,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.selectedItem
                : _hovered
                ? AppTheme.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: widget.isSelected
                ? Border(left: BorderSide(color: AppTheme.primary, width: 3))
                : null,
          ),
          child: Row(
            children: [
              Icon(
                widget.icon,
                size: 18,
                color: widget.isSelected
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  widget.label,
                  style: TextStyle(
                    color: widget.isSelected
                        ? AppTheme.textPrimary
                        : AppTheme.textSecondary,
                    fontSize: 13,
                    fontWeight: widget.isSelected
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
    );
  }
}

// ============================================================
// ERROR VIEW
// ============================================================
class ErrorView extends StatelessWidget {
  final String message;
  final VoidCallback? onRetry;

  const ErrorView({super.key, required this.message, this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.error.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: const Icon(
              Icons.error_outline,
              color: AppTheme.error,
              size: 48,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            'Something went wrong',
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 8),
          Text(
            message,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (onRetry != null) ...[
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ],
      ),
    );
  }
}

// ============================================================
// EMPTY STATE VIEW
// ============================================================
class EmptyView extends StatelessWidget {
  final String title;
  final String subtitle;
  final IconData icon;
  final Widget? action;

  const EmptyView({
    super.key,
    required this.title,
    required this.subtitle,
    this.icon = Icons.inbox_outlined,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: AppTheme.surfaceVariant,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: AppTheme.textMuted, size: 48),
          ),
          const SizedBox(height: 16),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            subtitle,
            style: Theme.of(context).textTheme.bodyMedium,
            textAlign: TextAlign.center,
          ),
          if (action != null) ...[const SizedBox(height: 24), action!],
        ],
      ),
    );
  }
}

// ============================================================
// GRADIENT BUTTON
// ============================================================
class GradientButton extends StatefulWidget {
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool isLoading;
  final FocusNode? focusNode;

  const GradientButton({
    super.key,
    required this.label,
    this.onPressed,
    this.icon,
    this.isLoading = false,
    this.focusNode,
  });

  @override
  State<GradientButton> createState() => _GradientButtonState();
}

class _GradientButtonState extends State<GradientButton> {
  bool _focused = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            (event.logicalKey == LogicalKeyboardKey.select ||
                event.logicalKey == LogicalKeyboardKey.enter ||
                event.logicalKey == LogicalKeyboardKey.space ||
                event.logicalKey == LogicalKeyboardKey.gameButtonA)) {
          if (widget.onPressed != null && !widget.isLoading) {
            setState(() => _pressed = true);
            widget.onPressed!();
          }
          return KeyEventResult.handled;
        }
        if (event is KeyUpEvent) {
          setState(() => _pressed = false);
          return KeyEventResult.ignored;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        cursor: widget.onPressed != null
            ? SystemMouseCursors.click
            : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: widget.isLoading ? null : widget.onPressed,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedScale(
            scale: _pressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 54,
              decoration: BoxDecoration(
                gradient: widget.onPressed == null
                    ? null
                    : AppTheme.primaryGradient,
                color: widget.onPressed == null
                    ? AppTheme.surfaceVariant
                    : null,
                borderRadius: BorderRadius.circular(14),
                boxShadow: widget.onPressed == null
                    ? []
                    : AppTheme.primaryShadow,
                border: _focused
                    ? Border.all(
                        color: Colors.white.withValues(alpha: 0.6),
                        width: 2,
                      )
                    : null,
              ),
              child: Center(
                child: widget.isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          color: Colors.white,
                          strokeWidth: 2,
                        ),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (widget.icon != null) ...[
                            Icon(widget.icon, color: Colors.white, size: 20),
                            const SizedBox(width: 8),
                          ],
                          Text(
                            widget.label,

                            style: const TextStyle(
                              color: Colors.white,

                              fontSize: 16,

                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ============================================================
// SEARCH BAR WIDGET
// ============================================================
class SearchBarWidget extends StatelessWidget {
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onClear;

  const SearchBarWidget({
    super.key,
    required this.controller,
    this.hint = 'Search...',
    this.onChanged,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          hintText: hint,
          hintStyle: const TextStyle(color: AppTheme.textMuted, fontSize: 15),
          prefixIcon: const Icon(
            Icons.search,
            color: AppTheme.textMuted,
            size: 20,
          ),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(
                    Icons.clear,
                    color: AppTheme.textMuted,
                    size: 18,
                  ),
                  onPressed: () {
                    controller.clear();
                    onClear?.call();
                  },
                )
              : null,
          border: InputBorder.none,
          focusedBorder: InputBorder.none,
          enabledBorder: InputBorder.none,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 12,
          ),
          isDense: true,
        ),
      ),
    );
  }
}
