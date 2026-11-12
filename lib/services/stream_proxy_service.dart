// Image widgets use HttpGet on web (see resolveImage); the enum lives in a
// package cached_network_image depends on but doesn't re-export.
// ignore: depend_on_referenced_packages
export 'package:cached_network_image_platform_interface/cached_network_image_platform_interface.dart'
    show ImageRenderMethodForWeb;
import 'package:flutter/foundation.dart';

/// Routes what the web app loads from IPTV servers through our HTTPS proxy
/// (`mediaProxy` Cloud Function, see functions/index.js).
///
/// The web app is served over HTTPS, so the browser blocks:
///  • plain-HTTP servers (mixed content) — API, playlists, streams, images;
///  • servers without CORS headers — API calls, M3U downloads and HLS
///    (hls.js fetches playlists and segments with XHR).
/// The proxy relays over HTTPS with CORS, follows redirects and rewrites HLS
/// playlists so every segment goes through it as well.
///
/// Native apps (Android, TV, desktop) never use it.
class StreamProxyService {
  StreamProxyService._();

  static const proxyBase =
      'https://us-central1-projects-2000.cloudfunctions.net/mediaProxy';

  static String _via(String url) =>
      '$proxyBase?url=${Uri.encodeComponent(url)}';

  static bool _isProxied(String url) => url.startsWith(proxyBase);

  /// API calls (player_api.php), M3U playlists, guides: always proxied on
  /// web (HTTP sources are blocked, HTTPS ones rarely send CORS headers).
  static String resolveApi(String url) {
    if (!kIsWeb || _isProxied(url)) return url;
    return _via(url);
  }

  /// Live / VOD / episode streams. HTTP always goes through the proxy; HLS
  /// does too (hls.js needs CORS). Other HTTPS files (mp4 …) play directly
  /// in the browser's video element, which needs no CORS.
  static String resolveStream(String url) {
    if (!kIsWeb || _isProxied(url)) return url;
    if (url.startsWith('http://') || url.toLowerCase().contains('m3u8')) {
      return _via(url);
    }
    return url;
  }

  /// Posters / logos: on web the image widgets fetch the bytes
  /// (ImageRenderMethodForWeb.HttpGet; the default <img> route drew some
  /// proxied logos as black boxes) and that fetch needs CORS, so
  /// image hosts without CORS headers (most IPTV logo / poster servers) and
  /// plain-HTTP ones go through the proxy. The proxy marks images cacheable
  /// for a week, so each is fetched once per browser.
  static String resolveImage(String url) {
    if (!kIsWeb || _isProxied(url)) return url;
    if (!url.startsWith('http://') && !url.startsWith('https://')) return url;
    return _via(url);
  }

  /// Returns true if the URL is an HTTP stream that needs proxying on web.
  static bool needsProxy(String url) => kIsWeb && url.startsWith('http://');
}
