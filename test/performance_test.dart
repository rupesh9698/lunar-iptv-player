import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/core/utils/performance.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/services/cache_service.dart';

/// Builds an Xtream-style get_vod_streams payload with [n] movies spread
/// over 40 categories.
String _vodJson(int n) => jsonEncode([
  for (var i = 0; i < n; i++)
    {
      'num': '$i',
      'name': 'Movie $i',
      'stream_type': 'movie',
      'stream_id': '$i',
      'stream_icon': 'https://img.example.com/p/$i.jpg',
      'rating': '7.1',
      'rating_5based': '3.5',
      'added': '${1700000000 + i}',
      'category_id': '${i % 40}',
      'container_extension': 'mkv',
    },
]);

VodStream _vod(int i) => VodStream(
  num: '$i',
  name: 'Movie $i',
  streamType: 'movie',
  streamId: '$i',
  streamIcon: 'https://img.example.com/p/$i.jpg',
  rating5based: '3.5',
  added: '${1700000000 + i}',
  categoryId: '${i % 40}',
  containerExtension: 'mp4',
);

void main() {
  group('isolate decoders', () {
    test('decode a 60k-movie library without the old 20k cap', () {
      final sw = Stopwatch()..start();
      final list = decodeVodList(_vodJson(60000));
      sw.stop();
      // ignore: avoid_print
      print('decodeVodList(60k) took ${sw.elapsedMilliseconds} ms');

      expect(list, hasLength(60000));
      expect(list.last.name, 'Movie 59999');
      expect(list.last.categoryId, '39');
      expect(list.first.containerExtension, 'mkv');
    });

    test('repeated short strings are interned (shared instances)', () {
      final list = decodeVodList(_vodJson(200));
      // Items 0 and 40 share category "0".
      expect(identical(list[0].categoryId, list[40].categoryId), isTrue);
      expect(identical(list[0].streamType, list[1].streamType), isTrue);
      // Unique values are untouched.
      expect(list[0].streamId, isNot(list[1].streamId));
    });

    test('series decoder maps empty strings to null', () {
      final raw = jsonEncode([
        {
          'series_id': '1',
          'name': 'Show',
          'cover': '',
          'plot': 'A plot',
          'category_id': '7',
          'backdrop_path': '',
        },
      ]);
      final s = decodeSeriesList(raw).single;
      expect(s.cover, isNull);
      expect(s.backdropPath, isNull);
      expect(s.plot, 'A plot');
      expect(s.categoryId, '7');
    });
  });

  group('CacheService (lazy box + single decoded copy)', () {
    late Directory dir;
    final cache = CacheService.instance;

    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('lunar_cache_test');
      Hive.init(dir.path);
      await cache.init();
    });

    tearDownAll(() async {
      await Hive.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('nothing cached → presence is unknown, no decode needed', () async {
      cache.setActivePlaylist('empty_playlist');
      expect(cache.vodStreamsNonEmpty(), isNull);
      expect(cache.hasVodStreams(), isFalse);
      expect(await cache.loadVodStreams(ignoreExpiry: true), isNull);
    });

    test('save → load returns the in-memory list (no re-decode)', () async {
      cache.setActivePlaylist('playlist_a');
      final movies = List.generate(1000, _vod);
      await cache.saveVodStreams(movies);

      expect(cache.hasVodStreams(), isTrue);
      final loaded = await cache.loadVodStreams(ignoreExpiry: true);
      expect(identical(loaded, movies), isTrue);
    });

    test('after a playlist switch the list is decoded from disk', () async {
      cache.setActivePlaylist('playlist_b');
      cache.setActivePlaylist('playlist_a'); // memory dropped on switch

      // Presence answered from the stored count — no decoding.
      expect(cache.vodStreamsNonEmpty(), isTrue);

      final loaded = await cache.loadVodStreams(ignoreExpiry: true);
      expect(loaded, hasLength(1000));
      expect(loaded!.last.name, 'Movie 999');

      // Second call is served from memory (same instance).
      final again = await cache.loadVodStreams(ignoreExpiry: true);
      expect(identical(again, loaded), isTrue);
    });

    test('concurrent loads share one decode', () async {
      cache.setActivePlaylist('playlist_b');
      cache.setActivePlaylist('playlist_a');
      final results = await Future.wait([
        cache.loadVodStreams(ignoreExpiry: true),
        cache.loadVodStreams(ignoreExpiry: true),
      ]);
      expect(identical(results[0], results[1]), isTrue);
    });

    test('an empty saved library reports false, not unknown', () async {
      cache.setActivePlaylist('playlist_empty_saved');
      await cache.saveSeriesList(const []);
      expect(cache.seriesListNonEmpty(), isFalse);
    });
  });

  group('Perf.decodeWidth', () {
    test('posters are decoded near display size, never full-size', () {
      // A 140 px tile at 2x density → 280 px, rounded up to 320.
      expect(Perf.decodeWidth(140, 2), 320);
      // Huge layouts are capped (desktop default cap 600).
      expect(Perf.decodeWidth(2000, 3), lessThanOrEqualTo(600));
      // Tiny logos still get a sane minimum.
      expect(Perf.decodeWidth(10, 1), 64);
    });

    test('a tile a few px smaller keeps the same decode (no reload)', () {
      // Focus borders used to shrink tiles by 2 px → new cache key →
      // the poster re-loaded and flickered.
      expect(Perf.decodeWidth(138, 2), Perf.decodeWidth(140, 2));
      expect(Perf.decodeWidth(155, 1), Perf.decodeWidth(157, 1));
    });
  });
}
