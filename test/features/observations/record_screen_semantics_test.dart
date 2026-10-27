import 'package:flutter/widgets.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/pulse_rate_unit_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/record_screen_tags.dart';

/// **What the Record screen still says after task 11.197 stopped printing it.**
///
/// Michael walked this screen on his phone on 2026-09-07 and the standing rule
/// that came out of it is now in `CLAUDE.md`: *simplicity and readability over
/// verbosity, so long as the user can find the option by exploring or by
/// tapping an information icon.* Applied here, that removed three section
/// headings (*Record type*, *Tag*, *Bearing*), shortened three more
/// (*Bearing quality* → *Quality*, *Pulse mode* → *Mode*, *Signal strength* →
/// *Strength*), cut a button's label from *Preview / set position on map* to
/// *Preview/Set*, and replaced the five record-type words with icons.
///
/// **Every one of those decisions is about ink, and none of them is about
/// what the screen says.** A heading deleted from a screen is a heading a
/// screen reader still needs; an icon with no word beside it is silent unless
/// somebody says the word for it. The rule in `CLAUDE.md` names this exception
/// in the same breath as the licence, and this file is what holds it — so that
/// the next task to shorten something on this screen finds out here rather
/// than from somebody who cannot use the app.
///
/// **Why a separate file rather than a group in the space-budget suite.** That
/// one is about pixels and this one is about what is announced; they fail for
/// different reasons and a reader looking for "does this screen still tell a
/// screen reader what these controls are" should not have to guess which
/// layout file it was folded into.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  /// The same shape as `record_screen_pulse_modes_test.dart`'s harness, and
  /// for the same reason: every provider this screen watches is pre-resolved
  /// inside `runAsync`, because a provider's future is tied to whichever zone
  /// started it and one started in the fake-async zone never resolves.
  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(
          (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
        ),
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);

      await userRepo.insert(sampleUser());
      await projectRepo.insert(sampleProject());
      await tagRepo.insert(sampleTag());
      // Task 11.249: on an animal, or the wheel does not offer it.
      await putSampleTagOnAnAnimal(container);
      // The phone holder is the project's owner, `user-1`, said explicitly
      // (task 11.237). Left unset, `currentUserProvider` mints a fresh user
      // the project's rows do not name — which used to resolve to "cannot
      // say" and be permitted, and is now a read-only snapshot that refuses
      // the very save these tests exist to exercise.
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});
      container.listen(pulseRateUnitSettingProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(mayWriteProjectDataProvider('project-1').future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
      await container.read(pulseRateUnitSettingProvider.future);
    });

    return container;
  }

  Future<void> pumpScreen(
    WidgetTester tester,
    ProviderContainer container,
  ) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
    );
  }

  testWidgets('every record type is announced by name, though four of the '
      'five are drawn as bare icons', (tester) async {
    final handle = tester.ensureSemantics();
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    for (final type in RecordType.values) {
      expect(
        find.bySemanticsLabel(type.label),
        findsOneWidget,
        reason: 'Task 11.197 made this control iconic to give the width back. '
            'A person who cannot see the icon has only what it is announced '
            'as — and this control decides what kind of record gets written, '
            'so an unnamed segment is a wrong row in somebody\'s data. '
            '"${type.label}" must survive as a `Semantics` label whether or '
            'not it is drawn.',
      );
    }

    // The selected one is the only one that also shows its word, which is the
    // half of the compromise that keeps *what am I recording right now*
    // legible without anybody having to learn five glyphs. Directional is the
    // draft's default.
    expect(find.text(RecordType.directional.label), findsOneWidget);
    for (final type in RecordType.values) {
      if (type == RecordType.directional) continue;
      expect(find.text(type.label), findsNothing,
          reason: 'The four types a person is not recording are icons only — '
              'that is the width this change bought.');
    }
    handle.dispose();
  });

  testWidgets('the sections whose headings were deleted are still named',
      (tester) async {
    final handle = tester.ensureSemantics();
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    // Deleted as ink by task 11.197 — a wheel of frequencies and a live
    // compass reading say what they are to somebody looking at them.
    expect(find.text('RECORD TYPE'), findsNothing);
    expect(find.text('TAG'), findsNothing);
    expect(find.text('BEARING'), findsNothing);

    // Kept as speech, because nothing about a wheel of numbers says "tag" to
    // somebody hearing the controls read out one at a time.
    //
    // **Matched as a pattern rather than an exact string, because a
    // screen reader does not read one widget at a time.** Flutter merges a
    // label with the labels beside it into one node — *Bearing* is announced
    // as "Bearing / 45°", together with the live heading it introduces,
    // which is the right thing to hear and is not an exact match for
    // anything. What is being asserted is that the word is still in what
    // gets read out.
    expect(find.bySemanticsLabel('Tag'), findsOneWidget);
    expect(find.bySemanticsLabel(RegExp('Bearing')), findsWidgets);
    handle.dispose();
  });

  testWidgets('the three shortened wheel headings are announced in full',
      (tester) async {
    final handle = tester.ensureSemantics();
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    // Short in ink: unambiguous *in place*, in a row under the bearing block
    // with each wheel's own values under it.
    expect(find.text('QUALITY'), findsOneWidget);
    expect(find.text('MODE'), findsOneWidget);
    expect(find.text('STRENGTH'), findsOneWidget);

    // Long in speech: a listener has none of that context. The three
    // headings merge into one node with the wheels between them, so these
    // are patterns — see the note in the test above.
    expect(find.bySemanticsLabel(RegExp('Bearing quality')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Pulse mode')), findsWidgets);
    expect(find.bySemanticsLabel(RegExp('Signal strength')), findsWidgets);
    handle.dispose();
  });

  testWidgets('Advanced still says what is behind it, to a screen reader',
      (tester) async {
    final handle = tester.ensureSemantics();
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    // **Scrolled to first.** ADVANCED is one of the three things task 11.197
    // put below the fold on purpose, so a `ListView` has not built it yet —
    // and a semantics assertion about a widget that does not exist passes
    // for the wrong reason in the other direction.
    final advanced = find.textContaining('Advanced');
    await tester.dragUntilVisible(
      advanced,
      find.byKey(const ValueKey('record-form')),
      const Offset(0, -80),
    );
    await tester.pumpAndSettle();

    // Michael, on the ink: *"Advanced: bearing method, antenna type, receiver
    // gain"* is a disclosure control listing its own contents, and the way to
    // find out what is in it is to open it.
    expect(advanced, findsOneWidget);
    expect(find.textContaining('bearing method, antenna type'), findsNothing);

    // **The words are kept in speech, and the reason is that the exploration
    // the rule relies on is not equally cheap for everybody.** A sighted
    // person tapping the triangle sees three controls at a glance; somebody
    // listening has to expand the section and hear each one read out. So
    // knowing what is behind it before opening it is worth more here than it
    // was on the screen.
    expect(
      find.bySemanticsLabel(
          RegExp('Advanced: bearing method, antenna type, receiver gain')),
      findsWidgets,
    );
    handle.dispose();
  });

  testWidgets('Preview/Set is announced as what it does', (tester) async {
    final handle = tester.ensureSemantics();
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    expect(find.text('Preview/Set'), findsOneWidget);
    expect(
      find.bySemanticsLabel(RegExp('Preview or set position on map')),
      findsWidgets,
      reason: 'Two words beside a coordinate are unambiguous to somebody '
          'looking at the line. Read out on their own they are two verbs with '
          'no object.',
    );
    handle.dispose();
  });
}
