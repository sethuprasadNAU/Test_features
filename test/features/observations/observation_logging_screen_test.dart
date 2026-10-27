import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
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
import 'package:tritrack/core/format/observation_quality_display.dart';
import 'package:tritrack/core/theme/app_theme.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack/data/repositories/repository_providers.dart';
import 'package:tritrack_sync/tritrack_sync.dart';
import 'package:tritrack/features/observations/providers/observation_form_provider.dart';
import 'package:tritrack/features/observations/screens/observation_logging_screen.dart';
import 'package:tritrack/localization/declination/declination_override_provider.dart';

import '../../data/fixtures.dart';
import '../../support/fake_path_provider.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/record_screen_tags.dart';

/// Task 5.5: the bearing entry sheet must open on the tab matching compass
/// availability — Compass when a heading is available, Manual entry when
/// it isn't (rather than opening on a dead Compass tab). This exercises the
/// actual wiring in `_BearingCaptureBlock`
/// (`observation_logging_screen.dart`), not just `showBearingEntrySheet`'s
/// `initialManualTab` parameter in isolation (already covered directly by
/// `bearing_entry_sheet_test.dart` from task 5.3).
void main() {
  setUp(() {
    installFakeSharedPreferences();
    installFakePathProvider();
    EditableText.debugDeterministicCursor = true;
  });

  tearDown(() {
    EditableText.debugDeterministicCursor = false;
  });

  /// Seeds an in-memory database with one project + one active tag (the
  /// screen otherwise shows a "no tags yet" empty state instead of the
  /// bearing capture UI this test needs) and makes that project active.
  ///
  /// `projectActiveTagsProvider`/`observationFormProvider` are plain
  /// `@riverpod` (autoDispose, no `keepAlive`) — pre-resolving them with a
  /// bare `container.read(...future)` isn't enough, since nothing keeps
  /// listening afterward and they get disposed again immediately, forcing a
  /// *fresh* rebuild once the widget watches them later. The
  /// `container.listen` below prevents that — but it must happen **inside**
  /// `tester.runAsync`, same as every other touch of this async chain: a
  /// provider's underlying `Future`/`Stream` is tied to whichever zone was
  /// current when it first started, real or fake — starting it outside
  /// `runAsync` (even just via `container.listen`, which kicks off the
  /// provider's build immediately) permanently poisons it to the fake-async
  /// zone, where its `sqflite_common_ffi` round trip then never resolves.
  /// That's the same rule Phase 4's Discovered Scope documents for
  /// tap-then-wait ("splitting the tap and the wait across separate
  /// `runAsync` calls does not work") — it turned out to apply just as much
  /// to *where a listener is attached* as to where an interaction happens.
  Future<ProviderContainer> readyContainer(
    WidgetTester tester, {
    required Stream<CompassEvent> Function(Ref) compassHeading,
  }) async {
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
        compassHeadingProvider.overrideWith(compassHeading),
        // `CompassController` (behind the bearing capture UI) also listens to
        // these raw sensors_plus streams — real platform channels with no
        // test-time implementation, unlike flutter_compass which at least
        // returns a stream. Left un-overridden, they only ever throw
        // `MissingPluginException`s once something actually drives real async
        // (e.g. `tester.runAsync` for a real DB write), not before.
        accelerometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        magnetometerReadingProvider.overrideWith((ref) => const Stream.empty()),
        // Same reasoning: geolocator has no test-time platform implementation
        // either, and unlike the others this one auto-retries on error
        // (Riverpod's default provider retry), leaving a pending Timer behind
        // that trips the "no pending timers" test invariant once something
        // (the save's real DB write) actually runs the real event loop.
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

      // Pre-resolve everything the screen watches on first build so pumping
      // doesn't need a fresh, uncached DB/prefs read mid-fake-async-zone.
      await container.read(currentProjectProvider.future);
      await container.read(projectActiveTagsProvider('project-1').future);
      await container.read(projectDeploymentsProvider('project-1').future);
      await container.read(observationFormProvider.future);
      await container.read(mayWriteProjectDataProvider('project-1').future);

      // Also pre-resolve what `_save` reads on a real device (currentUser,
      // deviceId) — both are real SharedPreferencesAsync/sqflite round trips
      // that must start in this real `runAsync` zone, not the fake-async zone
      // a bare `tester.tap` runs in, or they never resolve (see the
      // `container.listen`/zone-poisoning note above).
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
        child: MaterialApp(theme: AppTheme.light(), home: const ObservationLoggingScreen()),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('bearing sheet opens on the Compass tab when a heading is available', (tester) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
    );
    await pumpScreen(tester, container);

    expect(find.text('✎'), findsOneWidget);
    await tester.tap(find.text('✎'));
    await tester.pumpAndSettle();

    expect(find.text('Single Point'), findsOneWidget);
    expect(find.textContaining('magnetic bearing'), findsNothing);
  });

  testWidgets('bearing sheet opens on the Manual entry tab when the compass is unavailable', (tester) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.error(StateError('no compass')),
    );
    await pumpScreen(tester, container);

    expect(find.text('Manual entry'), findsOneWidget);
    expect(find.text('✎'), findsNothing);
    await tester.tap(find.text('Manual entry'));
    await tester.pumpAndSettle();

    expect(find.textContaining('magnetic bearing'), findsOneWidget);
    expect(find.text('Single Point'), findsNothing);
  });

  /// Task 11.315 — *Take on map* sweeps with the compass, so it is offered
  /// exactly where RANGE can be pressed, by the same check RANGE uses.
  testWidgets('Take on map is beside RANGE on a device with a compass', (tester) async {
    final semantics = tester.ensureSemantics();
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
    );
    await pumpScreen(tester, container);

    final button = find.byKey(const ValueKey('record-take-on-map'));
    expect(button, findsOneWidget);
    // On the button's own node, with the tap — not merged into the bearing
    // block, which is what a `Semantics` wrapper did on the first attempt.
    final node = tester.getSemantics(button);
    expect(node.label, 'Take on map');
    expect(node.getSemanticsData().hasAction(SemanticsAction.tap), isTrue);
    final range = tester.getRect(find.text('RANGE'));
    final map = tester.getRect(button);
    expect(map.left, greaterThan(range.right), reason: 'Beside RANGE, after it.');
    expect(map.center.dy, closeTo(range.center.dy, 12), reason: 'In the same row.');
    semantics.dispose();
  });

  testWidgets('Take on map is hidden where there is no compass', (tester) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.error(StateError('no compass')),
    );
    await pumpScreen(tester, container);

    expect(find.text('RANGE'), findsOneWidget);
    expect(find.byKey(const ValueKey('record-take-on-map')), findsNothing);
  });

  /// Task 11.317 item 3 — RANGE used to give up the sweep once a thumb slid
  /// about 3 mm (18 px), because it was built on a tap recognizer, which
  /// gives up on a slide. It now reads the same raw pointer *Take on map*
  /// does, so the sweep ends only when that finger lifts, wherever it has
  /// wandered.
  testWidgets('a thumb that slides while holding RANGE keeps the sweep', (tester) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.value(CompassEvent.fromList([100.0, 100.0, 5.0])),
    );
    await pumpScreen(tester, container);

    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(const ValueKey('record-range-button'))),
    );
    await tester.pump();
    expect(find.text('RANGE (recording)'), findsOneWidget);

    // A 30-pixel slide (about 5 mm) lost RANGE's bearing before this task.
    await gesture.moveBy(const Offset(30, -10));
    await tester.pump();
    expect(
      find.text('RANGE (recording)'),
      findsOneWidget,
      reason: 'The slide alone must not end the hold.',
    );

    await gesture.up();
    await tester.pump();

    final draft = container.read(observationFormProvider).value!;
    expect(draft.bearingCaptureMethodDb, 'range_capture');
    expect(draft.bearingDeg, isNotNull);
  });

  testWidgets(
      'saving uses the currently-selected tag, not a stale persisted draft.tagId that no longer '
      'matches an active tag', (tester) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0])),
    );

    // Simulate a draft left over from before this tag went inactive/was
    // deleted — `draft.tagId` no longer matches any tag in `tags`, but is
    // not null, so the screen's own build-time reconciliation (a
    // postFrameCallback) hasn't run yet when `_save` would otherwise read it.
    container.read(observationFormProvider.notifier).setTag('stale-tag-id');
    container.read(observationFormProvider.notifier).setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    container
        .read(observationFormProvider.notifier)
        .setManualPosition(true, lat: 35.2, lon: -111.6);
    // Sidesteps `_save`'s WMM-declination lookup, which loads its coefficient
    // asset via `rootBundle` — a call the test's mocked binary messenger
    // answers on the fake-async zone, so it can never resolve if reached from
    // inside `runAsync`'s real zone below.
    await tester.runAsync(() async {
      // Let `build()` finish first — setting state before it resolves gets
      // clobbered when the pending build's own result lands afterward.
      await container.read(declinationOverrideProvider.future);
      await container.read(declinationOverrideProvider.notifier).set(9.77);
    });

    await pumpScreen(tester, container);

    // Tap and settle must happen inside the same `runAsync` call — `_save`
    // does real file/DB I/O (DemTileStore, the observation insert) that
    // can't resolve if started in the surrounding fake-async test zone. The
    // wait between pumps is a real `Future.delayed`, not a fake-clock
    // `tester.pump(duration)` advance — the real sqflite FFI round trip runs
    // at real wall-clock speed regardless of how far the fake clock jumps.
    await tester.runAsync(() async {
      await tester.tap(find.text('SAVE OBSERVATION'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.text('Observation saved').evaluate().isNotEmpty ||
            find.textContaining('Could not save').evaluate().isNotEmpty) {
          break;
        }
      }
    });

    expect(tester.takeException(), isNull);
    late List<Observation> saved;
    await tester.runAsync(() async {
      final repo = await container.read(observationRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    expect(saved, hasLength(1));
    expect(saved.single.tagId, 'tag-1');
  });

  /// **Task 11.193 — the flag has to reach the row, and only where the
  /// question was asked.**
  ///
  /// The control on the screen and the column in the database are two
  /// different things, and the interesting half is the record type that shows
  /// no such control:
  /// a note carries no signal, so it stores NULL — nobody was asked — rather
  /// than `false`, which would say somebody listened and heard nothing wrong.
  ///
  /// **Task 11.197 replaced the chip with a checkbox** — see the group below
  /// for why, and for what the two states have to look like. Nothing about
  /// what reaches the row changed.
  ///
  /// One record saved per test rather than three in a loop: this harness pumps
  /// a fresh container and a fresh screen each time, and standing two of them
  /// up inside one `testWidgets` leaves the first one's providers running.
  Future<Observation> saveWith(
    WidgetTester tester, {
    required RecordType recordType,
    required bool tickTheFlag,
  }) async {
    final container = await readyContainer(
      tester,
      compassHeading: (ref) => Stream.value(CompassEvent.fromList([45, 45, 5])),
    );
    final notifier = container.read(observationFormProvider.notifier);
    notifier.setRecordType(recordType);
    notifier.setBearing(bearingDeg: 45, uncertaintyDeg: 12);
    notifier.setManualPosition(true, lat: 35.2, lon: -111.6);
    if (tickTheFlag) notifier.setSignalIrregular(true);
    // Same declination sidestep as the save test above: the WMM asset load
    // cannot resolve from inside `runAsync`'s real zone.
    await tester.runAsync(() async {
      await container.read(declinationOverrideProvider.future);
      await container.read(declinationOverrideProvider.notifier).set(9.77);
    });

    await pumpScreen(tester, container);

    final saveLabel =
        recordType == RecordType.note ? 'SAVE NOTE' : 'SAVE OBSERVATION';
    await tester.runAsync(() async {
      await tester.tap(find.text(saveLabel));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        await tester.pump();
        if (find.textContaining('saved').evaluate().isNotEmpty ||
            find.textContaining('Could not save').evaluate().isNotEmpty) {
          break;
        }
      }
    });
    expect(tester.takeException(), isNull);

    late List<Observation> saved;
    await tester.runAsync(() async {
      final repo = await container.read(observationRepositoryProvider.future);
      saved = await repo.findByProject('project-1');
    });
    expect(saved, hasLength(1));
    return saved.single;
  }

  testWidgets('a ticked irregular-signal flag reaches the saved bearing',
      (tester) async {
    final saved = await saveWith(
      tester,
      recordType: RecordType.directional,
      tickTheFlag: true,
    );
    expect(saved.signalIrregular, isTrue);
  });

  testWidgets('an unticked one saves as "no", which is a real answer',
      (tester) async {
    final saved = await saveWith(
      tester,
      recordType: RecordType.directional,
      tickTheFlag: false,
    );
    expect(
      saved.signalIrregular,
      isFalse,
      reason: 'The control was on the screen and the person did not tick it. '
          'That is an answer, and it is the common one — it is what makes a '
          'season of bearings evidence about a collar rather than a list of '
          'the times somebody remembered to complain.',
    );
  });

  testWidgets('a note stores no answer at all, because it was never asked',
      (tester) async {
    final saved = await saveWith(
      tester,
      recordType: RecordType.note,
      tickTheFlag: false,
    );
    expect(
      saved.signalIrregular,
      isNull,
      reason: 'A note has no signal in it and shows no such control, so the '
          'question was never put. NULL says that; false would say somebody '
          'listened and heard nothing wrong.',
    );
  });

  /// **The Irregular/Malfunctioning control, as a checkbox — task 11.197.**
  ///
  /// Michael, having used it in the field: *"right now it looks to the user
  /// like it is on by default — it isn't clear until you click on it that
  /// something happens — it turns red so the user will think: is that on or
  /// off?"* That is a real defect and not a preference: the chip's two states
  /// were *a chip* and *a slightly tinted chip*, on a screen where reading it
  /// wrong writes the wrong data. An empty checkbox is the one shape nobody
  /// has to have seen before to read as off.
  ///
  /// **The colour is the accelerator, not the answer** (`CLAUDE.md`). The box
  /// itself says which state it is in; grey and red only make it faster.
  group('the irregular-signal control (task 11.197)', () {
    Future<void> pumpFresh(WidgetTester tester) async {
      final container = await readyContainer(
        tester,
        compassHeading: (ref) =>
            Stream.value(CompassEvent.fromList([45, 45, 5])),
      );
      await pumpScreen(tester, container);
    }

    Checkbox boxOf(WidgetTester tester) => tester.widget<Checkbox>(
          find.descendant(
            of: find.byKey(const ValueKey('record-signal-irregular')),
            matching: find.byType(Checkbox),
          ),
        );

    Color labelColourOf(WidgetTester tester) => tester
        .widget<Text>(
          find.descendant(
            of: find.byKey(const ValueKey('record-signal-irregular')),
            matching: find.text(irregularSignalLabel),
          ),
        )
        .style!
        .color!;

    testWidgets('is a checkbox, off, and grey until somebody ticks it',
        (tester) async {
      await pumpFresh(tester);
      expect(boxOf(tester).value, isFalse,
          reason: 'Off by default. It is a claim that something was wrong '
              'with what was heard, and the default has to be the honest one.');
      final scheme =
          Theme.of(tester.element(find.byType(Checkbox).first)).colorScheme;
      expect(labelColourOf(tester), scheme.onSurfaceVariant,
          reason: 'Light grey when off — Michael\'s word — but the theme\'s '
              'muted *text* grey, not its border grey. Built against '
              '`scheme.outline` first, and the screenshot harness showed a '
              'label nobody could read, which reads as disabled rather than '
              'as off. That is a worse ambiguity than the one this control '
              'was rebuilt to remove.');
      // **Task 11.200: the assertion above passed for a year of nothing.**
      // It compared the label to a token, and the token was undefined, so it
      // resolved to `onSurface` — the assertion was "this grey equals this
      // grey" where both sides were full-strength black. A check keyed on a
      // name cannot notice that the name means the wrong thing. So assert the
      // *value*: whatever `onSurfaceVariant` is, it has to be visibly lighter
      // than ordinary body text, or "light grey when off" is not what
      // shipped.
      expect(labelColourOf(tester), isNot(scheme.onSurface),
          reason: 'The off label is the same colour as body text, so it is '
              'not "light grey by default" whatever the token is called. '
              'That was live from the day 11.197 shipped until 11.200 '
              'defined onSurfaceVariant.');
      expect(_relativeLuminance(labelColourOf(tester)),
          greaterThan(_relativeLuminance(scheme.onSurface) + 0.05),
          reason: 'Muted means lighter than body text in this app\'s light '
              'theme, by enough to read as a different weight of '
              'information rather than as a rendering artefact.');
    });

    testWidgets('turns red when it is ticked, and the word does not move',
        (tester) async {
      await pumpFresh(tester);
      final colors = Theme.of(tester.element(find.byType(Checkbox).first))
          .extension<TriTrackColors>()!;
      await tester.tap(find.byKey(const ValueKey('record-signal-irregular')));
      await tester.pumpAndSettle();
      expect(boxOf(tester).value, isTrue);
      expect(labelColourOf(tester), colors.bounceRed,
          reason: 'Red when checked. It is the same red every other "this is '
              'suspect" mark in the app uses, taken from the theme.');
      expect(find.text(irregularSignalLabel), findsOneWidget,
          reason: 'And the word is still there in both states — a colour '
              'never carries a meaning on its own in this app.');
    });

    testWidgets('the whole row is the tap target, not the 24-pixel box',
        (tester) async {
      await pumpFresh(tester);
      final row = tester.getRect(
          find.byKey(const ValueKey('record-signal-irregular')));
      expect(row.height, greaterThanOrEqualTo(44.0),
          reason: 'Rule 4 of this screen\'s space budget: 44-point targets, '
              'because this form is filled in one-handed and in gloves.');
    });
  });

  group('role-aware controls (task 11.12)', () {
    // The failure 11.12 exists to fix: a viewer walks the whole Record flow
    // — with no idea it will ever refuse them — and only discovers it isn't
    // allowed once `insertRow`'s role-gradient check throws out of `_save`.
    testWidgets('a viewer sees the reason up front and cannot save',
        (tester) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider
              .overrideWith((ref) async => sampleUser(id: 'user-2', email: 'viewer@x.com')),
          compassHeadingProvider
              .overrideWith((ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0]))),
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
        final db = (await container.read(appDatabaseProvider.future)).raw;

        await userRepo.insert(sampleUser(id: 'user-1'));
        await userRepo.insert(sampleUser(id: 'user-2', email: 'viewer@x.com'));
        await projectRepo.insert(sampleProject());
        await tagRepo.insert(sampleTag());
        // Task 11.249: on an animal, or the wheel does not offer it.
        await putSampleTagOnAnAnimal(container);
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-2', role: ProjectRole.viewer).toColumns(),
        );
        await container.read(activeProjectIdProvider.notifier).set('project-1');

        container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

        container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
        container.listen(observationFormProvider, (_, _) {});
        container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});

        await container.read(currentProjectProvider.future);
        await container.read(projectActiveTagsProvider('project-1').future);
        await container.read(projectDeploymentsProvider('project-1').future);
        await container.read(observationFormProvider.future);
        await container.read(mayWriteProjectDataProvider('project-1').future);
        await container.read(currentUserProvider.future);
        await container.read(deviceIdProvider.future);
      });

      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const ObservationLoggingScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      expect(
        find.textContaining('Viewers cannot record observations'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'SAVE OBSERVATION')).onPressed,
        isNull,
      );
    });

    testWidgets('a contributor sees no banner and can save', (tester) async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
          currentUserProvider
              .overrideWith((ref) async => sampleUser(id: 'user-2', email: 'contributor@x.com')),
          compassHeadingProvider
              .overrideWith((ref) => Stream.value(CompassEvent.fromList([45.0, 45.0, 5.0]))),
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
        final db = (await container.read(appDatabaseProvider.future)).raw;

        await userRepo.insert(sampleUser(id: 'user-1'));
        await userRepo.insert(sampleUser(id: 'user-2', email: 'contributor@x.com'));
        await projectRepo.insert(sampleProject());
        await tagRepo.insert(sampleTag());
        // Task 11.249: on an animal, or the wheel does not offer it.
        await putSampleTagOnAnAnimal(container);
        await db.insert(
          Tables.projectMemberships,
          sampleMembership(userId: 'user-2', role: ProjectRole.contributor).toColumns(),
        );
        await container.read(activeProjectIdProvider.notifier).set('project-1');

        container.listen(projectActiveTagsProvider('project-1'), (_, _) {});

        container.listen(projectDeploymentsProvider('project-1'), (_, _) {});
        container.listen(observationFormProvider, (_, _) {});
        container.listen(mayWriteProjectDataProvider('project-1'), (_, _) {});

        await container.read(currentProjectProvider.future);
        await container.read(projectActiveTagsProvider('project-1').future);
        await container.read(projectDeploymentsProvider('project-1').future);
        await container.read(observationFormProvider.future);
        await container.read(mayWriteProjectDataProvider('project-1').future);
        await container.read(currentUserProvider.future);
        await container.read(deviceIdProvider.future);
      });

      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(theme: AppTheme.light(), home: const ObservationLoggingScreen()),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      // The banner is the role gate's own signal, asserted directly rather
      // than through the Save button: `hasBearing` is false at first load
      // (no bearing captured yet), so Save is legitimately disabled by form
      // validity regardless of role, and asserting `onPressed` here would
      // conflate the two.
      expect(find.textContaining('Viewers cannot record observations'), findsNothing);
    });
  });
}

/// WCAG relative luminance, so "lighter than body text" is a measured claim
/// rather than a look. Added by task 11.200.
double _relativeLuminance(Color c) {
  double channel(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}
