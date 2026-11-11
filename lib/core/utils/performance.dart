import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import '../../services/storage_service.dart';
import 'platform_utils.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PERFORMANCE PROFILE
// Detects low-spec hardware (Android TV boxes, Android "Go"/low-RAM devices,
// anything under ~3 GB RAM) and exposes a single switch — "performance
// mode" — that the rest of the app uses to pick lighter settings:
//   • video: MediaCodec direct rendering (vo=mediacodec_embed) instead of
//     GPU copy-back, smaller demuxer buffers
//   • images: smaller in-memory decoded-image cache
//   • UI: no staggered list animations
// The user can force it on/off in Settings → Playback; null = automatic.
// ─────────────────────────────────────────────────────────────────────────────
class Perf {
  Perf._();

  static const String settingKey = 'performance_mode';

  static bool _lowEndDevice = false;
  static int _ramMb = 0;

  /// Physical RAM in MB (Android only, 0 when unknown).
  static int get ramMb => _ramMb;

  /// What auto-detection decided for this device.
  static bool get detectedLowEnd => _lowEndDevice;

  /// Explicit user choice from Settings (null = automatic).
  static bool? get userOverride {
    try {
      final v = StorageService.instance.getSetting(settingKey);
      return v is bool ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Effective performance mode.
  static bool get enabled => userOverride ?? _lowEndDevice;

  /// Call once at start-up (after StorageService.init).
  static Future<void> init() async {
    if (PlatformUtils.isAndroid) {
      try {
        final info = await DeviceInfoPlugin().androidInfo;
        _ramMb = info.physicalRamSize;
        _lowEndDevice =
            PlatformUtils.isTV ||
            info.isLowRamDevice ||
            (_ramMb > 0 && _ramMb < 3072);
      } catch (e) {
        debugPrint('Perf detection failed: $e');
        _lowEndDevice = PlatformUtils.isTV;
      }
    }
    applyImageCacheLimits();
  }

  static Future<void> setUserOverride(bool? value) async {
    await StorageService.instance.setSetting(settingKey, value);
    applyImageCacheLimits();
  }

  /// Decoded-image cache budget. Posters are now decoded at display size,
  /// so even the small budget holds a few hundred of them.
  static void applyImageCacheLimits() {
    final cache = PaintingBinding.instance.imageCache;
    if (enabled) {
      cache.maximumSizeBytes = 48 << 20; // 48 MB
      cache.maximumSize = 300;
    } else {
      cache.maximumSizeBytes = 100 << 20; // Flutter default
      cache.maximumSize = 1000;
    }
  }

  /// Max pixel width an image is decoded at. Thumbnails never need more than
  /// ~2× their logical size; huge originals (TMDB posters are often
  /// 2000×3000 = 24 MB decoded) are what exhausted memory on TVs.
  static int decodeWidth(double logicalWidth, double devicePixelRatio) {
    final cap = enabled ? 360 : 600;
    // Rounded up to a 64 px step: the decode width is part of the image's
    // cache key, so a tile that changed size by a pixel or two (a focus
    // border, a scrollbar) used to re-decode its image and flicker.
    final px = ((logicalWidth * devicePixelRatio) / 64).ceil() * 64;
    return px.clamp(64, cap);
  }

  /// Whether decorative staggered list animations should run.
  static bool get listAnimations => !enabled;
}
