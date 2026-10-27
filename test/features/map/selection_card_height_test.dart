import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/map/screens/map_screen.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';

/// Task 11.133 item 1 — the selection card's height, measured.
///
/// **Michael's field feedback, 2026-09-02:** the point-and-bearing box "could
/// be reduced in size a bit. There is a lot of white space in the box
/// typically." Task 11.126 made every piece of bottom furniture — the scale
/// bar, the coordinate readout, the map credit, the "+" record button and the
/// legend — clear this card by **its measured height each frame** rather than
/// by a constant. So every pixel taken out of this card is a pixel none of
/// that furniture moves.
///
/// That makes the card's height an acceptance criterion in its own right, and
/// task 11.109's rule says it has to be a number rather than a look. The
/// budgets below are the heights measured after task 11.133's trim, with 8
/// pixels of slack. A change that pushes one over is a change that lifts the
/// bottom of the map again, and it should have to say so here.
///
/// **These numbers are larger than the same cards on a real phone, and the
/// reason is worth knowing before anybody chases one.** A widget test renders
/// in Flutter's built-in test font, in which every character is about as wide
/// as the font size — roughly twice the average width of the Roboto the app
/// actually ships. So a text line that fits comfortably on a device wraps to
/// two lines here, and several of these cards' lines do. The consequence:
///
///   * The **savings that come from padding and tap-target sizes are exact**,
///     because those are constants and no font touches them.
///   * The **savings that come from putting two facts on one line are
///     understated here** — sometimes to nothing, because the joined line
///     wraps in the test font when it would not on a phone.
///
/// So treat a number here as an upper bound that moves in the right
/// direction, not as the height Michael sees. Task 11.126's overlap test has
/// the same property and neither test is wrong; they are just measured in a
/// wider font than the app uses.
///
/// ## Two budgets per card since task 11.137, not one
///
/// The card's Edit control used to carry its *disabled reason* in a `Tooltip`,
/// which a touchscreen never shows: on a phone the button greyed out and no
/// explanation existed anywhere. Task 11.137 moved the reason onto a line under
/// the buttons, and **a line of text has a height where a tooltip had none.**
///
/// That is a real cost against exactly the pixels task 11.133 fought for, so it
/// is measured rather than absorbed: the ordinary card — the one somebody
/// editing their own bearing sees — keeps its old budget unchanged, and the
/// card carrying a reason has its own, larger, stated budget. **The cost is
/// paid only by the person who cannot use the control**, and it buys them the
/// only explanation they were ever going to get.
///
/// Per the font note above, the reason line's cost here is an **over**estimate:
/// it is a sentence, and a sentence is exactly what the test font makes wrap.
void main() {
  setUp(installFakeSharedPreferences);
  setUp(installFakePathProvider);

  void silenceTileLoadErrors() {
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
  }

  /// A degenerate bbox puts the camera exactly on the row, so tapping the
  /// map's own centre lands inside `_selectAtPoint`'s hit radius of it.
  Project pointProject({required double lat, required double lon}) =>
      sampleProject(id: 'project-1', ownerUserId: 'user-1').copyWith(
        bboxMinLat: lat,
        bboxMaxLat: lat,
        bboxMinLon: lon,
        bboxMaxLon: lon,
      );

  /// [signedIn] false signs the app in as a *second contributor* — somebody on
  /// the project who did not record the bearing — which is what makes
  /// `authorEditVerdict` refuse: the state the reason line is drawn in. (It
  /// used to leave the device's own fresh user in place, who resolved to
  /// "cannot say" and was refused on authorship alone; since task 11.237 a
  /// user the rows do not name holds a read-only snapshot and gets a
  /// different, longer sentence — a different card from the one measured
  /// here.)
  Future<ProviderContainer> setUpScreen(
    WidgetTester tester, {
    required Project project,
    Observation? observation,
    bool truthPoint = false,
    bool signedIn = true,
  }) async {
    silenceTileLoadErrors();
    final user = sampleUser(id: 'user-1', email: 'a@example.com');
    final other = sampleUser(id: 'user-2', email: 'b@example.com');
    final tag = sampleTag(id: 'tag-1', tagName: 'Coco');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        currentUserProvider.overrideWith(
          (ref) async => signedIn ? user : other,
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      await userRepo.insert(user);
      await userRepo.insert(other);
      await projectRepo.insert(project);
      await seedContributors(
        (await container.read(appDatabaseProvider.future)).raw,
        projectId: project.projectId,
        userIds: [other.userId],
      );
      await tagRepo.insert(tag);
      if (observation != null) {
        final obsRepo =
            await container.read(observationRepositoryProvider.future);
        await obsRepo.insert(observation);
      }
      if (truthPoint) {
        final locRepo =
            await container.read(actualTagLocationRepositoryProvider.future);
        await locRepo.insert(sampleActualLocation());
      }
      await container
          .read(activeProjectIdProvider.notifier)
          .set(project.projectId);
    });

    await pumpInAppShell(
      tester,
      container: container,
      screen: const MapScreen(),
      tabIndex: 0,
    );
    return container;
  }

  Future<void> tapMapCenter(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.tapAt(tester.getCenter(find.byType(FlutterMap)));
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await tester.pump();
    });
    await tester.pump();
  }

  double cardHeight(WidgetTester tester, String what) {
    final finder = find.byKey(const ValueKey('map-selection-panel'));
    expect(finder, findsOneWidget, reason: 'the $what card is not up');
    final height = tester.getRect(finder).height;
    // An instrument's last words must be a finding, not a name (CLAUDE.md):
    // on a red, the tail of the run says the height, not just which card.
    printOnFailure('$what selection card: $height logical pixels');
    return height;
  }

  testWidgets('a map point card stays within its height budget',
      (tester) async {
    await setUpScreen(tester, project: pointProject(lat: 35.19, lon: -111.61));
    final map = tester.getRect(find.byKey(const ValueKey('main-map')));
    await tester.longPressAt(map.center);
    await tester.pump();
    // Task 11.133 before/after: 137.0 -> 111.0 logical pixels.
    expect(cardHeight(tester, 'map point'), lessThanOrEqualTo(119.0));
  });

  testWidgets('a bearing card stays within its height budget', (tester) async {
    final observation = sampleObservation(
      id: 'obs-1',
      projectId: 'project-1',
      userId: 'user-1',
      tagId: 'tag-1',
      sessionId: null,
      latitude: 35.19,
      longitude: -111.61,
    ).copyWith(trueNorthBearing: 72, magneticBearing: 72);
    await setUpScreen(
      tester,
      project: pointProject(lat: 35.19, lon: -111.61),
      observation: observation,
    );
    await tapMapCenter(tester);
    // Task 11.133 before/after: 171.0 -> 153.0 logical pixels.
    expect(cardHeight(tester, 'bearing'), lessThanOrEqualTo(161.0));
  });

  testWidgets(
      'a bearing card whose Edit is refused pays for the reason, and says how '
      'much', (tester) async {
    final observation = sampleObservation(
      id: 'obs-1',
      projectId: 'project-1',
      userId: 'user-1',
      tagId: 'tag-1',
      sessionId: null,
      latitude: 35.19,
      longitude: -111.61,
    ).copyWith(trueNorthBearing: 72, magneticBearing: 72);
    await setUpScreen(
      tester,
      project: pointProject(lat: 35.19, lon: -111.61),
      observation: observation,
      signedIn: false,
    );
    await tapMapCenter(tester);
    // Task 11.137: 153.0 -> 205.0 logical pixels, all of it the reason line,
    // which wraps to three lines in the test font and would take fewer on a
    // phone. It is drawn only while Edit is unusable — the card above, which is
    // what somebody editing their own bearing sees, is unchanged at 153.
    expect(
      find.textContaining('You can only edit or delete observations you '
          'recorded yourself'),
      findsOneWidget,
      reason: 'the reason is on the card, where a finger can reach it',
    );
    expect(cardHeight(tester, 'bearing with a refusal'),
        lessThanOrEqualTo(213.0));
  });

  testWidgets('a truth point card stays within its height budget',
      (tester) async {
    await setUpScreen(
      tester,
      project: pointProject(lat: 35.196, lon: -111.616),
      truthPoint: true,
    );
    await tapMapCenter(tester);
    // Task 11.133 before/after: 299.0 -> 267.0 logical pixels. Still the
    // tallest of the four by a wide margin, and so the one that lifts the
    // bottom furniture furthest — it carries five facts about provenance that
    // task 11.92 and 11.93 added for good reasons, and none of them was
    // dropped here.
    expect(cardHeight(tester, 'truth point'), lessThanOrEqualTo(275.0));
  });
}
