import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lunar_iptv_player/core/utils/focus_utils.dart';
import 'package:lunar_iptv_player/core/utils/responsive.dart';

/// Tests for the TV-remote / D-pad focus toolkit (lib/core/utils).
void main() {
  Widget host(Widget child) => MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );

  Widget box(String label) =>
      SizedBox(width: 120, height: 40, child: Text(label));

  setUp(() {
    FocusManager.instance.highlightStrategy =
        FocusHighlightStrategy.alwaysTraditional;
  });

  testWidgets('OK/Select activates a focused TvFocusable exactly once', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      host(
        TvFocusable(
          autofocus: true,
          onActivate: () => taps++,
          builder: (_, _) => box('btn'),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(taps, 1);
  });

  testWidgets('holding OK fires onLongPress instead of onActivate', (
    tester,
  ) async {
    var taps = 0;
    var longs = 0;
    await tester.pumpWidget(
      host(
        TvFocusable(
          autofocus: true,
          onActivate: () => taps++,
          onLongPress: () => longs++,
          builder: (_, _) => box('btn'),
        ),
      ),
    );
    await tester.pump();

    // Short press → activate on key-up.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    expect(taps, 0, reason: 'activation is deferred to key-up');
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(taps, 1);
    expect(longs, 0);

    // Held press → long-press, no activation.
    await tester.sendKeyDownEvent(LogicalKeyboardKey.select);
    for (var i = 0; i < kTvLongPressRepeats + 2; i++) {
      await tester.sendKeyRepeatEvent(LogicalKeyboardKey.select);
    }
    await tester.sendKeyUpEvent(LogicalKeyboardKey.select);
    expect(longs, 1);
    expect(taps, 1);
  });

  testWidgets('Menu key triggers onLongPress', (tester) async {
    var longs = 0;
    await tester.pumpWidget(
      host(
        TvFocusable(
          autofocus: true,
          onLongPress: () => longs++,
          builder: (_, _) => box('btn'),
        ),
      ),
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.contextMenu);
    expect(longs, 1);
  });

  testWidgets('TvNav.wire adds arrow navigation WITHOUT breaking OK', (
    tester,
  ) async {
    final a = FocusNode(debugLabel: 'a');
    final b = FocusNode(debugLabel: 'b');
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    var aTaps = 0;
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvFocusable(
              focusNode: a,
              autofocus: true,
              onActivate: () => aTaps++,
              builder: (_, _) => box('a'),
            ),
            // Deliberately far away / to the right so geometric traversal
            // alone would not pick it for "down".
            Padding(
              padding: const EdgeInsets.only(left: 400),
              child: TvFocusable(focusNode: b, builder: (_, _) => box('b')),
            ),
          ],
        ),
      ),
    );
    TvNav.wire(a, TvNav.handler(right: b));
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    expect(aTaps, 1, reason: 'OK must still activate a wired node');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(b.hasPrimaryFocus, isTrue);
  });

  testWidgets('TvFocusable wrapping a Material button is one focus stop', (
    tester,
  ) async {
    final outer = FocusNode(debugLabel: 'outer');
    final next = FocusNode(debugLabel: 'next');
    addTearDown(outer.dispose);
    addTearDown(next.dispose);
    await tester.pumpWidget(
      host(
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TvFocusable(
              focusNode: outer,
              autofocus: true,
              onActivate: () {},
              builder: (_, _) => IconButton(
                onPressed: () {},
                icon: const Icon(Icons.favorite),
              ),
            ),
            TvFocusable(focusNode: next, builder: (_, _) => box('next')),
          ],
        ),
      ),
    );
    await tester.pump();
    expect(outer.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(
      next.hasPrimaryFocus,
      isTrue,
      reason: 'inner IconButton must not be a second stop',
    );
  });

  testWidgets('D-pad Down leaves a single-line TextField (TvTextFieldNav)', (
    tester,
  ) async {
    final field = FocusNode(debugLabel: 'field');
    final below = FocusNode(debugLabel: 'below');
    addTearDown(field.dispose);
    addTearDown(below.dispose);
    final ctrl = TextEditingController(text: 'abc');
    addTearDown(ctrl.dispose);
    await tester.pumpWidget(
      host(
        SizedBox(
          width: 300,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TvTextFieldNav(
                controller: ctrl,
                child: TextField(
                  controller: ctrl,
                  focusNode: field,
                  autofocus: true,
                ),
              ),
              const SizedBox(height: 20),
              TvFocusable(focusNode: below, builder: (_, _) => box('below')),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    expect(field.hasPrimaryFocus, isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(below.hasPrimaryFocus, isTrue);
  });

  testWidgets('TvSlider adjusts with Left/Right and releases focus on Down', (
    tester,
  ) async {
    final sliderNode = FocusNode(debugLabel: 'slider');
    final below = FocusNode(debugLabel: 'below');
    addTearDown(sliderNode.dispose);
    addTearDown(below.dispose);
    var value = 0.5;
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => SizedBox(
            width: 300,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TvSlider(
                  focusNode: sliderNode,
                  value: value,
                  step: 0.1,
                  onChanged: (v) => setState(() => value = v),
                ),
                const SizedBox(height: 20),
                TvFocusable(focusNode: below, builder: (_, _) => box('below')),
              ],
            ),
          ),
        ),
      ),
    );
    sliderNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, closeTo(0.6, 1e-9));

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(below.hasPrimaryFocus, isTrue, reason: 'slider must not trap D-pad');
  });

  testWidgets('AdaptiveViewport lays tiny windows out at the minimum canvas', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(500, 300);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size seen;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AdaptiveViewport(child: child!),
        home: Builder(
          builder: (context) {
            seen = MediaQuery.sizeOf(context);
            return const SizedBox.expand();
          },
        ),
      ),
    );
    expect(seen.width, greaterThanOrEqualTo(AdaptiveViewport.minWidth - 0.5));
    expect(seen.height, greaterThanOrEqualTo(AdaptiveViewport.minHeight - 0.5));
  });

  testWidgets('AdaptiveViewport leaves normal screens untouched', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    late Size seen;
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => AdaptiveViewport(child: child!),
        home: Builder(
          builder: (context) {
            seen = MediaQuery.sizeOf(context);
            return const SizedBox.expand();
          },
        ),
      ),
    );
    expect(seen, const Size(1280, 720));
  });
}
