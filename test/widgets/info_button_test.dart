/// Task 11.320 — the one (i) button every screen now shares.
///
/// The detail a screen moves behind it is the part a person needs least often
/// and most carefully, so the button has to be findable by a screen reader,
/// tappable at 48 points, and readable at the largest text size.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/widgets/info_button.dart';

import '../support/text_scale_probe.dart';

void main() {
  const detail =
      'First paragraph of the explanation.\n\n'
      'Second paragraph, which a person reads only when they ask for it.';

  Future<void> pump(
    WidgetTester tester, {
    double scale = 1.0,
    String text = detail,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: Scaffold(
            body: InfoLine(
              text: 'The one thing to know.',
              title: 'Why this matters',
              detail: text,
              buttonKey: const ValueKey('info'),
              detailKey: const ValueKey('info_detail'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('a screen reader hears what it is about', (tester) async {
    final handle = tester.ensureSemantics();
    await pump(tester);
    expect(
      tester.getSemantics(find.byKey(const ValueKey('info'))),
      isSemantics(
        tooltip: 'More about why this matters',
        isButton: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('the tap target is at least 48 points', (tester) async {
    await pump(tester);
    final size = tester.getSize(find.byKey(const ValueKey('info')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });

  testWidgets('a tap opens the detail, paragraph by paragraph', (
    tester,
  ) async {
    await pump(tester);
    expect(find.textContaining('Second paragraph'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('info')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('info_detail')), findsOneWidget);
    expect(find.text('First paragraph of the explanation.'), findsOneWidget);
    expect(find.textContaining('Second paragraph'), findsOneWidget);

    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('info_detail')), findsNothing);
  });

  testWidgets('at the largest text size the detail scrolls rather than '
      'overflowing', (tester) async {
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    // Long enough that a dialog which does not scroll overflows — watched
    // red with `scrollable: false` in `showInfoDetail`.
    await pump(
      tester,
      scale: iosTextScales.last,
      text: List.filled(6, detail).join('\n\n'),
    );
    await tester.tap(find.byKey(const ValueKey('info')));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('info_detail')), findsOneWidget);
  });
}
