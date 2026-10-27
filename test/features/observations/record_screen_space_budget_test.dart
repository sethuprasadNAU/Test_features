import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/data/repositories/project_standing.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';

import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack/widgets/segmented_toggle.dart';
import 'package:tritrack/widgets/wheel_picker.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/text_scale_probe.dart';

/// Task 11.110 — the acceptance criterion the Record screen never had.
///
/// This and the Main Map are the two screens somebody uses all day, and
/// neither had ever been measured. Task 11.109 found the Position screen with
/// one bearing row visible, crowded there by four additions each of which was
/// justified by the task that made it; **no task's acceptance had ever been
/// "and the screen still works with all of this on it."**
///
/// A form fails differently from a map. Nothing here can be pushed off the
/// screen — only below the fold — so what is asserted is that **the one
/// control this record type is gated on is fully visible without scrolling**,
/// on a 6.1-inch phone, inside the real app shell. The rules are written at
/// the top of `observation_logging_screen.dart`.
///
/// **Measured with the warnings live**, because that is 11.109's transferable
/// finding: what broke that screen was not how many bearings there were, it
/// was whether a conditional band was showing. This screen has three of them
/// — the viewer lock banner, the "no compass on this device" line, and (until
/// task 11.189 removed them) the app shell's two banners — and every existing
/// test on this screen pumps it bare at 1200x1600, where none of that can be
/// seen.
///
/// **The shell's half of that is gone and this file still pumps the shell.**
/// Task 11.189 deleted the two banners above every tab, so this screen was
/// handed 109 more logical pixels at the default text size and 623 more at
/// AX5. The numbers quoted below were measured with the banners live and are
/// therefore *worse* than what the screen gets today; they are kept because
/// they are what the bound was argued from, and the bound is unchanged.
/// `syncLive` still switches the sync surface on — it now costs this screen
/// nothing, and asserting that is the point.
void main() {
  setUp(installFakeSharedPreferences);

  Future<ProviderContainer> setUpScreen(
    WidgetTester tester, {
    bool syncLive = false,
    bool compassAvailable = true,
    ProjectRole role = ProjectRole.owner,
    double textScale = 1.0,
    DeviceGeometry geometry = phoneGeometry,
    RecordType recordType = RecordType.directional,
    /// Task 11.241: the name of the animal wearing the seeded collar. Null
    /// names it after the collar — the wheel then reads `150.325 MHz · Coco`
    /// with nothing appended; a different name is the case where the wheel
    /// appends the animal's name to the collar's. **Since task 11.249 the
    /// collar is always on an animal**, because the wheel offers nothing
    /// else; a bare tag now reaches the empty state, which is its own test.
    String? animalName,

    /// Task 11.244: an animal that wore the same collar **before** the one
    /// [animalName] names, in a deployment that has ended. The wheel must
    /// show the current one; this is what makes that assertion mean
    /// something rather than passing because there is only one animal.
    String? previousAnimalName,

    /// Task 11.249: more collars, each on its own animal, so the wheel has
    /// more rows than it can show and the number it shows can be counted.
    int extraTags = 0,

    /// A bare-day removal today on the seeded collar, with a second collar
    /// attached to the same animal the same bare day — the pair task 11.260
    /// put a prompt above the wheel for, and task 11.263 made unwritable
    /// (design §6a). Planted past the interlock, the way a build with the
    /// one-day allowance left it, so the fold can be measured with it
    /// present.
    bool legacyHandover = false,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(
          (ref) => compassAvailable
              ? Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0]))
              : const Stream.empty(),
        ),
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        if (syncLive)
          syncControllerProvider.overrideWith(LiveSyncStatusController.new),
        // The role gate itself is `project_members_screen_test.dart`'s
        // subject, not this file's. What is under test here is the band that
        // being a viewer puts at the top of the form, and how far down it
        // pushes the control the screen exists to reach.
        // The standing rather than the bool since task 11.237: the screen
        // reads *why* a write is refused, because a viewer and a snapshot
        // get different sentences.
        if (role == ProjectRole.viewer)
          myProjectStandingProvider('project-1').overrideWith(
            (ref) async => const ProjectStanding.member(ProjectRole.viewer),
          ),
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
      // Task 11.243: the animal and the link are written out, because
      // creating a collar no longer invents either.
      final individuals = await container.read(
        individualRepositoryProvider.future,
      );
      final deployments = await container.read(
        deploymentRepositoryProvider.future,
      );
      if (previousAnimalName != null) {
        await individuals.insert(
          sampleIndividual(id: 'animal-0', name: previousAnimalName),
        );
        // Off on the last day of 2025; the next animal's link starts on
        // the first day of 2026 — a day apart, which the interlock permits.
        // The same bare day at both ends is refused since task 11.263.
        await deployments.link(
          sampleDeployment(
            id: 'deployment-0',
            individualId: 'animal-0',
            attachedDate: DateTime(2025),
            removedDate: DateTime(2025, 12, 31),
          ),
        );
      }
      await individuals.insert(
        sampleIndividual(id: 'animal-1', name: animalName ?? 'Coco'),
      );
      await deployments.link(
        sampleDeployment(
          individualId: 'animal-1',
          attachedDate: DateTime(2026),
          removedDate: legacyHandover ? deploymentDateFor(DateTime.now()) : null,
        ),
      );
      if (legacyHandover) {
        await tagRepo.insert(
          sampleTag(id: 'tag-handover', tagName: 'Handover', frequencyMhz: 150.6),
        );
        // Straight into the table, past the rule — see the parameter's
        // comment.
        await deployments.insertRow(
          sampleDeployment(
            id: 'deployment-handover',
            tagId: 'tag-handover',
            individualId: 'animal-1',
            attachedDate: deploymentDateFor(DateTime.now()),
          ).toColumns(),
        );
      }
      for (var i = 1; i <= extraTags; i++) {
        await tagRepo.insert(
          sampleTag(id: 'tag-x$i', tagName: 'Collar $i', frequencyMhz: 150.325 + i * 0.05),
        );
        await individuals.insert(sampleIndividual(id: 'animal-x$i', name: 'Animal $i'));
        await deployments.link(
          sampleDeployment(
            id: 'deployment-x$i',
            tagId: 'tag-x$i',
            individualId: 'animal-x$i',
            attachedDate: DateTime(2026),
          ),
        );
      }
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      // Same zone discipline as `observation_logging_screen_test.dart`: these
      // providers do real sqflite/prefs round trips and have to be started
      // inside `runAsync`, or they never resolve under the fake clock.
      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});
      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(myProjectStandingProvider('project-1'), (_, _) {});
      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(myProjectStandingProvider('project-1').future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
    });

    // Set before the pump, the way `ground_truth_entry_test.dart` does it:
    // the draft is what the screen builds from, so choosing a record type
    // afterwards would be measuring a rebuild rather than the screen.
    if (recordType != RecordType.directional) {
      container.read(observationFormProvider.notifier).setRecordType(recordType);
    }

    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
      textScale: textScale,
      geometry: geometry,
    );
    return container;
  }

  final form = find.byKey(const ValueKey('record-form'));
  final subject = find.byKey(const ValueKey('record-bearing-capture'));
  final actionBar = find.byKey(const ValueKey('record-action-bar'));

  /// The pinned footer: a 52pt Save button and its 12pt inset, and **nothing
  /// else since 2026-09-07**. Asserted rather than trusted — this bar is the
  /// one thing on the screen that never scrolls, so a line added here is
  /// taken from every record type at once.
  ///
  /// **85 until the "Draft autosaves" note was removed at Michael's
  /// direction** — *"users will figure this out as they use the app"* — which
  /// gave the form back 21 logical pixels at the default text size.
  const declaredActionBarHeight = 64.0;

  // =====================================================================
  // Task 11.165 — rule 3 as something that can refuse, not a comment.
  //
  // `declaredActionBarHeight` above checks the bar at **one** text size, and
  // the ladder below only notices when the form's viewport reaches zero and
  // something stripes. In between, the bar could take any share of the body
  // it liked and nothing said no: measured, it takes 86 logical pixels of a
  // 570-pixel body at the default and **222 of 533 at AX5**. The bound is
  // now [kRecordPinnedBarShare], imposed by a `ConstrainedBox` the bar is
  // laid out inside.
  // =====================================================================

  /// The bar's share of the body, at every text size somebody's phone can be
  /// set to. **This is the assertion the printed-but-unchecked viewport
  /// number should always have been.**
  for (final scale in iosTextScalesUpward) {
    testWidgets('the pinned bar keeps to its share of the body at '
        '${textScaleName(scale)}', (tester) async {
      await setUpScreen(tester, syncLive: true, textScale: scale);
      final formHeight = tester.getRect(form).height;
      final barHeight = tester.getRect(actionBar).height;
      final body = formHeight + barHeight;
      printOnFailure('${textScaleName(scale)}: body ${body.toStringAsFixed(0)}px, '
          'bar ${barHeight.toStringAsFixed(0)}px '
          '(${(100 * barHeight / body).toStringAsFixed(0)}%), '
          'form ${formHeight.toStringAsFixed(0)}px');
      expect(
        barHeight,
        lessThanOrEqualTo(body * kRecordPinnedBarShare + 1),
        reason: 'Rule 3: the pinned bar is a floor, not a place to expand. '
            'If this has failed, the Save button alone no longer fits inside '
            'its share of the body — the one thing in that bar that may not '
            'shed — and the answer is not a bigger share, it is that '
            'something in the bar does not belong there.',
      );
    });
  }

  testWidgets('the bar is the button and nothing else', (tester) async {
    // **Task 11.165 built `BudgetedColumn` so that a line added to this bar
    // is paid for by the bar rather than by the form.** On 2026-09-07 the
    // only thing it had to spend — the "Draft autosaves" note — was removed
    // at Michael's direction, so the mechanism is armed with nothing in it.
    // That is deliberate: the day somebody adds a second line here, it is
    // that line which stands down and not the form which loses its viewport.
    //
    // **The old test here made a short surface and watched the note go.**
    // With nothing left to shed, what can still be checked is the thing the
    // note's absence is supposed to guarantee — the button survives a
    // surface far too short for it, and the form keeps a viewport.
    await setUpScreen(tester, syncLive: true, textScale: 53 / 17);
    tester.view.physicalSize = const Size(393 * 3, 500 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final formHeight = tester.getRect(form).height;
    final barHeight = tester.getRect(actionBar).height;
    printOnFailure('short surface: form ${formHeight.toStringAsFixed(0)}px, '
        'bar ${barHeight.toStringAsFixed(0)}px');
    expect(find.text('Draft autosaves'), findsNothing,
        reason: 'The note is gone from every state, not hidden in this one.');
    expect(
      find.descendant(of: actionBar, matching: find.byType(FilledButton)),
      findsOneWidget,
      reason: 'The Save button never sheds — it is the control the screen '
          'exists for.',
    );
    expect(formHeight, greaterThan(0),
        reason: 'The form keeps a viewport. Before this bound existed it was '
            'given zero at AX4 and the bar overflowed the body by 29 pixels.');
  });

  testWidgets('the bearing controls are reachable without scrolling',
      (tester) async {
    await setUpScreen(tester);
    expect(
      isFullyVisibleIn(tester, subject, form),
      isTrue,
      reason: 'A directional observation is what this screen is for, and the '
          'POINT / RANGE buttons are the control it is gated on. It sits '
          'below the record-type toggle and the tag wheel; anything else '
          'added above it pushes it under the fold, where somebody with one '
          'free hand and an animal still audible has to go looking for it. '
          'Read the SPACE BUDGET at the top of '
          'observation_logging_screen.dart.',
    );
  });

  testWidgets(
      'the bearing controls stay reachable with every warning band live',
      (tester) async {
    // The state a real device is in, not the calm one: a viewer's lock
    // banner and the "no compass on this device" line, with the sync surface
    // live. **A conditional band appearing is the variable** (task 11.109) —
    // this screen's own bands are worth about 150 logical pixels between
    // them, and no test that pumps it bare can see any of them.
    //
    // **The shell's two banners used to be in this list** and were the
    // largest term in it; task 11.189 deleted them. The floor below is
    // unchanged — removing the squeeze does not remove the need for the
    // floor, it gives it headroom.
    await setUpScreen(
      tester,
      syncLive: true,
      compassAvailable: false,
      role: ProjectRole.viewer,
    );
    expect(find.textContaining('Viewers cannot record observations'),
        findsOneWidget,
        reason: 'the viewer lock band is meant to be up');

    expect(
      isFullyVisibleIn(tester, subject, form),
      isTrue,
      reason: 'Every one of these bands was added by a task that justified '
          'it, and each one pushes the bearing controls down. If this has '
          'failed, the fix is not to delete a warning — it is rule 1: put '
          'the new thing below the subject, or behind a disclosure.',
    );
  });

  testWidgets('the save button never scrolls away', (tester) async {
    await setUpScreen(tester, syncLive: true);
    expect(
      find.descendant(of: actionBar, matching: find.byType(FilledButton)),
      findsOneWidget,
      reason: 'Save is pinned, not scrolled to — that is what makes the form '
          'above it safe to be long',
    );
    expect(
      tester.getRect(actionBar).height,
      lessThanOrEqualTo(declaredActionBarHeight + 1),
      reason: 'The pinned bar is one short line and one button. It is the one '
          'strip on this screen that costs every record type at once, so it '
          'does not grow (rule 3). If you need somewhere for a new control, '
          'it goes in the scrolling form below the subject.',
    );
  });

  testWidgets('a viewer is told why above the form, not in the pinned bar',
      (tester) async {
    await setUpScreen(tester, syncLive: true, role: ProjectRole.viewer);
    expect(
      find.descendant(
        of: form,
        matching: find.textContaining('Viewers cannot record observations'),
      ),
      findsOneWidget,
      reason: 'Task 11.164 — this message moved back to the scrolling form. '
          'The pinned bar is a place for a control, not an explanation (rule '
          '3): a viewer has nothing to press there, only something to read, '
          'and at AX5 the sentence alone was taller than the body the shell '
          'guarantees, with nowhere for the pinned bar to shed it.',
    );
    expect(
      find.descendant(
        of: actionBar,
        matching: find.textContaining('Viewers cannot record observations'),
      ),
      findsNothing,
    );
    expect(find.text('Draft autosaves'), findsNothing,
        reason: 'Task 11.164 gave both roles the same pinned bar; on '
            '2026-09-07 Michael emptied it of everything but the button. '
            'What is asserted here is still the thing 11.164 was about — the '
            'viewer\'s explanation is in the form, above, and not down here.');
  });

  testWidgets('nothing on the form overflows at phone width', (tester) async {
    await setUpScreen(
      tester,
      syncLive: true,
      compassAvailable: false,
      role: ProjectRole.viewer,
    );
    expect(tester.takeException(), isNull);
  });

  // =====================================================================
  // Task 11.139 — the form at the text size somebody's phone is set to.
  //
  // A form fails differently from a panel, and it failed **silently** here.
  // Nothing striped until the accessibility sizes, because the form scrolls
  // and a scrollable simply gets longer. What did fail, from AX1 upward, was
  // the one control the screen exists for: **SAVE OBSERVATION was held in a
  // fixed 52-pixel box and had the bottom cut off its own label** — 49% of it
  // drawn at the largest size, with no stripe and no ellipsis to say so. That
  // is now a minimum height.
  //
  // Every floor is measured in the test font, about twice Roboto's width
  // (task 11.133), so it is a **lower bound** on a real phone's.
  // =====================================================================

  /// The largest text size at which this form shows neither an overflow
  /// stripe nor silently-cut text, with both shell banners live.
  ///
  /// **Both roles are now clean through the whole ladder.** A viewer used to
  /// stop one stop short of an owner's, because their explanation of why
  /// they cannot record lived in the pinned bar, which cannot scroll. Task
  /// 11.164 moved that sentence into the scrolling form instead — the pinned
  /// bar is a place for a control, not an explanation (rule 3 above) — so it
  /// now costs the form nothing and the ceiling matches an owner's.
  ///
  /// Written as the ladder's own fractions — AX4 is 47/17, and `<= 2.76`
  /// would be false for the stop it names.
  ///
  /// ## Task 11.149 measured this screen rather than assuming it, and the
  /// answer was that the shell was the whole of it
  ///
  /// Task 11.147 reported this form clean through AX3 for somebody who can
  /// record and AX2 for a viewer, striping above — and said in so many words
  /// that its resemblance to the shell finding was **a hypothesis, not a
  /// diagnosis.** Task 11.149 pointed the ladder at it and printed the
  /// form's own viewport at every stop, which settled it:
  ///
  /// | text size | form viewport | what overflowed |
  /// |---|---|---|
  /// | Large (default), owner | 484 px | nothing |
  /// | AX2, owner | 293 px | nothing |
  /// | AX3, owner |  67 px | nothing |
  /// | AX4, owner |   **0 px** | the Column, by 29 px |
  /// | AX5, owner |   **0 px** | the Column, by 166 px |
  /// | AX3, viewer | **0 px** | the Column, by 155 px |
  /// | AX5, viewer | **0 px** | the Column, by 509 px |
  ///
  /// **The scrolling form was given a viewport of zero and the pinned SAVE
  /// bar alone was taller than the whole body** — 222 logical pixels at AX5
  /// against a body of 56. Nothing in this screen's layout could have
  /// produced a different answer; the shell had taken the screen before the
  /// form was built. It is now clean for both roles two stops higher, with
  /// **nothing on this screen changed.**
  ///
  /// The one stop lost after that — a viewer at AX5 — was this screen's own,
  /// not the shell's, and is fixed by task 11.164.
  const cleanThrough = <ProjectRole, double>{
    ProjectRole.owner: 53 / 17, // AX5 — the whole ladder
    ProjectRole.viewer: 53 / 17, // AX5 — task 11.164
  };

  for (final role in [ProjectRole.owner, ProjectRole.viewer]) {
    for (final scale in iosTextScalesUpward) {
      testWidgets('the record form at ${textScaleName(scale)}, '
          'for ${role.name == 'owner' ? 'somebody who can record' : 'a viewer'}',
          (tester) async {
        final overflows = collectLayoutOverflows();
        await setUpScreen(
          tester,
          syncLive: true,
          role: role,
          textScale: scale,
        );
        final verdict = textScaleVerdict(tester, overflows);
        // **The number that tells this screen's own defects apart from the
        // shell's** (task 11.149): the scrolling form's viewport. A form that
        // is merely long shows a smaller slice of itself; a form whose
        // viewport has reached zero has been given no room at all, and no
        // layout on this screen can answer that.
        final viewport = form.evaluate().isEmpty
            ? 0.0
            : tester.getRect(form).height;
        printOnFailure('${role.name} at ${textScaleName(scale)}: '
            'form viewport ${viewport.toStringAsFixed(0)}px — $verdict');
        expect(
          verdict.clean,
          scale <= cleanThrough[role]!,
          reason: textScaleFloorReason(
            panel: 'record form, for a ${role.name}',
            scale: scale,
            declaredCleanThrough: cleanThrough[role]!,
            verdict: verdict,
          ),
        );
      });
    }
  }

  // =====================================================================
  // Task 11.197 — the floor, restated by the person it is for.
  //
  // **Tasks 11.193 and 11.195 were both written to hold one control above
  // the fold: `Preview / set position on map`.** 11.193 bought 138 logical
  // pixels for it by moving the notes box and ADVANCED below it; 11.195
  // bought another 157 by folding the record type and the tag behind a
  // header card. Michael tested the second on his phone and rejected it —
  // *"the two things that are most likely to be changed for each record —
  // is an extra click away in order to better expose options that are far
  // less likely to be used"* — and then withdrew the requirement itself:
  // **"I'm okay with notes and preview/set position on map being below the
  // fold."**
  //
  // **So the old assertion is not deleted, it is replaced**, because a
  // screen with no floor is how this screen got measured at 46 pixels short
  // in the first place. The new one is decided rather than inherited:
  //
  //   **Everything above the position row is reachable without scrolling, at
  //   the default text size, on both phones.**
  //
  // That is the record type, the tag, the bearing block, the three wheels
  // and the irregular-signal checkbox that closes them — every answer a
  // person gives on every directional record. **What is allowed below the
  // fold, by name: the position row (the coordinate and `Preview/Set`), the
  // notes box and ADVANCED.** Those are the three Michael named or accepted,
  // and naming them is the point — a floor that does not say what is outside
  // it is a floor nobody can add to deliberately.
  //
  // **This is a floor and the test font errs in its favour**, which is the
  // opposite of the situation 11.195's note described. `flutter_test`'s
  // fallback font is about twice Roboto's width (task 11.133), so this form
  // is *taller* here than on a device — the mode line and the flag take two
  // runs where a phone gives them one. A ceiling measured in it would be
  // fiction; a floor that holds in it holds on a phone. **So this one is
  // asserted on the 6.1-inch phone as well**, which the previous floor could
  // not be.
  // =====================================================================

  /// The last control above the position row on a directional record: the
  /// checkbox for a signal that sounded wrong. If it is visible, everything
  /// this floor covers is.
  ///
  /// **Measured, 2026-09-07, in this suite's font: 84 logical pixels of
  /// clearance on the 6.1-inch phone and 185 on the 6.9-inch.** And an
  /// observation rather than an assertion, because it is not the floor and
  /// nobody has asked for it: with the position row down to one line, its
  /// bottom lands at 650 against a form ending at 652 on the smaller phone —
  /// **`Preview/Set` is above the fold after all**, which is what tasks
  /// 11.193 and 11.195 spent 295 pixels failing to buy. It is not asserted
  /// because Michael withdrew the requirement and a floor nobody wants is a
  /// floor that will one day block a change he does want; and because two
  /// pixels of margin in a font twice Roboto's width is not a claim worth
  /// making. It is written down so the next person to measure this screen
  /// knows it was seen.
  final lastControlAboveTheFold =
      find.byKey(const ValueKey('record-signal-irregular'));
  final positionRow = find.byKey(const ValueKey('record-position-row'));

  for (final geometry in [phoneGeometry, phone69Geometry]) {
    testWidgets('everything above the position row is reachable without '
        'scrolling on a ${geometry.name}', (tester) async {
      await setUpScreen(tester, syncLive: true, geometry: geometry);
      expect(lastControlAboveTheFold, findsOneWidget);
      final formRect = tester.getRect(form);
      final lastRect = tester.getRect(lastControlAboveTheFold);
      printOnFailure('${geometry.name}: form '
          '${formRect.top.toStringAsFixed(0)}..'
          '${formRect.bottom.toStringAsFixed(0)}, last control above the fold '
          '${lastRect.top.toStringAsFixed(0)}..'
          '${lastRect.bottom.toStringAsFixed(0)} '
          '(${(formRect.bottom - lastRect.bottom).toStringAsFixed(0)}px of '
          'clearance)');
      expect(
        isFullyVisibleIn(tester, lastControlAboveTheFold, form),
        isTrue,
        reason: 'Task 11.197\'s floor: everything a person answers on every '
            'record is above the fold. The position row, the notes box and '
            'ADVANCED are allowed below it — Michael said so — and nothing '
            'else is. If this has failed, rule 1 applies: whatever was added '
            'goes below the position row, or behind a disclosure the way '
            'ADVANCED is.',
      );
    });
  }

  testWidgets('the coordinate and Preview/Set share one line', (tester) async {
    // **Task 11.197.** Michael: *"being adjacent to the lat/lon implies
    // position, so just saying 'Preview/Set' is sufficient."* The two were a
    // sentence on one line and a wide button on the next; they are now one
    // line, which is about 48 logical pixels back and — more to the point —
    // a button that no longer repeats what the text beside it says.
    //
    // **Asserted at tablet width for the reason the flag chip beside the
    // pulse-mode line is** (task 11.193): in this suite's font, about twice
    // Roboto's, the pair does not fit at 393 logical pixels, so "same line
    // on a phone" would be asserting a property of the test font. What is
    // asserted is that they are in one `Wrap` — so sharing a line is what
    // they do when there is room, and dropping to a second is what they do
    // instead of striping — and that they take it where there is room.
    await setUpScreen(tester, syncLive: true, geometry: tabletGeometry);
    final coordinate = find.byKey(const ValueKey('record-position-text'));
    final button =
        find.byKey(const ValueKey('record-position-preview-button'));
    expect(coordinate, findsOneWidget);
    expect(button, findsOneWidget);
    expect(
      tester.widget(positionRow),
      isA<Wrap>(),
      reason: 'A `Row` would ellipsise the coordinate — the one thing on this '
          'line that is data — as the button grew. The `Wrap` moves the '
          'button to its own run instead.',
    );
    expect(find.ancestor(of: button, matching: positionRow), findsOneWidget,
        reason: 'and the button is in it, so one line is what they do when '
            'there is room rather than a coincidence of two boxes.');
    expect(
      tester.getRect(coordinate).center.dy,
      closeTo(tester.getRect(button).center.dy, 1.0),
      reason: 'Given the width, they share the line.',
    );
    expect(find.text('Preview/Set'), findsOneWidget);
    expect(find.textContaining('position on map'), findsNothing,
        reason: 'The button no longer says what the coordinate beside it '
            'already says. If this has failed, the long label is back.');
  });

  testWidgets('on a Note, the notes box fills the space above SAVE NOTE',
      (tester) async {
    // **Michael, 2026-09-07: "on the Note record type, the notes box fills
    // the vertical space above Save note."** On a Note the box *is* the
    // record — above it there is one toggle, a tag and a coordinate — so a
    // three-line box with a scrollbar in the middle of an otherwise empty
    // screen was the wrong shape. On the other four types the notes are an
    // afterthought and stay three lines, because a bearing block is
    // competing for the same pixels.
    await setUpScreen(tester, syncLive: true, recordType: RecordType.note);
    final notes = find.byKey(const ValueKey('record-notes-field'));
    expect(notes, findsOneWidget);
    final formRect = tester.getRect(form);
    final notesRect = tester.getRect(notes);
    printOnFailure('note: form ${formRect.top.toStringAsFixed(0)}..'
        '${formRect.bottom.toStringAsFixed(0)}, notes '
        '${notesRect.top.toStringAsFixed(0)}..'
        '${notesRect.bottom.toStringAsFixed(0)} '
        '(${notesRect.height.toStringAsFixed(0)}px tall)');
    expect(
      notesRect.bottom,
      closeTo(formRect.bottom - 12, 2.0),
      reason: 'It reaches the bottom of the form, less the 12-pixel padding '
          'the body already has. If this has failed, either something was '
          'added below the notes box on a Note or the `Expanded` that fills '
          'the space has been lost.',
    );
    expect(
      notesRect.height,
      greaterThan(150),
      reason: 'A three-line box is about 80 logical pixels here. The point of '
          'the change is that a Note gets a box somebody can write in, not '
          'that it gets one pixel more than it had.',
    );
  });

  testWidgets('every other record type keeps a one-line notes box until it '
      'is tapped, and opens to four lines when it is', (tester) async {
    // **The other half of the same decision** — asserted so that "the notes
    // box grows" cannot quietly become true everywhere. On a directional
    // record the bearing block is what the screen is for, and a notes box
    // that ate the remaining height would push the floor above straight
    // through the fold.
    //
    // **One line at rest since Michael asked for it on 2026-09-07**, where
    // it used to be three. A note is written on a minority of records and
    // until it is being written it was two lines of empty box between the
    // position row and ADVANCED.
    await setUpScreen(tester, syncLive: true);
    final notes = find.byKey(const ValueKey('record-notes-field'));
    // **It is below the fold on a directional record, which is the floor
    // above working as intended** — Michael accepted the notes box being
    // there. So it has to be scrolled to before it can be measured, and a
    // `ListView` does not build what it has not reached.
    await tester.dragUntilVisible(notes, form, const Offset(0, -80));
    await tester.pumpAndSettle();
    final closed = tester.getRect(notes).height;
    printOnFailure('notes box closed: ${closed.toStringAsFixed(0)}px');
    expect(closed, lessThan(70),
        reason: 'One line and its border. If this has grown, the box is '
            'spending the form\'s headroom while it is empty.');

    await tester.tap(notes);
    await tester.pumpAndSettle();
    final open = tester.getRect(notes).height;
    printOnFailure('notes box open: ${open.toStringAsFixed(0)}px');
    expect(open, greaterThan(closed + 40),
        reason: 'Tapping it opens it to four lines — enough to see a '
            'sentence and its continuation. If this has failed, the focus '
            'node is no longer driving `minLines`/`maxLines`.');
    expect(open, lessThan(200),
        reason: 'And not so far that ADVANCED leaves the screen behind it.');
  });

  testWidgets('the opened notes box is wholly on screen, with the keyboard up',
      (tester) async {
    // **Michael, 2026-09-07, on the first version of this: "the expansion of
    // the notes pushed below the save button rather than moving the stuff
    // above the notes block up."** That is what a `ListView` does on its own
    // — a child that grows grows *downward*, into the fold, then the pinned
    // bar, then the keyboard — and nothing scrolls unless something asks it
    // to.
    //
    // **Flutter's own scroll-on-focus does not cover it, which is the part
    // worth remembering.** `EditableText` asks for the *caret* to be brought
    // on screen; the caret is on the first line, so that request is already
    // satisfied while the other three lines are under the keyboard.
    //
    // **The keyboard is simulated here, because it is half the problem.** It
    // arrives some frames after the tap and takes the bottom of the form with
    // it, so a screen that scrolled once on the tap would have put the box
    // exactly where the keyboard was about to be.
    await setUpScreen(tester, syncLive: true);
    final notes = find.byKey(const ValueKey('record-notes-field'));
    await tester.dragUntilVisible(notes, form, const Offset(0, -80));
    await tester.pumpAndSettle();

    await tester.tap(notes);
    await tester.pumpAndSettle();

    // A keyboard's worth of inset, arriving after the tap the way a real one
    // does. 336 is about an iPhone's.
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final formRect = tester.getRect(form);
    final notesRect = tester.getRect(notes);
    printOnFailure('with the keyboard up: form '
        '${formRect.top.toStringAsFixed(0)}..'
        '${formRect.bottom.toStringAsFixed(0)}, notes '
        '${notesRect.top.toStringAsFixed(0)}..'
        '${notesRect.bottom.toStringAsFixed(0)}');
    // Measured 2026-09-07: the box lands at 306..422 inside a viewport
    // ending at 430 — the whole of it, with the 8 pixels of air the reveal
    // asks for. Before the fix it sat at 354..470, forty pixels of it under
    // the pinned bar.
    expect(
      isFullyVisibleIn(tester, notes, form),
      isTrue,
      reason: 'The whole opened box is inside the form\'s viewport, which '
          'ends above the pinned SAVE bar and above the keyboard. If this has '
          'failed, either `_scrollNotesIntoView` is no longer being called or '
          'it is being called before the taller box exists — scrolling to a '
          'one-line box moves the form by the wrong amount.',
    );
  });

  testWidgets('on a Note, the keyboard takes the record type and the tag off '
      'the top rather than lines off the box', (tester) async {
    // **Michael, 2026-09-07: "the opening of the keyboard simply reduces the
    // size of the large notes block... in all cases it should move up the
    // other items above it."**
    //
    // The Note's box fills what is left, and when the keyboard comes up
    // there is very little left — measured before the fix, it fell to a
    // single line. The fix is that a Note being written stops filling and
    // starts demanding: eight lines, which is more than the keyboard leaves,
    // so the column outgrows its viewport and the form scrolls instead.
    await setUpScreen(tester, syncLive: true, recordType: RecordType.note);
    final notes = find.byKey(const ValueKey('record-notes-field'));
    final atRest = tester.getRect(notes).height;

    await tester.tap(notes);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 336);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final formRect = tester.getRect(form);
    final notesRect = tester.getRect(notes);
    printOnFailure('note at rest ${atRest.toStringAsFixed(0)}px; with the '
        'keyboard up form ${formRect.top.toStringAsFixed(0)}..'
        '${formRect.bottom.toStringAsFixed(0)}, notes '
        '${notesRect.top.toStringAsFixed(0)}..'
        '${notesRect.bottom.toStringAsFixed(0)} '
        '(${notesRect.height.toStringAsFixed(0)}px tall)');

    expect(
      notesRect.height,
      greaterThan(formRect.height / 2),
      reason: 'The box keeps most of what is left of the screen. If this has '
          'failed it has gone back to filling — `Expanded` fills what is '
          'left, and with a keyboard up what is left is one line.',
    );
    expect(
      isFullyVisibleIn(tester, notes, form),
      isTrue,
      reason: 'And the whole of it is on screen, which is what the form '
          'scrolling up is for.',
    );
    // **What is deliberately not asserted here, and why the obvious version
    // of it was wrong.** The first draft checked that the record-type picker
    // had scrolled off the top by looking for
    // `find.text(RecordType.directional.label)` — **which finds nothing on a
    // Note page whatever happens**, because only the *selected* segment
    // shows a word and the other four are icons. It passed for no reason.
    // The picker moving out of the way is asserted below, on a surface short
    // enough that it has to.
  });

  testWidgets('on a Note with no room, the picker goes off the top and the '
      'box keeps its size', (tester) async {
    // The other half of the same behaviour: when the eight lines and
    // everything above them cannot both fit, **it is the things above that
    // give way**. That is Michael's *"in all cases it should move up the
    // other items above it"*, and it needs a surface where the two are
    // genuinely in competition — at full phone height with a keyboard up
    // they both fit, which is the outcome the fix is for rather than a case
    // that exercises the scroll.
    await setUpScreen(tester, syncLive: true, recordType: RecordType.note);
    // **A phone short enough that the box and the picker cannot both fit,
    // and no shorter.** 760 logical pixels with an ordinary 336-pixel
    // keyboard leaves the form about 300 — room for the eight-line box and
    // not for what sits above it. Making it shorter than that would leave
    // room for neither, which measures nothing: the box would be cut off
    // whatever this screen did.
    tester.view.physicalSize = const Size(393 * 3, 760 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpAndSettle();

    final notes = find.byKey(const ValueKey('record-notes-field'));
    await tester.tap(notes);
    await tester.pumpAndSettle();
    tester.view.viewInsets = const FakeViewPadding(bottom: 336 * 3);
    addTearDown(tester.view.resetViewInsets);
    await tester.pumpAndSettle();

    final formRect = tester.getRect(form);
    final notesRect = tester.getRect(notes);
    printOnFailure('short surface, keyboard up: form '
        '${formRect.top.toStringAsFixed(0)}..'
        '${formRect.bottom.toStringAsFixed(0)}, notes '
        '${notesRect.top.toStringAsFixed(0)}..'
        '${notesRect.bottom.toStringAsFixed(0)} '
        '(${notesRect.height.toStringAsFixed(0)}px tall)');

    // **Asserted by position, not by absence**, and both of the obvious
    // shortcuts are wrong here. `find.text` of an *unselected* record type
    // finds nothing whatever happens, because those four are icons. And on a
    // Note the form is a `SingleChildScrollView`, so everything in it stays
    // built whether or not it is on screen — "not found" would never be true
    // no matter how far this scrolled.
    expect(
      tester.getRect(find.byKey(const ValueKey('record-type-toggle'))).bottom,
      lessThan(tester.getRect(form).top),
      reason: 'The record-type picker has scrolled clear off the top of the '
          'form. That is Michael\'s "move up the other items above it": when '
          'the box and the things above it cannot both fit, it is the things '
          'above that give way.',
    );
    expect(
      isFullyVisibleIn(tester, notes, form),
      isTrue,
      reason: 'and the whole box is on screen, which is what it was moved '
          'out of the way for.',
    );
  });

  testWidgets('the notes box closes again when focus leaves, and keeps what '
      'was typed', (tester) async {
    // **Michael, 2026-09-07: "the note section should shrink back down to
    // one line when they click outside... but keep the entered text."** The
    // text lives in the controller and in the autosaved draft; only the
    // number of lines drawn changes, and this is what says so.
    await setUpScreen(tester, syncLive: true);
    final notes = find.byKey(const ValueKey('record-notes-field'));
    await tester.dragUntilVisible(notes, form, const Offset(0, -80));
    await tester.pumpAndSettle();

    await tester.tap(notes);
    await tester.pumpAndSettle();
    await tester.enterText(notes, 'heard it twice from the ridge');
    await tester.pumpAndSettle();
    final open = tester.getRect(notes).height;

    // A tap anywhere that is not the field. `onTapOutside` is what carries
    // this, and it is the same callback that puts the keyboard away —
    // Flutter's default handler for it does nothing at all on iOS and
    // Android, which is why the field passes its own.
    await tester.tapAt(tester.getCenter(subject));
    await tester.pumpAndSettle();

    // **Focus and the keyboard are asserted before the box's height**, and
    // the order is deliberate. All three come from the same `unfocus()`, so
    // whichever is checked first is the one that reports the failure —
    // and "the keyboard is still up over the wheels" is the more useful
    // thing to be told than "the box is 116 pixels tall."
    expect(
      tester.widget<TextField>(notes).focusNode!.hasFocus,
      isFalse,
      reason: 'The field let go of focus. `FocusManager.primaryFocus` is the '
          'wrong thing to ask here — focus moves to the enclosing scope '
          'rather than to nothing, so that node reports `hasFocus` either '
          'way and the check would pass with the fix removed.',
    );
    expect(
      tester.testTextInput.isVisible,
      isFalse,
      reason: 'And the keyboard is down, which is the half Michael asked '
          'for and the half that is not implied by the box closing. This '
          'asks the platform text-input channel directly rather than '
          'inferring it from focus.',
    );
    // **Watched red on 2026-09-07 by deleting the field\'s `onTapOutside`**,
    // which is what carries all three of these. The focus assertion above is
    // the one that fires; this one is a second, independent reading of the
    // same outcome through the platform channel rather than a separately
    // falsifiable claim, and is worth having for the day somebody changes
    // *how* the keyboard is dismissed.

    expect(tester.getRect(notes).height, lessThan(open - 40),
        reason: 'It closed.');
    expect(
      tester.widget<TextField>(notes).controller!.text,
      'heard it twice from the ridge',
      reason: 'and the sentence is still there. Closing the box is a change '
          'to how many lines are drawn, not to what was written.',
    );
  });

  testWidgets('a Note still scrolls when it cannot fit', (tester) async {
    // **The half that is easy to get wrong.** `Expanded` needs a bounded
    // height, and the obvious way to give it one — swap the scrolling list
    // for a `Column` — turns every text size above the default into an
    // overflow stripe. What is used instead is a scroll view whose child is
    // *at least* a viewport tall, so the column grows past the viewport and
    // the whole thing scrolls exactly as the list did.
    //
    // AX5 on the smallest phone is the case that proves it: the content is
    // far taller than the surface, so nothing may stripe and the notes box
    // must fall back to its natural height rather than being squeezed to
    // nothing.
    final overflows = collectLayoutOverflows();
    await setUpScreen(
      tester,
      syncLive: true,
      recordType: RecordType.note,
      textScale: 53 / 17,
    );
    final verdict = textScaleVerdict(tester, overflows);
    printOnFailure('note at AX5: $verdict');
    expect(verdict.clean, isTrue,
        reason: 'A `Column` here would stripe. The scroll view is what makes '
            'the fill safe.');
    expect(tester.getRect(find.byKey(const ValueKey('record-notes-field')))
        .height, greaterThan(0));
  });

  testWidgets('the flag for a signal that sounded wrong shares the pulse-mode '
      'line rather than taking a row of its own', (tester) async {
    // **What the control cost, and why the check is structural rather than a
    // number.** The chip is laid out beside the pulse-mode line, so what it
    // spends is the difference between its tap target and a line of 12-point
    // text: **31 logical pixels at the default text size**, measured. A row of
    // its own would have been about 54, and this screen had no row to give.
    //
    // **At the largest accessibility size it takes a row anyway, and that is
    // the `Wrap` working rather than the saving evaporating.** Measured at
    // AX5: the chip is 71 pixels tall, the line beside it 53, and they no
    // longer fit side by side at any phone width — so the chip drops to its
    // own run and costs 75 (71 plus the 4-pixel run gap). On a form that
    // scrolls that is length; the alternative at that size is a stripe.
    //
    // The two are in one `Wrap`, which is the half that can refuse: when they
    // do not fit side by side the chip moves to its own line instead of
    // striping. **In this suite's font, about twice Roboto's width (task
    // 11.133), they never fit at phone width** — so asserting "same line at
    // 393 pixels" would assert a property of the test font. What is asserted
    // instead is that they are in the same `Wrap` (so one line is what they do
    // when there is room) and that they take it on a surface wide enough for
    // both, which is the tablet the harness already photographs.
    await setUpScreen(tester, syncLive: true, geometry: tabletGeometry);
    final chip = find.byKey(const ValueKey('record-signal-irregular'));
    final modeLine = find.byKey(const ValueKey('record-pulse-mode-line'));
    expect(chip, findsOneWidget);
    expect(modeLine, findsOneWidget);

    expect(
      find.ancestor(of: chip, matching: find.byType(Wrap)),
      findsOneWidget,
      reason: 'A `Row` here overflowed by 58 pixels at AX1 — the chip keeps '
          'growing after the sentence beside it has run out of room to '
          'ellipsise. The `Wrap` is what says no, by moving the chip down a '
          'line on a form that scrolls.',
    );
    expect(
      tester.getRect(modeLine).center.dy,
      closeTo(tester.getRect(chip).center.dy, 1.0),
      reason: 'Given the width, they share the line — which is what makes the '
          'flag cost 31 pixels instead of a whole row.',
    );
    expect(
      tester.getRect(chip).height,
      greaterThanOrEqualTo(44.0),
      reason: 'Rule 4: 44-point tap targets are the floor on a screen used in '
          'gloves. The chip body is smaller than this; the target is not.',
    );
  });

  testWidgets('ticking the flag changes nothing else on the form',
      (tester) async {
    // The flag is one bit about what was heard. It does not withdraw the
    // bearing (that is `ObservationExclusion`, task 11.7) and it does not
    // move a roller, so nothing on this screen may move when it is set —
    // which is what makes the floor above hold in both of the screen's
    // states. **Task 11.197 turned it from a chip into a checkbox and this
    // still has to be true**: a control that grew a line when it was ticked
    // would push everything under it down at exactly the moment somebody is
    // telling the app that something is wrong.
    await setUpScreen(tester, syncLive: true, geometry: phone69Geometry);
    final before = tester.getRect(positionRow);
    await tester.tap(find.byKey(const ValueKey('record-signal-irregular')));
    await tester.pumpAndSettle();
    expect(tester.getRect(positionRow), before);
    expect(isFullyVisibleIn(tester, lastControlAboveTheFold, form), isTrue);
  });

  // =====================================================================
  // Task 11.241 — recording is unchanged, and this is the check that it is.
  //
  // The Record screen still picks a collar, because the receiver is tuned to
  // a frequency. The one thing 11.241 added to this screen is the animal's
  // name on the wheel's line, and only when it differs from the collar's.
  // Michael's standing rule is that the common case must not pay for the
  // rare one, so the assertion is by position rather than by absence: the
  // fold — where the bearing controls sit — is at the same pixel with a
  // collar named after its animal, with a collar whose animal has another
  // name, and it was there before this task (the floor test above).
  // =====================================================================
  testWidgets('the animal adds nothing above the fold at phone width — the '
      'bearing controls sit at the same pixel whatever the animal is called',
      (tester) async {
    await setUpScreen(tester);
    final sameName = tester.getRect(subject);
    final wheelSame = tester.getRect(find.byType(WheelPicker<Tag>));
    expect(find.textContaining('150.325 MHz · Coco'), findsWidgets,
        reason: 'the animal is named after the collar here');
    expect(isFullyVisibleIn(tester, subject, form), isTrue);

    await setUpScreen(tester, animalName: 'Marie');
    expect(find.textContaining('150.325 MHz · Marie'), findsWidgets,
        reason: 'the animal\'s name and the frequency — the collar\'s own ID '
            'is not on the wheel (Michael, 2026-09-14)');
    expect(find.textContaining('Coco'), findsNothing);
    expect(
      tester.getRect(subject),
      sameName,
      reason: 'the POINT / RANGE controls have not moved by a pixel',
    );
    expect(
      tester.getRect(find.byType(WheelPicker<Tag>)),
      wheelSame,
      reason: 'the wheel is the same size — the name rides on its one line',
    );
    expect(isFullyVisibleIn(tester, subject, form), isTrue);
  });

  // =====================================================================
  // Task 11.244 — Michael: *"It should be the same as it is today."*
  //
  // 11.244 built a screen for the animals and the §5a linking flow. **It
  // changed nothing here**, and the test above proves that only *relatively*
  // — it compares two runs of this screen against each other, so a change
  // that pushed the fold down in both would pass it.
  //
  // This one pins the number. It is a measurement, not a target: if it
  // fails, something was added above the bearing controls, and the answer is
  // rule 1 — put the new thing below the subject, or behind a disclosure —
  // not a bigger number here.
  // =====================================================================

  /// How far below the top of the scrolling form the POINT / RANGE controls
  /// begin, at 6.1-inch phone width and the default text size, inside the
  /// real app shell.
  ///
  /// **Measured 2026-09-14 (task 11.244)** with the record-type toggle and
  /// the tag wheel above it, and nothing else. The tolerance is a pixel:
  /// this is a layout that either moved or did not. **Re-measured the same
  /// day by task 11.249**, which put a sort switch beside the wheel and took
  /// the pulse rate off its line: still 186 — the switch is the wheel's
  /// height and the line is the wheel's one row.
  const declaredFoldOffset = 186.0;

  testWidgets('the bearing controls begin where they began — the fold is '
      'measured, not just compared', (tester) async {
    await setUpScreen(tester);
    final offset = tester.getRect(subject).top - tester.getRect(form).top;
    printOnFailure('fold offset ${offset.toStringAsFixed(1)}px '
        '(declared $declaredFoldOffset)');
    expect(
      offset,
      closeTo(declaredFoldOffset, 1),
      reason: 'Something was added above the POINT / RANGE controls, or the '
          'wheel changed height. The Record screen is the one a person uses '
          'all day with one free hand and an animal still audible; read the '
          'SPACE BUDGET at the top of observation_logging_screen.dart before '
          'changing this number.',
    );
  });

  testWidgets('a bare-day pair from an older build costs the fold nothing '
      '(task 11.263) — the prompt task 11.260 put above the wheel is gone, '
      'measured rather than assumed', (tester) async {
    // Task 11.260 measured its prompt pushing the fold down by its own
    // height, and 11.262's chooser was taller still. Both are deleted: the
    // interlock no longer lets this app write the pair they explained
    // (design §6a). The fold with such a pair present is therefore the fold
    // without it — re-measured here rather than inferred from the deletion,
    // because "the widget is gone" and "nothing else took its place" are
    // two different claims.
    await setUpScreen(tester);
    final before = tester.getRect(subject).top - tester.getRect(form).top;

    await setUpScreen(tester, legacyHandover: true);
    expect(find.byKey(const ValueKey('record-handover-time-prompt')),
        findsNothing);
    final after = tester.getRect(subject).top - tester.getRect(form).top;
    printOnFailure('fold with a legacy bare-day pair ${after.toStringAsFixed(1)}px '
        '(without $before, declared $declaredFoldOffset)');
    expect(after, closeTo(before, 0.5),
        reason: 'nothing above the wheel reacts to the pair any more');
    expect(after, closeTo(declaredFoldOffset, 1));
  });

  testWidgets('a collar that has been on two animals in turn shows the one '
      'wearing it now, and the fold has not moved', (tester) async {
    // **Task 11.243 made a collar able to have worn several animals**, and
    // the wheel shows one name. Which one is `latestAnimalForTag`'s answer —
    // whose collar this is — and the Record screen is the place that most
    // obviously wants it: a person recording a bearing is recording it
    // against the collar on the animal it is on today.
    await setUpScreen(tester, animalName: 'Marie', previousAnimalName: 'Kea');
    expect(find.textContaining('150.325 MHz · Marie'), findsWidgets);
    expect(
      find.textContaining('Kea'),
      findsNothing,
      reason: 'the animal that wore it last season is not the one it is on',
    );
    final offset = tester.getRect(subject).top - tester.getRect(form).top;
    expect(offset, closeTo(declaredFoldOffset, 1));
  });

  // =====================================================================
  // Task 11.249 — a change *inside* the fold, measured rather than judged.
  //
  // The pulse rate left the collar's line and a sort switch arrived beside
  // the wheel. The fold test above says the bearing controls did not move
  // (186, unchanged); these two say what happened inside the wheel's box.
  // =====================================================================

  /// How many of the wheel's rows are on screen at once, at phone width.
  /// **Measured 2026-09-14 before the change: 3**, with five collars seeded
  /// (106 logical pixels of wheel at a 34-pixel row extent). The switch
  /// declares the wheel's own height rather than a height of its own, so
  /// this cannot move unless somebody changes `kTagWheelHeight`.
  const declaredWheelRows = 3;

  testWidgets('the wheel still shows the same number of rows with the sort '
      'switch beside it', (tester) async {
    await setUpScreen(tester, extraTags: 4);
    final wheelFinder = find.byType(WheelPicker<Tag>);
    final wheel = tester.getRect(wheelFinder);
    var rows = 0;
    for (final e in find.descendant(of: wheelFinder, matching: find.byType(Text)).evaluate()) {
      final r = tester.getRect(find.byWidget(e.widget));
      if (r.top >= wheel.top - 0.5 && r.bottom <= wheel.bottom + 0.5) rows++;
    }
    printOnFailure('wheel ${wheel.height.toStringAsFixed(1)}px tall, '
        '$rows rows wholly inside it (declared $declaredWheelRows)');
    expect(rows, declaredWheelRows,
        reason: 'The wheel shows the same number of rows it did before the '
            'switch. If this has failed the wheel changed height — the switch '
            'is sized from `kTagWheelHeight`, so look there — or the row '
            'extent did.');
    expect(rows, greaterThanOrEqualTo(2),
        reason: 'A count of one would pass by finding the centred row alone.');
  });

  testWidgets('the sort switch costs the wheel exactly its own width and gap, '
      'and nothing else on the form moved for it', (tester) async {
    await setUpScreen(tester);
    final wheel = tester.getRect(find.byType(WheelPicker<Tag>));
    final freq = tester.getRect(find.byKey(const ValueKey('tag-wheel-sort-frequency')));
    final animal = tester.getRect(find.byKey(const ValueKey('tag-wheel-sort-animal')));
    // The record-type toggle above the wheel is the form's full content
    // width; the switch's right edge lands on it, so the switch was paid
    // for by the wheel and not by the form getting wider.
    final toggle = tester.getRect(find.byType(SegmentedToggle<RecordType>));
    // The widths are exact in any font (task 11.133): a margin is a margin.
    expect(freq.width, kTagWheelSortWidth);
    expect(animal.width, kTagWheelSortWidth);
    expect(freq.left - wheel.right, closeTo(kTagWheelSortGap, 0.5));
    expect(freq.right, closeTo(toggle.right, 0.5),
        reason: 'the switch ends where the form content ends');
    expect(wheel.left, closeTo(toggle.left, 0.5));
    expect(wheel.width, closeTo(toggle.width - kTagWheelSortWidth - kTagWheelSortGap, 0.5),
        reason: 'the wheel gave up exactly ${kTagWheelSortWidth + kTagWheelSortGap} '
            'logical pixels — 46 on 2026-09-14, 353 → 307 at 6.1-inch width');
    // Both buttons inside the wheel's height, whole, with room to be hit.
    for (final r in [freq, animal]) {
      expect(r.top, greaterThanOrEqualTo(wheel.top - 0.5));
      expect(r.bottom, lessThanOrEqualTo(wheel.bottom + 0.5));
      expect(r.height, greaterThanOrEqualTo(44),
          reason: 'rule 4: 44-point targets, gloves');
    }
    expect(animal.top, greaterThanOrEqualTo(freq.bottom),
        reason: 'stacked, not overlapping');

    // The half that depends on the font is printed, not asserted. The
    // centred collar line lost "· 40 bpm": in the test font that is 162
    // logical pixels at the centred size, in Roboto it measured **76–78**
    // (2026-09-14, from the SDK's own Roboto files); the switch took 46. So
    // on a phone the name has about 30 pixels more than it had, and the
    // realistic line — at most "150.523 MHz · 150.523 (Marie)", 257 in Roboto,
    // and shorter since the tag ID left the wheel — fits
    // in the 284 the centred label box now has. See `kTagWheelSortWidth`.
    final centred = tester.renderObject<RenderParagraph>(
      find.descendant(of: find.byType(WheelPicker<Tag>), matching: find.text('150.325 MHz · Coco')),
    );
    printOnFailure('centred label box ${centred.size.width.toStringAsFixed(1)}px '
        '(330 before the switch, 284 after, measured 2026-09-14)');
    expect(centred.size.width, greaterThanOrEqualTo(257),
        reason: 'the realistic line must fit in Roboto (257 px measured); if '
            'the label box has shrunk below that, the switch has to move '
            'rather than the wheel shrinking — the plan\'s own rule');
  });
}
