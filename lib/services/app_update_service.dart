import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:in_app_update/in_app_update.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:upgrader/upgrader.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/theme/app_theme.dart';

// ============================================================================
// In-app updates on every platform
//
//  * Android installed from Google Play (phones, tablets, Android TV):
//    Google's official Play in-app update API — the update downloads and
//    installs from inside the app (Play's own full-screen flow).
//  * Android sideloaded APK (TV boxes without Play), Windows, macOS, Linux:
//    an appcast feed (Sparkle format) hosted on Firebase:
//    brand/appcast.xml → https://lunar-iptv.web.app/appcast.xml
//    Each <item> carries `sparkle:os` and links to the store page / download.
//  * iOS: App Store lookup.
//  * Web: always serves the latest build — nothing to do.
//
// One remote-friendly dialog for all of them, at most once a day; "Skip"
// hides that version for good, a critical update can't be skipped.
// ============================================================================

class AppUpdateService {
  AppUpdateService._();
  static final instance = AppUpdateService._();

  static const appcastUrl = 'https://lunar-iptv.web.app/appcast.xml';
  static const _kLastPrompt = 'app_update_last_prompt';
  static const _kSkipped = 'app_update_skipped_version';
  static const _remindAfter = Duration(days: 1);

  bool _checkedThisSession = false;

  /// Checks once per app session and shows the update dialog when needed.
  Future<void> checkAndPrompt(BuildContext context, {bool force = false}) async {
    if (kIsWeb) return;
    if (_checkedThisSession && !force) return;
    _checkedThisSession = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!force) {
        final last = prefs.getInt(_kLastPrompt);
        if (last != null &&
            DateTime.now().difference(
                  DateTime.fromMillisecondsSinceEpoch(last),
                ) <
                _remindAfter) {
          return;
        }
      }

      // 1. Google Play in-app update (Android, installed from Play).
      if (defaultTargetPlatform == TargetPlatform.android) {
        if (!context.mounted) return;
        final handled = await _tryPlay(context, prefs, force: force);
        if (!context.mounted) return;
        if (handled != null) {
          if (!handled && force) _upToDate(context);
          return;
        }
      }

      // 2. Appcast / App Store via upgrader.
      final upgrader = Upgrader(
        durationUntilAlertAgain: Duration.zero,
        storeController: UpgraderStoreController(
          onAndroid: () => UpgraderAppcastStore(appcastURL: appcastUrl),
          oniOS: () => UpgraderAppStore(),
          onMacOS: () => UpgraderAppcastStore(appcastURL: appcastUrl),
          onWindows: () => UpgraderAppcastStore(appcastURL: appcastUrl),
          onLinux: () => UpgraderAppcastStore(appcastURL: appcastUrl),
        ),
      );
      await upgrader.initialize();
      final available = upgrader.isUpdateAvailable();
      final version = upgrader.currentAppStoreVersion;
      final url = upgrader.currentAppStoreListingURL;
      if (!available || version == null || url == null || url.isEmpty) {
        if (force && context.mounted) _upToDate(context);
        return;
      }
      final critical = upgrader.belowMinAppVersion() ||
          (upgrader.versionInfo?.isCriticalUpdate ?? false);
      if (!force && !critical && prefs.getString(_kSkipped) == version) return;
      if (!context.mounted) return;
      await prefs.setInt(_kLastPrompt, DateTime.now().millisecondsSinceEpoch);
      if (!context.mounted) return;
      final choice = await _showDialog(
        context,
        version: version,
        installed: upgrader.currentInstalledVersion,
        notes: upgrader.releaseNotes,
        critical: critical,
      );
      if (choice == _Choice.update) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      } else if (choice == _Choice.skip) {
        await prefs.setString(_kSkipped, version);
      }
    } catch (e) {
      debugPrint('[update] check failed: $e');
      if (force && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            behavior: SnackBarBehavior.floating,
            content: Text('Could not check for updates'),
          ),
        );
      }
    }
  }

  /// Returns null when Play isn't available (sideloaded / no Play services),
  /// otherwise whether an update was offered.
  Future<bool?> _tryPlay(
    BuildContext context,
    SharedPreferences prefs, {
    required bool force,
  }) async {
    AppUpdateInfo info;
    try {
      info = await InAppUpdate.checkForUpdate();
    } catch (e) {
      debugPrint('[update] Play in-app update unavailable: $e');
      return null;
    }
    if (info.updateAvailability ==
        UpdateAvailability.developerTriggeredUpdateInProgress) {
      // An immediate update was interrupted → resume it.
      await InAppUpdate.performImmediateUpdate();
      return true;
    }
    if (info.updateAvailability != UpdateAvailability.updateAvailable) {
      return false;
    }
    final version = '${info.availableVersionCode ?? ''}';
    // Priority 4-5 (set when uploading the release) = critical.
    final critical = info.updatePriority >= 4;
    if (!force && !critical && prefs.getString(_kSkipped) == version) {
      return false;
    }
    if (!context.mounted) return true;
    await prefs.setInt(_kLastPrompt, DateTime.now().millisecondsSinceEpoch);
    if (!context.mounted) return true;
    final choice = await _showDialog(context, critical: critical);
    if (choice == _Choice.update) {
      if (info.immediateUpdateAllowed) {
        await InAppUpdate.performImmediateUpdate();
      } else if (info.flexibleUpdateAllowed) {
        await InAppUpdate.startFlexibleUpdate();
        await InAppUpdate.completeFlexibleUpdate(); // restarts the app
      }
    } else if (choice == _Choice.skip) {
      await prefs.setString(_kSkipped, version);
    }
    return true;
  }

  void _upToDate(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text('You have the latest version'),
      ),
    );
  }

  Future<_Choice?> _showDialog(
    BuildContext context, {
    String? version,
    String? installed,
    String? notes,
    required bool critical,
  }) {
    return showDialog<_Choice>(
      context: context,
      barrierDismissible: !critical,
      builder: (ctx) => PopScope(
        canPop: !critical,
        child: AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Row(
            children: [
              Icon(Icons.system_update, color: AppTheme.primary),
              SizedBox(width: 10),
              Expanded(child: Text('Update available')),
            ],
          ),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420, maxHeight: 280),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    version == null
                        ? 'A new version of Lunar IPTV Player is available.'
                        : 'Lunar IPTV Player $version is available'
                              '${installed != null ? ' (you have $installed)' : ''}.',
                  ),
                  if (notes != null && notes.trim().isNotEmpty) ...[
                    const SizedBox(height: 12),
                    const Text(
                      "What's new",
                      style: TextStyle(fontWeight: FontWeight.w700),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notes.trim(),
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                  if (critical) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'This update is required to keep using the app.',
                      style: TextStyle(color: AppTheme.warning),
                    ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            if (!critical) ...[
              TextButton(
                onPressed: () => Navigator.pop(ctx, _Choice.skip),
                child: const Text('Skip this version'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, _Choice.later),
                child: const Text('Later'),
              ),
            ],
            FilledButton(
              autofocus: true, // remote: OK updates straight away
              onPressed: () => Navigator.pop(ctx, _Choice.update),
              child: const Text('Update'),
            ),
          ],
        ),
      ),
    );
  }
}

enum _Choice { update, later, skip }
