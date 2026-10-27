import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/models/tag.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/position_estimation/screens/position_estimation_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../../data/fixtures.dart';
import '../../../support/fake_shared_preferences.dart';

/// Task 11.5: a teammate's bearing is included in every Position Estimation
/// solve by default (Phase 6 replica import), but until now was visually
/// identical to the current user's own — this is the regression coverage for
/// making that observer visible, and for the distance sort's "never lie
/// about what it's sorted by" rule carried over from task 11.4.
///
/// Modeled on `map_screen_test.dart`: this screen's directional-observations
/// and observer-lookup providers are private and can't be overridden, so
/// rows are seeded through the real repositories inside `runAsync`, and the
/// map's `TileLayer` issues real network requests that never resolve under
/// `flutter test` — deliberate plain `pump()` calls, never `pumpAndSettle()`.
void main() {
  setUp(installFakeSharedPreferences);

  /// The map's attribution row overflows the default 800x600 test surface —
  /// same fix `map_screen_test.dart` needed.
  void useWideSurface(WidgetTester tester, {double height = 1200}) {
    tester.view.physicalSize = Size(1200, height);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required Project project,
    required List<User> users,
    required Tag tag,
    required List<Observation> observations,
    Stream<Position>? gpsStream,
    // Task 11.14: when set, the acting user is given this role via a
    // membership row and `currentUserProvider` is overridden to them, so a
    // role-aware control's gating can be exercised. Callers that don't pass
    // this get the device's own fresh user, **seeded onto the project as a
    // contributor** — until task 11.237 a membership-less user resolved to
    // "this device can't say" and every write control defaulted to
    // permitted; now a user the device can see is not on the project holds a
    // read-only snapshot, and these tests are about a member's screen.
    User? actingUser,
    ProjectRole? role,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => gpsStream ?? const Stream.empty()),
        if (actingUser != null) currentUserProvider.overrideWith((ref) async => actingUser),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      final obsRepo = await container.read(observationRepositoryProvider.future);

      for (final u in users) {
        await userRepo.insert(u);
      }
      await projectRepo.insert(project);
      // Task 11.237: every row planted below is planted *as* the user its
      // audit column names, and the repository refuses a non-member — so the
      // fixture's users, the fixture's stamp (`sampleSync` says `user-1`)
      // and, unless a role is being granted explicitly, the acting user are
      // all put on the project first.
      final db = (await container.read(appDatabaseProvider.future)).raw;
      await seedContributors(
        db,
        projectId: project.projectId,
        userIds: [
          for (final u in users) u.userId,
          'user-1',
          if (actingUser == null)
            (await container.read(currentUserProvider.future)).userId
          else if (role == null)
            actingUser.userId,
        ],
      );
      await tagRepo.insert(tag);
      for (final o in observations) {
        await obsRepo.insert(o);
      }
      if (actingUser != null && role != null) {
        if (!users.any((u) => u.userId == actingUser.userId)) {
          await userRepo.insert(actingUser);
        }
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(
            projectId: project.projectId,
            userId: actingUser.userId,
            role: role,
          ).toColumns(),
        );
      }

      await container.read(activeProjectIdProvider.notifier).set(project.projectId);
      // Pre-resolved for the same reason `tag_database_screen_test.dart`
      // pre-resolves `mayCreateTagProvider`: a fresh FFI call triggered
      // after pumping never resolves inside `testWidgets`' fake-async zone.
      // For every caller since task 11.237, because the screen now reads the
      // standing for everybody, not only when a role was granted.
      container.listen(myProjectStandingProvider(project.projectId), (_, _) {});
      await container.read(myProjectStandingProvider(project.projectId).future);
    });

    return container;
  }

  /// Stops pumping the instant the real repository-backed providers have
  /// resolved, rather than a fixed number of extra pumps — each further pump
  /// re-triggers the map's `CachedTileProvider` (a fresh instance every
  /// build) into firing more never-resolving tile fetches under `flutter
  /// test`, and letting those pile up is what turns "expected image-load
  /// noise" (as tolerated in `map_screen_test.dart`) into `takeException()`
  /// seeing more than one pending exception and refusing to pick one.
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    await tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const PositionEstimationScreen()),
        ),
      );
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw TestFailure('pumpScreen: still loading after 5s');
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
      }
    });
  }


  /// Task 11.109 replaced the three permanently-visible sort `ChoiceChip`s
  /// with one button that opens a menu — the row they occupied was part of
  /// what left the bearings list with no visible row on a phone. The rule
  /// from tasks 11.4/11.5 is unchanged and is what these tests still hold:
  /// distance sort must present as unavailable *with a visible reason* when
  /// there is no GPS fix, and the button must name the order the list is
  /// actually in.
  Future<void> openSortMenu(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.sort));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> chooseSort(WidgetTester tester, String label) async {
    await openSortMenu(tester);
    await tester.tap(find.text(label).last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Two observers on the same tag: Alice's bearing due north, Bob's due
  /// east, both from points far enough apart to give the solver a real fix
  /// rather than a degenerate one.
  ({Project project, User alice, User bob, Tag tag, Observation aliceObs, Observation bobObs})
      twoObserverFixture() {
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-bob');
    final alice = sampleUser(id: 'user-alice', email: 'alice@example.com')
        .copyWith(firstName: 'Alice', lastName: 'Vega');
    final bob =
        sampleUser(id: 'user-bob', email: 'bob@example.com').copyWith(firstName: 'Bob', lastName: 'Wren');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final aliceObs = sampleObservation(
      id: 'obs-alice',
      projectId: project.projectId,
      userId: alice.userId,
      tagId: tag.tagId,
      sessionId: null,
      latitude: 35.10,
      longitude: -111.70,
    ).copyWith(trueNorthBearing: 90.0, magneticBearing: 90.0);
    final bobObs = sampleObservation(
      id: 'obs-bob',
      projectId: project.projectId,
      userId: bob.userId,
      tagId: tag.tagId,
      sessionId: null,
      latitude: 35.10,
      longitude: -111.50,
    ).copyWith(trueNorthBearing: 200.0, magneticBearing: 200.0);
    return (project: project, alice: alice, bob: bob, tag: tag, aliceObs: aliceObs, bobObs: bobObs);
  }

  testWidgets('teammates\' bearings are attributed by observer name, not colour alone',
      (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, f.bobObs],
    );
    await pumpScreen(tester, container);

    expect(tester.takeException(), isNull);
    // Task 11.274, Michael: "you don't need the user name as well" — Alice
    // and Bob's initials don't collide (AV, BW), so the row's visible line
    // drops the short name the badge already carries. The full name is
    // still there for a screen reader (Semantics) and a sighted long-press
    // (Tooltip), just not painted twice.
    expect(find.textContaining('A. Vega'), findsNothing);
    expect(find.textContaining('B. Wren'), findsNothing);
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Alice Vega'),
      findsOneWidget,
    );
    expect(
      find.byWidgetPredicate((w) => w is Tooltip && w.message == 'Bob Wren'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Alice Vega, ')),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel(RegExp('^Bob Wren, ')),
      findsOneWidget,
    );
    // The badge carries initials as text, not just a colour swap — the
    // project's standing rule against colour-only cues.
    expect(find.text('AV'), findsOneWidget);
    expect(find.text('BW'), findsOneWidget);
  });

  // Task 11.274: two observers whose initials collide keep the visible short
  // name — the badge alone would be ambiguous between them.
  testWidgets(
      'two observers who share an initials pair keep the short name on the '
      'row, not just in the badge', (tester) async {
    useWideSurface(tester);
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-jane');
    final jane =
        sampleUser(id: 'user-jane', email: 'jane@example.com').copyWith(firstName: 'Jane', lastName: 'Doe');
    final john =
        sampleUser(id: 'user-john', email: 'john@example.com').copyWith(firstName: 'John', lastName: 'Doe');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final janeObs = sampleObservation(
      id: 'obs-jane',
      projectId: project.projectId,
      userId: jane.userId,
      tagId: tag.tagId,
      sessionId: null,
      latitude: 35.10,
      longitude: -111.70,
    ).copyWith(trueNorthBearing: 90.0, magneticBearing: 90.0);
    final johnObs = sampleObservation(
      id: 'obs-john',
      projectId: project.projectId,
      userId: john.userId,
      tagId: tag.tagId,
      sessionId: null,
      latitude: 35.10,
      longitude: -111.50,
    ).copyWith(trueNorthBearing: 200.0, magneticBearing: 200.0);
    final container = await readyContainer(
      tester,
      project: project,
      users: [jane, john],
      tag: tag,
      observations: [janeObs, johnObs],
    );
    await pumpScreen(tester, container);

    expect(tester.takeException(), isNull);
    // Both badges read "JD" — the collision this test is about.
    expect(find.text('JD'), findsNWidgets(2));
    expect(find.textContaining('J. Doe'), findsNWidgets(2));
  });

  // Task 11.274: Michael's device logs showed `SegmentedToggle`'s `Row`
  // thrown from `performLayout` with `size: MISSING`, and the same
  // `RenderDecoratedBox` id in a second log producing "RenderBox was not
  // laid out" and "cannot hit test a render box with no size" — the map
  // layers card sits in this screen's corner-buttons `Column`, which a
  // `Positioned(top:, right:)` gives no width constraint at all.
  testWidgets('opening the map-type card does not throw a layout exception',
      (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, f.bobObs],
    );
    await pumpScreen(tester, container);

    await tester.tap(find.byTooltip('Map type'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    // Two of each since task 11.319: `MapTypeToggle` draws the toggle once as
    // the dark outline behind the real one, and both carry the words.
    expect(find.text('Terrain'), findsNWidgets(2));
    expect(find.text('Street'), findsNWidgets(2));
    expect(find.text('Satellite'), findsNWidgets(2));
  });

  // Task 11.274, Michael: "the animal it was mounted to isn't listed so you
  // don't know who you are taking a position on … the animal name has to be
  // in the list too." The bar and the wheel both read `Tag.individualName`,
  // the same current-owner join the Tag Database and the Record wheel use.
  group('the tag picker names the animal (task 11.274)', () {
    testWidgets('the bar names the collar\'s current animal, animal first',
        (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
      );
      await tester.runAsync(() async {
        final individualRepo = await container.read(individualRepositoryProvider.future);
        final deploymentRepo = await container.read(deploymentRepositoryProvider.future);
        await individualRepo.insert(
          sampleIndividual(id: 'individual-marie', projectId: f.project.projectId, name: 'Marie'),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'deployment-marie',
            projectId: f.project.projectId,
            tagId: f.tag.tagId,
            individualId: 'individual-marie',
          ),
        );
      });
      await pumpScreen(tester, container);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('Marie · ${f.tag.tagName}'), findsOneWidget);
    });

    testWidgets(
        'a collar reassigned to a second animal names the current one, not '
        'the collar alone', (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
      );
      await tester.runAsync(() async {
        final individualRepo = await container.read(individualRepositoryProvider.future);
        final deploymentRepo = await container.read(deploymentRepositoryProvider.future);
        await individualRepo.insert(
          sampleIndividual(id: 'individual-old', projectId: f.project.projectId, name: 'OldOwner'),
        );
        await individualRepo.insert(
          sampleIndividual(id: 'individual-new', projectId: f.project.projectId, name: 'NewOwner'),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'deployment-old',
            projectId: f.project.projectId,
            tagId: f.tag.tagId,
            individualId: 'individual-old',
            attachedDate: DateTime.now().subtract(const Duration(days: 30)),
            removedDate: DateTime.now().subtract(const Duration(days: 10)),
          ),
        );
        await deploymentRepo.link(
          sampleDeployment(
            id: 'deployment-new',
            projectId: f.project.projectId,
            tagId: f.tag.tagId,
            individualId: 'individual-new',
            attachedDate: DateTime.now().subtract(const Duration(days: 5)),
          ),
        );
      });
      await pumpScreen(tester, container);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('NewOwner'), findsOneWidget);
      expect(find.textContaining('OldOwner'), findsNothing);
    });

    testWidgets('a collar on nobody keeps its plain line, with no placeholder',
        (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
      );
      await pumpScreen(tester, container);

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('${f.tag.tagName} · ${f.tag.frequencyMhz.toStringAsFixed(3)} MHz'),
        findsOneWidget,
      );
    });
  });

  // =====================================================================
  // The bearing row a person actually decides on — Michael, 2026-09-07:
  // "the bearing quality is shown in the position screen — where you'd care
  // about excluding it. The words ... should probably be updated with colors
  // green, yellow, red."
  //
  // Two things were wrong and only one of them was the colour. The row
  // printed `bearingQuality.db` and `signalStrength.db`, which are the
  // **stored tokens**: a bounced bearing read `suspected_bounce` and the
  // strongest signal read `very_strong`, underscores and all, on the one
  // screen where somebody is choosing what evidence to count. The Record
  // screen had been showing `Bounce?` in red the whole time.
  // =====================================================================

  ({Project project, User alice, Tag tag, List<Observation> observations})
      qualityFixture() {
    final project = sampleProject(id: 'project-1', ownerUserId: 'user-alice');
    final alice = sampleUser(id: 'user-alice', email: 'a@example.com')
        .copyWith(firstName: 'Alice', lastName: 'Vega');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    Observation at(
      int i, {
      required BearingQuality quality,
      required SignalStrength strength,
      bool? irregular,
    }) =>
        sampleObservation(
          id: 'obs-$i',
          projectId: project.projectId,
          userId: alice.userId,
          tagId: tag.tagId,
          sessionId: null,
          latitude: 35.10 + i * 0.004,
          longitude: -111.70 + i * 0.006,
          signalIrregular: irregular,
        ).copyWith(
          trueNorthBearing: 60.0 + i * 20,
          magneticBearing: 60.0 + i * 20,
          bearingQuality: quality,
          signalStrength: strength,
        );
    return (
      project: project,
      alice: alice,
      tag: tag,
      observations: [
        at(0, quality: BearingQuality.good, strength: SignalStrength.strong),
        at(1, quality: BearingQuality.fair, strength: SignalStrength.medium),
        at(2,
            quality: BearingQuality.suspectedBounce,
            strength: SignalStrength.veryStrong),
      ],
    );
  }

  /// The `TextSpan` the row's subtitle is built from, flattened to the string
  /// a person reads — the row is now rich text, so `find.text` on the whole
  /// line cannot see it.
  String subtitleTextOf(WidgetTester tester, String observationId) {
    final tile = tester.widget<CheckboxListTile>(
      find.byKey(ValueKey('bearing-row-$observationId')),
    );
    return (tile.subtitle! as Text).textSpan!.toPlainText();
  }

  /// The colour the quality word is drawn in, or null if it is not coloured.
  Color? qualityColourOf(WidgetTester tester, String observationId, String word) {
    final tile = tester.widget<CheckboxListTile>(
      find.byKey(ValueKey('bearing-row-$observationId')),
    );
    Color? found;
    (tile.subtitle! as Text).textSpan!.visitChildren((span) {
      if (span is TextSpan && span.text == word) {
        found = span.style?.color;
        return false;
      }
      return true;
    });
    return found;
  }

  testWidgets('the bearing row shows the words a person saw when recording, '
      'not the database tokens', (tester) async {
    useWideSurface(tester);
    final f = qualityFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice],
      tag: f.tag,
      observations: f.observations,
    );
    await pumpScreen(tester, container);
    expect(tester.takeException(), isNull);

    expect(subtitleTextOf(tester, 'obs-0'), contains('✓ Good'));
    expect(subtitleTextOf(tester, 'obs-1'), contains('Fair'));
    expect(subtitleTextOf(tester, 'obs-2'), contains('Bounce?'));

    for (final id in ['obs-0', 'obs-1', 'obs-2']) {
      final line = subtitleTextOf(tester, id);
      expect(
        line,
        isNot(contains('_')),
        reason: 'An underscore in this row is a stored value that escaped onto '
            'a screen. `suspected_bounce` and `very_strong` are what the '
            'column holds, not what anybody should be asked to read while '
            'deciding which bearings to count. Row was: $line',
      );
    }
    expect(subtitleTextOf(tester, 'obs-2'), contains('very strong'));
  });

  testWidgets('the three qualities are green, amber and red — and the word is '
      'always there too', (tester) async {
    useWideSurface(tester);
    final f = qualityFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice],
      tag: f.tag,
      observations: f.observations,
    );
    await pumpScreen(tester, container);

    final colors = AppTheme.light().extension<TriTrackColors>()!;
    expect(qualityColourOf(tester, 'obs-0', '✓ Good'), colors.animalFix);
    expect(qualityColourOf(tester, 'obs-1', 'Fair'), colors.fairAmber);
    expect(qualityColourOf(tester, 'obs-2', 'Bounce?'), colors.bounceRed);

    // **The colour is an accelerator, never the answer.** A coloured dot with
    // no word was the alternative and it was rejected: there is no legend on
    // this panel to teach one, and green and red are the pair that collapses
    // for a red-green colour vision deficiency. If a later change removes the
    // words in favour of a mark, this is what should stop it.
    expect(subtitleTextOf(tester, 'obs-0'), contains('Good'));
    expect(subtitleTextOf(tester, 'obs-2'), contains('Bounce?'));
  });

  testWidgets('an excluded row keeps its dimming and gives up its colour',
      (tester) async {
    // A stated decision rather than an accident, because it reads like one
    // the other way round. Being out of the estimate is the louder fact about
    // an unticked row, and a green *✓ Good* glowing inside a greyed-out line
    // says the opposite of what the row means.
    useWideSurface(tester);
    final f = qualityFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice],
      tag: f.tag,
      observations: f.observations,
    );
    await pumpScreen(tester, container);

    final colors = AppTheme.light().extension<TriTrackColors>()!;
    expect(qualityColourOf(tester, 'obs-0', '✓ Good'), colors.animalFix);

    await tester.tap(find.byKey(const ValueKey('bearing-row-obs-0')));
    await tester.pumpAndSettle();

    expect(
      qualityColourOf(tester, 'obs-0', '✓ Good'),
      isNull,
      reason: 'The span stops naming a colour, so it inherits the row\'s own '
          'dimmed one. The word is still there — what changed is that the '
          'row no longer shouts a quality it is not contributing.',
    );
  });

  testWidgets('a bearing flagged as sounding irregular is marked here, and '
      'still counted', (tester) async {
    useWideSurface(tester);
    final f = qualityFixture();
    final flagged = f.observations[1].copyWith(signalIrregular: true);
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice],
      tag: f.tag,
      observations: [f.observations[0], flagged, f.observations[2]],
    );
    await pumpScreen(tester, container);

    Finder markIn(String id) => find.descendant(
          of: find.byKey(ValueKey('bearing-row-$id')),
          matching: find.byIcon(Icons.warning_amber_rounded),
        );

    expect(markIn('obs-1'), findsOneWidget,
        reason: 'Task 11.193 records that the signal itself sounded wrong. '
            'This is the screen where somebody decides what to count, so it '
            'is the screen where that fact has to be visible — otherwise it '
            'is invisible until a CSV export.');
    expect(markIn('obs-0'), findsNothing);
    expect(markIn('obs-2'), findsNothing,
        reason: 'A bearing nobody flagged, and one nobody was asked about, '
            'both show nothing. The mark is not a quality grade.');

    // **It marks; it does not withdraw.** Excluding a bearing is its own act
    // with a name on it (task 11.7), and a flag that silently unticked a row
    // would move every position estimate for that animal with nothing on any
    // screen saying so.
    final tile = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('bearing-row-obs-1')),
    );
    expect(tile.value, isTrue,
        reason: 'the flagged bearing is still selected and still counted');
  });

  testWidgets('the mark does not cost the list a row', (tester) async {
    // Task 11.109's trap, on this screen's own budget: a conditional thing
    // appearing is what changes a screen's height, and this panel's split
    // asks for space in whole bearing rows. The mark is an inline icon
    // smaller than the line it sits on, so a flagged row must be exactly as
    // tall as an unflagged one — measured rather than assumed.
    useWideSurface(tester);
    final f = qualityFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice],
      tag: f.tag,
      observations: [
        f.observations[0],
        f.observations[1].copyWith(signalIrregular: true),
      ],
    );
    await pumpScreen(tester, container);

    final plain = tester.getRect(find.byKey(const ValueKey('bearing-row-obs-0')));
    final marked = tester.getRect(find.byKey(const ValueKey('bearing-row-obs-1')));
    printOnFailure('unflagged row ${plain.height}, flagged row ${marked.height}');
    expect(marked.height, plain.height);
  });

  testWidgets('member sort orders the bearing list by observer name', (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, f.bobObs],
    );
    await pumpScreen(tester, container);

    await chooseSort(tester, 'Member');

    expect(tester.takeException(), isNull);
    // Sort order is still by full name (task 11.152 shortens only the
    // rendering); the rows carry it as the badge's initials now (task
    // 11.274 drops the redundant short name from the visible line when, as
    // here, the initials don't collide).
    final initials = tester
        .widgetList<ObserverBadge>(find.descendant(
          of: find.byType(CheckboxListTile),
          matching: find.byType(ObserverBadge),
        ))
        .map((b) => b.initials)
        .toList();
    expect(initials, ['AV', 'BW']);
  });

  testWidgets(
      'distance sort is disabled with a reason when there is no GPS fix, and the '
      'saved estimate is unaffected by which sort is selected', (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, f.bobObs],
    );
    await pumpScreen(tester, container);

    await openSortMenu(tester);
    final disabledEntry =
        find.byWidgetPredicate((w) => w is PopupMenuItem && !w.enabled);
    expect(disabledEntry, findsOneWidget,
        reason: 'distance sort must be unselectable with no GPS fix');
    expect(
      find.descendant(of: disabledEntry, matching: find.text('Distance — no GPS fix')),
      findsOneWidget,
      reason: 'the reason must be readable in the menu itself, not only in a '
          'tooltip nobody in the field can summon (task 11.101)',
    );
    // Dismiss the menu without choosing anything.
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    // "N of total selected" reflects the included set the solver actually
    // sees; switching sorts must never change it (task 11.5's "byte-identical
    // inputs" rule shows up here as "the selection count doesn't move when
    // you re-sort"). Task 11.205 removed the header row's separate "N="
    // summary — this is the one count that remains.
    String summaryLine() => tester
        .widgetList<Text>(find.textContaining('selected'))
        .first
        .data!;
    final before = summaryLine();
    await chooseSort(tester, 'Member');
    expect(summaryLine(), before);
  });

  testWidgets('distance sort is enabled and reorders once a GPS fix exists', (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    // Nearer to Alice's observation point than Bob's.
    final fix = Position(
      latitude: 35.10,
      longitude: -111.71,
      timestamp: DateTime.utc(2026, 7, 16, 17, 0, 0),
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 0,
      speedAccuracy: 0,
    );
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, f.bobObs],
      gpsStream: Stream.value(fix),
    );
    await pumpScreen(tester, container);

    await openSortMenu(tester);
    expect(
      find.byWidgetPredicate((w) => w is PopupMenuItem && !w.enabled),
      findsNothing,
      reason: 'distance sort must be selectable with a GPS fix',
    );
    expect(find.text('Distance — no GPS fix'), findsNothing);
    await tester.tap(find.text('Distance').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));

    expect(tester.takeException(), isNull);
    expect(find.text('Distance'), findsWidgets,
        reason: 'the sort button must name the order the list is actually in');
    final initials = tester
        .widgetList<ObserverBadge>(find.descendant(
          of: find.byType(CheckboxListTile),
          matching: find.byType(ObserverBadge),
        ))
        .map((b) => b.initials)
        .toList();
    expect(initials.first, 'AV', reason: 'the nearer observer sorts first');
  });

  testWidgets(
      'a caution is still reachable after task 11.109 moved it out of the '
      'bearings list\'s way', (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    // **Eight hours apart — past kTriangulationDefaultWindow's 6 hours**
    // (task 11.268, item 7). Bob's is the later timestamp, so Alice's is
    // the one the default filter excludes as more than 6 hours older than
    // the most recent bearing; the caution cannot fire on its own with her
    // excluded. Manually re-including her is the human override that trips
    // "animal may have moved", which is the point of the fixed window
    // replacing the old per-project 15-minute one.
    final apart = f.bobObs.copyWith(
      timestampUtc: f.bobObs.timestampUtc.add(const Duration(hours: 8)),
      timestampLocal: f.bobObs.timestampLocal.add(const Duration(hours: 8)),
    );
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, apart],
    );
    await pumpScreen(tester, container);
    // The default-exclusion filter runs from a post-frame callback and
    // calls `setState` there, so one more pump is needed before it shows.
    await tester.pump();

    expect(find.text('1 of 2 selected'), findsOneWidget,
        reason: 'the default filter already excluded the bearing more than '
            '6 hours older than the most recent one, on its own');

    // The override: re-include the bearing the default filter excluded.
    await tester.tap(find.byKey(const ValueKey('bearing-row-obs-alice')));
    await tester.pumpAndSettle();

    // The button carries a word, not just a glyph: a control whose meaning is
    // only in its tooltip is not usable in the field (task 11.101).
    final button = find.textContaining('caution');
    expect(button, findsOneWidget);
    expect(find.textContaining('animal may have moved'), findsNothing,
        reason: 'the caution detail must not occupy a band above the list');

    await tester.tap(button);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.textContaining('animal may have moved'), findsOneWidget,
        reason: 'and it must be one tap away, not gone');
  });

  testWidgets(
      'the caution does not fire on the default selection alone (task '
      '11.268, item 7) — only a manual override can trip it',
      (tester) async {
    useWideSurface(tester);
    final f = twoObserverFixture();
    // Inside the 6-hour default window: both bearings stay selected by
    // default, and the caution must not appear at all — the whole point of
    // sizing the default window to the caution's own threshold.
    final apart = f.bobObs.copyWith(
      timestampUtc: f.bobObs.timestampUtc.add(const Duration(hours: 3)),
      timestampLocal: f.bobObs.timestampLocal.add(const Duration(hours: 3)),
    );
    final container = await readyContainer(
      tester,
      project: f.project,
      users: [f.alice, f.bob],
      tag: f.tag,
      observations: [f.aliceObs, apart],
    );
    await pumpScreen(tester, container);

    final button = find.textContaining('caution');
    if (button.evaluate().isNotEmpty) {
      await tester.tap(button);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
    expect(find.textContaining('animal may have moved'), findsNothing,
        reason: 'a 3-hour span is well inside the 6-hour default window; '
            'any other caution here is about geometry, not the time span');
  });

  group('role-aware controls (task 11.14)', () {
    /// Opens the past-estimates sheet without `pumpAndSettle()` — this screen's
    /// map keeps issuing tile fetches that never resolve under `flutter test`
    /// (see `pumpScreen`'s own comment above), so settling would spin forever.
    Future<void> openPastEstimatesSheet(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Past estimates for this tag'));
      await tester.runAsync(() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            throw TestFailure('openPastEstimatesSheet: still loading after 5s');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
    }

    testWidgets('a viewer sees SAVE POSITION disabled, with a reason', (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
        actingUser: viewer,
        role: ProjectRole.viewer,
      );
      await pumpScreen(tester, container);

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'SAVE POSITION')).onPressed,
        isNull,
      );
      // Task 11.138: on the control, not in a tooltip a phone never opens.
      expect(
        find.text(
          'Viewers cannot save a position estimate — ask an owner to change your role.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a contributor sees SAVE POSITION enabled', (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final contributor = sampleUser(id: 'user-contributor', email: 'contributor@example.com');
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
        actingUser: contributor,
        role: ProjectRole.contributor,
      );
      await pumpScreen(tester, container);

      expect(tester.takeException(), isNull);
      // Whether the button itself is enabled also depends on whether this
      // fixture's geometry produced a solvable estimate (`hasEstimate`),
      // which is not this test's concern — the disabling *reason*'s absence
      // is the direct proof that `mayWrite` gated nothing here.
      expect(
        find.text(
          'Viewers cannot save a position estimate — ask an owner to change your role.',
        ),
        findsNothing,
      );
    });

    testWidgets('a viewer can tap the past-estimate Delete button and is told why not',
        (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final viewer = sampleUser(id: 'user-viewer', email: 'viewer@example.com');
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
        actingUser: viewer,
        role: ProjectRole.viewer,
      );
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.estimatedPositions,
          sampleEstimatedPosition(projectId: f.project.projectId, tagId: f.tag.tagId).toColumns(),
        );
      });
      await pumpScreen(tester, container);

      await openPastEstimatesSheet(tester);

      expect(tester.takeException(), isNull);
      // Task 11.94/11.101: the button no longer disables itself — a
      // touchscreen never shows the `tooltip:` that used to carry the
      // reason, so it stays tappable and explains itself in a dialog.
      expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).onPressed,
        isNotNull,
      );

      await tester.tap(find.widgetWithIcon(IconButton, Icons.delete_outline));
      await tester.pumpAndSettle();
      expect(find.text('Only an owner or contributor can delete this'), findsOneWidget);
      expect(
        find.text(
          'Viewers cannot delete a position estimate — ask an owner to change your role.',
        ),
        findsOneWidget,
      );
    });

    testWidgets('a contributor sees the past-estimate Delete button enabled', (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final contributor = sampleUser(id: 'user-contributor', email: 'contributor@example.com');
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
        actingUser: contributor,
        role: ProjectRole.contributor,
      );
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.estimatedPositions,
          sampleEstimatedPosition(projectId: f.project.projectId, tagId: f.tag.tagId).toColumns(),
        );
      });
      await pumpScreen(tester, container);

      await openPastEstimatesSheet(tester);

      expect(tester.takeException(), isNull);
      expect(
        tester.widget<IconButton>(find.widgetWithIcon(IconButton, Icons.delete_outline)).onPressed,
        isNotNull,
      );
    });
  });

  /// Task 11.259. A season clone carries `observation_ids_used` across on
  /// purpose (task 11.56) — the bearings it names stay in last season's
  /// project. The past-estimates sheet used to read `observationIdsUsed
  /// .length` straight off the stored row, which said "0 observations" for a
  /// fully carried-over estimate (false — it came from real bearings, just
  /// not ones this device holds) and the stored total for a partially
  /// carried one (also false once a bearing is added this season and the
  /// estimate isn't recomputed).
  group('a carried-over estimate in the past-estimates sheet (task 11.259)',
      () {
    Future<void> openPastEstimatesSheet(WidgetTester tester) async {
      await tester.tap(find.byTooltip('Past estimates for this tag'));
      await tester.runAsync(() async {
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
          if (DateTime.now().isAfter(deadline)) {
            throw TestFailure('openPastEstimatesSheet: still loading after 5s');
          }
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
        }
      });
    }

    testWidgets(
        'says "computed in an earlier season" instead of "0 observations"',
        (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
      );
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.estimatedPositions,
          sampleEstimatedPosition(projectId: f.project.projectId, tagId: f.tag.tagId)
              .copyWith(observationIdsUsed: const ['obs-elsewhere-1', 'obs-elsewhere-2'])
              .toColumns(),
        );
      });
      await pumpScreen(tester, container);

      await openPastEstimatesSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('computed in an earlier season'), findsOneWidget);
      expect(find.textContaining('0 observations'), findsNothing);
    });

    testWidgets(
        'partial carry: counts only the bearing recorded new this season, '
        'not the stored total', (tester) async {
      useWideSurface(tester);
      final f = twoObserverFixture();
      final container = await readyContainer(
        tester,
        project: f.project,
        users: [f.alice, f.bob],
        tag: f.tag,
        observations: [f.aliceObs, f.bobObs],
      );
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        await db.insert(
          Tables.estimatedPositions,
          sampleEstimatedPosition(projectId: f.project.projectId, tagId: f.tag.tagId)
              .copyWith(observationIdsUsed: [
            'obs-elsewhere-1',
            'obs-elsewhere-2',
            f.aliceObs.observationId,
          ])
              .toColumns(),
        );
      });
      await pumpScreen(tester, container);

      await openPastEstimatesSheet(tester);

      expect(tester.takeException(), isNull);
      expect(find.textContaining('1 observations'), findsOneWidget,
          reason: 'only the resolvable bearing (Alice\'s) is counted — never '
              'the stored list\'s length of 3');
    });
  });
}
