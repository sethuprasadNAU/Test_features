import 'package:flutter_test/flutter_test.dart';

import '../support/app_boot_helper.dart';
import '../support/complete_identity_setup.dart';
import '../support/fake_shared_preferences.dart';

/// Phase 4 built real screens (Observation Logging, Main Map, Position
/// Estimation, Project Setup, Pre-Trip Checklist) in place of every
/// remaining placeholder. This is a smoke test across all five tabs on a
/// fresh install (no active project yet) — each should render its
/// no-project empty state without throwing, rather than the old bare
/// "Built in Phase N" placeholder text.
///
/// The app now boots to a branded splash (Phase 7) before the tab shell,
/// then routes straight into the non-skippable first-run identity screen —
/// `completeIdentitySetup` fills and submits it so these tests reach the
/// real tab shell.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('all five tabs render without error on a fresh install', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);
    await completeIdentitySetup(tester);
    expect(tester.takeException(), isNull);

    expect(find.text('No active project'), findsOneWidget); // Map tab

    await tester.tap(find.text('Record'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('No active project'), findsOneWidget);

    await tester.tap(find.text('Compass'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('⟲ Calibrate (figure-8)'), findsOneWidget);

    await tester.tap(find.text('Position'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.textContaining('Set up a project'), findsOneWidget);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Project Setup / Extent'), findsOneWidget);
    expect(find.text('Pre-Trip Checklist'), findsOneWidget);
  });

  testWidgets('More > Pre-Trip Checklist opens without a project and says so', (tester) async {
    final container = await pumpAppForTest(tester);
    addTearDown(container.dispose);
    await completeIdentitySetup(tester);

    await tester.tap(find.text('More'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pre-Trip Checklist'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Set up a project first.'), findsOneWidget);
  });
}
