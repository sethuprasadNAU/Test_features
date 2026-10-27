import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart' show CompassEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/position_estimation/screens/position_estimation_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/roboto_font.dart';
import '../../support/text_scale_probe.dart';

/// **Task 11.336 item 1 — say plainly when the 95% ellipse rests on few
/// bearings.**
///
/// The ellipse is the standard one (Lenth's covariance, the chi-square 95%
/// scale), and with κ estimated from the same few bearings it contains the
/// animal well under 95% of the time: task 11.323's simulation measured
/// 40–60% at three and four bearings, about 70% at five and 83–86% at ten.
/// So at **five or fewer bearings** the Position screen, the Map's estimate
/// card and Past estimates each say so, in one line.
///
/// This file covers the Position screen and Past estimates; the Map's card is
/// in `map_screen_test.dart`, where that screen's harness lives. The estimate,
/// κ and the ellipse are untouched — `lenth_mle_test.dart` pins them.
///
/// The words are written out here, not read from the app's constant: a copy
/// test that quotes the constant can never notice the copy changing.
void main() {
  setUp(installFakeSharedPreferences);

  const caution = 'Few bearings — the 95% ellipse usually understates the '
      'uncertainty. Add bearings if you can. See “How the estimate is '
      'calculated” in the TriTrack guide.';

  const projectId = 'project-1';
  const me = 'user-me';
  const tagId = 'tag-1';

  // The animal, and the scatter each bearing is given (degrees). Stations sit
  // 1–1.5 km from it along a half-circle, so the geometry is ordinary and the
  // long axis stays well under the 5 km "Poor geometry" threshold.
  const animalLat = 35.10;
  const animalLon = -111.60;
  const scatterDeg = [1.5, -2.0, 0.5, 2.5, -1.0, -1.5, 2.0, -0.5];

  /// A bearing from a station to the animal, with [errorDeg] added.
  double bearingTo(double lat, double lon, double errorDeg) {
    final dx = (animalLon - lon) * math.cos(animalLat * math.pi / 180) * 111320;
    final dy = (animalLat - lat) * 110574;
    return (math.atan2(dx, dy) * 180 / math.pi + errorDeg + 360) % 360;
  }

  Future<ProviderContainer> seed({
    required int bearings,
    List<EstimateSeed> estimates = const [],
  }) async {
    final project = sampleProject(id: projectId, ownerUserId: me);
    final user = sampleUser(id: me, email: 'me@example.com');
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        currentUserProvider.overrideWith((ref) async => user),
        gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
        compassHeadingProvider
            .overrideWith((ref) => const Stream<CompassEvent>.empty()),
      ],
    );
    final db = (await container.read(appDatabaseProvider.future)).raw;
    await db.insert(Tables.users, user.toColumns());
    await db.insert(Tables.projects, project.toColumns());
    await db.insert(
      Tables.projectMemberships,
      sampleMembership(
        id: 'm-me',
        projectId: projectId,
        userId: me,
        role: ProjectRole.owner,
      ).toColumns(),
    );
    await db.insert(
      Tables.tags,
      sampleTag(id: tagId, projectId: projectId).toColumns(),
    );
    for (var i = 0; i < bearings; i++) {
      final around = math.pi * i / (bearings - 1) - math.pi / 2;
      final distanceM = 1000.0 + 500.0 * (i % 2);
      final lat = animalLat + distanceM * math.cos(around) / 110574 * -1;
      final lon = animalLon +
          distanceM *
              math.sin(around) /
              (111320 * math.cos(animalLat * math.pi / 180)) *
              -1;
      final bearing = bearingTo(lat, lon, scatterDeg[i]);
      await db.insert(
        Tables.observations,
        sampleObservation(
          id: 'obs-$i',
          projectId: projectId,
          userId: me,
          tagId: tagId,
          sessionId: null,
          tagVersionId: null,
          latitude: lat,
          longitude: lon,
        ).copyWith(trueNorthBearing: bearing, magneticBearing: bearing).toColumns(),
      );
    }
    for (final e in estimates) {
      await db.insert(
        Tables.estimatedPositions,
        sampleEstimatedPosition(
          id: e.id,
          projectId: projectId,
          tagId: tagId,
        )
            .copyWith(
              timestampLocal: e.at,
              timestampUtc: e.at.toUtc(),
              observationIdsUsed: [for (var i = 0; i < e.bearings; i++) 'b-$i'],
              semiMajorAxis: e.hasEllipse ? 120.0 : null,
              semiMinorAxis: e.hasEllipse ? 60.0 : null,
              rotationAngle: e.hasEllipse ? 42.0 : null,
            )
            .toColumns(),
      );
    }
    await container.read(activeUserIdProvider.notifier).set(me);
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    container.listen(myProjectStandingProvider(projectId), (_, _) {});
    await container.read(myProjectStandingProvider(projectId).future);
    return container;
  }

  Future<void> openPosition(WidgetTester tester, int bearings,
      {List<EstimateSeed> estimates = const [], double textScale = 1.0}) async {
    late ProviderContainer container;
    await tester.runAsync(
      () async => container = await seed(bearings: bearings, estimates: estimates),
    );
    addTearDown(container.dispose);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3,
      textScale: textScale,
    );
  }

  /// Every caution the screen lists, read from the sheet behind its button —
  /// or none, when it shows no button at all.
  Future<void> openCautions(WidgetTester tester) async {
    final button = find.textContaining('caution');
    if (button.evaluate().isEmpty) return;
    await tester.tap(button);
    await tester.pumpAndSettle();
  }

  /// Opens the Past estimates sheet and waits for its saved rows.
  Future<void> openPastEstimates(WidgetTester tester) async {
    await tester.tap(find.byTooltip('Past estimates for this tag'));
    // The sheet reads the saved estimates from the database, which needs
    // real time, not the test clock; and the map behind it keeps requesting
    // tiles, so `pumpAndSettle` would never settle.
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('2026-06-01 08:00').evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('Past estimates never listed the saved estimates');
        }
        await tester.pump(const Duration(milliseconds: 50));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('the Position screen warns at five bearings', (tester) async {
    await openPosition(tester, 5);
    await openCautions(tester);
    expect(find.text(caution), findsOneWidget);
  });

  testWidgets('the Position screen warns at three bearings', (tester) async {
    await openPosition(tester, 3);
    await openCautions(tester);
    expect(find.text(caution), findsOneWidget);
  });

  testWidgets('the Position screen does not warn at six bearings',
      (tester) async {
    await openPosition(tester, 6);
    await openCautions(tester);
    expect(find.textContaining('Few bearings'), findsNothing);
  });

  testWidgets('two bearings say why there is no ellipse, not "few bearings"',
      (tester) async {
    await openPosition(tester, 2);
    await openCautions(tester);
    expect(find.textContaining('Few bearings'), findsNothing,
        reason: 'two bearings have no ellipse for the caution to be about; '
            'their own caution already says so');
    expect(find.textContaining('No ellipse'), findsOneWidget);
  });

  testWidgets('Past estimates warns on a five-bearing ellipse only',
      (tester) async {
    await openPosition(
      tester,
      6,
      estimates: [
        EstimateSeed('est-five', DateTime(2026, 6, 1, 8), bearings: 5),
        EstimateSeed('est-six', DateTime(2026, 6, 1, 9), bearings: 6),
        // Five bearings but no ellipse: nothing to say the 95% of.
        EstimateSeed('est-two', DateTime(2026, 6, 1, 10),
            bearings: 2, hasEllipse: false),
      ],
    );
    await openPastEstimates(tester);

    Finder cautionIn(String time) => find.descendant(
          of: find.widgetWithText(ListTile, '2026-06-01 $time'),
          matching: find.text(caution),
        );
    expect(cautionIn('08:00'), findsOneWidget);
    expect(cautionIn('09:00'), findsNothing);
    expect(cautionIn('10:00'), findsNothing);
  });
  /// **Task 11.338.** The caution now ends by naming the guide page, so it is
  /// longer. The generic clipped-text sweep pumps one bearing per screen and
  /// never shows this line (it needs an ellipse), so it is measured here, on
  /// the 6.1-inch phone, in Roboto, at every text size up to the ordinary
  /// Dynamic Type slider's top stop. The Map's card is in
  /// `map_screen_test.dart`.
  group('the line is not clipped on the 6.1-inch phone (task 11.338)', () {
    setUpAll(loadRobotoFromSdkCache);

    for (final scale
        in iosTextScalesUpward.where((s) => s <= dynamicTypeSliderCeiling)) {
      testWidgets('Position screen, ${textScaleName(scale)}', (tester) async {
        final overflows = collectLayoutOverflows();
        await openPosition(tester, 3, textScale: scale);
        await openCautions(tester);
        expect(find.text(caution), findsOneWidget);
        expect(
          clippedTexts(tester).where((c) => c.text.startsWith('Few bearings')),
          isEmpty,
          reason: 'the few-bearings line is cut short in the Position '
              'screen\'s cautions at ${textScaleName(scale)}',
        );
        expect(overflows, isEmpty);
      });

      testWidgets('Past estimates, ${textScaleName(scale)}', (tester) async {
        final overflows = collectLayoutOverflows();
        await openPosition(
          tester,
          6,
          textScale: scale,
          estimates: [
            EstimateSeed('est-five', DateTime(2026, 6, 1, 8), bearings: 5),
          ],
        );
        await openPastEstimates(tester);
        expect(find.text(caution), findsOneWidget);
        expect(
          clippedTexts(tester).where((c) => c.text.startsWith('Few bearings')),
          isEmpty,
          reason: 'the few-bearings line is cut short in Past estimates '
              'at ${textScaleName(scale)}',
        );
        expect(overflows, isEmpty);
      });
    }
  });

}

/// One saved estimate to plant: how many bearings it names and whether it
/// has an ellipse.
class EstimateSeed {
  EstimateSeed(this.id, this.at, {required this.bearings, this.hasEllipse = true});
  final String id;
  final DateTime at;
  final int bearings;
  final bool hasEllipse;
}
