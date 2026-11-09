import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;

/// Image cache: 2000 objects, 14-day stale period.
///
/// Uses a [_ResilientClient] so that a dead or slow image host can't stall
/// every poster: the default downloader allows 10 parallel downloads with NO
/// timeout, so a provider whose image server is down (e.g. `webhop.live`,
/// ~4,500 series covers on the test TV) occupied every slot for minutes and
/// the working TMDB posters waited behind them — "posters not showing".
class AppCacheManager {
  AppCacheManager._();

  static const String _key = 'lunip_img_cache_v1';

  static final CacheManager instance = CacheManager(
    Config(
      _key,
      stalePeriod: const Duration(days: 14),
      maxNrOfCacheObjects: 2000,
      fileService: HttpFileService(httpClient: _ResilientClient())
        // More parallel downloads: posters are small and mostly from fast
        // CDNs; a few slow hosts no longer starve the queue.
        ..concurrentFetches = 16,
    ),
  );
}

/// http client with a per-request timeout and a per-host circuit breaker:
/// after [_kMaxFailures] consecutive timeouts/connection errors a host is
/// skipped (fails instantly → fallback artwork) for [_kCooldown].
class _ResilientClient extends http.BaseClient {
  _ResilientClient() : _inner = http.Client();

  final http.Client _inner;

  static const Duration _kTimeout = Duration(seconds: 10);
  static const int _kMaxFailures = 3;
  static const Duration _kCooldown = Duration(minutes: 10);

  final Map<String, int> _failures = {};
  final Map<String, DateTime> _blockedUntil = {};

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final host = request.url.authority;
    final until = _blockedUntil[host];
    if (until != null) {
      if (DateTime.now().isBefore(until)) {
        throw http.ClientException('Image host unavailable: $host', request.url);
      }
      _blockedUntil.remove(host);
      _failures.remove(host);
    }
    try {
      final res = await _inner.send(request).timeout(_kTimeout);
      _failures.remove(host);
      return res;
    } catch (e) {
      final n = (_failures[host] ?? 0) + 1;
      _failures[host] = n;
      if (n >= _kMaxFailures) {
        _blockedUntil[host] = DateTime.now().add(_kCooldown);
        debugPrint('Image host $host unreachable — skipping for 10 min');
      }
      rethrow;
    }
  }

  @override
  void close() => _inner.close();
}
