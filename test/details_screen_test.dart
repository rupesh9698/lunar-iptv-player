import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/movies_provider.dart';
import 'package:lunar_iptv_player/providers/series_provider.dart';
import 'package:lunar_iptv_player/screens/details/content_details_screen.dart';
import 'package:lunar_iptv_player/services/behavior_service.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

/// Netflix-style details pages: content from the Xtream API, Resume from
/// Continue Watching, and explicit D-pad navigation.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('lunar_details_test');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (_) async => dir.path,
        );
    await StorageService.instance.init();
    await BehaviorService.instance.init();
    // Movie 273474 watched to 10 min of 2h54; series episode S2E1 to 20 min.
    await BehaviorService.instance.savePosition(
      id: '273474',
      url: 'http://x/movie/273474.mp4',
      positionSeconds: 600,
      durationSeconds: 10444,
      type: 'movie',
      title: 'Salaar',
    );
    await BehaviorService.instance.savePosition(
      id: 'e21',
      url: 'http://x/series/e21.mkv',
      positionSeconds: 1200,
      durationSeconds: 3562,
      type: 'series',
      title: 'Farzi S2E1',
    );
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

  Widget app({
    required String path,
    required Object extra,
    List<Override> o = const [],
  }) {
    final router = GoRouter(
      initialLocation: path,
      initialExtra: extra,
      routes: [
        GoRoute(
          path: '/movie-details',
          builder: (_, s) => MovieDetailsScreen(movie: s.extra! as VodStream),
        ),
        GoRoute(
          path: '/series-details',
          builder: (_, s) => SeriesDetailsScreen(series: s.extra! as Series),
        ),
      ],
    );
    return ProviderScope(
      overrides: [xtreamServiceProvider.overrideWithValue(null), ...o],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  VodStream vod(String id, String name) => VodStream.fromJson({
    'stream_id': id,
    'name': name,
    'category_id': '166',
    'rating': '7.1',
  });

  testWidgets('movie: API details, Resume + Start Over, D-pad order', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    final movie = vod('273474', 'Salaar (2023)');
    await t.pumpWidget(
      app(
        path: '/movie-details',
        extra: movie,
        o: [
          vodInfoProvider.overrideWith(
            (ref, id) async => VodInfo.fromJson({
              'info': {
                'name': 'Salaar: Part 1 – Ceasefire',
                'releasedate': '2023-12-21',
                'genre': 'Action, Crime, Thriller',
                'plot': 'In the city of Khansaar…',
                'cast': 'Prabhas, Prithviraj Sukumaran',
                'director': 'Prashanth Neel',
                'duration_secs': 10444,
                'rating': '6.9',
                'video': {'height': 1080, 'codec_name': 'h264'},
                'audio': {
                  'channels': 2,
                  'tags': {'language': 'kan'},
                },
              },
              'movie_data': {'stream_id': 273474, 'container_extension': 'mp4'},
            }),
          ),
          vodAllStreamsProvider.overrideWith(
            (ref) async => [movie, vod('2', 'KGF'), vod('3', 'RRR')],
          ),
        ],
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('Salaar: Part 1 – Ceasefire'), findsOneWidget);
    expect(find.text('Resume'), findsOneWidget);
    expect(find.text('Start Over'), findsOneWidget);
    expect(find.text('1080p'), findsOneWidget);
    expect(find.text('Kannada'), findsWidgets); // badge + About
    expect(find.text('2h 54m'), findsOneWidget);

    // Buttons: Resume, Start Over, Favourite (no server → no Download).
    expect(focused(), 'detailsAction0', reason: 'Resume has initial focus');
    await key(t, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'detailsAction1');
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'detailsAction0');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'detailsAction1', reason: 'Down walks the buttons');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'detailsAction2');
    await key(t, LogicalKeyboardKey.arrowDown);
    await t.pumpAndSettle();
    expect(focused(), 'detailsSimilar0', reason: 'scrolls past About to it');
    expect(find.text('More Like This'), findsOneWidget);
    expect(find.text('KGF'), findsOneWidget);
    await key(t, LogicalKeyboardKey.arrowRight);
    expect(focused(), 'detailsSimilar1');
    await key(t, LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    expect(focused(), 'detailsAction2', reason: 'back to the last button');
    await key(t, LogicalKeyboardKey.arrowUp);
    await key(t, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'detailsAction0');
    await key(t, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'detailsBack');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'detailsAction0');
  });

  testWidgets('series: resumes the right season; seasons ⇄ episodes', (
    t,
  ) async {
    t.view.physicalSize = const Size(1280, 720);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);

    Map<String, dynamic> ep(String id, int n, int season) => {
      'id': id,
      'episode_num': n,
      'title': 'Farzi - S0${season}E0$n - S$season Chapter $n',
      'container_extension': 'mkv',
      'season': season,
      'info': {'duration': '00:59:22', 'plot': 'Episode $n plot'},
    };
    final series = Series.fromJson({
      'series_id': '4274',
      'name': 'Farzi',
      'category_id': '108',
    });
    await t.pumpWidget(
      app(
        path: '/series-details',
        extra: series,
        o: [
          seriesInfoProvider.overrideWith(
            (ref, id) async => SeriesInfo.fromJson({
              'seasons': [
                {'season_number': 1, 'name': 'Season 1', 'overview': 'S1'},
                {'season_number': 2, 'name': 'Season 2', 'overview': 'S2'},
              ],
              'info': {'name': 'Farzi', 'plot': 'Sunny, an artist…'},
              'episodes': {
                '1': [ep('e11', 1, 1), ep('e12', 2, 1)],
                '2': [ep('e21', 1, 2), ep('e22', 2, 2), ep('e23', 3, 2)],
              },
            }),
          ),
          seriesAllListProvider.overrideWith((ref) async => [series]),
        ],
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('Resume S2:E1'), findsOneWidget);
    expect(find.text('From S1:E1'), findsOneWidget);
    // Opened on the season being watched.
    expect(find.text('S2 Chapter 1', skipOffstage: false), findsOneWidget);
    expect(find.text('Episode 1 plot', skipOffstage: false), findsOneWidget);

    // Buttons: Resume S2:E1, From S1:E1, Favourite.
    expect(focused(), 'detailsAction0');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'detailsAction1');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'detailsAction2');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'season2', reason: 'Down lands on the selected season');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'episode0');
    await key(t, LogicalKeyboardKey.arrowDown);
    expect(focused(), 'episode1');
    await key(t, LogicalKeyboardKey.arrowUp);
    await key(t, LogicalKeyboardKey.arrowUp);
    expect(focused(), 'season2');
    await key(t, LogicalKeyboardKey.arrowLeft);
    expect(focused(), 'season1');
    await key(t, LogicalKeyboardKey.select);
    await t.pumpAndSettle();
    expect(find.text('S2 Chapter 1'), findsNothing);
    expect(find.text('S1 Chapter 1'), findsOneWidget, reason: 'season 1');
    await key(t, LogicalKeyboardKey.arrowUp);
    await t.pumpAndSettle();
    expect(focused(), 'detailsAction2');
  });

  testWidgets('phone layout renders without overflow', (t) async {
    t.view.physicalSize = const Size(390, 844);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final movie = vod('9', 'Some Movie');
    await t.pumpWidget(
      app(
        path: '/movie-details',
        extra: movie,
        o: [
          vodInfoProvider.overrideWith(
            (ref, id) async => VodInfo.fromJson({
              'info': {'name': 'Some Movie', 'plot': 'Plot', 'rating': '5'},
            }),
          ),
          vodAllStreamsProvider.overrideWith((ref) async => [movie]),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(find.text('Play'), findsOneWidget);
    expect(find.text('Favourite'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('phone landscape: title stays below the Back button', (t) async {
    t.view.physicalSize = const Size(915, 412);
    t.view.devicePixelRatio = 1.0;
    // Landscape phone: camera / nav-bar inset on the left.
    t.view.padding = const FakeViewPadding(left: 48);
    t.view.viewPadding = const FakeViewPadding(left: 48);
    addTearDown(t.view.reset);
    final movie = vod('11', 'server101 Chitralahari (2019)');
    await t.pumpWidget(
      app(
        path: '/movie-details',
        extra: movie,
        o: [
          vodInfoProvider.overrideWith(
            (ref, id) async => VodInfo.fromJson({
              'info': {
                'name': 'server101 Chitralahari (2019)',
                'releasedate': '2019-04-12',
                'genre': 'Drama, Romance',
                'rating': '6.8',
                'duration_secs': 7140,
                'plot':
                    'Vijay is a down-on-luck mechanical engineer who is '
                    'looking for that big break in life. Both his personal '
                    'and professional lives are a mess; will he ever catch '
                    'a break?',
                'video': {'height': 720},
              },
            }),
          ),
          vodAllStreamsProvider.overrideWith((ref) async => [movie]),
        ],
      ),
    );
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    final back = t.getRect(find.byIcon(Icons.arrow_back_rounded));
    final title = t.getRect(find.text('server101 Chitralahari (2019)').first);
    expect(
      title.top,
      greaterThanOrEqualTo(back.bottom),
      reason: 'title must not run up under the Back button',
    );
    expect(
      back.left,
      lessThan(title.left),
      reason: 'Back sits at the left edge, not pushed in by the inset',
    );
    // The poster card shows on phones too (no artwork → its placeholder).
    final poster = t.getRect(find.byIcon(Icons.movie_outlined).first);
    expect(poster.left, greaterThan(915 / 2));
    // Buttons are sized to their labels, not stretched across the row.
    final play = t.getRect(
      find.ancestor(
        of: find.text('Play'),
        matching: find.byType(IntrinsicWidth),
      ),
    );
    expect(play.width, lessThan(400));
  });
}
