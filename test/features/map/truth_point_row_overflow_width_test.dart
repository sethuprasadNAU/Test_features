import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Task 11.102: a truth-point panel's Edit/Delete/Navigate row overflowed by
/// `0.0896` pixels on Michael's real device — a row that fit by nothing.
/// **Contrary to the development plan's guess, this is not driven by the
/// tag's name length**: all three button labels ('Edit', 'Delete',
/// 'Navigate') are fixed strings, not derived from the tag at all — no tag
/// name, however long, changes this row's width. What actually starved it is
/// screen width: `map_screen_test.dart`'s own truth-point tests all use a
/// 1200-logical-pixel-wide surface, far wider than any real phone, which is
/// why nothing there had ever seen this row overflow before a person held a
/// real device.
///
/// **The number for the content lane, measured by hand-bisecting this
/// shape's own width** (at the test font/1.0x text scale): the row needs
/// **between 460px and 470px** of horizontal space to avoid overflowing —
/// below that it clips, above it there's room. A `map_screen.dart` panel's
/// content column comes out to roughly `deviceWidth - 56` (two 12px screen
/// insets, a 14+6px Material padding, then a 4+8px inner padding), so this
/// threshold reads as *any phone narrower than about 520 logical pixels wide*
/// — every real phone Michael tests on.
///
/// Isolates the exact shape that overflowed (three `OutlinedButton.icon`s
/// with fixed labels in a plain `Row(mainAxisAlignment: end)`, no
/// `Expanded`/`Flexible`) in its own file/isolate, deliberately not inside
/// `map_screen_test.dart`: run there, after that file's many heavy real-
/// sqlite/real-network tests, this hit a 10-minute timeout — this shape has
/// no such dependency and shouldn't need to share that isolate's leftover
/// state. Each width is its own fresh test, not a loop reusing one `tester`
/// across many `pumpWidget` calls, which produced an inconsistent,
/// non-monotonic result when tried.
void main() {
  // `tester.takeException()` — the same mechanism `map_screen_test.dart`'s
  // own overflow regression check uses — rather than swapping out
  // `FlutterError.onError`: overriding that handler here left the binding in
  // a state where the *next* test's `pumpWidget` never returned, hanging
  // until the 10-minute test timeout.
  Future<bool> rowOverflowsAt(WidgetTester tester, double width) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.edit, size: 16),
                    label: const Text('Edit'),
                    onPressed: null,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.delete_outline, size: 16),
                    label: const Text('Delete'),
                    onPressed: null,
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.navigation, size: 16),
                    label: const Text('Navigate'),
                    onPressed: null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.takeException() != null;
  }

  testWidgets(
    'the old fixed-label Row overflows at 200px — narrower than any real '
    'phone content width, but not by a comfortable margin',
    (tester) async {
      expect(await rowOverflowsAt(tester, 200), isTrue);
    },
  );

  testWidgets(
    'the old fixed-label Row overflows at 460px — the actual measured '
    'threshold, well within a real phone panel width',
    (tester) async {
      expect(await rowOverflowsAt(tester, 460), isTrue);
    },
  );

  testWidgets(
    'the old fixed-label Row fits at 470px — one pixel-probe step above the '
    'measured threshold',
    (tester) async {
      expect(await rowOverflowsAt(tester, 470), isFalse);
    },
  );

  testWidgets(
    'the old fixed-label Row fits at 700px, comfortably',
    (tester) async {
      expect(await rowOverflowsAt(tester, 700), isFalse);
    },
  );
}
