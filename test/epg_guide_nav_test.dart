import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/epg_timeline.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

/// EPG guide on the remote: channel → heart → programmes, the programme
/// cursor scrolls the list, and the highlighted show stays fully visible.
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
    dir = await Directory.systemTemp.createTemp('lunar_epg_test');
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

  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
    await t.sendKeyEvent(k);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));
  }

  // Fixed pumps: the guide has periodic work, so pumpAndSettle may never
  // settle.
  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 12; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  testWidgets('channel → heart → guide; cursor scrolls; ring fully visible', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final now = DateTime.now();
    int ts(DateTime d) => d.millisecondsSinceEpoch ~/ 1000;
    final streams = [
      for (var i = 0; i < 30; i++)
        LiveStream.fromJson({
          'stream_id': '$i',
          'name': 'Channel $i',
          'num': '${i + 1}',
        }),
    ];
    // Every channel: a show that began 3 h ago (before the guide's window,
    // so it starts left of the visible part) and the next one.
    final epg = {
      for (final s in streams)
        s.streamId: [
          EpgListing.plain(
            title: 'Now ${s.streamId}',
            description: '',
            startTimestamp: ts(now.subtract(const Duration(hours: 3))),
            stopTimestamp: ts(now.add(const Duration(minutes: 40))),
          ),
          EpgListing.plain(
            title: 'Next ${s.streamId}',
            description: '',
            startTimestamp: ts(now.add(const Duration(minutes: 40))),
            stopTimestamp: ts(now.add(const Duration(hours: 2))),
          ),
        ],
    };

    FocusNode? first;
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          filteredLiveStreamsProvider.overrideWithValue(
            AsyncValue.data(streams),
          ),
          epgCacheProvider.overrideWith((ref) => _FakeEpg(ref, epg)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpgTimeline(
              isFullscreen: false,
              onToggleFullscreen: () {},
              onFirstItemFocusReady: (n) => first = n,
            ),
          ),
        ),
      ),
    );
    await settle(t);
    first!.requestFocus();
    await settle(t);
    expect(focused(), 'epgChannel0');

    // Right: the favourite heart is a stop, then the programmes.
    await key(t, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'epgHeart0');
    await key(t, LogicalKeyboardKey.arrowRight);
    await settle(t);
    expect(focused(), 'epgProg0');

    // The highlighted show began before the visible part of the timeline:
    // its ring and title must start right of the channel column, not
    // under it.
    final column = t.getRect(find.text('Channel 0')).right;
    final title = t.getRect(find.text('Now 0'));
    expect(title.left, greaterThan(column));

    // Down walks the rows and the list follows.
    for (var i = 0; i < 15; i++) {
      await key(t, LogicalKeyboardKey.arrowDown);
    }
    await settle(t);
    expect(focused(), 'epgProg15');
    final row15 = t.getRect(find.text('Now 15'));
    expect(row15.bottom, lessThanOrEqualTo(720));
    expect(row15.top, greaterThan(0));
    final ch15 = t.getRect(find.text('Channel 15'));
    expect(
      (ch15.center.dy - row15.center.dy).abs(),
      lessThan(30),
      reason: 'channel column scrolls with the guide',
    );

    // Left on the live show: back to the heart, then the channel.
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'epgHeart15');
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'epgChannel15');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
