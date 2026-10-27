/// The text-scale instrument's own checks — task 11.232.
///
/// `collectLayoutOverflows` intercepts `FlutterError.onError` and swallows
/// layout overflows so a ladder can report them instead of dying on the
/// first. **What it swallows is the whole question.** Until 2026-09-12 it
/// decided by the words `overflowed by` in the error text, and a test whose
/// failure message *quoted* a stripe was swallowed with the stripes: the
/// binding then asserted inside its own uncaught-error path and the test
/// waited ten idle minutes for its timeout, three times, and was written up
/// as the app freezing. These hold the classification to the act instead.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'text_scale_probe.dart';

void main() {
  testWidgets(
      'a TestFailure whose message quotes a stripe is forwarded, not swallowed',
      (tester) async {
    final overflows = collectLayoutOverflows();
    // The exact shape flutter_test produces when an expect() with a quoting
    // reason fails: the failure's own text contains the overflow wording.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: TestFailure(
          'Expected: true\n  Actual: <false>\n'
          'Edit tag at xxxLarge: STRIPED: A RenderFlex overflowed by 3.4 '
          'pixels on the right.',
        ),
        library: 'Flutter test framework',
      ),
    );
    expect(
      overflows,
      isEmpty,
      reason: 'a test failure is not a layout overflow, whatever it says — '
          'swallowing one here is what left task 11.229 waiting ten minutes '
          'for a dialog that had laid out in 86 ms',
    );
    expect(
      tester.takeException(),
      isA<TestFailure>(),
      reason: 'the failure must reach the binding, which is what turns it '
          'into a red test rather than a hang',
    );
  });

  testWidgets('a real RenderFlex overflow is still collected, with its creator',
      (tester) async {
    final overflows = collectLayoutOverflows();
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 100,
            child: Row(children: [SizedBox(width: 150, height: 10)]),
          ),
        ),
      ),
    );
    expect(overflows, hasLength(1));
    expect(overflows.single, contains('overflowed by 50 pixels on the right'));
    expect(
      overflows.single,
      contains('creator:'),
      reason: 'the line names the widget chain, not only the direction',
    );
    expect(
      tester.takeException(),
      isNull,
      reason: 'the overflow was swallowed into the list, as intended',
    );
  });

  testWidgets('a non-overflow rendering error is forwarded', (tester) async {
    final overflows = collectLayoutOverflows();
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: FlutterError('RenderBox was not laid out'),
        library: 'rendering library',
      ),
    );
    expect(overflows, isEmpty);
    expect(tester.takeException(), isA<FlutterError>());
  });

  test('a verdict that is not clean says which font it was measured in', () {
    const verdict = TextScaleVerdict(stripes: ['A RenderFlex overflowed by 1 pixel'], clipped: []);
    expect(verdict.toString(), contains('measured in the test font'));
    expect(const TextScaleVerdict(stripes: [], clipped: []).toString(), 'clean');
  });

  /// **Task 11.332 item 1.** An ellipsis used to excuse any cut: the owner's
  /// deletion countdown lost "or cancel from ⋮" to a "…" on the 6.1-inch
  /// phone and the sweep, which fails only on a silent clip, passed. The line
  /// drawn here: **a piece of text given one line and cut at its end is a
  /// one-line label, and that is a design choice; a piece that wraps onto a
  /// second line and is then cut is a sentence that lost words.** A "piece"
  /// is a hard line — the text between two `\n` — because several screens
  /// join a sentence and a one-line description into one `Text`.
  group('a sentence cut short by an ellipsis (task 11.332)', () {
    Future<ClippedText> cutOf(
      WidgetTester tester,
      String text, {
      int? maxLines,
      TextOverflow overflow = TextOverflow.ellipsis,
      bool softWrap = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                // The test font draws every character 10 px wide at size 10,
                // so this is 20 characters a line.
                width: 200,
                child: Text(
                  text,
                  maxLines: maxLines,
                  overflow: overflow,
                  softWrap: softWrap,
                  style: const TextStyle(fontSize: 10),
                ),
              ),
            ),
          ),
        ),
      );
      return clippedTexts(tester).singleWhere((c) => c.text == text);
    }

    const sentence = 'Deletion from the server scheduled for 3 November; '
        'export first, or cancel from the menu.';

    testWidgets('a long name in a one-line row is a label, not a sentence',
        (tester) async {
      final cut = await cutOf(
        tester,
        'Estimate · Sage · 150.284 MHz · collar two',
        maxLines: 1,
      );
      expect(cut.silent, isFalse);
      expect(cut.cutsRunningText, isFalse);
      expect(cut.fails, isFalse);
    });

    testWidgets(
        'an ellipsis with no line limit is a sentence cut short: nobody said '
        'one line (a form field\'s error text does this by default)',
        (tester) async {
      final cut = await cutOf(tester, sentence);
      expect(cut.cutsRunningText, isTrue);
    });

    testWidgets('a form field\'s error, with no errorMaxLines, fails',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 200,
              child: TextField(
                decoration: InputDecoration(errorText: sentence),
              ),
            ),
          ),
        ),
      );
      final cut = clippedTexts(tester).singleWhere((c) => c.text == sentence);
      expect(cut.fails, isTrue);
    });

    testWidgets('a label that does not wrap and fades is one line too',
        (tester) async {
      final cut = await cutOf(
        tester,
        sentence,
        overflow: TextOverflow.fade,
        softWrap: false,
      );
      expect(cut.cutsRunningText, isFalse);
    });

    testWidgets('a sentence that wraps and is then cut by "…" fails',
        (tester) async {
      final cut = await cutOf(tester, sentence, maxLines: 3);
      expect(cut.silent, isFalse, reason: 'it ends in an ellipsis');
      expect(cut.cutsRunningText, isTrue);
      expect(cut.fails, isTrue);
      expect(cut.toString(), contains('sentence cut short'));
    });

    testWidgets(
        'a sentence above a one-line description: cutting the description '
        'is the label rule', (tester) async {
      final cut = await cutOf(
        tester,
        'Read-only snapshot.\n$sentence',
        maxLines: 2,
      );
      expect(cut.cutsRunningText, isFalse);
    });

    testWidgets(
        'the countdown and the description in one Text, with the countdown '
        'cut: fails (the shape 11.323 fixed)', (tester) async {
      final cut = await cutOf(
        tester,
        '$sentence\nWinter range study',
        maxLines: 4,
      );
      expect(cut.cutsRunningText, isTrue);
    });

    testWidgets('a silent clip still fails, whatever the text is',
        (tester) async {
      final cut = await cutOf(
        tester,
        'Sage · 150.284 MHz · collar two of three',
        maxLines: 1,
        overflow: TextOverflow.clip,
      );
      expect(cut.silent, isTrue);
      expect(cut.fails, isTrue);
    });
  });
}
