import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/screens/player/widgets/player_channel_guide.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

/// The TV Guide strip in the full-screen Live TV player.
class _FakeEpg extends EpgCacheNotifier {
  _FakeEpg(super.ref, Map<String, List<EpgListing>> data) {
    state = data;
  }

  @override
  Future<void> loadEpg(String streamId, {bool force = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lunar_guide_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
    await StorageService.instance.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
  });

  Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
    await t.sendKeyEvent(k);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('now/next with progress; focused channel centred', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final now = DateTime.now();
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    final streams = [
      for (var i = 0; i < 40; i++)
        LiveStream.fromJson({'stream_id': '$i', 'name': 'Channel $i'}),
    ];
    final epg = {
      for (final s in streams)
        s.streamId: [
          EpgListing.plain(
            title: 'Show ${s.streamId}',
            description: 'About show ${s.streamId}',
            startTimestamp: ts(now.subtract(const Duration(minutes: 30))),
            stopTimestamp: ts(now.add(const Duration(minutes: 90))),
          ),
          EpgListing.plain(
            title: 'Next ${s.streamId}',
            description: '',
            startTimestamp: ts(now.add(const Duration(minutes: 90))),
            stopTimestamp: ts(now.add(const Duration(minutes: 150))),
          ),
          EpgListing.plain(
            title: 'Later ${s.streamId}',
            description: '',
            startTimestamp: ts(now.add(const Duration(minutes: 150))),
            stopTimestamp: ts(now.add(const Duration(minutes: 200))),
          ),
        ],
    };

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          filteredLiveStreamsProvider.overrideWithValue(
            AsyncValue.data(streams),
          ),
          epgCacheProvider.overrideWith((ref) => _FakeEpg(ref, epg)),
          selectedChannelProvider.overrideWith((ref) => streams[20]),
          xtreamServiceProvider.overrideWithValue(null),
        ],
        child: MaterialApp(
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Stack(
              children: [
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: PlayerChannelGuide(onMinimize: () {}, onClose: () {}),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 4; i++) {
      await t.pump(const Duration(milliseconds: 150));
    }

    // No "TV Guide" button and no channel-name line above the strip.
    expect(find.text('TV Guide'), findsNothing);
    expect(find.text('Channel 20'), findsOneWidget, reason: 'strip only');

    // The playing channel's show with its progress and what's next.
    expect(find.text('WATCHING'), findsOneWidget);
    expect(find.text('Show 20'), findsOneWidget);
    expect(find.text('About show 20'), findsOneWidget);
    expect(find.text('1h 30m left'), findsOneWidget);
    expect(find.text('30m in · '), findsOneWidget);
    expect(find.text('NEXT'), findsOneWidget);
    expect(find.text('Next 20'), findsOneWidget);
    expect(find.text('Later 20'), findsOneWidget);

    // The focused channel sits in the middle of the strip.
    double centreOf(String name) => t.getCenter(find.text(name)).dx;
    expect((centreOf('Channel 20') - 640).abs(), lessThan(4));

    // Browsing: the focus stays centred and the info follows it.
    await key(t, LogicalKeyboardKey.arrowRight);
    expect((centreOf('Channel 21') - 640).abs(), lessThan(4));
    expect(find.text('ON NOW'), findsOneWidget);
    expect(find.text('Show 21'), findsOneWidget);

    // At the start of the list it can't centre: it rests at the left.
    for (var i = 0; i < 25; i++) {
      await key(t, LogicalKeyboardKey.arrowLeft);
    }
    expect(centreOf('Channel 0'), lessThan(200));
    expect(find.text('Show 0'), findsOneWidget);

    await t.pumpWidget(const SizedBox());
  });
}
