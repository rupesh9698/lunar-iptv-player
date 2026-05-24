import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/platform_utils.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../providers/live_tv_provider.dart';
import '../../providers/movies_provider.dart';
import '../../providers/series_provider.dart';
import '../../services/cache_service.dart';
import '../../services/storage_service.dart';
import '../add_playlist/add_playlist_screen.dart';

// ─────────────────────────────────────────────────────────────────────────────
enum _SettSection {
  playlists,
  account,
  playback,
  parental,
  content,
  cache,
  about,
}

extension _SettSectionLabel on _SettSection {
  String get label => switch (this) {
    _SettSection.playlists => 'Playlists',
    _SettSection.account => 'Account',
    _SettSection.playback => 'Playback',
    _SettSection.parental => 'Parental Control',
    _SettSection.content => 'Content & EPG',
    _SettSection.cache => 'Cache & Data',
    _SettSection.about => 'About',
  };

  IconData get icon => switch (this) {
    _SettSection.playlists => Icons.playlist_play,
    _SettSection.account => Icons.person_outline,
    _SettSection.playback => Icons.play_circle_outline,
    _SettSection.parental => Icons.lock_outline,
    _SettSection.content => Icons.view_timeline_outlined,
    _SettSection.cache => Icons.delete_outline,
    _SettSection.about => Icons.info_outline,
  };
}

// ─────────────────────────────────────────────────────────────────────────────
class SettingsScreen extends ConsumerStatefulWidget {
  final bool isStandalone;
  const SettingsScreen({super.key, this.isStandalone = false});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  _SettSection _section = _SettSection.playlists;

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: isWide ? _buildDesktop() : _buildMobile(),
    );
  }

  Widget _buildDesktop() {
    return Column(
      children: [
        // Top bar
        _SettingsTopBar(sectionLabel: _section.label),
        Expanded(
          child: Row(
            children: [
              // Sidebar
              _SettingsSidebar(
                selected: _section,
                onSelect: (s) => setState(() => _section = s),
              ),
              const VerticalDivider(
                color: AppTheme.divider,
                width: 1,
                thickness: 1,
              ),
              // Content
              Expanded(child: _buildSectionContent(_section)),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMobile() {
    return CustomScrollView(
      slivers: [
        // if (widget.isStandalone)
        //   IconButton(
        //     icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
        //     onPressed: () => context.go('/home'),
        //   )
        // else
        //   const SizedBox(width: 16),
        SliverAppBar(
          title: const Text('Settings'),
          floating: true,
          backgroundColor: AppTheme.sidebarBg,
        ),
        SliverList(
          delegate: SliverChildListDelegate([
            for (final s in _SettSection.values) _buildSectionContent(s),
          ]),
        ),
      ],
    );
  }

  Widget _buildSectionContent(_SettSection s) {
    return switch (s) {
      _SettSection.playlists => _PlaylistsSection(ref: ref),
      _SettSection.account => _AccountSection(),
      _SettSection.playback => _PlaybackSection(),
      _SettSection.parental => _ParentalSection(),
      _SettSection.content => _ContentSection(),
      _SettSection.cache => _CacheSection(ref: ref),
      _SettSection.about => _AboutSection(),
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TOP BAR
// ─────────────────────────────────────────────────────────────────────────────
class _SettingsTopBar extends StatelessWidget {
  final String sectionLabel;
  const _SettingsTopBar({required this.sectionLabel});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 52,
      color: AppTheme.sidebarBg,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Row(
        children: [
          IconButton(
            onPressed: () =>
                context.canPop() ? context.pop() : context.go('/home'),
            icon: const Icon(
              Icons.arrow_back_ios_new,
              color: AppTheme.textSecondary,
              size: 16,
            ),
            tooltip: 'Back',
          ),
          const Icon(
            Icons.settings_outlined,
            color: AppTheme.primary,
            size: 16,
          ),
          const SizedBox(width: 8),
          const Text(
            'Settings',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 8),
            child: Icon(
              Icons.chevron_right,
              color: AppTheme.textMuted,
              size: 16,
            ),
          ),
          Text(
            sectionLabel,
            style: const TextStyle(color: AppTheme.primary, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SIDEBAR
// ─────────────────────────────────────────────────────────────────────────────
class _SettingsSidebar extends StatelessWidget {
  final _SettSection selected;
  final ValueChanged<_SettSection> onSelect;

  const _SettingsSidebar({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 200,
      color: AppTheme.sidebarBg,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: _SettSection.values
            .map(
              (s) => _SidebarItem(
                section: s,
                isSelected: s == selected,
                onTap: () => onSelect(s),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _SidebarItem extends StatefulWidget {
  final _SettSection section;
  final bool isSelected;
  final VoidCallback onTap;

  const _SidebarItem({
    required this.section,
    required this.isSelected,
    required this.onTap,
  });

  @override
  State<_SidebarItem> createState() => _SidebarItemState();
}

class _SidebarItemState extends State<_SidebarItem> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: widget.isSelected
                ? AppTheme.selectedItem
                : _hovering
                ? AppTheme.surface
                : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: widget.isSelected
                ? Border.all(color: AppTheme.primary.withValues(alpha: 0.3))
                : null,
          ),
          child: Row(
            children: [
              Icon(
                widget.section.icon,
                size: 18,
                color: widget.isSelected
                    ? AppTheme.primary
                    : AppTheme.textSecondary,
              ),
              const SizedBox(width: 10),
              Text(
                widget.section.label,
                style: TextStyle(
                  color: widget.isSelected
                      ? AppTheme.textPrimary
                      : AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: widget.isSelected
                      ? FontWeight.w600
                      : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────
class _SectionHeader extends StatelessWidget {
  final String title;
  final String? subtitle;
  const _SectionHeader({required this.title, this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(
              subtitle!,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SettCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets margin;

  const _SettCard({
    required this.child,
    this.margin = const EdgeInsets.fromLTRB(16, 0, 16, 12),
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.divider),
      ),
      child: child,
    );
  }
}

class _SettTile extends StatelessWidget {
  final IconData icon;
  final Color? iconColor;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool showDivider;

  const _SettTile({
    required this.icon,
    this.iconColor,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          onTap: onTap,
          leading: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: (iconColor ?? AppTheme.primary).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 18, color: iconColor ?? AppTheme.primary),
          ),
          title: Text(
            title,
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle!,
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                )
              : null,
          trailing:
              trailing ??
              (onTap != null
                  ? const Icon(
                      Icons.chevron_right,
                      color: AppTheme.textMuted,
                      size: 18,
                    )
                  : null),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
        ),
        if (showDivider)
          const Divider(
            color: AppTheme.divider,
            height: 1,
            indent: 68,
            endIndent: 16,
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: PLAYLISTS
// ─────────────────────────────────────────────────────────────────────────────
class _PlaylistsSection extends ConsumerWidget {
  final WidgetRef ref;
  const _PlaylistsSection({required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final playlists = ref.watch(playlistsProvider);
    final activeId = StorageService.instance.getActivePlaylistId();

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Playlists',
            subtitle: 'Manage your Xtream Codes playlists',
          ),

          if (playlists.isEmpty)
            Padding(
              padding: const EdgeInsets.all(20),
              child: Center(
                child: Column(
                  children: [
                    const Icon(
                      Icons.playlist_play,
                      color: AppTheme.textMuted,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'No playlists added yet',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                    const SizedBox(height: 16),
                    ElevatedButton.icon(
                      onPressed: () => _goAddPlaylist(context),
                      icon: const Icon(Icons.add),
                      label: const Text('Add Playlist'),
                    ),
                  ],
                ),
              ),
            )
          else ...[
            _SettCard(
              child: Column(
                children: playlists.asMap().entries.map((e) {
                  final i = e.key;
                  final p = e.value;
                  final isActive = p.id == activeId;
                  return _PlaylistTile(
                    playlist: p,
                    isActive: isActive,
                    showDivider: i < playlists.length - 1,
                    onSetActive: () =>
                        ref.read(playlistsProvider.notifier).setActive(p.id),
                    onDelete: () => _confirmDelete(context, ref, p),
                  );
                }).toList(),
              ),
            ),

            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _goAddPlaylist(context),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add New Playlist'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.primary),
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _goAddPlaylist(BuildContext context) {
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddPlaylistScreen()),
    );
  }

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    Playlist p,
  ) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Playlist'),
        content: Text('Remove "${p.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Delete',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok == true && context.mounted) {
      ref.read(playlistsProvider.notifier).removePlaylist(p.id);
    }
  }
}

class _PlaylistTile extends StatelessWidget {
  final Playlist playlist;
  final bool isActive;
  final bool showDivider;
  final VoidCallback onSetActive;
  final VoidCallback onDelete;

  const _PlaylistTile({
    required this.playlist,
    required this.isActive,
    required this.showDivider,
    required this.onSetActive,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        ListTile(
          onTap: onSetActive,
          leading: Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: isActive
                  ? AppTheme.primary.withValues(alpha: 0.15)
                  : AppTheme.surfaceVariant,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.playlist_play,
              color: isActive ? AppTheme.primary : AppTheme.textMuted,
              size: 20,
            ),
          ),
          title: Row(
            children: [
              Expanded(
                child: Text(
                  playlist.name,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (isActive)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: AppTheme.success.withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Text(
                    'Active',
                    style: TextStyle(
                      color: AppTheme.success,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
            ],
          ),
          subtitle: Text(
            playlist.serverUrl,
            style: const TextStyle(color: AppTheme.textMuted, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: IconButton(
            onPressed: onDelete,
            icon: const Icon(
              Icons.delete_outline,
              color: AppTheme.textMuted,
              size: 18,
            ),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 4,
          ),
        ),
        if (showDivider)
          const Divider(color: AppTheme.divider, height: 1, indent: 72),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: ACCOUNT
// ─────────────────────────────────────────────────────────────────────────────
class _AccountSection extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final infoAsync = ref.watch(accountInfoProvider);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Account',
            subtitle: 'Active playlist account information',
          ),
          infoAsync.when(
            data: (info) {
              if (info == null) {
                return const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'No active playlist',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                );
              }
              return _AccountCard(info: info);
            },
            loading: () => const Center(
              child: Padding(
                padding: EdgeInsets.all(40),
                child: CircularProgressIndicator(color: AppTheme.primary),
              ),
            ),
            error: (e, _) => Padding(
              padding: const EdgeInsets.all(20),
              child: Text(
                'Error: $e',
                style: const TextStyle(color: AppTheme.error),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

class _AccountCard extends StatelessWidget {
  final AccountInfo info;
  const _AccountCard({required this.info});

  @override
  Widget build(BuildContext context) {
    final u = info.userInfo;
    final exp = u.expirationDate;

    return _SettCard(
      child: Column(
        children: [
          _InfoRow(
            'Username',
            u.username,
            Icons.person_outline,
            showDivider: true,
          ),
          _InfoRow(
            'Status',
            u.status,
            u.status == 'Active'
                ? Icons.check_circle_outline
                : Icons.cancel_outlined,
            valueColor: u.status == 'Active'
                ? AppTheme.success
                : AppTheme.error,
            showDivider: true,
          ),
          _InfoRow(
            'Expiry',
            exp != null ? '${exp.day}/${exp.month}/${exp.year}' : 'Lifetime',
            Icons.calendar_today_outlined,
            showDivider: true,
          ),
          _InfoRow(
            'Connections',
            '${u.activeConnections} / ${u.maxConnections}',
            Icons.devices_outlined,
            showDivider: true,
          ),
          _InfoRow(
            'Trial',
            u.isTrial ? 'Yes' : 'No',
            Icons.info_outline,
            showDivider: true,
          ),
          _InfoRow(
            'Formats',
            u.allowedOutputFormats.join(' · '),
            Icons.videocam_outlined,
          ),
        ],
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  final IconData icon;
  final Color? valueColor;
  final bool showDivider;

  const _InfoRow(
    this.label,
    this.value,
    this.icon, {
    this.valueColor,
    this.showDivider = false,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(icon, size: 16, color: AppTheme.textMuted),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                ),
              ),
              const Spacer(),
              Text(
                value,
                style: TextStyle(
                  color: valueColor ?? AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        if (showDivider)
          const Divider(color: AppTheme.divider, height: 1, indent: 44),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: PLAYBACK
// ─────────────────────────────────────────────────────────────────────────────
class _PlaybackSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_PlaybackSection> createState() => _PlaybackSectionState();
}

class _PlaybackSectionState extends ConsumerState<_PlaybackSection> {
  late bool _remember;

  @override
  void initState() {
    super.initState();
    _remember =
        StorageService.instance.getSetting(
              AppConstants.rememberPositionKey,
              true,
            )
            as bool;
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Playback',
            subtitle: 'Player preferences',
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: const Text(
              'PLAYER OPTIONS',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          _SettCard(
            child: _SettTile(
              icon: Icons.history,
              title: 'Remember Watch Position',
              subtitle:
                  'Auto-select last watched category and channel on Live TV',
              trailing: Switch(
                value: _remember,
                onChanged: (v) async {
                  setState(() => _remember = v);
                  await StorageService.instance.setSetting(
                    AppConstants.rememberPositionKey,
                    v,
                  );
                  if (!v) {
                    // Clear saved position when user disables
                    ref.read(lastWatchedLiveProvider.notifier).clear();
                  }
                },
                activeTrackColor: AppTheme.primary,
                activeThumbColor: Colors.white,
                inactiveTrackColor: AppTheme.surfaceVariant,
                inactiveThumbColor: AppTheme.textMuted,
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: PARENTAL CONTROL
// ─────────────────────────────────────────────────────────────────────────────
class _ParentalSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ParentalSection> createState() => _ParentalSectionState();
}

class _ParentalSectionState extends ConsumerState<_ParentalSection> {
  late bool _enabled;
  final _storage = StorageService.instance;

  @override
  void initState() {
    super.initState();
    _enabled = _storage.isParentalEnabled();
  }

  bool get _hasPin {
    final p = _storage.getParentalPin();
    return p != null && p.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final lockedCats = ref.watch(parentalLockedLiveCategoriesProvider);
    final catsAsync = ref.watch(liveCategoriesProvider);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Parental Control',
            subtitle: 'Restrict Live TV categories with a PIN',
          ),

          // ── Enable + Set PIN ──────────────────────────────────────────
          _SettCard(
            child: Column(
              children: [
                _SettTile(
                  icon: Icons.family_restroom,
                  title: 'Enable Parental Control',
                  subtitle: _hasPin
                      ? 'Locked categories require PIN'
                      : 'Set a PIN first to enable',
                  showDivider: true,
                  trailing: Switch(
                    value: _enabled && _hasPin,
                    onChanged: (v) async {
                      if (v && !_hasPin) {
                        await _showSetPin(context);
                      } else if (!v) {
                        final ok = await _verifyPin(
                          context,
                          failMessage:
                              'Incorrect PIN. Re-add your playlist to disable.',
                        );
                        if (!mounted || !ok) return;
                        await _storage.setParentalEnabled(false);
                        ref
                                .read(parentalSessionUnlockedProvider.notifier)
                                .state =
                            const {};
                        setState(() => _enabled = false);
                      } else {
                        await _storage.setParentalEnabled(true);
                        setState(() => _enabled = true);
                      }
                    },
                    activeTrackColor: AppTheme.primary,
                    activeThumbColor: Colors.white,
                    inactiveTrackColor: AppTheme.surfaceVariant,
                    inactiveThumbColor: AppTheme.textMuted,
                  ),
                ),
                _SettTile(
                  icon: Icons.pin_outlined,
                  title: _hasPin ? 'Change PIN' : 'Set PIN',
                  subtitle: _hasPin
                      ? 'Update your 4-digit PIN'
                      : 'Create a 4-digit PIN',
                  onTap: () async {
                    final ok = await _verifyPin(
                      context,
                      failMessage:
                          'Incorrect PIN. Re-add your playlist to remove the PIN.',
                    );
                    if (!mounted || !ok) return;
                    if (!context.mounted) return;
                    await _confirmRemovePin(context);
                  },
                ),
              ],
            ),
          ),

          // ── Remove PIN ────────────────────────────────────────────────
          if (_hasPin && _enabled)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: _SettCard(
                margin: EdgeInsets.zero,
                child: _SettTile(
                  icon: Icons.lock_reset,
                  iconColor: AppTheme.error,
                  title: 'Remove PIN',
                  subtitle: 'Disables parental control',
                  onTap: () async {
                    final ok = await _verifyPin(
                      context,
                      failMessage:
                          'Incorrect PIN. Re-add your playlist to remove the PIN.',
                    );
                    if (!ok) return;
                    if (!context.mounted) return;
                    await _confirmRemovePin(context);
                  },
                ),
              ),
            ),

          // ── Protected categories ──────────────────────────────────────
          if (_enabled && _hasPin) ...[
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
              child: Text(
                'PROTECTED LIVE CATEGORIES',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'Locked categories will prompt for PIN in Live TV.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ),
            _SettCard(
              child: catsAsync.when(
                data: (cats) {
                  if (cats.isEmpty) {
                    return const _SettTile(
                      icon: Icons.info_outline,
                      title: 'No categories found',
                      subtitle: 'Sync Live TV data first',
                    );
                  }
                  return Column(
                    children: cats.asMap().entries.map((e) {
                      final i = e.key;
                      final cat = e.value;
                      final locked = lockedCats.contains(cat.categoryId);
                      return _SettTile(
                        icon: locked
                            ? Icons.lock_rounded
                            : Icons.lock_open_outlined,
                        iconColor: locked ? AppTheme.error : AppTheme.textMuted,
                        title: cat.categoryName,
                        subtitle: locked
                            ? 'PIN required to access'
                            : 'Tap toggle to protect',
                        showDivider: i < cats.length - 1,
                        trailing: Switch(
                          value: locked,
                          onChanged: (v) async {
                            // Both locking and unlocking require PIN — prevents child from toggling
                            final ok = await _verifyPin(context);
                            if (!ok || !context.mounted) return;
                            ref
                                .read(
                                  parentalLockedLiveCategoriesProvider.notifier,
                                )
                                .toggle(cat.categoryId);
                          },
                          activeTrackColor: AppTheme.error,
                          activeThumbColor: Colors.white,
                          inactiveTrackColor: AppTheme.surfaceVariant,
                          inactiveThumbColor: AppTheme.textMuted,
                        ),
                      );
                    }).toList(),
                  );
                },
                loading: () => const Padding(
                  padding: EdgeInsets.all(20),
                  child: Center(
                    child: CircularProgressIndicator(
                      color: AppTheme.primary,
                      strokeWidth: 2,
                    ),
                  ),
                ),
                error: (_, _) => const _SettTile(
                  icon: Icons.error_outline,
                  iconColor: AppTheme.error,
                  title: 'Could not load categories',
                  subtitle: 'Check your connection',
                ),
              ),
            ),
          ],

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  Future<bool> _verifyPin(
    BuildContext context, {
    String failMessage = 'Incorrect PIN',
  }) async {
    final pin = _storage.getParentalPin();
    if (pin == null || pin.isEmpty) return true;
    final ctrl = TextEditingController();
    bool? result;
    try {
      result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          title: const Row(
            children: [
              Icon(Icons.lock_rounded, color: AppTheme.error, size: 20),
              SizedBox(width: 8),
              Text('Confirm PIN'),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter your PIN to continue',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: ctrl,
                keyboardType: TextInputType.number,
                maxLength: 4,
                obscureText: true,
                autofocus: true,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  letterSpacing: 8,
                  fontWeight: FontWeight.w700,
                ),
                decoration: const InputDecoration(
                  counterText: '',
                  hintText: '••••',
                ),
                onSubmitted: (_) => Navigator.pop(ctx, ctrl.text == pin),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(ctx, ctrl.text == pin),
              child: const Text('Confirm'),
            ),
          ],
        ),
      );
    } finally {
      ctrl.dispose();
    }
    if ((result == null || !result) && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(failMessage),
          backgroundColor: AppTheme.error,
          duration: const Duration(seconds: 4),
        ),
      );
    }
    return result ?? false;
  }

  Future<void> _showSetPin(BuildContext context) async {
    final pin = await showDialog<String>(
      context: context,
      builder: (ctx) => _PinDialog(title: 'Set PIN'),
    );
    if (pin != null && pin.length == 4 && context.mounted) {
      await _storage.setParentalPin(pin);
      await _storage.setParentalEnabled(true);
      setState(() => _enabled = true);
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('PIN set successfully')));
      }
    }
  }

  Future<void> _confirmRemovePin(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove PIN?'),
        content: const Text('This will disable parental control.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text(
              'Remove',
              style: TextStyle(color: AppTheme.error),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _storage.setParentalPin('');
      await _storage.setParentalEnabled(false);
      ref.read(parentalSessionUnlockedProvider.notifier).state = const {};
      setState(() => _enabled = false);
    }
  }
}

class _PinDialog extends StatefulWidget {
  final String title;
  const _PinDialog({required this.title});

  @override
  State<_PinDialog> createState() => _PinDialogState();
}

class _PinDialogState extends State<_PinDialog> {
  final _ctrl = TextEditingController();

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Enter a 4-digit PIN',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _ctrl,
            keyboardType: TextInputType.number,
            maxLength: 4,
            obscureText: true,
            autofocus: true,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 24,
              letterSpacing: 8,
              fontWeight: FontWeight.w700,
            ),
            decoration: const InputDecoration(
              counterText: '',
              hintText: '••••',
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            if (_ctrl.text.length == 4) {
              Navigator.pop(context, _ctrl.text);
            }
          },
          child: const Text('Set PIN'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: CONTENT & EPG
// ─────────────────────────────────────────────────────────────────────────────
class _ContentSection extends ConsumerStatefulWidget {
  @override
  ConsumerState<_ContentSection> createState() => _ContentSectionState();
}

class _ContentSectionState extends ConsumerState<_ContentSection> {
  @override
  Widget build(BuildContext context) {
    final showNums = ref.watch(showChannelNumberProvider);
    final hiddenCats = ref.watch(hiddenLiveCategoriesProvider);
    final catsAsync = ref.watch(liveCategoriesProvider);

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Content & EPG',
            subtitle: 'Channel display and program guide',
          ),

          // ── Show channel numbers ──────────────────────────────────────
          _SettCard(
            child: _SettTile(
              icon: Icons.format_list_numbered,
              title: 'Show Channel Numbers',
              subtitle: 'Display channel number badge in Live TV',
              trailing: Switch(
                value: showNums,
                onChanged: (v) =>
                    ref.read(showChannelNumberProvider.notifier).set(v),
                activeTrackColor: AppTheme.primary,
                activeThumbColor: Colors.white,
                inactiveTrackColor: AppTheme.surfaceVariant,
                inactiveThumbColor: AppTheme.textMuted,
              ),
            ),
          ),

          // ── Hidden categories ─────────────────────────────────────────
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: Text(
              'HIDDEN LIVE CATEGORIES',
              style: TextStyle(
                color: AppTheme.textMuted,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),

          if (hiddenCats.isEmpty)
            _SettCard(
              child: const _SettTile(
                icon: Icons.check_circle_outline,
                iconColor: AppTheme.success,
                title: 'No hidden categories',
                subtitle: 'Long-press any category in Live TV to hide it',
              ),
            )
          else
            catsAsync.when(
              data: (cats) {
                final hidden = cats
                    .where((c) => hiddenCats.contains(c.categoryId))
                    .toList();
                if (hidden.isEmpty) return const SizedBox.shrink();
                return _SettCard(
                  child: Column(
                    children: hidden.asMap().entries.map((e) {
                      final i = e.key;
                      final cat = e.value;
                      return _SettTile(
                        icon: Icons.folder_off_outlined,
                        iconColor: AppTheme.textMuted,
                        title: cat.categoryName,
                        subtitle: 'Hidden — tap Restore to show again',
                        showDivider: i < hidden.length - 1,
                        trailing: MouseRegion(
                          cursor: SystemMouseCursors.click,
                          child: GestureDetector(
                            onTap: () => ref
                                .read(hiddenLiveCategoriesProvider.notifier)
                                .toggle(cat.categoryId),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: AppTheme.primary.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                'Restore',
                                style: TextStyle(
                                  color: AppTheme.primary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                        onTap: () => ref
                            .read(hiddenLiveCategoriesProvider.notifier)
                            .toggle(cat.categoryId),
                      );
                    }).toList(),
                  ),
                );
              },
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(20),
                  child: CircularProgressIndicator(
                    color: AppTheme.primary,
                    strokeWidth: 2,
                  ),
                ),
              ),
              error: (_, _) => const SizedBox.shrink(),
            ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: CACHE & DATA
// ─────────────────────────────────────────────────────────────────────────────
class _CacheSection extends ConsumerWidget {
  final WidgetRef ref;
  const _CacheSection({required this.ref});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final vodRecentCount = ref.watch(recentlyViewedVodProvider).length;
    final seriesRecentCount = ref.watch(recentlyViewedSeriesProvider).length;
    final liveRecentCount = ref.watch(recentlyViewedLiveProvider).length;
    final totalHistoryCount = vodRecentCount + seriesRecentCount;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(
            title: 'Cache & Data',
            subtitle: 'Clear cached content and history',
          ),
          _SettCard(
            child: Column(
              children: [
                _SettTile(
                  icon: Icons.sync,
                  iconColor: AppTheme.primary,
                  title: 'Refresh All Data',
                  subtitle: _buildLastUpdatedText(context),
                  trailing: const Icon(
                    Icons.chevron_right,
                    color: AppTheme.textMuted,
                    size: 18,
                  ),
                  onTap: () async {
                    // Navigate to sync screen for manual refresh
                    if (!context.mounted) return;
                    context.push('/sync', extra: 'manual');
                  },
                ),
                const Divider(color: AppTheme.divider, height: 1),
                _SettTile(
                  icon: Icons.cloud_sync_outlined,
                  title: 'Clear EPG Cache',
                  subtitle: 'Re-fetch all program guide data',
                  showDivider: true,
                  trailing: const Icon(
                    Icons.delete_sweep_outlined,
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                  onTap: () {
                    ref.read(epgCacheProvider.notifier).clear();
                    _snack(context, 'EPG cache cleared');
                  },
                ),
                _SettTile(
                  icon: Icons.history_toggle_off,
                  title: 'Clear Recently Viewed (Live)',
                  subtitle: '$liveRecentCount channels in history',
                  showDivider: true,
                  trailing: const Icon(
                    Icons.delete_sweep_outlined,
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                  onTap: () {
                    ref.read(recentlyViewedLiveProvider.notifier).clear();
                    _snack(context, 'Recently viewed cleared');
                  },
                ),
                _SettTile(
                  icon: Icons.manage_history,
                  title: 'Clear Watch History',
                  subtitle: '$totalHistoryCount items (movies & series)',
                  trailing: const Icon(
                    Icons.delete_sweep_outlined,
                    color: AppTheme.textMuted,
                    size: 20,
                  ),
                  onTap: () async {
                    await StorageService.instance.clearHistory();
                    ref.read(recentlyViewedVodProvider.notifier).clear();
                    ref.read(recentlyViewedSeriesProvider.notifier).clear();
                    if (!context.mounted) return;
                    _snack(context, 'Watch history cleared');
                  },
                ),
              ],
            ),
          ),

          // Danger zone
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 20, 16, 4),
            child: const Text(
              'DANGER ZONE',
              style: TextStyle(
                color: AppTheme.error,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          _SettCard(
            child: _SettTile(
              icon: Icons.delete_forever,
              iconColor: AppTheme.error,
              title: 'Reset All Settings',
              subtitle: 'Clears all data including playlists',
              onTap: () => _confirmReset(context, ref),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), behavior: SnackBarBehavior.floating),
    );
  }

  Future<void> _confirmReset(BuildContext ctx, WidgetRef ref) async {
    final ok = await showDialog<bool>(
      context: ctx,
      builder: (d) => AlertDialog(
        title: const Text('Reset All Settings?'),
        content: const Text(
          'This will delete all playlists and settings. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(d, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: AppTheme.error),
            onPressed: () => Navigator.pop(d, true),
            child: const Text('Reset Everything'),
          ),
        ],
      ),
    );
    if (ok == true) {
      // Clear all playlists
      for (final p in ref.read(playlistsProvider)) {
        await ref.read(playlistsProvider.notifier).removePlaylist(p.id);
      }
      ref.read(epgCacheProvider.notifier).clear();
      ref.read(recentlyViewedLiveProvider.notifier).clear();
      await StorageService.instance.clearHistory();
      if (!ctx.mounted) return;
    }
  }

  String _buildLastUpdatedText(BuildContext context) {
    final live = CacheService.instance.lastUpdatedLive();
    if (live == null) return 'Never synced';
    final diff = DateTime.now().difference(live);
    if (diff.inHours < 1) return 'Updated ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Updated ${diff.inHours}h ago';
    return 'Updated ${diff.inDays}d ago';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION: ABOUT
// ─────────────────────────────────────────────────────────────────────────────
class _AboutSection extends StatefulWidget {
  @override
  State<_AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<_AboutSection> {
  PackageInfo? _pkgInfo;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) => setState(() => _pkgInfo = info));
  }

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader(title: 'About', subtitle: 'Lunar IPTV Player'),

          // Logo card
          _SettCard(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Row(
                children: [
                  SizedBox(
                    width: 56,
                    height: 56,
                    child: Image.asset(
                      "assets/images/logo.png",
                      fit: BoxFit.contain,
                    ),
                  ),
                  const SizedBox(width: 16),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Lunar IPTV Player',
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const Text(
                        'Premium IPTV Player',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      if (_pkgInfo != null)
                        Text(
                          'v${_pkgInfo!.version} (${_pkgInfo!.buildNumber})',
                          style: const TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),

          // Info rows
          _SettCard(
            child: Column(
              children: [
                _InfoRow(
                  'Version',
                  _pkgInfo?.version ?? '1.0.0',
                  Icons.new_releases_outlined,
                  showDivider: true,
                ),
                _InfoRow(
                  'Build',
                  _pkgInfo?.buildNumber ?? '1',
                  Icons.build_outlined,
                  showDivider: true,
                ),
                _InfoRow(
                  'Package',
                  _pkgInfo?.packageName ?? 'com.iptv.lunar.app',
                  Icons.apps_outlined,
                  showDivider: true,
                ),
                _InfoRow('Platform', _getPlatform(), Icons.devices_outlined),
              ],
            ),
          ),

          // Disclaimer
          Padding(
            padding: const EdgeInsets.all(16),
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppTheme.surfaceVariant,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.divider),
              ),
              child: const Text(
                'Lunar IPTV Player is a standalone media player. We do not '
                'provide or sell any content, playlists, or subscriptions. '
                'All content is provided by third-party IPTV services.',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ),

          const SizedBox(height: 24),
        ],
      ),
    );
  }

  String _getPlatform() {
    if (PlatformUtils.isAndroid) return 'Android';
    if (PlatformUtils.isIOS) return 'iOS';
    if (PlatformUtils.isMacOS) return 'macOS';
    if (PlatformUtils.isWindows) return 'Windows';
    if (PlatformUtils.isLinux) return 'Linux';
    if (PlatformUtils.isWeb) return 'Web';
    return 'Unknown';
  }
}
