import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../services/m3u_service.dart';
import '../../services/xtream_service.dart';
import '../../widgets/app_widgets.dart';

class AddPlaylistScreen extends ConsumerStatefulWidget {
  const AddPlaylistScreen({super.key});

  @override
  ConsumerState<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends ConsumerState<AddPlaylistScreen> {
  // ── Controllers ───────────────────────────────────────────────────────────
  final _nameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _m3uUrlCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _scrollCtrl = ScrollController();

  // ── UI state ──────────────────────────────────────────────────────────────
  bool _showPassword = false;
  bool _isAdding = false; // covers both test + add loading
  String? _testError; // shown when connection/add fails

  // ── Mode ──────────────────────────────────────────────────────────────────
  PlaylistType _mode = PlaylistType.xtream;

  // ── Focus nodes ───────────────────────────────────────────────────────────
  // Mode toggle row — left/right D-pad to switch
  final _xtreamModeFocus = FocusNode(debugLabel: 'xtreamMode');
  final _m3uModeFocus = FocusNode(debugLabel: 'm3uMode');

  // Form fields
  final _nameFocus = FocusNode(debugLabel: 'name');
  final _serverFocus = FocusNode(debugLabel: 'server');
  final _usernameFocus = FocusNode(debugLabel: 'username');
  final _passwordFocus = FocusNode(debugLabel: 'password');
  final _passwordVisibilityFocus = FocusNode(debugLabel: 'passVis');
  final _m3uUrlFocus = FocusNode(debugLabel: 'm3uUrl');

  // Action button (single — "Add Playlist")
  final _addBtnFocus = FocusNode(debugLabel: 'addBtn');

  // ──────────────────────────────────────────────────────────────────────────
  @override
  void initState() {
    super.initState();

    // ── Mode toggle: left/right D-pad, select to activate ─────────────────
    _xtreamModeFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
        _m3uModeFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _nameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      // Let select / enter / space fall through to _ModeBtn's own handler
      return KeyEventResult.ignored;
    };

    _m3uModeFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
        _xtreamModeFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _nameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── Name field ─────────────────────────────────────────────────────────
    _nameFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        // Go back to whichever mode button is active
        (_mode == PlaylistType.xtream ? _xtreamModeFocus : _m3uModeFocus)
            .requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        // Go to first field of whichever mode is active
        (_mode == PlaylistType.m3u ? _m3uUrlFocus : _serverFocus)
            .requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── Xtream fields ──────────────────────────────────────────────────────
    _serverFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _usernameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _nameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _usernameFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _passwordFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _serverFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _passwordFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _addBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _usernameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── M3U URL field ──────────────────────────────────────────────────────
    _m3uUrlFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _addBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _nameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── Add Playlist button ────────────────────────────────────────────────
    _addBtnFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        (_mode == PlaylistType.m3u ? _m3uUrlFocus : _passwordFocus)
            .requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── Auto-scroll when Add button receives focus ─────────────────────────
    _addBtnFocus.addListener(_scrollToAddBtn);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _xtreamModeFocus.requestFocus();
    });
  }

  void _scrollToAddBtn() {
    if (!_addBtnFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_addBtnFocus.context != null) {
        Scrollable.ensureVisible(
          _addBtnFocus.context!,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.9,
        );
      }
    });
  }

  @override
  void dispose() {
    _addBtnFocus.removeListener(_scrollToAddBtn);

    _xtreamModeFocus.dispose();
    _m3uModeFocus.dispose();
    _nameFocus.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _passwordVisibilityFocus.dispose();
    _m3uUrlFocus.dispose();
    _addBtnFocus.dispose();
    _scrollCtrl.dispose();

    _nameCtrl.dispose();
    _serverCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    _m3uUrlCtrl.dispose();

    super.dispose();
  }

  // ── MERGED: Test → Add (single action) ───────────────────────────────────
  Future<void> _addPlaylist() async {
    if (_isAdding) return;
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isAdding = true;
      _testError = null;
    });

    try {
      // ── Step 1: Verify connectivity ──────────────────────────────────────
      if (_mode == PlaylistType.m3u) {
        final url = _m3uUrlCtrl.text.trim();
        final (_, _) = await M3uService.fetchAndParse(url);
      } else {
        final service = XtreamService(
          playlist: Playlist(
            id: 'test',
            name: 'test',
            serverUrl: _serverCtrl.text.trim(),
            username: _usernameCtrl.text.trim(),
            password: _passwordCtrl.text.trim(),
            addedAt: DateTime.now(),
          ),
        );
        await service.getAccountInfo(); // throws on failure
        service.dispose();
      }

      if (!mounted) return;

      // ── Step 2: Duplicate check ──────────────────────────────────────────
      final name = _nameCtrl.text.trim();
      final existing = ref.read(playlistsProvider);

      if (existing.any((p) => p.name.toLowerCase() == name.toLowerCase())) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('A playlist with this name already exists'),
            backgroundColor: AppTheme.error,
            behavior: SnackBarBehavior.floating,
          ),
        );
        setState(() => _isAdding = false);
        return;
      }

      Playlist playlist;
      if (_mode == PlaylistType.m3u) {
        final m3uUrl = _m3uUrlCtrl.text.trim();
        if (existing.any((p) => p.isM3u && p.m3uUrl == m3uUrl)) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A playlist with this URL already exists'),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() => _isAdding = false);
          return;
        }
        playlist = Playlist(
          id: const Uuid().v4(),
          name: name,
          addedAt: DateTime.now(),
          type: PlaylistType.m3u,
          m3uUrl: m3uUrl,
        );
      } else {
        final server = _serverCtrl.text.trim();
        final user = _usernameCtrl.text.trim();
        final pass = _passwordCtrl.text.trim();
        if (existing.any(
          (p) =>
              p.serverUrl == server && p.username == user && p.password == pass,
        )) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('A playlist with these credentials already exists'),
              backgroundColor: AppTheme.error,
              behavior: SnackBarBehavior.floating,
            ),
          );
          setState(() => _isAdding = false);
          return;
        }
        playlist = Playlist(
          id: const Uuid().v4(),
          name: name,
          serverUrl: server,
          username: user,
          password: pass,
          addedAt: DateTime.now(),
        );
      }

      // ── Step 3: Persist and navigate ─────────────────────────────────────
      await ref.read(playlistsProvider.notifier).addPlaylist(playlist);
      await ref.read(playlistsProvider.notifier).setActive(playlist.id);
      if (mounted) context.go('/sync');
    } catch (e) {
      if (mounted) {
        setState(() {
          _testError = e.toString();
          _isAdding = false;
        });
      }
    }
  }

  // ──────────────────────────────────────────────────────────────────────────
  // BUILD
  // ──────────────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            colors: [Color(0xFF0A0C14), Color(0xFF0E1220)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildHeader(),
              Expanded(
                child: SingleChildScrollView(
                  controller: _scrollCtrl,
                  padding: const EdgeInsets.fromLTRB(60, 0, 60, 24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(
                        maxWidth: double.infinity,
                      ),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildTitle(),
                            const SizedBox(height: 12),
                            _buildModeToggle(),
                            const SizedBox(height: 20),
                            _mode == PlaylistType.xtream
                                ? _buildFormFields()
                                : _buildM3uFields(),
                            const SizedBox(height: 20),
                            _buildError(),
                            const SizedBox(height: 20),
                            _buildAction(),
                            const SizedBox(height: 32),
                            _buildDisclaimer(),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          _BackButton(
            onTap: () {
              if (context.canPop()) context.pop();
            },
          ),
          const Spacer(),
          const Text(
            'Add Playlist',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          const SizedBox(width: 36),
        ],
      ),
    );
  }

  Widget _buildTitle() {
    return Column(
      children: [
        Text(
          _mode == PlaylistType.xtream ? 'Xtream Codes' : 'M3U Playlist',
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        Text(
          _mode == PlaylistType.xtream
              ? 'Enter your Xtream Codes credentials'
              : 'Enter your M3U playlist URL',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ],
    ).animate().fadeIn(delay: 200.ms);
  }

  // ── Mode toggle — Xtream | M3U (D-pad left/right switches focus) ──────────
  Widget _buildModeToggle() {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.divider),
      ),
      padding: const EdgeInsets.all(4),
      child: Row(
        children: [
          Expanded(
            child: _ModeBtn(
              focusNode: _xtreamModeFocus,
              label: 'Xtream Codes',
              icon: Icons.api_outlined,
              active: _mode == PlaylistType.xtream,
              onTap: () => setState(() {
                _mode = PlaylistType.xtream;
                _testError = null;
              }),
            ),
          ),
          Expanded(
            child: _ModeBtn(
              focusNode: _m3uModeFocus,
              label: 'M3U URL',
              icon: Icons.subscriptions_outlined,
              active: _mode == PlaylistType.m3u,
              onTap: () => setState(() {
                _mode = PlaylistType.m3u;
                _testError = null;
              }),
            ),
          ),
        ],
      ),
    ).animate().fadeIn(delay: 150.ms);
  }

  // ── M3U fields ────────────────────────────────────────────────────────────
  Widget _buildM3uFields() {
    return Column(
      children: [
        _buildTextField(
              controller: _nameCtrl,
              focusNode: _nameFocus,
              nextFocus: _m3uUrlFocus,
              label: 'Playlist name',
              hint: 'My IPTV',
              icon: Icons.playlist_play,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Enter a playlist name'
                  : null,
            )
            .animate(delay: 100.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),

        const SizedBox(height: 18),

        TextFormField(
              controller: _m3uUrlCtrl,
              focusNode: _m3uUrlFocus,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.done,
              onFieldSubmitted: (_) => _addBtnFocus.requestFocus(),
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
              validator: (v) {
                if (v == null || v.trim().isEmpty) return 'M3U URL is required';
                final uri = Uri.tryParse(v.trim());
                if (uri == null || !uri.hasAuthority) {
                  return 'Enter a valid URL';
                }
                return null;
              },
              decoration: InputDecoration(
                labelText: 'M3U Playlist URL',
                hintText: 'http://server.com/playlist.m3u',
                prefixIcon: const Icon(
                  Icons.link,
                  color: AppTheme.textMuted,
                  size: 22,
                ),
                labelStyle: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 14,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  vertical: 18,
                  horizontal: 16,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.divider),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(color: AppTheme.divider),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: AppTheme.primary,
                    width: 2,
                  ),
                ),
              ),
            )
            .animate(delay: 120.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),
      ],
    );
  }

  // ── Xtream fields ─────────────────────────────────────────────────────────
  Widget _buildFormFields() {
    return Column(
      children: [
        _buildTextField(
              controller: _nameCtrl,
              focusNode: _nameFocus,
              nextFocus: _serverFocus,
              label: 'Playlist name',
              hint: 'My IPTV',
              icon: Icons.playlist_play,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Please enter a playlist name'
                  : null,
            )
            .animate(delay: 100.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),

        const SizedBox(height: 18),

        _buildTextField(
              controller: _serverCtrl,
              focusNode: _serverFocus,
              nextFocus: _usernameFocus,
              label: 'Server URL',
              hint: 'http://your-server.com:8080',
              icon: Icons.link,
              keyboardType: TextInputType.url,
              validator: (v) {
                if (v == null || v.trim().isEmpty) {
                  return 'Server URL is required';
                }
                final uri = Uri.tryParse(v.trim());
                if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
                  return 'Enter a valid URL (e.g. http://server.com:8080)';
                }
                return null;
              },
            )
            .animate(delay: 120.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),

        const SizedBox(height: 18),

        _buildTextField(
              controller: _usernameCtrl,
              focusNode: _usernameFocus,
              nextFocus: _passwordFocus,
              label: 'Username',
              hint: 'Enter username',
              icon: Icons.person_outline,
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? 'Username is required'
                  : null,
            )
            .animate(delay: 140.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),

        const SizedBox(height: 18),

        _buildPasswordField()
            .animate(delay: 160.ms)
            .fadeIn(duration: 350.ms)
            .moveY(begin: 10, end: 0),
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    required FocusNode focusNode,
    FocusNode? nextFocus,
    required String label,
    required String hint,
    required IconData icon,
    String? Function(String?)? validator,
    TextInputType? keyboardType,
  }) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      validator: validator,
      keyboardType: keyboardType,
      textInputAction: nextFocus != null
          ? TextInputAction.next
          : TextInputAction.done,
      onFieldSubmitted: (_) => nextFocus?.requestFocus(),
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(icon, color: AppTheme.textMuted, size: 22),
        labelStyle: const TextStyle(color: AppTheme.primary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 18,
          horizontal: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.primary, width: 2),
        ),
      ),
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordCtrl,
      focusNode: _passwordFocus,
      obscureText: !_showPassword,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _addBtnFocus.requestFocus(),
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Password is required' : null,
      decoration: InputDecoration(
        labelText: 'Password',
        hintText: 'Enter password',
        prefixIcon: const Icon(
          Icons.lock_outline,
          color: AppTheme.textMuted,
          size: 22,
        ),
        suffixIcon: IconButton(
          focusNode: _passwordVisibilityFocus,
          icon: Icon(
            _showPassword ? Icons.visibility_off : Icons.visibility,
            color: AppTheme.textMuted,
            size: 22,
          ),
          onPressed: () => setState(() => _showPassword = !_showPassword),
        ),
        labelStyle: const TextStyle(color: AppTheme.primary, fontSize: 14),
        contentPadding: const EdgeInsets.symmetric(
          vertical: 18,
          horizontal: 16,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.divider),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.divider),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: AppTheme.primary, width: 2),
        ),
      ),
    );
  }

  // ── Error display only (success navigates away immediately) ───────────────
  Widget _buildError() {
    if (_testError == null) return const SizedBox.shrink();

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.error.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.error.withValues(alpha: 0.3)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.error_outline, color: AppTheme.error, size: 20),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Failed to connect:\n$_testError',
              style: const TextStyle(color: AppTheme.error, fontSize: 13),
            ),
          ),
        ],
      ),
    ).animate().fadeIn().shake(hz: 3, offset: const Offset(4, 0));
  }

  // ── Single "Add Playlist" button ──────────────────────────────────────────
  Widget _buildAction() {
    return GradientButton(
      focusNode: _addBtnFocus,
      label: _isAdding ? 'Connecting...' : 'Add Playlist',
      icon: _isAdding ? Icons.sync : Icons.add,
      onPressed: _isAdding ? null : _addPlaylist,
      isLoading: _isAdding,
    ).animate().fadeIn(delay: 150.ms);
  }

  Widget _buildDisclaimer() {
    return const Column(
      children: [
        Text(
          'Lunar IPTV Player is a standalone media player. We do not provide or sell content.',
          style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
        SizedBox(height: 4),
        Text(
          "Lunar IPTV Player doesn't sell playlist or subscriptions.",
          style: TextStyle(color: AppTheme.textMuted, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BACK BUTTON — touch · mouse · keyboard · TV remote
// ─────────────────────────────────────────────────────────────────────────────
class _BackButton extends StatefulWidget {
  final VoidCallback onTap;
  const _BackButton({required this.onTap});

  @override
  State<_BackButton> createState() => _BackButtonState();
}

class _BackButtonState extends State<_BackButton> {
  bool _focused = false;
  bool _pressed = false;

  // Only show ring during keyboard / TV-remote navigation
  bool get _showFocusRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightChanged);
  }

  void _onHighlightChanged(FocusHighlightMode _) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
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
        child: GestureDetector(
          onTap: widget.onTap,
          onTapDown: (_) => setState(() => _pressed = true),
          onTapUp: (_) => setState(() => _pressed = false),
          onTapCancel: () => setState(() => _pressed = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: _pressed
                  ? AppTheme.primary.withValues(alpha: 0.18)
                  : _showFocusRing // ← was: _focused
                  ? AppTheme.primary.withValues(alpha: 0.12)
                  : AppTheme.surface,
              borderRadius: BorderRadius.circular(10),
              border:
                  _showFocusRing // ← was: _focused
                  ? Border.all(
                      color: Colors.white.withValues(alpha: 0.6),
                      width: 2,
                    )
                  : null,
            ),
            child: const Icon(
              Icons.arrow_back,
              color: AppTheme.textPrimary,
              size: 20,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MODE BUTTON — now accepts a FocusNode for D-pad navigation
// ─────────────────────────────────────────────────────────────────────────────
class _ModeBtn extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool active;
  final VoidCallback onTap;
  final FocusNode? focusNode; // ← allows D-pad wiring from parent

  const _ModeBtn({
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.focusNode,
  });

  @override
  State<_ModeBtn> createState() => _ModeBtnState();
}

class _ModeBtnState extends State<_ModeBtn> {
  bool _focused = false;

  // Only show ring during keyboard / TV-remote navigation
  bool get _showFocusRing =>
      _focused &&
      FocusManager.instance.highlightMode == FocusHighlightMode.traditional;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addHighlightModeListener(_onHighlightChanged);
  }

  void _onHighlightChanged(FocusHighlightMode _) => setState(() {});

  @override
  void dispose() {
    FocusManager.instance.removeHighlightModeListener(_onHighlightChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: widget.focusNode,
      onFocusChange: (f) => setState(() => _focused = f),
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent &&
            (e.logicalKey == LogicalKeyboardKey.select ||
                e.logicalKey == LogicalKeyboardKey.enter ||
                e.logicalKey == LogicalKeyboardKey.space)) {
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
            duration: const Duration(milliseconds: 200),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: widget.active ? AppTheme.primary : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
              border:
                  _showFocusRing // ← was: _focused && !widget.active
                  ? Border.all(
                      color: widget.active
                          ? Colors.white.withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.4),
                      width: 2,
                    )
                  : null,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  widget.icon,
                  size: 15,
                  color: widget.active ? Colors.white : AppTheme.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: widget.active
                        ? Colors.white
                        : AppTheme.textSecondary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
