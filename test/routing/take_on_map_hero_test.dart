import 'package:flutter/material.dart';
import 'package:flutter_compass/flutter_compass.dart' show CompassEvent;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/compass/compass_controller.dart';
import 'package:tritrack/compass/compass_reading.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/bearing_map_capture_screen.dart';
import 'package:tritrack/localization/declination/declination_override_provider.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../data/fixtures.dart';
import '../support/app_shell_harness.dart';
import '../support/fake_path_provider.dart';
import '../support/fake_shared_preferences.dart';

/// **Task 11.323 item 6 — opening *Take on map* must not find two heroes with
/// one tag.**
///
/// `/w-32`'s screenshot harness hit *"There are multiple heroes that share the
/// same tag within a subtree"* on open and on close, when the More tab had
/// been left on a screen with a floating "+" (Animals, Projects, the Tag
/// Library) and the Map tab's own "+" was mounted too. The shell keeps hidden
/// branches built (`keepHiddenBranchesResumed`), so every branch's floating
/// button is inside the route *Take on map* is pushed over, and a
/// `FloatingActionButton` left on Flutter's default hero tag shares it with
/// every other one.
///
/// A release build compiles that assertion out, so the phone showed nothing;
/// a debug build logs it. This drives the **real** route table, the real
/// screens and the real push, from each tab state the harness found.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
  });

  const projectId = 'project-1';
  const ownerId = 'user-owner';
  const tagId = 'tag-1';

  for (final moreScreen in const [
    '/more/animals',
    '/more/projects',
    '/more/tag-database',
  ]) {
    testWidgets(
      'opening and closing Take on map with More left on $moreScreen and the '
      'Map tab built raises no shared-hero error',
      (tester) async {
        usePhoneGeometry(tester);
        final project = sampleProject(id: projectId, ownerUserId: ownerId);
        final owner = sampleUser(id: ownerId, email: 'owner@example.com');
        final container = ProviderContainer(
          overrides: [
            appDatabaseProvider
                .overrideWith((ref) => AppDatabase.openInMemory()),
            currentUserProvider.overrideWith((ref) async => owner),
            currentProjectProvider.overrideWith((ref) async => project),
            allProjectsProvider.overrideWith((ref) async => [project]),
            gpsPositionProvider.overrideWith((ref) => const Stream.empty()),
            compassHeadingProvider
                .overrideWith((ref) => const Stream<CompassEvent>.empty()),
            accelerometerReadingProvider
                .overrideWith((ref) => const Stream.empty()),
            magnetometerReadingProvider
                .overrideWith((ref) => const Stream.empty()),
            compassControllerProvider.overrideWith(_FixedCompass.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          final db = (await container.read(appDatabaseProvider.future)).raw;
          await db.insert(Tables.users, owner.toColumns());
          await db.insert(Tables.projects, project.toColumns());
          await db.insert(
            Tables.projectMemberships,
            sampleMembership(
              id: 'membership-owner',
              projectId: projectId,
              userId: ownerId,
              role: ProjectRole.owner,
            ).toColumns(),
          );
          await db.insert(
            Tables.tags,
            sampleTag(id: tagId, projectId: projectId).toColumns(),
          );
          await container.read(activeUserIdProvider.notifier).set(ownerId);
          await container.read(activeProjectIdProvider.notifier).set(projectId);
          container.listen(observationFormProvider, (_, _) {});
          await container.read(observationFormProvider.future);
          container.read(observationFormProvider.notifier)
            ..setTag(tagId)
            ..setManualPosition(true, lat: 35.19, lon: -111.62);
          await container.read(declinationOverrideProvider.future);
          await container.read(declinationOverrideProvider.notifier).set(10);
        });

        final router = container.read(appRouterProvider);
        await tester.runAsync(() async {
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: MaterialApp.router(
                theme: AppTheme.light(),
                routerConfig: router,
              ),
            ),
          );
          await _settle(tester);
        });

        final raised = <FlutterErrorDetails>[];
        final previousOnError = FlutterError.onError;
        FlutterError.onError = raised.add;
        addTearDown(() => FlutterError.onError = previousOnError);

        Future<void> visit(String location) => tester.runAsync(() async {
              router.go(location);
              await _settle(tester);
            });

        // The Map tab's "+" and the More tab's "+" both built, then Record,
        // which is where *Take on map* is opened from.
        await visit('/map');
        await visit(moreScreen);
        await visit('/record');

        await tester.runAsync(() async {
          router.push('/record-bearing-map');
          await _settle(tester);
        });
        expect(find.byType(BearingMapCaptureScreen), findsOneWidget);

        await tester.runAsync(() async {
          router.pop();
          await _settle(tester);
        });
        expect(find.byType(BearingMapCaptureScreen), findsNothing);

        FlutterError.onError = previousOnError;
        final heroErrors = raised
            .map((e) => e.exceptionAsString())
            .where((m) => m.contains('share the same tag'))
            .toList();
        expect(
          heroErrors,
          isEmpty,
          reason: 'Two floating buttons in the tab shell share a hero tag, so '
              'pushing a route over the shell finds both.',
        );
      },
    );
  }
}

/// Pumps real frames until nothing is animating, for at most two seconds — a
/// map screen's tile layer never settles under `pumpAndSettle`, so this
/// counts frames rather than waiting for an idle that never comes.
Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

class _FixedCompass extends CompassController {
  @override
  CompassReading build() =>
      CompassReading.initial.copyWith(magneticHeadingDeg: 100);
}
