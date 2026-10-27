import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/features/observations/widgets/bearing_entry_sheet.dart';

import '../../support/fake_shared_preferences.dart';

/// Holds the sheet's eventual result so tests can open it, interact with it,
/// then read back whatever `Navigator.pop` was called with (or `null` if
/// still open / dismissed without a value).
class _Harness {
  BearingEntryResult? result;
  bool completed = false;
}

/// Manual bearing entry (task 5.3): explicit magnetic framing, a visible
/// inline error instead of a silently-dead button on invalid input, and
/// input constraints (no minus sign, `360` normalizes to `0`).
void main() {
  setUp(() {
    installFakeSharedPreferences();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  Future<_Harness> openSheet(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final harness = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) => Scaffold(
              body: ElevatedButton(
                onPressed: () async {
                  harness.result = await showBearingEntrySheet(context, initialManualTab: true);
                  harness.completed = true;
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return harness;
  }

  testWidgets('shows the magnetic-framing note on the manual tab', (tester) async {
    await openSheet(tester);

    expect(find.textContaining('magnetic bearing'), findsOneWidget);
    expect(find.textContaining('clockwise from'), findsOneWidget);
    expect(find.textContaining('magnetic north'), findsWidgets);
  });

  testWidgets('empty input shows an inline error instead of doing nothing', (tester) async {
    final harness = await openSheet(tester);

    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pump();

    expect(find.text('Enter a bearing'), findsOneWidget);
    expect(harness.completed, isFalse);
  });

  testWidgets('a lone decimal point shows a non-numeric error', (tester) async {
    final harness = await openSheet(tester);

    await tester.enterText(find.byType(TextField), '.');
    await tester.pump();
    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pump();

    expect(find.text('Enter a valid number'), findsOneWidget);
    expect(harness.completed, isFalse);
  });

  testWidgets('a minus sign cannot be typed at all', (tester) async {
    await openSheet(tester);

    await tester.enterText(find.byType(TextField), '-10');
    await tester.pump();

    expect(find.text('10'), findsOneWidget);
    expect(find.text('-10'), findsNothing);
  });

  testWidgets('0 is accepted as a valid bearing', (tester) async {
    final harness = await openSheet(tester);

    await tester.enterText(find.byType(TextField), '0');
    await tester.pump();
    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pumpAndSettle();

    expect(harness.result, isNotNull);
    expect(harness.result!.magneticBearingDeg, 0.0);
    expect(harness.result!.captureMethod, isNull);
  });

  testWidgets('359.9 is accepted as-is', (tester) async {
    final harness = await openSheet(tester);

    await tester.enterText(find.byType(TextField), '359.9');
    await tester.pump();
    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pumpAndSettle();

    expect(harness.result, isNotNull);
    expect(harness.result!.magneticBearingDeg, closeTo(359.9, 1e-9));
  });

  testWidgets('360 is accepted and normalized to 0', (tester) async {
    final harness = await openSheet(tester);

    await tester.enterText(find.byType(TextField), '360');
    await tester.pump();
    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pumpAndSettle();

    expect(harness.result, isNotNull);
    expect(harness.result!.magneticBearingDeg, 0.0);
  });

  testWidgets('greater than 360 shows an inline error', (tester) async {
    final harness = await openSheet(tester);

    await tester.enterText(find.byType(TextField), '360.5');
    await tester.pump();
    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pump();

    expect(find.text('Bearing must be 360° or less'), findsOneWidget);
    expect(harness.completed, isFalse);
  });

  testWidgets('typing after an error clears it', (tester) async {
    await openSheet(tester);

    await tester.tap(find.text('USE THIS BEARING'));
    await tester.pump();
    expect(find.text('Enter a bearing'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '90');
    await tester.pump();

    expect(find.text('Enter a bearing'), findsNothing);
  });
}
