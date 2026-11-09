import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/services/cache_service.dart';

/// Builds a listing the way Xtream sends it (base64 title/description).
EpgListing _e(String title, DateTime start, DateTime end, {String desc = ''}) =>
    EpgListing(
      id: '',
      epgId: '',
      title: base64.encode(utf8.encode(title)),
      description: base64.encode(utf8.encode(desc)),
      start: '',
      end: '',
      startTimestamp: start.millisecondsSinceEpoch ~/ 1000,
      stopTimestamp: end.millisecondsSinceEpoch ~/ 1000,
    );

DateTime _t(int h, int m) => DateTime(2026, 11, 10, h, m);

void main() {
  group('EpgNormalizer (patterns from the real provider data)', () {
    final now = _t(3, 30);

    test('"Now Playing" is by the clock, never a days-old first entry', () {
      final raw = [
        // A week-old listing at the head of the list (what used to show).
        _e('Nayaki', DateTime(2026, 11, 2, 7, 2), DateTime(2026, 11, 2, 8, 45)),
        _e('Kya Bolti Tu', _t(2, 25), _t(4, 0), desc: 'Tammy believes...'),
        _e('Kabadadaari', _t(4, 0), _t(6, 7)),
      ];
      final epg = EpgNormalizer.normalize(raw, now: now);
      expect(epg.first.decodedTitle, 'Kya Bolti Tu');
      expect(epg.currentAt(now)!.decodedTitle, 'Kya Bolti Tu');
      expect(epg.currentAt(now)!.decodedDescription, 'Tammy believes...');
      expect(epg.nextAt(now)!.decodedTitle, 'Kabadadaari');
    });

    test('generic "Movie" filler never hides a real programme', () {
      final raw = [
        _e('Kya Bolti Tu', _t(2, 25), _t(4, 0)),
        _e('Movie', _t(3, 0), _t(6, 0), desc: 'Bringing the best in cinema.'),
        _e('Kabadadaari', _t(4, 0), _t(6, 7)),
        _e('Movie', _t(6, 0), _t(9, 0)),
      ];
      final epg = EpgNormalizer.normalize(raw, now: now);
      final titles = epg.map((e) => e.decodedTitle).toList();
      expect(titles.take(2), ['Kya Bolti Tu', 'Kabadadaari']);
      expect(epg.currentAt(now)!.decodedTitle, 'Kya Bolti Tu');
      // Schedule never overlaps.
      for (var i = 1; i < epg.length; i++) {
        expect(
          epg[i].startTimestamp,
          greaterThanOrEqualTo(epg[i - 1].stopTimestamp),
        );
      }
    });

    test('a filler slot with no real programme is still shown', () {
      final raw = [_e('Movie', _t(3, 0), _t(6, 0))];
      final epg = EpgNormalizer.normalize(raw, now: now);
      expect(epg.currentAt(now)!.decodedTitle, 'Movie');
    });

    test('offset duplicate of the same programme is dropped', () {
      final raw = [
        _e('A Wednesday!', _t(3, 0), _t(4, 44)),
        _e('A Wednesday!', _t(3, 30), _t(5, 14)),
        _e('Kahani', _t(4, 44), _t(6, 0)),
      ];
      final epg = EpgNormalizer.normalize(raw, now: now);
      expect(epg.map((e) => e.decodedTitle), ['A Wednesday!', 'Kahani']);
    });

    test('no programme airing → null, not a stale one', () {
      final raw = [_e('Old', _t(1, 0), _t(2, 0))];
      final epg = EpgNormalizer.normalize(raw, now: now);
      expect(epg.currentAt(now), isNull);
    });
  });

  group('library file format', () {
    late Directory dir;
    setUpAll(() async {
      dir = await Directory.systemTemp.createTemp('lunar_lib_test');
    });
    tearDownAll(() async {
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    test('movies round-trip, including awkward characters', () async {
      final path = '${dir.path}/vod.lib';
      final movies = [
        for (var i = 0; i < 5000; i++)
          VodStream(
            num: '$i',
            name: i == 7 ? 'Line\nbreak\tand\u001fsep' : 'Movie $i',
            streamType: 'movie',
            streamId: '$i',
            streamIcon: i.isEven ? 'https://img/$i.jpg' : '',
            rating5based: '3.5',
            added: '170000$i',
            categoryId: '${i % 7}',
            containerExtension: 'mkv',
          ),
      ];
      await writeVodFile((path, movies));
      final sw = Stopwatch()..start();
      final back = readVodFile(path);
      // ignore: avoid_print
      print('readVodFile(5k) ${sw.elapsedMilliseconds} ms');
      expect(back, hasLength(5000));
      // Line breaks / separators become spaces; tabs are kept.
      expect(back[7].name, 'Line break\tand sep');
      expect(back[4999].categoryId, '${4999 % 7}');
      expect(back[1].streamIcon, '');
      expect(back[2].containerExtension, 'mkv');
      expect(identical(back[0].categoryId, back[7].categoryId), isTrue);
    });

    test('series round-trip maps empty fields to null', () async {
      final path = '${dir.path}/series.lib';
      await writeSeriesFile((
        path,
        [
          Series(seriesId: '1', name: 'Show', cover: 'http://c', categoryId: '9'),
        ],
      ));
      final s = readSeriesFile(path).single;
      expect(s.name, 'Show');
      expect(s.cover, 'http://c');
      expect(s.plot, isNull);
      expect(s.categoryId, '9');
    });

    test('a corrupt file is rejected (cache falls back to JSON)', () {
      final path = '${dir.path}/bad.lib';
      File(path).writeAsStringSync('{"not": "ours"}');
      expect(() => readVodFile(path), throwsFormatException);
    });
  });
}
