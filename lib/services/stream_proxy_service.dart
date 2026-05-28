import 'package:flutter/foundation.dart';

/// Resolves the correct stream URL for each platform.
///
/// Strategy:
/// - Native (Android/iOS/Desktop): Direct HTTP is fine — use original URL.
/// - Web: Route through our Firebase stream proxy which pipes the HTTP
///   stream via HTTPS, eliminating Mixed Content block in Chrome.
class StreamProxyService {
  StreamProxyService._();

  // Your Firebase Cloud Run stream proxy (deployed separately — see instructions)
  static const _streamProxyBase =
      'https://lunar-iptv-stream-proxy-870264865700.us-central1.run.app/proxy';

  // Your existing API proxy (Firebase Functions)
  static const _apiProxyBase =
      'https://us-central1-projects-2000.cloudfunctions.net/iptvProxy';

  /// Resolves a stream URL (HLS/TS live, VOD, series episode).
  /// On web: routes through the stream proxy.
  /// On native: returns original URL.
  static String resolveStream(String originalUrl) {
    if (!kIsWeb) return originalUrl;
    if (!originalUrl.startsWith('http://')) return originalUrl;
    // Encode and route through Cloud Run proxy
    return '$_streamProxyBase?url=${Uri.encodeComponent(originalUrl)}';
  }

  /// Resolves an API call URL (player_api.php).
  /// On web: routes through Firebase Function proxy.
  /// On native: returns original URL.
  static String resolveApi(String originalUrl) {
    if (!kIsWeb) return originalUrl;
    return '$_apiProxyBase?url=${Uri.encodeComponent(originalUrl)}';
  }

  /// Returns true if the URL is an HTTP stream that needs proxying on web.
  static bool needsProxy(String url) => kIsWeb && url.startsWith('http://');
}
