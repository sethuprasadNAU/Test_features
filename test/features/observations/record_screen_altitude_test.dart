import 'dart:typed_data';

import 'package:flutter/material.dart';
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
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/non_detection.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/providers/receiver_altitude_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack/features/observations/widgets/receiver_altitude_sheet.dart';
import 'package:tritrack/localization/declination/declination_override_provider.dart';
import 'package:tritrack/viewshed/dem_tile_store.dart';
import 'package:tritrack/viewshed/elevation_grid.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../support/app_shell_harness.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/record_screen_tags.dart';

/// Task 11.67 — a receiver in an aircraft is not on the ground.
///
/// What is asserted, in the order the acceptance lists it: the ground screen
/// gains one unticked *At altitude* checkbox and nothing else (Michael's
/// 2026-09-12 revision, replacing a gauge icon on the position line); the
/// sheet's own icon is not the aeroplane-mode glyph; a set value is visible
/// in the checkbox's label without opening anything, above the fold on a
/// bearing record; it reaches a bearing **and a no-signal record**; the first
/// screen after the window lapses says so and offers the value back; and the
/// MSL path refuses — watched refusing — when there is no ground elevation
/// to subtract, and converts when there is.
///
/// The harness is `observation_logging_screen_test.dart`'s, for the reasons
/// written there about zones: anything that touches the database or a file
/// runs inside `runAsync`, and nothing awaits either from the test body.
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });
  tearDown(() => EditableText.debugDeterministicCursor = false);

  /// The tile the seeded ground lives in: 35.0–35.1 N, 111.7–111.6 W.
  const tile = DemTileId(350, -1117);
  const groundMetres = 1200.0;
  const insideTile = (lat: 35.05, lon: -111.65);
  const outsideTile = (lat: 35.2, lon: -111.6);

  Future<ProviderContainer> readyContainer(WidgetTester tester) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(
          (ref) => Stream.value(CompassEvent.fromList([45, 45, 5])),
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
      await container.read(activeUserIdProvider.notifier).set('user-1');
      await container.read(activeProjectIdProvider.notifier).set('project-1');

      container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

      container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
      container.listen(observationFormProvider, (_, _) {});
      container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});
      container.listen(receiverAltitudeSettingProvider, (_, _) {});

      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(mayWriteProjectDataProvider('project-1').future);
      await container.read(receiverAltitudeSettingProvider.future);
      await container.read(currentUserProvider.future);
      await container.read(deviceIdProvider.future);
      // Sidesteps the WMM asset load the save path would otherwise do — see
      // the sibling file for why it cannot resolve from `runAsync`.
      await container.read(declinationOverrideProvider.future);
      await container.read(declinationOverrideProvider.notifier).set(9.77);
    });
    return container;
  }

  /// Inside the real tab shell on a 6.1-inch phone — the surface the app
  /// actually gives this screen, and the one on which "above the fold" can
  /// be asserted at all.
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) async {
    await pumpInAppShell(
      tester,
      container: container,
      screen: const ObservationLoggingScreen(),
      tabIndex: 1, // Map / **Record** / Compass / Position / More
    );
    await tester.pumpAndSettle();
  }

  /// Writes a flat tile at [groundMetres] where the sheet's own
  /// `DemTileStore` will find it. Called inside `runAsync` — file work.
  Future<void> seedGround() async {
    final spec = tile.gridSpec();
    final data = Float64List(spec.ncols * spec.nrows);
    for (var i = 0; i < data.length; i++) {
      data[i] = groundMetres;
    }
    await DemTileStore().saveTile(
      tile,
      ElevationGrid(
        ncols: spec.ncols,
        nrows: spec.nrows,
        xllCorner: spec.xllCorner,
        yllCorner: spec.yllCorner,
        cellSizeDegrees: spec.cellSizeDegrees,
        data: data,
      ),
    );
  }

  /// Taps [saveLabel] and waits for the snackbar, inside one `runAsync`.
  Future<void> save(WidgetTester tester, String saveLabel) async {
    await tester.runAsync(() async {
      await tester.tap(find.text(saveLabel));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.textContaining('saved').evaluate().isNotEmpty ||
            find.textContaining('Could not save').evaluate().isNotEmpty) {
          return;
        }
      }
      fail('the record never reported saving');
    });
    expect(tester.takeException(), isNull);
  }

  /// Opens the sheet from the *At altitude* checkbox and waits for its
  /// ground lookup — file work, so inside `runAsync`, and the wait is on the
  /// observable outcome (the ground line no longer says it is looking)
  /// rather than on the sheet merely existing.
  Future<void> openSheet(WidgetTester tester) async {
    await tester.runAsync(() async {
      await tester.ensureVisible(find.byKey(const ValueKey('record-at-altitude')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('record-at-altitude')));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        final ground = find.byKey(const ValueKey('receiver-altitude-ground'));
        if (ground.evaluate().isNotEmpty &&
            !tester.widget<Text>(ground).data!.startsWith('Looking up')) {
          return;
        }
      }
      fail('the altitude sheet never finished looking up the ground');
    });
    // The sheet slides in on the fake clock, which the loop above did not
    // advance; settle it before anything is tapped.
    await tester.pumpAndSettle();
  }

  /// The form is a lazy `ListView`; a row scrolled out of view is not built
  /// until it is scrolled back — which is what a thumb does.
  Future<void> scrollToTop(WidgetTester tester) async {
    await tester.drag(
      find.byKey(const ValueKey('record-form')),
      const Offset(0, 2000),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('on foot the screen gains one unticked box and nothing else',
      (tester) async {
    final container = await readyContainer(tester);
    await pumpScreen(tester, container);

    final box = find.byKey(const ValueKey('record-at-altitude'));
    expect(box, findsOneWidget);
    expect(find.text('At altitude'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.descendant(of: box, matching: find.byType(Checkbox))).value,
      isFalse,
    );
    expect(find.byKey(const ValueKey('record-altitude-cleared')), findsNothing);
    expect(find.textContaining('300'), findsNothing);
    // After Malfunctioning in reading order (Michael, 2026-09-12: to its
    // right, on the same line). **Whether the two share a line cannot be
    // decided here**: `flutter_test`'s fallback font is about twice Roboto's
    // width, so the `Wrap` moves this box to a second run in the test where
    // the phone would keep it on the first — `CLAUDE.md`'s "some savings are
    // fiction" rule. What is asserted is the order, which the font cannot
    // change; the line is a device look.
    final malfunction = find.byKey(const ValueKey('record-signal-irregular'));
    expect(find.text('Malfunctioning'), findsOneWidget);
    final boxTop = tester.getTopLeft(box);
    final malTop = tester.getTopLeft(malfunction);
    final sameRun = (boxTop.dy - malTop.dy).abs() < 1;
    expect(
      sameRun ? boxTop.dx > tester.getTopRight(malfunction).dx - 1 : boxTop.dy > malTop.dy,
      isTrue,
      reason: 'At altitude must follow Malfunctioning: beside it or on the '
          'next run, never before it',
    );
    // ignore: avoid_print
    print('altitude-row widths in the test font: mode line '
        '${tester.getSize(find.byKey(const ValueKey('record-pulse-mode-line'))).width.round()}, '
        'Malfunctioning ${tester.getSize(malfunction).width.round()}, '
        'At altitude ${tester.getSize(box).width.round()}, '
        'form ${tester.getSize(find.byKey(const ValueKey('record-form'))).width.round()}');
  });

  testWidgets('a record type with no signal line gets the box on its own row, '
      'left-justified', (tester) async {
    final container = await readyContainer(tester);
    container.read(observationFormProvider.notifier).setRecordType(RecordType.note);
    await pumpScreen(tester, container);
    final box = find.byKey(const ValueKey('record-at-altitude'));
    expect(box, findsOneWidget);
    expect(find.byKey(const ValueKey('record-signal-irregular')), findsNothing);
    final form = tester.getRect(find.byKey(const ValueKey('record-form')));
    // Left edge sits at the form's own left padding, like every other row.
    expect(tester.getTopLeft(box).dx, lessThan(form.left + 40));
    // And above the position line, not on it.
    expect(
      tester.getBottomLeft(box).dy,
      lessThanOrEqualTo(
        tester.getTopLeft(find.byKey(const ValueKey('record-position-row'))).dy,
      ),
    );
  });

  test("the sheet's icon is not the aeroplane-mode glyph or its neighbour", () {
    expect(kReceiverAltitudeIcon, isNot(Icons.airplanemode_active));
    expect(kReceiverAltitudeIcon, isNot(Icons.airplanemode_on));
    expect(kReceiverAltitudeIcon, isNot(Icons.flight));
    expect(kReceiverAltitudeIcon, isNot(Icons.flight_takeoff));
    expect(kReceiverAltitudeIcon, isNot(Icons.flight_land));
    expect(kReceiverAltitudeIcon, isNot(Icons.local_airport));
  });

  testWidgets('a set altitude ticks the box and puts the number in its label, '
      'above the fold', (tester) async {
    final container = await readyContainer(tester);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(300));
    await pumpScreen(tester, container);

    final box = find.byKey(const ValueKey('record-at-altitude'));
    expect(find.text('At altitude · 300 m'), findsOneWidget);
    expect(
      tester.widget<Checkbox>(find.descendant(of: box, matching: find.byType(Checkbox))).value,
      isTrue,
    );
    // Visible without scrolling on the phone: inside the form's viewport.
    final form = tester.getRect(find.byKey(const ValueKey('record-form')));
    expect(tester.getRect(box).top, greaterThanOrEqualTo(form.top));
    expect(tester.getRect(box).bottom, lessThanOrEqualTo(form.bottom));
    // The line that used to sit at the top of the form is gone.
    expect(find.textContaining('Receiver altitude 300'), findsNothing);
  });

  testWidgets('the number is shown in the unit last chosen', (tester) async {
    final container = await readyContainer(tester);
    await tester.runAsync(() async {
      final n = container.read(receiverAltitudeSettingProvider.notifier);
      await n.setAglMetres(300);
      await n.setUnit(AltitudeUnit.feet);
    });
    await pumpScreen(tester, container);
    expect(find.text('At altitude · 984 ft'), findsOneWidget);
  });

  testWidgets('the value reaches a saved bearing', (tester) async {
    final container = await readyContainer(tester);
    final form = container.read(observationFormProvider.notifier);
    form.setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    form.setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(300));
    await pumpScreen(tester, container);
    await save(tester, 'SAVE OBSERVATION');

    late List<Observation> saved;
    await tester.runAsync(() async {
      final repo = await container.read(observationRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    expect(saved.single.altitudeAgl, 300);
    // And the value is still in force for the next record — the clock moved.
    expect(container.read(receiverAltitudeProvider).aglMetres, 300);
  });

  testWidgets('the value reaches a saved no-signal record', (tester) async {
    final container = await readyContainer(tester);
    final form = container.read(observationFormProvider.notifier);
    form.setRecordType(RecordType.noSignal);
    form.setNoSignalTags(['tag-1']);
    form.setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(300));
    await pumpScreen(tester, container);
    await save(tester, 'SAVE NO-SIGNAL');

    late List<NonDetection> saved;
    await tester.runAsync(() async {
      final repo = await container.read(nonDetectionRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    expect(saved.single.altitudeAgl, 300);
  });

  testWidgets('a bearing on foot still records zero', (tester) async {
    final container = await readyContainer(tester);
    final form = container.read(observationFormProvider.notifier);
    form.setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    form.setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
    await pumpScreen(tester, container);
    await save(tester, 'SAVE OBSERVATION');
    late List<Observation> saved;
    await tester.runAsync(() async {
      final repo = await container.read(observationRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    expect(saved.single.altitudeAgl, 0);
  });

  testWidgets('after the window lapses the screen says so, and Restore puts '
      'the value back', (tester) async {
    final container = await readyContainer(tester);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(
          300,
          now: DateTime.now().subtract(const Duration(hours: 4, minutes: 1)),
        ));
    await pumpScreen(tester, container);

    expect(find.text('At altitude'), findsOneWidget);
    expect(find.byKey(const ValueKey('record-altitude-cleared')), findsOneWidget);
    expect(find.text('Altitude cleared — was 300 m above ground'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('record-altitude-restore')));
    await tester.pumpAndSettle();
    expect(find.text('At altitude · 300 m'), findsOneWidget);
    expect(find.byKey(const ValueKey('record-altitude-cleared')), findsNothing);
  });

  testWidgets('the lapse notice is retired by one saved record', (tester) async {
    final container = await readyContainer(tester);
    final form = container.read(observationFormProvider.notifier);
    form.setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    form.setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(
          300,
          now: DateTime.now().subtract(const Duration(hours: 5)),
        ));
    await pumpScreen(tester, container);
    expect(find.byKey(const ValueKey('record-altitude-cleared')), findsOneWidget);

    await save(tester, 'SAVE OBSERVATION');
    await tester.pump();
    late List<Observation> saved;
    await tester.runAsync(() async {
      final repo = await container.read(observationRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    // Recorded on the ground — the lapse is real — and the notice is gone.
    expect(saved.single.altitudeAgl, 0);
    expect(find.byKey(const ValueKey('record-altitude-cleared')), findsNothing);
    expect(container.read(receiverAltitudeProvider).noticeOwed, isFalse);
  });

  testWidgets('tapping a ticked box opens the sheet rather than clearing',
      (tester) async {
    final container = await readyContainer(tester);
    await tester.runAsync(() => container
        .read(receiverAltitudeSettingProvider.notifier)
        .setAglMetres(300));
    await pumpScreen(tester, container);
    await openSheet(tester);
    expect(find.byKey(const ValueKey('receiver-altitude-sheet')), findsOneWidget);
    // One tap in the air changed nothing about what will be recorded.
    expect(container.read(receiverAltitudeProvider).aglMetres, 300);
    // The deliberate way down is a named button.
    expect(find.byKey(const ValueKey('receiver-altitude-clear')), findsOneWidget);
  });

  group('the sheet', () {
    testWidgets('sets a height above ground from the position row', (tester) async {
      final container = await readyContainer(tester);
      container
          .read(observationFormProvider.notifier)
          .setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
      await pumpScreen(tester, container);
      await openSheet(tester);

      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '250',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(container.read(receiverAltitudeProvider).aglMetres, 250);
      await scrollToTop(tester);
      expect(find.text('At altitude · 250 m'), findsOneWidget);
    });

    testWidgets('MSL is refused, on screen, when there is no ground elevation',
        (tester) async {
      final container = await readyContainer(tester);
      // A pin over ground with no tile — the seeded tile is elsewhere and
      // nothing has been seeded anyway.
      container
          .read(observationFormProvider.notifier)
          .setManualPosition(true, lat: outsideTile.lat, lon: outsideTile.lon);
      await pumpScreen(tester, container);
      await openSheet(tester);

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('receiver-altitude-ground')))
            .data,
        startsWith('No ground elevation stored'),
      );
      await tester.tap(find.text('MSL — above sea level'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '1500',
      );
      await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
      await tester.pump();

      // Watched refusing: the sheet is still open, the refusal names its
      // reason, and nothing was written.
      final refusal = find.byKey(const ValueKey('receiver-altitude-refusal'));
      expect(refusal, findsOneWidget);
      expect(
        tester.widget<Text>(refusal).data,
        contains('cannot be converted'),
      );
      expect(find.byKey(const ValueKey('receiver-altitude-sheet')), findsOneWidget);
      expect(container.read(receiverAltitudeProvider).aglMetres, 0);
    });

    testWidgets('MSL is refused when there is no position at all', (tester) async {
      final container = await readyContainer(tester);
      await pumpScreen(tester, container);
      await openSheet(tester);
      await tester.tap(find.text('MSL — above sea level'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '1500',
      );
      await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
      await tester.pump();
      final refusal = find.byKey(const ValueKey('receiver-altitude-refusal'));
      expect(tester.widget<Text>(refusal).data, startsWith('No position yet'));
      expect(container.read(receiverAltitudeProvider).aglMetres, 0);
    });

    testWidgets('MSL converts by the terrain tile when there is one',
        (tester) async {
      final container = await readyContainer(tester);
      await tester.runAsync(seedGround);
      container
          .read(observationFormProvider.notifier)
          .setManualPosition(true, lat: insideTile.lat, lon: insideTile.lon);
      await pumpScreen(tester, container);
      await openSheet(tester);

      expect(
        tester
            .widget<Text>(find.byKey(const ValueKey('receiver-altitude-ground')))
            .data,
        'Ground here: 1200 m above sea level',
      );
      await tester.tap(find.text('MSL — above sea level'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '1500',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(container.read(receiverAltitudeProvider).aglMetres, closeTo(300, 1e-9));
    });

    testWidgets('an MSL figure below the ground is refused', (tester) async {
      final container = await readyContainer(tester);
      await tester.runAsync(seedGround);
      container
          .read(observationFormProvider.notifier)
          .setManualPosition(true, lat: insideTile.lat, lon: insideTile.lon);
      await pumpScreen(tester, container);
      await openSheet(tester);
      await tester.tap(find.text('MSL — above sea level'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '1000',
      );
      await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
      await tester.pump();
      final refusal = find.byKey(const ValueKey('receiver-altitude-refusal'));
      expect(tester.widget<Text>(refusal).data, startsWith('That is below the ground'));
      expect(container.read(receiverAltitudeProvider).aglMetres, 0);
    });

    testWidgets('feet are stored as metres', (tester) async {
      final container = await readyContainer(tester);
      await pumpScreen(tester, container);
      await openSheet(tester);
      await tester.tap(find.text('ft'));
      await tester.pump();
      await tester.enterText(
        find.byKey(const ValueKey('receiver-altitude-field')),
        '1000',
      );
      await tester.runAsync(() async {
        await tester.tap(find.byKey(const ValueKey('receiver-altitude-set')));
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      final s = container.read(receiverAltitudeProvider);
      expect(s.aglMetres, closeTo(304.8, 1e-9));
      expect(s.unit, AltitudeUnit.feet);
      await scrollToTop(tester);
      expect(find.text('At altitude · 1000 ft'), findsOneWidget);
    });
  });
}
