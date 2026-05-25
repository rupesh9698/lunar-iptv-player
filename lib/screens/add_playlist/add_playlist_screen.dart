import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../core/theme/app_theme.dart';
import '../../models/xtream_models.dart';
import '../../providers/app_providers.dart';
import '../../services/xtream_service.dart';
import '../../widgets/app_widgets.dart';

class AddPlaylistScreen extends ConsumerStatefulWidget {
  const AddPlaylistScreen({super.key});

  @override
  ConsumerState<AddPlaylistScreen> createState() => _AddPlaylistScreenState();
}

class _AddPlaylistScreenState extends ConsumerState<AddPlaylistScreen> {
  final _nameCtrl = TextEditingController();
  final _serverCtrl = TextEditingController();
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _showPassword = false;
  bool _isTesting = false;
  bool _isAdding = false;
  String? _testError;
  AccountInfo? _testResult;
  bool _isTestSuccessful = false;

  // Focus nodes for better remote + keyboard navigation
  final _nameFocus = FocusNode();
  final _serverFocus = FocusNode();
  final _usernameFocus = FocusNode();
  final _passwordFocus = FocusNode();
  final _passwordVisibilityFocus = FocusNode();
  final _testBtnFocus = FocusNode();
  final _addBtnFocus = FocusNode();

  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();

    _serverCtrl.addListener(_onConnectionFieldChanged);
    _usernameCtrl.addListener(_onConnectionFieldChanged);
    _passwordCtrl.addListener(_onConnectionFieldChanged);

    // ── D-pad navigation set on FocusNode directly ────────────────────────────
    // FocusNode.onKeyEvent fires BEFORE EditableText processes the arrow key,
    // which means we correctly intercept it with a single D-pad press.
    _nameFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _serverFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

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
        _testBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _usernameFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _testBtnFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
        _addBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _passwordFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    _addBtnFocus.onKeyEvent = (_, event) {
      if (event is! KeyDownEvent) return KeyEventResult.ignored;
      if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
        _testBtnFocus.requestFocus();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    };

    // ── Auto-scroll when buttons receive focus ────────────────────────────────
    _testBtnFocus.addListener(_scrollToTestBtn);
    _addBtnFocus.addListener(_scrollToAddBtn);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _nameFocus.requestFocus();
    });
  }

  void _scrollToTestBtn() {
    if (!_testBtnFocus.hasFocus) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_testBtnFocus.context != null) {
        Scrollable.ensureVisible(
          _testBtnFocus.context!,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeInOut,
          alignment: 0.8,
        );
      }
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
    _serverCtrl.removeListener(_onConnectionFieldChanged);
    _usernameCtrl.removeListener(_onConnectionFieldChanged);
    _passwordCtrl.removeListener(_onConnectionFieldChanged);

    _testBtnFocus.removeListener(_scrollToTestBtn);
    _addBtnFocus.removeListener(_scrollToAddBtn);

    _nameFocus.dispose();
    _serverFocus.dispose();
    _usernameFocus.dispose();
    _passwordFocus.dispose();
    _passwordVisibilityFocus.dispose();
    _testBtnFocus.dispose();
    _addBtnFocus.dispose();
    _scrollController.dispose();

    _nameCtrl.dispose();
    _serverCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  void _onConnectionFieldChanged() {
    if (_isTestSuccessful) {
      setState(() {
        _isTestSuccessful = false;
        _testResult = null;
        _testError = null;
      });
    }
  }

  Future<void> _testConnection() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() {
      _isTesting = true;
      _testError = null;
      _testResult = null;
    });

    try {
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

      final info = await service.getAccountInfo();
      service.dispose();

      if (mounted) {
        setState(() {
          _testResult = info;
          _testError = null;
          _isTestSuccessful = true;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _testResult = null;
          _testError = e.toString();
          _isTestSuccessful = false;
        });
      }
    } finally {
      if (mounted) {
        setState(() => _isTesting = false);
      }
    }
  }

  Future<void> _addPlaylist() async {
    if (!_formKey.currentState!.validate() || !_isTestSuccessful || _isAdding) {
      return;
    }

    // Prevent double tap
    setState(() => _isAdding = true);

    try {
      final name = _nameCtrl.text.trim();
      final server = _serverCtrl.text.trim();
      final user = _usernameCtrl.text.trim();

      // === Duplicate prevention ===
      final existingPlaylists = ref.read(playlistsProvider);
      final isDuplicate = existingPlaylists.any(
        (p) =>
            p.name.toLowerCase() == name.toLowerCase() ||
            (p.serverUrl == server &&
                p.username == user &&
                p.password == _passwordCtrl.text.trim()),
      );

      if (isDuplicate) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'A playlist with this name or credentials already exists',
              ),
              backgroundColor: AppTheme.error,
            ),
          );
        }
        return;
      }

      final playlist = Playlist(
        id: const Uuid().v4(),
        name: name,
        serverUrl: server,
        username: user,
        password: _passwordCtrl.text.trim(),
        addedAt: DateTime.now(),
      );

      await ref.read(playlistsProvider.notifier).addPlaylist(playlist);
      await ref.read(playlistsProvider.notifier).setActive(playlist.id);

      if (mounted) {
        context.go('/sync');
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error adding playlist: $e')));
      }
    } finally {
      if (mounted) setState(() => _isAdding = false);
    }
  }

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
                  controller: _scrollController,
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 520),
                      child: Form(
                        key: _formKey,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _buildLogo(),
                            const SizedBox(height: 32),
                            _buildTitle(),
                            const SizedBox(height: 32),
                            _buildFormFields(),
                            const SizedBox(height: 28),
                            _buildTestResult(),
                            const SizedBox(height: 20),
                            _buildActions(),
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

  Widget _buildLogo() {
    return Center(
      child: SizedBox(
        width: 80,
        height: 80,
        child: Center(
          child: Image.asset("assets/images/logo.png", fit: BoxFit.contain),
        ),
      ).animate().scale(duration: 500.ms, curve: Curves.elasticOut),
    );
  }

  Widget _buildTitle() {
    return Column(
      children: [
        const Text(
          'Playlist URL',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 26,
            fontWeight: FontWeight.w700,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Enter your Xtream Codes credentials',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          textAlign: TextAlign.center,
        ),
      ],
    ).animate().fadeIn(delay: 200.ms);
  }

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
        ).animate().slideX(begin: -0.2, delay: 300.ms),

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
            if (v == null || v.trim().isEmpty) return 'Server URL is required';
            final uri = Uri.tryParse(v.trim());
            if (uri == null || !uri.hasAuthority || uri.host.isEmpty) {
              return 'Enter a valid URL (e.g. http://server.com:8080)';
            }
            return null;
          },
        ).animate().slideX(begin: -0.2, delay: 350.ms),

        const SizedBox(height: 18),

        _buildTextField(
          controller: _usernameCtrl,
          focusNode: _usernameFocus,
          nextFocus: _passwordFocus,
          label: 'Username',
          hint: 'Enter username',
          icon: Icons.person_outline,
          validator: (v) =>
              (v == null || v.trim().isEmpty) ? 'Username is required' : null,
        ).animate().slideX(begin: -0.2, delay: 400.ms),

        const SizedBox(height: 18),

        _buildPasswordField().animate().slideX(begin: -0.2, delay: 450.ms),
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
      style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
      validator: (v) =>
          (v == null || v.trim().isEmpty) ? 'Password is required' : null,
      textInputAction: TextInputAction.done,
      onFieldSubmitted: (_) => _testBtnFocus.requestFocus(),
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

  Widget _buildTestResult() {
    if (_testResult != null) {
      final info = _testResult!;
      return Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.success.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(
                  Icons.check_circle,
                  color: AppTheme.success,
                  size: 20,
                ),
                const SizedBox(width: 8),
                const Text(
                  'Connection Successful',
                  style: TextStyle(
                    color: AppTheme.success,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _InfoRow('Username', info.userInfo.username),
            _InfoRow('Status', info.userInfo.status),
            _InfoRow(
              'Connections',
              '${info.userInfo.activeConnections}/'
                  '${info.userInfo.maxConnections}',
            ),
            _InfoRow(
              'Expiry',
              info.userInfo.expirationDate != null
                  ? '${info.userInfo.expirationDate!.day}/'
                        '${info.userInfo.expirationDate!.month}/'
                        '${info.userInfo.expirationDate!.year}'
                  : 'Never',
            ),
          ],
        ),
      ).animate().fadeIn();
    }

    if (_testError != null) {
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
                'Connection failed:\n$_testError',
                style: const TextStyle(color: AppTheme.error, fontSize: 13),
              ),
            ),
          ],
        ),
      ).animate().fadeIn();
    }

    return const SizedBox.shrink();
  }

  Widget _buildActions() {
    final bool canAdd = _isTestSuccessful && !_isAdding;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          focusNode: _testBtnFocus,
          onPressed: _isTesting ? null : _testConnection,
          icon: _isTesting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.network_check, size: 20),
          label: Text(_isTesting ? 'Testing...' : 'Test Connection'),
          style: OutlinedButton.styleFrom(
            foregroundColor: AppTheme.primary,
            side: const BorderSide(color: AppTheme.primary),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ).animate().fadeIn(delay: 100.ms),

        const SizedBox(height: 12),

        GradientButton(
          focusNode: _addBtnFocus,
          label: 'Add Playlist',
          icon: Icons.add,
          onPressed: canAdd ? _addPlaylist : null,
          isLoading: _isAdding,
        ).animate().fadeIn(delay: 150.ms),
      ],
    );
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
          'Lunar IPTV Player doesn\'t sell playlist or subscriptions.',
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
                  : _focused
                  ? AppTheme.primary.withValues(alpha: 0.12)
                  : AppTheme.surface,
              borderRadius: BorderRadius.circular(10),
              border: _focused
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

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Text(
            '$label: ',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
