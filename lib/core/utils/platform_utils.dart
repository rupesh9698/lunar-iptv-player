import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:screen_brightness/screen_brightness.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

class PlatformUtils {
  PlatformUtils._();

  // ── Basic Platform Detection ──────────────────────────────────────
  // Uses defaultTargetPlatform (works on ALL platforms including web)
  // Always check isWeb first before checking other platforms

  static bool get isWeb => kIsWeb;

  static bool get isAndroid =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  static bool get isIOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  static bool get isMacOS =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.macOS;

  static bool get isWindows =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static bool get isLinux =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.linux;

  static bool get isDesktop => isMacOS || isWindows || isLinux;

  static bool get isMobile => isAndroid || isIOS;

  static bool get isTV => _isAndroidTV;

  // ── Feature Support Flags ─────────────────────────────────────────
  // Used to gate feature availability across the codebase

  /// local_auth: no Linux plugin, limited web support
  static bool get supportsLocalAuth => !isWeb && !isLinux;

  /// screen_brightness: no Linux / Web plugin
  static bool get supportsScreenBrightness =>
      isMobile || isMacOS || isWindows;

  /// volume_controller: Android & iOS only
  static bool get supportsVolumeControl => isMobile;

  /// path_provider: has web stub since 2.0.6, works everywhere
  static bool get supportsPathProvider => true;

  /// media_kit: all native platforms
  static bool get supportsMediaKit => !isWeb;

  /// wakelock_plus: all platforms
  static bool get supportsWakelock => true;

  // ── Wakelock Helper ───────────────────────────────────────────────
  static Future<void> initWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (e) {
      debugPrint('Wakelock init skipped: $e');
    }
  }

  static Future<void> enableWakelock() async {
    try {
      await WakelockPlus.enable();
    } catch (_) {}
  }

  static Future<void> disableWakelock() async {
    try {
      await WakelockPlus.disable();
    } catch (_) {}
  }

  // ── Screen Brightness Helper ──────────────────────────────────────
  static Future<void> setBrightness(double value) async {
    // Brightness control only available on mobile
    if (kIsWeb || isDesktop) return;
    try {
      await ScreenBrightness().setApplicationScreenBrightness(
        value.clamp(0.0, 1.0),
      );
    } catch (_) {}
  }

  // ── Volume Helper ─────────────────────────────────────────────────
  static Future<void> setVolume(double value) async {
    if (!supportsVolumeControl) return;
    try {
      await _setVolume(value);
    } catch (e) {
      debugPrint('Volume control not available: $e');
    }
  }

  static Future<void> _setVolume(double value) async {
    if (!supportsVolumeControl) return;
    // Will be implemented in player step
  }

  // ── Android TV Detection ──────────────────────────────────────────
  static bool _isAndroidTV = false;

  /// Detects Android TV / Google TV / Fire TV via the package-manager
  /// system features. Must be awaited once at startup (see main.dart)
  /// before [isTV] is read.
  static Future<void> detectAndroidTV() async {
    if (!isAndroid) {
      _isAndroidTV = false;
      return;
    }
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final features = info.systemFeatures;
      _isAndroidTV =
          features.contains('android.software.leanback') ||
          features.contains('android.software.leanback_only') ||
          features.contains('android.hardware.type.television') ||
          // Amazon Fire TV devices
          features.contains('amazon.hardware.fire_tv') ||
          info.model.toUpperCase().startsWith('AFT');
    } catch (e) {
      debugPrint('Android TV detection failed: $e');
      _isAndroidTV = false;
    }
  }

  // ── Biometric Auth Helper ─────────────────────────────────────────
  static Future<bool> authenticateWithBiometrics({
    required String reason,
  }) async {
    if (!supportsLocalAuth) return false;
    try {
      return await _biometricAuth(reason);
    } catch (e) {
      debugPrint('Biometric auth error: $e');
      return false;
    }
  }

  static Future<bool> _biometricAuth(String reason) async {
    // Will be implemented in settings step
    return false;
  }

  // ── Layout Helpers ────────────────────────────────────────────────
  static bool isWideScreen(double width) => width >= 900;
  static bool isTablet(double width) => width >= 600;

  /// True when the primary input is a D-pad / keyboard rather than touch
  /// (Android TV, or any desktop/web where focus rings are expected).
  static bool get prefersDpad => isTV;

  static int gridColumns(double width) {
    if (width > 1400) return 7;
    if (width > 1200) return 6;
    if (width > 900) return 5;
    if (width > 600) return 4;
    if (width > 400) return 3;
    return 2;
  }
}