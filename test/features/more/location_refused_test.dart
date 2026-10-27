import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/features/more/screens/project_setup_screen.dart';

import '../../data/fixtures.dart';
import '../../support/fake_shared_preferences.dart';

/// **Task 11.105 — the first of the two instances task 11.66 reproduced on an
/// Android phone: location refused, and the app blames the sky.**
///
/// ## Why none of this tests the catch
///
/// `ProjectSetupScreen` had the right sentence for a refused location — *"Location
/// permission denied — enable it in Settings"* — sitting in a
/// `e is LocationPermissionDeniedException` branch, and that branch had never
/// been taken. `gpsPositionProvider` is autoDispose, so awaiting its `.future`
/// tears the provider down mid-load and destroys the exception; the `catch`
/// received a `StateError` about the teardown and fell through to *"Could not
/// get a GPS fix. Try again outdoors or with a clear sky view."*
///
/// **A person with location switched off was told to go outside.** That is the
/// wrong-cause class: not a vaguer version of the truth but a different
/// problem, and the instruction cannot work no matter how long they follow it.
///
/// So this file asserts nothing about which object was thrown. It starts from
/// **a device that refuses**, taps the button, and asserts **the sentence on
/// the screen** — the bar task 11.104 set for its half of the same defect. The
/// boundary itself is measured separately, from the real provider, in
/// `test/core/providers/provider_boundary_behaviour_test.dart`.
void main() {
  setUp(installFakeSharedPreferences);

  /// The screen, owned by the current user so the GPS button is enabled, with
  /// the device's location in whatever state [problem] describes.
  ///
  /// `gpsPositionProvider` is overridden to fail the way a refused device
  /// fails. **Overriding it with an error rather than an empty stream
  /// matters**: an empty stream would hang on the 15-second timeout and end in
  /// the fallback sentence for a completely different reason, and the test
  /// would pass while proving nothing.
  Future<void> pumpRefused(
    WidgetTester tester, {
    required LocationProblem? problem,
  }) async {
    final owner = sampleUser(id: 'user-owner', email: 'owner@x.com');
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentProjectProvider.overrideWith((ref) async => null),
          currentUserProvider.overrideWith((ref) async => owner),
          gpsPositionProvider.overrideWith(
            (ref) => Stream<Position>.error(
              const LocationPermissionDeniedException(),
            ),
          ),
          locationProblemProvider.overrideWith((ref) async => problem),
        ],
        child: const MaterialApp(home: ProjectSetupScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapUseCurrentLocation(WidgetTester tester) async {
    // **Scrolled into view, not tapped directly** — task 11.268 added a
    // one-line explanation under each remaining Project Setup section
    // (item 8), and on this test's 800×600 surface that is enough extra
    // height to push this button past what the `ListView`'s sliver has
    // built. `ensureVisible` cannot reach a widget a lazy list has not
    // built yet, which is why this scrolls by finder rather than by pixel.
    final button = find.widgetWithText(OutlinedButton, 'Use current location');
    await tester.scrollUntilVisible(
      button,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(button);
    await tester.pump();
    await tester.pumpAndSettle();
  }

  testWidgets('a permanently denied permission names itself, and says where '
      'to change it', (tester) async {
    await pumpRefused(
      tester,
      problem: const LocationProblem(
        LocationFault.permissionDeniedForever,
        'TriTrack has been permanently denied your location, so it can no '
        'longer ask. Turn Location on for TriTrack in the system settings '
        'for this app, then try again.',
      ),
    );
    await tapUseCurrentLocation(tester);

    expect(
      find.textContaining('permanently denied your location'),
      findsOneWidget,
      reason:
          'This is the branch that was dead. If it fails, the cause is once '
          'again not reaching the screen.',
    );
    expect(
      find.textContaining('clear sky view'),
      findsNothing,
      reason:
          'The exact wrong-cause sentence task 11.66 read on the phone. This '
          'assertion is what makes the test fail against the old code.',
    );
  });

  testWidgets('a location service switched off device-wide is not reported as '
      'a permission problem', (tester) async {
    // The fault the old single message could not express at all: no permission
    // change fixes this one, so "allow it when asked" and "check this app's
    // settings" are both instructions that cannot work.
    await pumpRefused(
      tester,
      problem: const LocationProblem(
        LocationFault.serviceDisabled,
        'Location is switched off for this device. Turn it on in the system '
        'settings, then try again.',
      ),
    );
    await tapUseCurrentLocation(tester);

    expect(find.textContaining('switched off for this device'), findsOneWidget);
    expect(find.textContaining('permission'), findsNothing);
  });

  testWidgets('a fix that simply has not arrived still gets the sky-view '
      'sentence', (tester) async {
    // The branch that was never wrong, kept honest: when nothing is refused,
    // the old message is the correct one and the fix must not have replaced
    // it with a permission story.
    await pumpRefused(tester, problem: null);
    await tapUseCurrentLocation(tester);

    expect(find.textContaining('clear sky view'), findsOneWidget);
  });

  group('the rule that decides which sentence, tested directly', () {
    // `describeLocationProblem` reads the real Geolocator statics, which do
    // not exist under `flutter test` — there is no platform channel. That is
    // the case worth pinning: it must not throw, because the caller is already
    // handling a failure and an exception raised while explaining an exception
    // leaves the screen with no message at all.
    test('with no platform channel it returns a sentence, never throws',
        () async {
      final problem = await describeLocationProblem();

      expect(problem, isNotNull);
      expect(problem!.fault, LocationFault.unknown);
      expect(problem.message, isNotEmpty);
    });

    test('each refusal is named as itself, not folded into one message', () {
      expect(
        locationProblemFor(
          serviceEnabled: false,
          permission: LocationPermission.always,
        )?.fault,
        LocationFault.serviceDisabled,
        reason:
            'Location off device-wide, even with permission granted. The old '
            'single message could not express this at all.',
      );
      expect(
        locationProblemFor(
          serviceEnabled: true,
          permission: LocationPermission.denied,
        )?.fault,
        LocationFault.permissionDenied,
      );
      expect(
        locationProblemFor(
          serviceEnabled: true,
          permission: LocationPermission.deniedForever,
        )?.fault,
        LocationFault.permissionDeniedForever,
      );
      expect(
        locationProblemFor(
          serviceEnabled: true,
          permission: LocationPermission.unableToDetermine,
        )?.fault,
        LocationFault.unknown,
        reason:
            'Reported as itself. Telling somebody their permission is refused '
            'when the device would not say is the wrong-cause defect again, '
            'one size smaller.',
      );
    });

    test('a working device has no problem to report', () {
      for (final granted in [
        LocationPermission.whileInUse,
        LocationPermission.always,
      ]) {
        expect(
          locationProblemFor(serviceEnabled: true, permission: granted),
          isNull,
          reason: '$granted must not produce a refusal message',
        );
      }
    });

    test('every fault a person can be shown ends with something to try', () {
      // The standing rule from task 11.104: a diagnosis somebody cannot act on
      // is not help. Asserted against the real sentences, from the real
      // decision, rather than against a list retyped here — a check keyed on a
      // hand-copied string is a hand-maintained list wearing a different hat.
      final produced = <LocationFault, String>{};
      for (final serviceEnabled in [true, false]) {
        for (final permission in LocationPermission.values) {
          final problem = locationProblemFor(
            serviceEnabled: serviceEnabled,
            permission: permission,
          );
          if (problem != null) produced[problem.fault] = problem.message;
        }
      }

      expect(
        produced.keys.toSet(),
        LocationFault.values.toSet(),
        reason:
            'A LocationFault exists that locationProblemFor never produces, '
            'or a new one was added with no sentence. Either is a fault a '
            'person can hit and the app cannot describe.',
      );
      for (final entry in produced.entries) {
        expect(
          entry.value,
          matches(RegExp(r'then try again\.$|when the phone asks\.$')),
          reason:
              '${entry.key.name} ends without telling anybody what to do '
              'next: "${entry.value}"',
        );
      }
    });
  });
}
