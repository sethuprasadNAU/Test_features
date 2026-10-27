import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/deployments_provider.dart';
import 'package:tritrack/core/providers/compass_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/gps_provider.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/actual_tag_location.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/record_screen_tags.dart';

/// **Task 11.33 — entering where the animal or the collar actually was.**
///
/// The two things this file is here to hold still are the ones the plan
/// singles out as looking like details and not being:
///
/// 1. **The precision field prefills from the phone's own reported accuracy
///    for a GPS fix, and says so.** A number nobody was told the origin of is
///    a number nobody can judge.
/// 2. **Nothing is prefilled for a map pin.** A pin is not automatically more
///    precise than a GPS fix — it is only as good as somebody's ability to
///    identify the spot in the imagery, and the imagery's own registration is
///    commonly off by a few metres. This is the one place an over-confident
///    default would quietly corrupt the accuracy statistics the feature exists
///    to produce, so the field is left empty and Save stays disabled until a
///    person makes a claim.
///
/// The harness (fake preferences/path provider, real in-memory database, every
/// real sensor stream overridden, and the zone discipline around `runAsync`)
/// follows `observation_logging_screen_test.dart` — see the long note there
/// for why each piece is necessary.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  Position fixAt(double accuracy) => Position(
    latitude: 35.2,
    longitude: -111.6,
    timestamp: DateTime.utc(2026, 8, 31, 17, 0),
    accuracy: accuracy,
    altitude: 2100,
    altitudeAccuracy: 5,
    heading: 0,
    headingAccuracy: 0,
    speed: 0,
    speedAccuracy: 0,
  );

  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    Position? gps,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith((ref) => const Stream.empty()),
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        gpsPositionProvider.overrideWith(
          (ref) => gps == null ? const Stream<Position>.empty() : Stream.value(gps),
        ),
      ],
    );
    addTearDown(container.dispose);

    await tester.runAsync(() async {
      final userRepo = await container.read(userRepositoryProvider.future);
      final projectRepo = await container.read(projectRepositoryProvider.future);
      final tagRepo = await container.read(tagRepositoryProvider.future);
      final versionRepo = await container.read(
        tagVersionRepositoryProvider.future,
      );

      await userRepo.insert(sampleUser());
      await projectRepo.insert(sampleProject());
      await tagRepo.insert(sampleTag());
      // Task 11.249: on an animal, or the wheel does not offer it.
      await putSampleTagOnAnAnimal(container);
      // The phone holder is the project's owner, `user-1`, said explicitly
      // (task 11.237): a fresh user the rows do not name now holds a
      // read-only snapshot, which refuses the save under test.
      await container.read(activeUserIdProvider.notifier).set('user-1');
      // The tag has been edited once, so it has a version to be recorded
      // against — the case task 11.32 built and this task reuses.
      await versionRepo.createInitialVersion(
        sampleTag(),
        now: DateTime.utc(2026, 8, 1),
        modifiedBy: 'user-1',
        deviceId: 'device-A',
      );
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});
      container.listen(gpsPositionProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(mayWriteProjectDataProvider('project-1').future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
    });

    return container;
  }

  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    tester.view.physicalSize = const Size(1200, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(),
          home: const ObservationLoggingScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// What the precision field currently holds.
  String precisionText(WidgetTester tester) {
    final field = tester.widget<TextField>(
      find.widgetWithText(TextField, 'Radius in meters').first,
    );
    return field.controller!.text;
  }

  testWidgets(
    'a GPS fix prefills the precision from the device and says where the '
    'number came from',
    (tester) async {
      final container = await readyContainer(tester, gps: fixAt(12.4));
      container
          .read(observationFormProvider.notifier)
          .setRecordType(RecordType.groundTruth);
      await pumpScreen(tester, container);

      expect(precisionText(tester), '12');
      expect(
        find.textContaining('Prefilled from this device'),
        findsOneWidget,
      );
      expect(find.textContaining('±12 m'), findsOneWidget);
    },
  );

  testWidgets(
    'a number the user typed survives, and is not overwritten by the device — '
    'including one below the device figure',
    (tester) async {
      final container = await readyContainer(tester, gps: fixAt(12.4));
      container
          .read(observationFormProvider.notifier)
          .setRecordType(RecordType.groundTruth);
      await pumpScreen(tester, container);

      await tester.enterText(
        find.widgetWithText(TextField, 'Radius in meters').first,
        '3',
      );
      await tester.pumpAndSettle();

      expect(precisionText(tester), '3');
      expect(container.read(observationFormProvider).value!.truthPrecisionM, 3);
      expect(find.textContaining('Prefilled from this device'), findsNothing);
    },
  );

  // **Michael found this on hardware, 2026-08-31.** With the field prefilled at
  // 4 m, deleting the 4 to type 10 put the 4 straight back on the next frame.
  // The only way to enter 10 was to type `410` and then delete the leading
  // digit — which is not a workaround anybody should have to find.
  //
  // The cause is this project's standing defect class: `truthPrecisionM` alone
  // could not tell "the person just emptied this" from "nobody has typed here
  // yet", because both are null, so the prefill treated a deliberate clear as
  // an empty slot to fill.
  testWidgets(
    'clearing the prefilled figure leaves it cleared, so the next number can '
    'simply be typed',
    (tester) async {
      final container = await readyContainer(tester, gps: fixAt(4.2));
      container
          .read(observationFormProvider.notifier)
          .setRecordType(RecordType.groundTruth);
      await pumpScreen(tester, container);
      expect(precisionText(tester), '4');

      final field = find.widgetWithText(TextField, 'Radius in meters').first;
      await tester.enterText(field, '');
      await tester.pumpAndSettle();

      expect(
        precisionText(tester),
        '',
        reason: 'the field must stay empty; the 4 coming back is the bug',
      );
      expect(container.read(observationFormProvider).value!.truthPrecisionM, isNull);

      // And the number that follows is the whole of what was typed — not `410`.
      await tester.enterText(field, '10');
      await tester.pumpAndSettle();

      expect(precisionText(tester), '10');
      expect(container.read(observationFormProvider).value!.truthPrecisionM, 10);
    },
  );

  testWidgets(
    'the field stays empty across many rebuilds, not just the first one',
    (tester) async {
      // The refill happened in a post-frame callback, so it fired on **every**
      // frame the block rebuilt — and a phone reports a new GPS accuracy about
      // once a second. A single settled frame is not enough to prove it stopped.
      final container = await readyContainer(tester, gps: fixAt(4.2));
      container
          .read(observationFormProvider.notifier)
          .setRecordType(RecordType.groundTruth);
      await pumpScreen(tester, container);

      await tester.enterText(
        find.widgetWithText(TextField, 'Radius in meters').first,
        '',
      );
      for (var frame = 0; frame < 10; frame++) {
        await tester.pump(const Duration(milliseconds: 100));
        expect(
          precisionText(tester),
          '',
          reason: 'refilled on frame $frame',
        );
      }
      expect(
        container.read(observationFormProvider).value!.truthPrecisionTouched,
        isTrue,
        reason: 'the flag that outlives the value going null is what stops it',
      );
    },
  );

  testWidgets(
    'switching to a map pin takes the device figure away rather than reusing '
    'it, and Save is refused until somebody makes a claim',
    (tester) async {
      final container = await readyContainer(tester, gps: fixAt(12.4));
      final notifier = container.read(observationFormProvider.notifier);
      notifier.setRecordType(RecordType.groundTruth);
      await pumpScreen(tester, container);
      expect(precisionText(tester), '12');

      notifier.setManualPosition(true, lat: 35.2004, lon: -111.6008);
      await tester.pumpAndSettle();

      expect(precisionText(tester), '');
      expect(container.read(observationFormProvider).value!.truthPrecisionM, isNull);
      expect(find.textContaining('Not prefilled for a map pin'), findsOneWidget);

      final save = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'SAVE TRUTH POINT'),
      );
      expect(save.onPressed, isNull);
    },
  );

  testWidgets(
    'saving writes a truth point carrying what was found and what the tag '
    'read at the time — and no observation',
    (tester) async {
      final container = await readyContainer(tester, gps: fixAt(9.0));
      final notifier = container.read(observationFormProvider.notifier);
      notifier.setRecordType(RecordType.groundTruth);
      notifier.setTruthKind(GroundTruthKind.collarOnly);
      notifier.setNotes('found in burrow');
      await pumpScreen(tester, container);
      expect(precisionText(tester), '9');

      await tester.runAsync(() async {
        await tester.tap(find.text('SAVE TRUTH POINT'));
        for (var i = 0; i < 50; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
          await tester.pump();
          if (find.text('Truth point saved').evaluate().isNotEmpty ||
              find.textContaining('Could not save').evaluate().isNotEmpty) {
            break;
          }
        }
      });
      expect(tester.takeException(), isNull);

      late List<ActualTagLocation> saved;
      late int observationCount;
      await tester.runAsync(() async {
        final repo = await container.read(
          actualTagLocationRepositoryProvider.future,
        );
        saved = await repo.findByProject('project-1');
        final obsRepo = await container.read(observationRepositoryProvider.future);
        observationCount = (await obsRepo.findByProject('project-1')).length;
      });

      final point = saved.single;
      expect(point.tagId, 'tag-1');
      expect(point.uncertaintyRadius, 9);
      expect(point.foundKind, GroundTruthKind.collarOnly);
      expect(point.notes, 'found in burrow');
      // Task 11.32's rule, applied here: the point remembers what the tag read
      // when somebody stood in front of the collar, so renaming the tag later
      // cannot rewrite this record's history.
      expect(point.tagVersionId, isNotNull);

      // And the yardstick did not become another measurement.
      expect(observationCount, 0);
    },
  );
}
