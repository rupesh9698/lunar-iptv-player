import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/services/xmltv_epg_service.dart';

const _xml = '''<?xml version="1.0" encoding="UTF-8"?>
<tv generator-info-name="test">
  <channel id="Sony.Max.SD.in">
    <display-name lang="en">Sony Max SD</display-name>
    <icon src="http://x/y.png" />
  </channel>
  <channel id="SONY.MAX.in"><display-name lang="en">SONY MAX</display-name></channel>
  <programme start="20261110180000 +0530" stop="20261110210000 +0530" channel="Sony.Max.SD.in">
    <title lang="hi-IN">Tom &amp; Jerry: The Movie</title>
    <sub-title lang="hi-IN">A cat &lt;and&gt; a mouse</sub-title>
  </programme>
  <programme channel="SONY.MAX.in" start="20261110180000 +0530" stop="20261110210000 +0530"><title lang="en">Movie</title><desc lang="en">Bringing the best in cinema.</desc></programme>
  <programme start="20261110210000 +0530" stop="20261110230000 +0530" channel="Sony.Max.SD.in"/>
</tv>''';

void main() {
  group('XmltvParser', () {
    test('parses channels and programmes in any attribute order', () {
      final chans = <String, List<String>>{};
      final progs = <List<Object>>[];
      XmltvParser.parseString(
        _xml,
        onChannel: (id, names) => chans[id] = names,
        onProgramme: (c, s, e, t, d) => progs.add([c, s, e, t, d]),
      );
      expect(chans, {
        'Sony.Max.SD.in': ['Sony Max SD'],
        'SONY.MAX.in': ['SONY MAX'],
      });
      expect(progs, hasLength(2)); // the self-closing one has no title
      expect(progs[0][3], 'Tom & Jerry: The Movie');
      expect(progs[0][4], 'A cat <and> a mouse'); // sub-title as fallback
      expect(progs[1][0], 'SONY.MAX.in');
      expect(progs[1][4], 'Bringing the best in cinema.');
      // 18:00 IST = 12:30 UTC
      expect(
        progs[0][1],
        DateTime.utc(2026, 11, 10, 12, 30).millisecondsSinceEpoch ~/ 1000,
      );
    });

    test('streams gzip input split at arbitrary chunk boundaries', () async {
      final gz = gzip.encode(utf8.encode(_xml));
      Stream<List<int>> chunks() async* {
        for (var i = 0; i < gz.length; i += 7) {
          yield gz.sublist(i, i + 7 > gz.length ? gz.length : i + 7);
        }
      }

      final titles = <String>[];
      await XmltvParser.parseBytes(
        chunks(),
        onChannel: (_, _) {},
        onProgramme: (c, s, e, t, d) => titles.add(t),
      );
      expect(titles, ['Tom & Jerry: The Movie', 'Movie']);
    });

    test('time zones', () {
      expect(
        XmltvParser.parseTime('20261110000000 +0000'),
        DateTime.utc(2026, 11, 10).millisecondsSinceEpoch ~/ 1000,
      );
      expect(
        XmltvParser.parseTime('20261110000000 -0500'),
        DateTime.utc(2026, 11, 10, 5).millisecondsSinceEpoch ~/ 1000,
      );
      expect(XmltvParser.parseTime('bogus'), isNull);
    });
  });

  group('XmltvMatcher', () {
    test('normalises provider and guide names', () {
      expect(XmltvMatcher.nameKey('IN: SONY MAX (FHD)'), 'sonymax');
      expect(XmltvMatcher.nameKey('Sony Max HD'), 'sonymax');
      expect(XmltvMatcher.nameKey('MAL | ASIANET NEWS ᴴᴰ'), 'asianetnews');
      expect(XmltvMatcher.nameKey('IN:  Aaj_Tak'), 'aajtak');
      expect(XmltvMatcher.nameKey('IN: STAR GOLD 2 (4K)'), 'stargold2');
      expect(XmltvMatcher.idKey('Sony.Max.SD.in'), 'sonymax');
      expect(XmltvMatcher.idKey('sonymaxhd.in'), 'sonymax');
    });

    test('matches by exact id, normalised id and name', () {
      final m = XmltvMatcher(
        ['IN: SONY MAX HD', 'IN: SONY MAX 2', 'UK: BBC One', 'Random'],
        ['sonymaxhd.in', '', 'bbc1.uk', 'Sony.Max.SD.in'],
      );
      final hits = m.match('Sony.Max.SD.in', ['Sony Max SD']);
      expect(hits[0], 2); // normalised id / name
      expect(hits[3], 3); // exact epg id
      expect(hits.containsKey(1), isFalse); // "Sony Max 2" is another channel
      expect(m.match('BBC.One.uk', ['BBC One HD']).keys, [2]);
    });

    test('filler titles', () {
      expect(XmltvMatcher.isFiller('Movie'), isTrue);
      expect(XmltvMatcher.isFiller('Sholay'), isFalse);
    });
  });

  test('service: download → match → disk → reload', () async {
    // Guide served over local HTTP, times around "now".
    String t(int offsetMin) {
      final d = DateTime.now().toUtc().add(Duration(minutes: offsetMin));
      String two(int v) => v.toString().padLeft(2, '0');
      return '${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}'
          '${two(d.minute)}00 +0000';
    }

    final guide =
        '''<tv>
<channel id="Sony.Max.SD.in"><display-name>Sony Max SD</display-name></channel>
<channel id="SONY.MAX.in"><display-name>SONY MAX</display-name></channel>
<channel id="Other.in"><display-name>Other</display-name></channel>
<programme channel="SONY.MAX.in" start="${t(-30)}" stop="${t(90)}"><title>Movie</title></programme>
<programme channel="Sony.Max.SD.in" start="${t(-30)}" stop="${t(90)}"><title>Sholay</title><desc>Classic</desc></programme>
<programme channel="Sony.Max.SD.in" start="${t(-2000)}" stop="${t(-1900)}"><title>Old</title></programme>
<programme channel="Other.in" start="${t(-30)}" stop="${t(90)}"><title>Unmatched</title></programme>
</tv>''';
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((req) {
      req.response
        ..headers.contentType = ContentType.binary
        ..add(gzip.encode(utf8.encode(guide)))
        ..close();
    });
    final dir = await Directory.systemTemp.createTemp('xmltv_test');
    final svc = XmltvEpgService.instance
      ..testDirectory = dir
      ..testSources = ['http://127.0.0.1:${server.port}/guide.xml.gz'];
    addTearDown(() async {
      svc
        ..testDirectory = null
        ..testSources = null;
      await server.close(force: true);
      await dir.delete(recursive: true);
    });

    Future<List<XmltvChannelRef>> channels() async => const [
      XmltvChannelRef('101', 'IN: SONY MAX HD', 'sonymaxhd.in'),
      XmltvChannelRef('102', 'IN: SONY MAX (FHD)', 'SONY.MAX.in'),
      XmltvChannelRef('103', 'IN: COLORS', null),
    ];

    // Nothing on disk yet → null now, download in the background.
    final first = svc.updates.firstWhere((i) => i != null);
    expect(await svc.index(playlistId: 'p1', channels: channels), isNull);
    final idx = (await first)!;
    // Both Sony Max streams use the guide channel with real titles, even
    // though 102's EPG id points at the filler-only one.
    expect(idx.listingsFor('101')!.map((e) => e.decodedTitle), ['Sholay']);
    expect(idx.listingsFor('102')!.single.decodedDescription, 'Classic');
    expect(idx.listingsFor('103'), isNull);
    expect(File('${dir.path}/p1_xmltv.json').existsSync(), isTrue);

    // Read back from disk (fresh memory state).
    svc.resetMemory();
    final again = await svc.index(playlistId: 'p1', channels: channels);
    expect(again!.listingsFor('101')!.single.decodedTitle, 'Sholay');
  });

  test('plain listings survive normalisation (no base64 decoding)', () {
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final list = EpgNormalizer.normalize([
      EpgListing.plain(
        title: 'Nela', // also valid base64 — must not be decoded
        description: 'An orphan boy',
        startTimestamp: now - 600,
        stopTimestamp: now + 600,
      ),
      EpgListing.plain(
        title: 'Next',
        description: '',
        startTimestamp: now + 300, // overlaps → trimmed copy
        stopTimestamp: now + 3600,
      ),
    ]);
    expect(list.map((e) => e.decodedTitle), ['Nela', 'Next']);
    expect(list[0].decodedDescription, 'An orphan boy');
  });
}
