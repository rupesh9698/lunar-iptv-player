import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/core/utils/focus_utils.dart';
import 'package:lunar_iptv_player/screens/player/player_screen.dart';

/// Movies / Series player controls driven by a TV remote. The controls sit
/// inside the player's full-screen key root, exactly like the real screen.
void main() {
  for (final size in const [Size(960, 540), Size(1280, 720)]) {
    testWidgets('remote reaches Back from the top bar ($size)', (t) async {
      t.view.physicalSize = size;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      FocusManager.instance.highlightStrategy =
          FocusHighlightStrategy.alwaysTraditional;
      final root = FocusNode(debugLabel: 'playerRoot');
      final play = FocusNode(debugLabel: 'play');
      addTearDown(root.dispose);
      addTearDown(play.dispose);
      var back = 0;
      await t.pumpWidget(
        MaterialApp(
          home: TvKeyRoot(
            focusNode: root,
            autofocus: true,
            onKeyEvent: (_, _) => KeyEventResult.ignored,
            child: Scaffold(
              backgroundColor: Colors.black,
              body: debugPlayerControls(
                playFocusNode: play,
                onBack: () => back++,
              ),
            ),
          ),
        ),
      );
      play.requestFocus();
      await t.pump();

      var trail = '';
      Future<void> key(LogicalKeyboardKey k) async {
        await t.sendKeyEvent(k);
        await t.pump();
        final f = FocusManager.instance.primaryFocus!;
        trail += '${k.keyLabel} → ${f.debugLabel ?? f.rect.left.round()}; ';
        expect(f, isNot(root), reason: 'focus fell onto the player: $trail');
      }

      // Play → up into the top bar → left until the Back button.
      await key(LogicalKeyboardKey.arrowUp);
      for (var i = 0; i < 4; i++) {
        await key(LogicalKeyboardKey.arrowLeft);
      }
      await key(LogicalKeyboardKey.select);
      expect(back, 1, reason: trail);
    });
  }
}
