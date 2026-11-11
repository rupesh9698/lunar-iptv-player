import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/core/utils/track_labels.dart';
import 'package:lunar_iptv_player/screens/player/widgets/player_loading_ring.dart';

void main() {
  group('language names', () {
    test('2- and 3-letter codes, tags and full names', () {
      expect(languageName('hin'), 'Hindi');
      expect(languageName('en'), 'English');
      expect(languageName('ENG'), 'English');
      expect(languageName('fra'), 'French');
      expect(languageName('fre'), 'French');
      expect(languageName('ger'), 'German');
      expect(languageName('pt-BR'), 'Portuguese (Brazil)');
      expect(languageName('es-419'), 'Spanish (Latin America)');
      expect(languageName('english'), 'English');
      expect(languageName('und'), isNull);
      expect(languageName(''), isNull);
      expect(languageName(null), isNull);
      expect(languageName('xyz'), 'XYZ');
    });
  });

  group('track labels', () {
    List<String> names(List<TrackInfo> t, {bool audio = true}) =>
        describeTracks(t, audio: audio).map((l) => l.name).toList();

    test('no info → numbered, not bare ids', () {
      final l = describeTracks(const [
        TrackInfo('auto'),
        TrackInfo('1'),
        TrackInfo('2', title: 'SoundHandler'),
        TrackInfo('3', title: 'Track 3', language: 'und'),
      ], audio: true);
      expect(l.map((e) => e.name), ['Auto', 'Audio 1', 'Audio 2', 'Audio 3']);
    });

    test('language, title and details', () {
      final l = describeTracks(const [
        TrackInfo(
          '1',
          language: 'hin',
          codec: 'eac3',
          channelsCount: 6,
          isDefault: true,
        ),
        TrackInfo('2', language: 'eng', title: 'Commentary', codec: 'aac'),
        TrackInfo('3', language: 'tam', title: 'Tamil [Original]'),
        TrackInfo('4', title: 'Telugu'),
        TrackInfo('5', title: 'tel'),
        TrackInfo('6', language: 'en', title: 'en', channelsCount: 2),
      ], audio: true);
      expect(l[0].name, 'Hindi');
      expect(l[0].detail, 'Dolby Digital+ · 5.1 · Default');
      expect(l[1].name, 'English');
      expect(l[1].detail, 'Commentary · AAC');
      expect(l[2].name, 'Tamil [Original]');
      expect(l[3].name, 'Telugu');
      expect(l[4].name, 'Telugu (2)'); // same as the one above
      expect(l[5].name, 'English');
      expect(l[5].detail, 'Stereo');
    });

    test('subtitles: Off, codecs, duplicates told apart', () {
      final l = describeTracks(const [
        TrackInfo('auto'),
        TrackInfo('no'),
        TrackInfo('1', language: 'eng', codec: 'subrip'),
        TrackInfo('2', language: 'eng', codec: 'subrip'),
        TrackInfo('3', language: 'eng', title: 'English (SDH)'),
      ], audio: false);
      expect(l.map((e) => e.name), [
        'Auto',
        'Off',
        'English',
        'English (2)',
        'English (SDH)',
      ]);
      expect(l[2].detail, 'SRT');
      expect(names(const [TrackInfo('1')], audio: false), ['Subtitle 1']);
    });
  });

  group('loading ring percentage', () {
    Future<StreamController<double>> pumpRing(
      WidgetTester t, {
      bool below = false,
    }) async {
      final c = StreamController<double>.broadcast();
      addTearDown(c.close);
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: PlayerLoadingRing(
                percent: c.stream,
                initialPercent: 12,
                percentBelow: below,
              ),
            ),
          ),
        ),
      );
      return c;
    }

    testWidgets('number in the middle of the ring, updates', (t) async {
      final c = await pumpRing(t);
      expect(find.text('12%'), findsOneWidget);
      final ring = find.byType(CircularProgressIndicator);
      expect(t.getCenter(find.text('12%')), t.getCenter(ring));
      c.add(57.6);
      await t.pump();
      expect(find.text('57%'), findsOneWidget);
    });

    testWidgets('under the ring when the play button is in the middle', (
      t,
    ) async {
      await pumpRing(t, below: true);
      final ring = t.getRect(find.byType(CircularProgressIndicator));
      final text = t.getRect(find.text('12%'));
      expect(text.top, greaterThan(ring.bottom));
      expect(text.center.dx, closeTo(ring.center.dx, 0.5));
    });
  });
}
