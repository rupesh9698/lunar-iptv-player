import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../theme/app_theme.dart';

/// Launches a YouTube trailer on the correct platform:
/// - Android/iOS: YouTube app → browser fallback
/// - Web: New tab
/// - Desktop (Windows/macOS/Linux): Default browser
Future<void> launchYouTubeTrailer(BuildContext context, String videoId) async {
  if (videoId.isEmpty) return;

  final Uri webUri = Uri.parse('https://www.youtube.com/watch?v=$videoId');
  bool launched = false;

  // On mobile: prefer YouTube app
  if (!kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS)) {
    try {
      final Uri appUri = Uri.parse('youtube://watch?v=$videoId');
      if (await canLaunchUrl(appUri)) {
        launched = await launchUrl(
          appUri,
          mode: LaunchMode.externalNonBrowserApplication,
        );
      }
    } catch (_) {}
  }

  // Fallback: web or desktop browser
  if (!launched) {
    try {
      launched = await launchUrl(
        webUri,
        mode: kIsWeb
            ? LaunchMode
                  .platformDefault // Opens new tab on web
            : LaunchMode
                  .externalApplication, // Default browser on desktop/mobile fallback
      );
    } catch (_) {}
  }

  if (!launched && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Could not open trailer'),
        backgroundColor: AppTheme.error,
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
