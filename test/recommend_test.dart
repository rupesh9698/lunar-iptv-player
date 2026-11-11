import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/core/utils/recommend.dart';

void main() {
  test('title words and years', () {
    expect(titleTokens('EN | Avengers: Endgame (2019) [4K]'), {
      'avengers',
      'endgame',
    });
    expect(titleTokens('The Dark Knight 1080p HEVC'), {'dark', 'knight'});
    expect(titleYear('Avengers: Endgame (2019)'), 2019);
    expect(titleYear('Blade Runner 2049'), isNull);
    expect(splitGenres('Action, Sci-Fi / Drama'), {
      'action',
      'sci-fi',
      'drama',
    });
  });

  group('more like this', () {
    final items = [
      RecItem(id: '1', name: 'Avengers: Endgame (2019)', categoryId: 'a'),
      RecItem(id: '2', name: 'Avengers: Infinity War (2018)', categoryId: 'b'),
      RecItem(
        id: '3',
        name: 'Random Comedy (2019)',
        categoryId: 'a',
        rating: 9,
      ),
      RecItem(id: '4', name: 'Unrelated Drama', categoryId: 'c', rating: 10),
      RecItem(id: '5', name: 'Old Film (1960)', categoryId: 'a', rating: 2),
    ];

    test('franchise first, even from another category; no unrelated', () {
      final r = moreLikeThis(items.first, items).map((e) => e.id).toList();
      expect(r.first, '2');
      expect(r, contains('3'));
      expect(r, isNot(contains('1')), reason: 'not itself');
      expect(r, isNot(contains('4')), reason: 'nothing in common');
      expect(r.indexOf('3'), lessThan(r.indexOf('5')), reason: 'year, rating');
    });

    test('series: shared genres count across categories', () {
      final shows = [
        RecItem(
          id: 's1',
          name: 'Dark',
          categoryId: 'x',
          genres: {'sci-fi', 'mystery'},
        ),
        RecItem(
          id: 's2',
          name: 'Stranger Things',
          categoryId: 'y',
          genres: {'sci-fi', 'mystery'},
        ),
        RecItem(
          id: 's3',
          name: 'Cooking Show',
          categoryId: 'z',
          genres: {'food'},
        ),
      ];
      final r = moreLikeThis(shows.first, shows).map((e) => e.id).toList();
      expect(r, ['s2']);
    });
  });

  group('recommended for you', () {
    final now = DateTime(2026, 11, 12).millisecondsSinceEpoch ~/ 1000;
    final lib = [
      for (var i = 0; i < 20; i++)
        RecItem(
          id: 'act$i',
          name: 'Action Movie $i',
          categoryId: 'action',
          rating: 6 + (i % 4).toDouble(),
        ),
      for (var i = 0; i < 20; i++)
        RecItem(
          id: 'rom$i',
          name: 'Love Story $i',
          categoryId: 'romance',
          rating: 9.5,
        ),
      RecItem(id: 'mi1', name: 'Mission Impossible', categoryId: 'thriller'),
      RecItem(id: 'mi2', name: 'Mission Impossible Fallout', categoryId: 'old'),
    ];
    final byId = {for (final x in lib) x.id: x};

    test('follows what was watched, never repeats it, stays varied', () {
      final taste = TasteProfile.build([
        const TasteSignal('act0', 3),
        const TasteSignal('act1', 2),
        const TasteSignal('mi1', 2),
      ], byId);
      final r = recommendFor(taste, lib, max: 10, perCategory: 6, nowSecs: now);
      final ids = r.map((e) => e.id).toList();
      expect(ids, isNot(contains('act0')));
      expect(ids, isNot(contains('mi1')));
      expect(ids, contains('mi2'), reason: 'same franchise');
      expect(ids.where((i) => i.startsWith('act')).length, 6, reason: 'cap');
      // Action (watched) beats higher rated romance (not watched).
      expect(
        ids.indexWhere((i) => i.startsWith('act')),
        lessThan(ids.indexWhere((i) => i.startsWith('rom'))),
      );
    });

    test('genre taste matches category names', () {
      final taste = TasteProfile.build(
        const [],
        byId,
        genreCounts: const [MapEntry('Romance', 5)],
      );
      final r = recommendFor(
        taste,
        lib,
        max: 5,
        categoryNames: const {'romance': 'Romance Movies', 'action': 'Action'},
        nowSecs: now,
      );
      expect(r.every((e) => e.categoryId == 'romance'), isTrue);
    });

    test('no history: best rated', () {
      final r = recommendFor(const TasteProfile(), lib, max: 3, nowSecs: now);
      expect(r.every((e) => e.rating == 9.5), isTrue);
    });
  });
}
