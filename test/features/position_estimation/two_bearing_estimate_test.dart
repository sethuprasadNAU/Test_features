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

/// **Task 11.323 item 1 — two bearings give a point and no ellipse.**
///
/// Two bearings that cross always cross exactly, so there is no scatter left
/// to measure: the solver returns a point with κ infinite and no covariance.
/// Until this task nothing on screen said why the ellipse was missing, and
/// saving wrote an ellipse of **0 × 0 m** — a perfectly precise position, in
/// the record and in every backup, and a value the sync rules refuse
/// (an ellipse axis must be greater than zero), so the estimate never left
/// the phone.
///
/// Now: one short caution says why, and the save stores **no ellipse** —
/// the three ellipse columns empty — which is schema v19 (major 6).
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'project-1';
  const me = 'user-me';
  const tagId = 'tag-1';

  Future<ProviderContainer> seed() async {
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
    // Two stations 18 km apart, bearings 45° and 315°: they cross once,
    // about 9 km north of the point between them.
    for (final (id, lon, bearing) in const [
      ('obs-a', -111.70, 45.0),
      ('obs-b', -111.50, 315.0),
    ]) {
      await db.insert(
        Tables.observations,
        sampleObservation(
          id: id,
          projectId: projectId,
          userId: me,
          tagId: tagId,
          sessionId: null,
          tagVersionId: null,
          latitude: 35.10,
          longitude: lon,
        )
            .copyWith(trueNorthBearing: bearing, magneticBearing: bearing)
            .toColumns(),
      );
    }
    await container.read(activeUserIdProvider.notifier).set(me);
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    container.listen(myProjectStandingProvider(projectId), (_, _) {});
    await container.read(myProjectStandingProvider(projectId).future);
    return container;
  }

  testWidgets('a two-bearing estimate says why it has no ellipse, and saves '
      'none rather than 0 × 0', (tester) async {
    // The map's tiles are real requests that fail under `flutter test`; this
    // test waits in real time for a save, long enough for them to report.
    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception is NetworkImageLoadException) return;
      original?.call(details);
    };
    addTearDown(() => FlutterError.onError = original);
    late ProviderContainer container;
    await tester.runAsync(() async => container = await seed());
    addTearDown(container.dispose);
    await pumpInAppShell(
      tester,
      container: container,
      screen: const PositionEstimationScreen(),
      tabIndex: 3,
    );

    // The why, behind the cautions button the header row already has.
    await tester.tap(find.textContaining('1 caution'));
    await tester.pumpAndSettle();
    expect(
      find.text("No ellipse — two bearings can't measure their own spread. "
          'Add a third.'),
      findsOneWidget,
    );
    Navigator.of(tester.element(find.byType(BottomSheet))).pop();
    await tester.pumpAndSettle();

    await tester.runAsync(() async {
      await tester.tap(find.widgetWithText(FilledButton, 'SAVE POSITION'));
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (find.text('Position saved').evaluate().isEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          fail('the save never reported back');
        }
        await tester.pump();
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    });

    final rows = await tester.runAsync(() async {
      final db = (await container.read(appDatabaseProvider.future)).raw;
      return db.query(Tables.estimatedPositions);
    });
    expect(rows, hasLength(1));
    final row = rows!.single;
    expect(row['latitude'], isNotNull);
    expect(row['semi_major_axis'], isNull, reason: 'saved as $row');
    expect(row['semi_minor_axis'], isNull);
    expect(row['rotation_angle'], isNull);
    expect(
      RowValidator.validate(Tables.estimatedPositions, row),
      isEmpty,
      reason: 'the saved row must be one the sync rules accept',
    );
  });
}
