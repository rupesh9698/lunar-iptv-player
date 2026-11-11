import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/epg_timeline.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/live_category_sidebar.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

/// Search boxes opened with the TV remote: the field gets focus (and the
/// keyboard) instead of staying on the search button.
class _FakeEpg extends EpgCacheNotifier {
  _FakeEpg(super.ref) {
    state = const {};
  }

  @override
  Future<void> loadEpg(String streamId, {bool force = false}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lunar_search_test');
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

  String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

  Future<void> settle(WidgetTester t) async {
    for (var i = 0; i < 8; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
  }

  Future<void> key(WidgetTester t, LogicalKeyboardKey k) async {
    await t.sendKeyEvent(k);
    await settle(t);
  }

  final streams = [
    for (var i = 0; i < 5; i++)
      LiveStream.fromJson({'stream_id': '$i', 'name': 'Channel $i'}),
  ];

  testWidgets('EPG: OK on search opens it, focuses the field, keyboard up', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final search = FocusNode(debugLabel: 'epgSearchBtn');
    addTearDown(search.dispose);

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          filteredLiveStreamsProvider.overrideWithValue(
            AsyncValue.data(streams),
          ),
          epgCacheProvider.overrideWith((ref) => _FakeEpg(ref)),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: EpgTimeline(
              isFullscreen: false,
              onToggleFullscreen: () {},
              searchFocusNode: search,
            ),
          ),
        ),
      ),
    );
    await settle(t);
    search.requestFocus();
    await settle(t);
    expect(focused(), 'epgSearchBtn');

    await key(t, LogicalKeyboardKey.select);
    expect(focused(), 'channelSearchField');
    expect(t.testTextInput.isVisible, isTrue, reason: 'keyboard shown');
    expect(find.text('Search channels...'), findsOneWidget);

    // Typing filters; the field keeps focus.
    await t.enterText(find.byType(TextField), 'abc');
    await settle(t);
    expect(focused(), 'channelSearchField');

    await t.pumpWidget(const SizedBox());
  });

  testWidgets('Live categories: OK opens search into the field; Up → button '
      '→ Down returns to the field (not All Channels)', (t) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
    final search = FocusNode(debugLabel: 'catSearchBtn');
    addTearDown(search.dispose);

    await t.pumpWidget(
      ProviderScope(
        overrides: [
          smartLiveCategoriesProvider.overrideWith(
            (ref) async => [
              for (var i = 0; i < 4; i++)
                XtreamCategory.fromJson({
                  'category_id': '$i',
                  'category_name': 'Cat $i',
                }),
            ],
          ),
          liveAllStreamsProvider.overrideWith((ref) async => streams),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                LiveCategorySidebar(width: 260, searchFocusNode: search),
              ],
            ),
          ),
        ),
      ),
    );
    await settle(t);
    search.requestFocus();
    await settle(t);
    expect(focused(), 'catSearchBtn');

    await key(t, LogicalKeyboardKey.select);
    expect(focused(), 'categorySearchField');
    expect(t.testTextInput.isVisible, isTrue, reason: 'keyboard shown');

    await key(t, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'catSearchBtn');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'categorySearchField');

    await t.pumpWidget(const SizedBox());
  });
}
