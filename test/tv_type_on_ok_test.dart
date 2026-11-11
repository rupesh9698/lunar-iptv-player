import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/core/utils/focus_utils.dart';

void main() {
  testWidgets('TV: landing on a field keeps the keyboard down; OK opens it', (
    t,
  ) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    Widget field(FocusNode n) => TvTypeOnOk(
      focusNode: n,
      enabled: true,
      builder: (context, readOnly, onTap) =>
          TextField(focusNode: n, readOnly: readOnly, onTap: onTap),
    );
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(body: Column(children: [field(a), field(b)])),
      ),
    );

    a.requestFocus();
    await t.pump();
    expect(a.hasFocus, isTrue);
    expect(t.testTextInput.isVisible, isFalse, reason: 'focus alone');

    await t.sendKeyEvent(LogicalKeyboardKey.select);
    await t.pump();
    await t.pump();
    expect(t.testTextInput.isVisible, isTrue, reason: 'OK opens keyboard');
    await t.enterText(find.byType(TextField).first, 'hello');
    expect(find.text('hello'), findsOneWidget);

    // Moving on: the next field is read-only again until OK.
    b.requestFocus();
    await t.pump();
    await t.pump();
    expect(t.testTextInput.isVisible, isFalse);
    final tf = t.widget<TextField>(find.byType(TextField).last);
    expect(tf.readOnly, isTrue);
  });
}
