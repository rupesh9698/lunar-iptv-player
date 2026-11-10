import 'package:flutter/foundation.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'performance.dart';
import 'platform_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PLAYER TUNING — shared by the full-screen player and the Live TV player.
//
// History / why this exists:
// • Both players used to call `(player as dynamic).setProperty(...)`.
//   `Player` has no such method (it lives on `NativePlayer`), so every call
//   threw and was silently swallowed — none of the tuning ever applied.
// • That list also set `vo=gpu` / `gpu-context=android` by hand. media_kit
//   manages `vo` itself; setting vo=gpu before the video surface exists is a
//   documented SIGSEGV on Android, and `gpu-context=android` breaks desktop.
// • It also enabled `vd-lavc-skipframe=nonref` / `skipidct=nonkey`, which
//   deliberately throw away frames → visibly stuttering motion.
//
// Low-spec devices (Perf.enabled) get MediaCodec *direct* rendering
// (vo=mediacodec_embed + hwdec=mediacodec): decoded frames go straight to
// the display surface with no GPU copy-back — the biggest single win on TV
// boxes. If a particular stream shows a black picture, the user can switch
// performance mode off in Settings → Playback.
// ─────────────────────────────────────────────────────────────────────────────
class PlayerTuning {
  PlayerTuning._();

  static bool get _directMediaCodec => PlatformUtils.isAndroid && Perf.enabled;

  static PlayerConfiguration playerConfig() => PlayerConfiguration(
    // libass off: subtitles are drawn by media_kit's Flutter SubtitleView.
    libass: false,
    // Forward demuxer cache. 16 MB is ~30 s of a 4 Mbit/s stream.
    bufferSize: (Perf.enabled ? 16 : 32) * 1024 * 1024,
  );

  static VideoControllerConfiguration videoConfig() => _directMediaCodec
      ? const VideoControllerConfiguration(
          vo: 'mediacodec_embed',
          hwdec: 'mediacodec',
          enableHardwareAcceleration: true,
        )
      : const VideoControllerConfiguration(enableHardwareAcceleration: true);

  /// Applies libmpv options. Safe to call on any platform (no-op on web).
  static Future<void> apply(Player player, {required bool live}) async {
    final native = player.platform;
    if (kIsWeb || native is! NativePlayer) return;
    final low = Perf.enabled;

    // NOTE: no stream / network / cache options for LIVE streams. Before
    // this class existed none of the tuning ever applied and live TV played
    // fine on media_kit's defaults; forcing `stream-lavf-o reconnect_streamed`,
    // `cache-secs`, a short `network-timeout` and a tiny back-buffer made
    // some providers' live streams pause, jump backwards and replay in a loop.
    final props = <String, String>{
      if (!live) ...{
        'network-timeout': '30',
        // VOD back-buffer: bufferSize sets it equal to the forward cache
        // (32 MB) by default — wasted RAM on low-end boxes.
        'demuxer-max-back-bytes': low ? '8MiB' : '16MiB',
      },
      // Cheap scalers / no post-processing (only matter for vo=gpu).
      'scale': 'bilinear',
      'dscale': 'bilinear',
      'cscale': 'bilinear',
      'correct-downscaling': 'no',
      'sigmoid-upscaling': 'no',
      'deband': 'no',
      'dither-depth': 'no',
      'interpolation': 'no',
      if (low) ...{
        // Software-decode fallback only: skip the in-loop deblocking filter
        // on non-key frames (big CPU saving, barely visible).
        'vd-lavc-skiploopfilter': 'nonkey',
        // Keyframe seeks are near-instant on weak CPUs (VOD only).
        if (!live) 'hr-seek': 'no',
      },
    };

    for (final e in props.entries) {
      try {
        await native.setProperty(e.key, e.value);
      } catch (err) {
        debugPrint('mpv ${e.key}=${e.value} rejected: $err');
      }
    }
  }
}
