import 'package:flutter/foundation.dart';

class WebProxyClient {
  WebProxyClient._();

  static const _proxyBase =
      'https://us-central1-projects-2000.cloudfunctions.net/iptvProxy';

  /// Error code used when an HTTP stream cannot be played in HTTPS web browser
  static const webHttpStreamError = 'WEB_HTTP_STREAM_NOT_SUPPORTED';

  /// Returns proxy URL on web, original URL on native
  static String resolve(String originalUrl) {
    if (!kIsWeb) return originalUrl;
    return '$_proxyBase?url=${Uri.encodeComponent(originalUrl)}';
  }

  /// Returns true when the URL is an HTTP stream on web (Chrome blocks these)
  static bool isWebHttpStream(String url) =>
      kIsWeb && url.startsWith('http://');
}