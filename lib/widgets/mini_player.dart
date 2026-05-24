import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

/// Platform-aware muted mini video player.
/// Native → real media_kit playback.
/// Web → thumbnail placeholder.
class MiniPlayer extends StatefulWidget {
  final String url;
  final String? thumbnailUrl;

  const MiniPlayer({super.key, required this.url, this.thumbnailUrl});

  @override
  State<MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends State<MiniPlayer> {
  Player? _player;
  VideoController? _ctrl;
  bool _loading = true;
  bool _error = false;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb) _init();
  }

  @override
  void didUpdateWidget(MiniPlayer old) {
    super.didUpdateWidget(old);
    if (old.url != widget.url && _player != null) {
      _player!.open(Media(widget.url));
    }
  }

  Future<void> _init() async {
    try {
      _player = Player();
      _ctrl    = VideoController(_player!);
      await _player!.setVolume(0);        // always muted in preview
      await _player!.open(Media(widget.url));
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() { _loading = false; _error = true; });
    }
  }

  @override
  void dispose() {
    _player?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Web or error → thumbnail + icon
    if (kIsWeb || _error) {
      return _StaticPreview(
        thumbnailUrl: widget.thumbnailUrl,
        icon: kIsWeb ? Icons.play_circle_outline : Icons.wifi_off_rounded,
        label: kIsWeb ? 'Press Watch Now to play' : 'Stream unavailable',
      );
    }

    // Loading → thumbnail + spinner
    if (_loading || _ctrl == null) {
      return Stack(fit: StackFit.expand, children: [
        _thumbnail(),
        const Center(
          child: CircularProgressIndicator(
              color: Colors.white, strokeWidth: 2),
        ),
      ]);
    }

    return Video(
        controller: _ctrl!,
        fit: BoxFit.cover,
        controls: NoVideoControls);
  }

  Widget _thumbnail() {
    final url = widget.thumbnailUrl;
    if (url != null && url.isNotEmpty) {
      return CachedNetworkImage(
        imageUrl: url,
        fit: BoxFit.cover,
        errorWidget: (_, _, _) => _blackBox(),
      );
    }
    return _blackBox();
  }

  Widget _blackBox() => Container(color: Colors.black);
}

class _StaticPreview extends StatelessWidget {
  final String? thumbnailUrl;
  final IconData icon;
  final String label;

  const _StaticPreview({
    this.thumbnailUrl,
    required this.icon,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black,
      child: Stack(fit: StackFit.expand, children: [
        if (thumbnailUrl != null && thumbnailUrl!.isNotEmpty)
          CachedNetworkImage(
            imageUrl: thumbnailUrl!,
            fit: BoxFit.cover,
            errorWidget: (_, _, _) => const SizedBox.shrink(),
          ),
        Center(
          child: Icon(icon,
              color: Colors.white.withValues(alpha: 0.5), size: 36),
        ),
        Positioned(
          bottom: 6,
          left: 6,
          child: Container(
            padding:
            const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            color: Colors.black.withValues(alpha: 0.55),
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white70, fontSize: 9)),
          ),
        ),
      ]),
    );
  }
}