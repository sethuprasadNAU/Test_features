import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/compass_provider.dart';

import '../../support/app_boot_helper.dart';
import '../../support/complete_identity_setup.dart';
import '../../support/fake_shared_preferences.dart';

/// Navigates the real app shell to the Compass tab. The live sensor streams
/// (accelerometer/magnetometer) aren't available under `flutter test`, so the
/// compass stays at its neutral initial reading (no heading yet) — this test
/// verifies the screen still renders correctly and doesn't crash in that
/// state. Compass is a pure live-viewing instrument (no capture/save UI —
/// that lives entirely in the Record tab's bearing entry sheet instead), so
/// there's no mode toggle or Save button to exercise here anymore.
void main() {
  setUp(installFakeSharedPreferences);

  testWidgets('Compass tab renders as a live instrument with no save/capture UI', (tester) async {
    final container = await pumpAppForTest(tester);
    await completeIdentitySetup(tester);

    await tester.tap(find.text('Compass'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('Magnetic:'), findsOneWidget);
    expect(find.textContaining('True North:'), findsOneWidget);
    expect(find.text('⟲ Calibrate (figure-8)'), findsOneWidget);

    // No capture/save UI on this screen anymore.
    expect(find.text('Single Point'), findsNothing);
    expect(find.text('Range Capture'), findsNothing);
    expect(find.text('SAVE BEARING'), findsNothing);

    // Dispose synchronously here (not via `addTearDown`, which only runs
    // after flutter_test's own end-of-test invariant check) — the Compass
    // screen leaves `CompassAvailable`'s 2-second availability `Timer`
    // pending the whole test, and `UncontrolledProviderScope`'s container
    // isn't tied to the widget tree's own disposal, so it must be disposed
    // before the test body returns for that timer to be cancelled in time.
    container.dispose();
  });

  testWidgets(
      'Compass tab shows the explanatory unavailable state, not a dead dial, when the compass errors',
      (tester) async {
    final container = await pumpAppForTest(
      tester,
      overrides: [
        // Simulates the null-events/errored-stream case directly rather
        // than waiting out the real timeout — see compass_provider_test.dart
        // for the timeout path itself.
        compassHeadingProvider.overrideWith((ref) => Stream.error(StateError('no compass'))),
      ],
    );
    addTearDown(container.dispose);
    await completeIdentitySetup(tester);

    await tester.tap(find.text('Compass'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('No compass available on this device'), findsOneWidget);
    expect(find.textContaining('entered manually on the Record screen'), findsOneWidget);
    expect(find.text('Go to Record'), findsOneWidget);
    // The dial/readouts must not render underneath the empty state.
    expect(find.textContaining('Magnetic:'), findsNothing);
    expect(find.textContaining('True North:'), findsNothing);

    await tester.tap(find.text('Go to Record'));
    await tester.pumpAndSettle();

    // Landed on the Record tab (bottom nav highlights it as selected).
    expect(find.text('Compass'), findsOneWidget); // still a nav label, not the empty state
    expect(find.text('No compass available on this device'), findsNothing);
  });
}
