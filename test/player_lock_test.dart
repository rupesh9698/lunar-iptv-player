import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:lunar_iptv_player/core/utils/platform_utils.dart';
import 'package:lunar_iptv_player/models/xtream_models.dart';
import 'package:lunar_iptv_player/providers/app_providers.dart';
import 'package:lunar_iptv_player/providers/live_tv_provider.dart';
import 'package:lunar_iptv_player/screens/live_tv/widgets/live_preview_area.dart';
import 'package:lunar_iptv_player/screens/player/widgets/player_lock_overlay.dart';
import 'package:lunar_iptv_player/services/storage_service.dart';

class _FakeEpg extends EpgCacheNotifier {
  _FakeEpg(super.ref) {
    state = const {};
  }

  @override
  Future<void> loadEpg(String streamId, {bool force = false}) async {}
}

KeyDownEvent _down(LogicalKeyboardKey k) => KeyDownEvent(
  physicalKey: PhysicalKeyboardKey.keyA,
  logicalKey: k,
  timeStamp: Duration.zero,
);

void main() {
  group('keys while locked', () {
    LockedKeyAction act(KeyEvent e, LockUnlockStyle s) =>
        PlayerLockOverlay.keyAction(e, s);

    test('TV: only Back unlocks, everything else shows the hint', () {
      const tv = LockUnlockStyle.tv;
      expect(act(_down(LogicalKeyboardKey.goBack), tv), LockedKeyAction.unlock);
      expect(act(_down(LogicalKeyboardKey.select), tv), LockedKeyAction.hint);
      expect(
        act(_down(LogicalKeyboardKey.arrowRight), tv),
        LockedKeyAction.hint,
      );
      expect(
        act(_down(LogicalKeyboardKey.mediaPlayPause), tv),
        LockedKeyAction.hint,
      );
      // The remote's volume keys keep working.
      expect(
        act(_down(LogicalKeyboardKey.audioVolumeUp), tv),
        LockedKeyAction.pass,
      );
      // A held Back doesn't unlock again (and then leave).
      expect(
        act(
          const KeyRepeatEvent(
            physicalKey: PhysicalKeyboardKey.escape,
            logicalKey: LogicalKeyboardKey.goBack,
            timeStamp: Duration.zero,
          ),
          tv,
        ),
        LockedKeyAction.hint,
      );
    });

    test('desktop: Esc unlocks; phones: Back only hints', () {
      expect(
        act(_down(LogicalKeyboardKey.escape), LockUnlockStyle.desktop),
        LockedKeyAction.unlock,
      );
      expect(
        act(_down(LogicalKeyboardKey.space), LockUnlockStyle.desktop),
        LockedKeyAction.hint,
      );
      expect(
        act(_down(LogicalKeyboardKey.goBack), LockUnlockStyle.touch),
        LockedKeyAction.hint,
      );
      expect(PlayerLockOverlay.backUnlocks(LockUnlockStyle.touch), isFalse);
      expect(PlayerLockOverlay.backUnlocks(LockUnlockStyle.tv), isTrue);
    });
  });

  group('lock overlay', () {
    Future<int> pumpOverlay(WidgetTester t, LockUnlockStyle style) async {
      var unlocked = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerLockOverlay(style: style, onUnlock: () => unlocked++),
          ),
        ),
      );
      return unlocked;
    }

    double opacityOf(WidgetTester t, Finder f) => t
        .widget<AnimatedOpacity>(
          find.ancestor(of: f, matching: find.byType(AnimatedOpacity)).first,
        )
        .opacity;

    testWidgets('phone: tap anywhere shows the hint, the lock unlocks', (
      t,
    ) async {
      var unlocked = 0;
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: PlayerLockOverlay(
              style: LockUnlockStyle.touch,
              onUnlock: () => unlocked++,
            ),
          ),
        ),
      );
      final hint = find.text('Screen locked · tap the lock to unlock');
      expect(opacityOf(t, hint), 1, reason: 'shown when locking');
      await t.pump(const Duration(seconds: 3));
      expect(opacityOf(t, hint), 0);

      await t.tapAt(const Offset(200, 200));
      await t.pump();
      expect(opacityOf(t, hint), 1);
      expect(unlocked, 0);

      await t.tap(find.byIcon(Icons.lock_rounded).first);
      await t.pump();
      expect(unlocked, 1);
      await t.pump(const Duration(seconds: 3));
    });

    testWidgets('TV: nothing to focus or tap; the lock shows with the hint', (
      t,
    ) async {
      await pumpOverlay(t, LockUnlockStyle.tv);
      expect(find.text('Screen locked · press BACK to unlock'), findsOneWidget);
      // The overlay never takes remote focus (Back goes to the player).
      final exclude = t.widget<ExcludeFocus>(
        find
            .descendant(
              of: find.byType(PlayerLockOverlay),
              matching: find.byType(ExcludeFocus),
            )
            .first,
      );
      expect(exclude.excluding, isTrue);
      await t.pump(const Duration(seconds: 3));
      expect(opacityOf(t, find.byIcon(Icons.lock_rounded).first), 0);
    });
  });

  group('Live TV full screen on a TV', () {
    late Directory dir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      dir = await Directory.systemTemp.createTemp('lunar_lock_test');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel('plugins.flutter.io/path_provider'),
            (_) async => dir.path,
          );
      await StorageService.instance.init();
    });

    tearDownAll(() async {
      PlatformUtils.debugIsTV = false;
      await Hive.close();
      try {
        await dir.delete(recursive: true);
      } catch (_) {}
    });

    testWidgets('lock is in the info bar; only Back unlocks', (t) async {
      PlatformUtils.debugIsTV = true;
      addTearDown(() => PlatformUtils.debugIsTV = false);
      t.view.physicalSize = const Size(1280, 720);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      final streams = [
        for (var i = 0; i < 5; i++)
          LiveStream.fromJson({'stream_id': '$i', 'name': 'Channel $i'}),
      ];
      final container = ProviderContainer(
        overrides: [
          filteredLiveStreamsProvider.overrideWithValue(
            AsyncValue.data(streams),
          ),
          epgCacheProvider.overrideWith((ref) => _FakeEpg(ref)),
          selectedChannelProvider.overrideWith((ref) => streams[2]),
          xtreamServiceProvider.overrideWithValue(null),
        ],
      );
      addTearDown(container.dispose);

      await t.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: LiveInlinePlayer(
              isMaximized: true,
              onMaximize: () {},
              onMinimize: () {},
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump();

      Future<void> key(LogicalKeyboardKey k) async {
        if (k == LogicalKeyboardKey.goBack) {
          // No physical key for Back in the test key maps.
          await t.sendKeyDownEvent(k, physicalKey: PhysicalKeyboardKey.escape);
          await t.sendKeyUpEvent(k, physicalKey: PhysicalKeyboardKey.escape);
        } else {
          await t.sendKeyEvent(k);
        }
        await t.pump();
        await t.pump(const Duration(milliseconds: 50));
      }

      String? focused() => FocusManager.instance.primaryFocus?.debugLabel;

      // Up shows the info bar; Right walks Minimize → Favourite → Lock.
      await key(LogicalKeyboardKey.arrowUp);
      expect(focused(), 'liveMaxMin');
      await key(LogicalKeyboardKey.arrowRight);
      expect(focused(), 'liveMaxFav');
      await key(LogicalKeyboardKey.arrowRight);
      expect(focused(), 'liveMaxLock');
      await key(LogicalKeyboardKey.select);
      expect(container.read(livePlayerLockedProvider), isTrue);
      expect(find.text('Screen locked · press BACK to unlock'), findsOneWidget);
      expect(focused(), 'liveMaxRoot');

      // Other keys don't unlock (or zap / open the guide).
      for (final k in [
        LogicalKeyboardKey.select,
        LogicalKeyboardKey.arrowRight,
        LogicalKeyboardKey.arrowUp,
      ]) {
        await key(k);
      }
      expect(container.read(livePlayerLockedProvider), isTrue);
      expect(container.read(selectedChannelProvider)?.streamId, '2');
      expect(container.read(livePlayerLockHintProvider), 3);

      await key(LogicalKeyboardKey.goBack);
      expect(container.read(livePlayerLockedProvider), isFalse);
      expect(find.text('Screen locked · press BACK to unlock'), findsNothing);

      await t.pumpWidget(const SizedBox());
    });
  });
}
