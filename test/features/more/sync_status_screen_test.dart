import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/sync_conflicts_provider.dart';
import 'package:tritrack/core/providers/sync_dropped_rows_provider.dart';
import 'package:tritrack/core/providers/sync_held_rows_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/sync/held_row_details.dart';
import 'package:tritrack/data/sync/remembered_sync_failure.dart';
import 'package:tritrack/data/sync/sync_conflicts.dart';
import 'package:tritrack/data/sync/sync_dropped_rows.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/features/more/screens/sync_status_screen.dart';
import 'package:tritrack/widgets/sync_status_presentation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 10.28's user-facing half: "the user is told, in the app, that something
/// did not sync and why."
///
/// §8 recorded that this screen had no widget test at all, which is how a
/// correct server refusal reached a device as a green "Synced" — the sign-in
/// bug's shape exactly.
///
/// **Rewritten at task 11.41, because it was passing against a screen that did
/// not do its job.** The assertions used to read the reason text back out of
/// `HeldRowReason.notPermitted.explanation` — which proved the screen rendered
/// *the enum*, and the enum is one paragraph covering three unrelated causes.
/// A card saying "Users" and that paragraph passed every check here and still
/// left a person unable to tell which record, which rule, or what to do. The
/// tests below assert those three things by name.
void main() {
  const projectId = 'proj-1';

  // Relative to now, not a fixed calendar date (task 11.114): a fixed past
  // date drifts past the 24-hour staleness threshold and would eventually
  // make every "clean"/"healthy" fixture in this file trip that state
  // instead of the one each test actually means to exercise.
  final recentSuccess = DateTime.now().toUtc().subtract(
    const Duration(hours: 1),
  );

  // No database: every provider this screen reads is overridden, so the tests
  // stay fast and deterministic. The store's own behaviour has its own suite.
  setUp(installFakeSharedPreferences);

  HeldRow heldRow({
    HeldRowReason reason = HeldRowReason.notPermitted,
    int refusalCount = 1,
  }) => HeldRow(
    id: 1,
    tableName: Tables.observations,
    rowKey: 'obs-refused',
    reason: reason,
    heldUpdatedAt: '2026-08-01T12:00:00.000Z',
    firstHeldAtUtc: DateTime.utc(2026, 8, 1, 12),
    lastRefusedAtUtc: DateTime.utc(2026, 8, 1, 12),
    refusalCount: refusalCount,
  );

  /// A resolved hold, as `HeldRowDetails` would produce it. The resolver's own
  /// sentences are asserted against a real database in
  /// `test/data/sync/held_row_details_test.dart`; here the fixture is fixed so
  /// the assertions are about the *screen* showing all three parts.
  HeldRowDetail detail({
    HeldRowReason reason = HeldRowReason.notPermitted,
    int refusalCount = 1,
    bool recordExists = true,
  }) => HeldRowDetail(
    held: heldRow(reason: reason, refusalCount: refusalCount),
    recordLabel: 'A bearing on "Elk 12" (150.220 MHz), 2026-08-01 12:00',
    heldBy: 'This record says Kim Reynolds made it, and this device is signed '
        'in as Michael Shafer.',
    whatYouCanDo: "Nothing. Kim Reynolds's own device sends it when it syncs.",
    recordExists: recordExists,
  );

  /// A resolved drop fixture, mirroring [detail] above — the resolver's own
  /// values live in [DroppedRowDetails], which reads no database, so no
  /// separate "as the resolver would produce it" test is needed for it.
  DroppedRow droppedRow({
    String field = 'signal_strength',
    String message = 'unknown value "blisteringly_loud"',
    int dropCount = 1,
  }) => DroppedRow(
    id: 1,
    tableName: Tables.observations,
    rowKey: 'obs-dropped',
    field: field,
    message: message,
    firstDroppedAtUtc: DateTime.utc(2026, 8, 28, 12),
    lastDroppedAtUtc: DateTime.utc(2026, 8, 28, 12),
    dropCount: dropCount,
  );

  Future<({ProviderContainer container, _FakeSyncController controller})>
  pumpScreen(
    WidgetTester tester, {
    required SyncStatus status,
    List<HeldRowDetail> held = const [],
    List<DroppedRow> dropped = const [],
    List<SyncConflict> conflicts = const [],
    HeldRowRetry? retry,
  }) async {
    // **Tall enough that the whole screen is laid out.** The status card grew
    // a frequency control at task 11.59 and this is a lazy `ListView`, so on a
    // phone-sized test surface the sections below it are never built and every
    // assertion about them fails for a reason that has nothing to do with what
    // it is testing. What is asserted here is the copy the screen contains,
    // not how far a user has scrolled.
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    final controller = _FakeSyncController(status);
    final container = ProviderContainer(
      overrides: [
        syncControllerProvider.overrideWith(() => controller),
        syncHeldRowDetailsProvider(
          projectId,
        ).overrideWith((ref) async => held),
        syncDroppedRowsProvider(
          projectId,
        ).overrideWith((ref) async => dropped),
        syncConflictsProvider(projectId).overrideWith((ref) async => conflicts),
        if (retry != null) heldRowRetryProvider.overrideWithValue(retry),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeProjectIdProvider.notifier).set(projectId);

    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: SyncStatusScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return (container: container, controller: controller);
  }

  testWidgets('a clean state says synced and lists nothing', (tester) async {
    await pumpScreen(
      tester,
      status: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: recentSuccess,
      ),
    );

    expect(find.text('Synced'), findsOneWidget);
    expect(find.text('Waiting to sync'), findsNothing);
    expect(find.text('Try again'), findsNothing);
    expect(find.text('Records that did not arrive'), findsNothing);
  });

  testWidgets(
    'a replaced server database is said, dated, and is not a failure '
    '(task 11.58)',
    (tester) async {
      final changedAt = DateTime.utc(2026, 9, 29, 14, 2);
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
          serverDatabaseChangedAt: changedAt,
        ),
      );

      final line = find.byKey(const ValueKey('server_database_changed'));
      expect(line, findsOneWidget);
      final text = tester.widget<Text>(line).data!;
      // Dated in local time, the way the "last synced" line beside it is.
      expect(
        text,
        contains(changedAt.toLocal().toString().substring(0, 16)),
      );
      // Names both ordinary causes and asserts neither.
      expect(text, contains('restored from a backup, or rebuilt'));
      expect(text, contains('started syncing this project over'));
      // The round that found it succeeded, so the headline does not move.
      expect(find.text('Synced'), findsOneWidget);
      // And it is not in the error color: it is news, not a warning.
      expect(tester.widget<Text>(line).style?.color, isNull);
    },
  );

  testWidgets('a device that has never met a replaced database says nothing '
      'about one', (tester) async {
    await pumpScreen(
      tester,
      status: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: recentSuccess,
      ),
    );
    expect(
      find.byKey(const ValueKey('server_database_changed')),
      findsNothing,
    );
  });

  testWidgets(
    'a dropped record is named, explained, and durable — not just a count '
    '(task 11.44)',
    (tester) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
          droppedOnArrivalCount: 1,
        ),
        dropped: [droppedRow()],
      );

      // Not "Synced" — the same rule task 10.28 established for the outbound
      // side, pointed the other way.
      expect(find.text('Synced'), findsNothing);
      expect(find.text('Some records did not arrive'), findsOneWidget);

      // Its own section, with no "Try again" — there is no local retry for a
      // record this device never stored.
      expect(find.text('Records that did not arrive'), findsOneWidget);
      expect(find.text('Try again'), findsNothing);

      // **Which record** — the table and the identity, since there is no
      // stored copy to read a friendlier name from.
      expect(find.textContaining('Observations · obs-dropped'), findsOneWidget);
      // **Which rule**, under a heading a person can scan for.
      expect(find.text('Why it did not arrive'), findsOneWidget);
      expect(
        find.textContaining('signal_strength — unknown value'),
        findsOneWidget,
      );
      // **What to do.**
      expect(find.text('What you can do'), findsOneWidget);
    },
  );

  testWidgets('a repeatedly dropped record says how many times', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SyncStatus(
        schedule: const SyncSchedule(),
        droppedOnArrivalCount: 1,
      ),
      dropped: [droppedRow(dropCount: 4)],
    );

    expect(find.textContaining('4 times'), findsOneWidget);
  });

  testWidgets('a held record is named, explained, and retryable', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SyncStatus(
        schedule: const SyncSchedule(),
        lastSuccessAt: recentSuccess,
        heldCount: 1,
      ),
      held: [detail()],
    );

    // Not "Synced", which is what this screen used to say in this exact state.
    expect(find.text('Synced'), findsNothing);
    expect(find.text('Some records not synced'), findsOneWidget);

    // The headline count on the status card...
    expect(
      find.textContaining('1 record is safe on this device but not yet on '
          'the server'),
      findsOneWidget,
    );
    // ...its own section, above "Overwritten edits"...
    expect(find.text('Waiting to sync'), findsOneWidget);
    expect(find.textContaining('safe on this device'), findsWidgets);

    // ...and the three things the banner promises and this screen did not
    // deliver. **Which record** — the card led with the literal word
    // "Observations" before this, which named nothing.
    expect(
      find.textContaining('Elk 12'),
      findsOneWidget,
      reason: 'the card must name the record, not its table',
    );
    expect(
      find.text('Observations'),
      findsNothing,
      reason: 'a bare table name is what this screen used to show instead',
    );
    // **Which rule**, under a heading a person can scan for.
    expect(find.text('Why it is waiting'), findsOneWidget);
    expect(find.textContaining('Kim Reynolds made it'), findsOneWidget);
    // **What to do.**
    expect(find.text('What you can do'), findsOneWidget);
    expect(find.textContaining("Nothing. Kim Reynolds's own device"), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
  });

  testWidgets('the table name and row key are still there, at the end', (
    tester,
  ) async {
    // Kept, and demoted: it is what somebody quotes in a bug report, and it is
    // not what the person reading a red card needs first.
    await pumpScreen(
      tester,
      status: SyncStatus(schedule: const SyncSchedule(), heldCount: 1),
      held: [detail()],
    );
    expect(find.textContaining('Observations · obs-refused'), findsOneWidget);
  });

  testWidgets('a record that is gone cannot be retried', (tester) async {
    // "Try again" on a record this device no longer holds is a button that
    // cannot do anything, and offering it is the same defect one size down:
    // a control that promises an outcome it cannot produce.
    await pumpScreen(
      tester,
      status: SyncStatus(schedule: const SyncSchedule(), heldCount: 1),
      held: [detail(recordExists: false)],
    );
    final button = tester.widget<TextButton>(find.byType(TextButton));
    expect(button.onPressed, isNull);
  });

  testWidgets('a repeatedly refused record says how many attempts', (
    tester,
  ) async {
    await pumpScreen(
      tester,
      status: SyncStatus(schedule: const SyncSchedule(), heldCount: 1),
      held: [detail(refusalCount: 4)],
    );

    expect(find.textContaining('4 attempts'), findsOneWidget);
  });

  testWidgets('"Try again" runs the retry action for that row', (tester) async {
    // The wiring, which is the half that was missing everywhere else: a correct
    // action nobody can reach is the same bug as a correct refusal nobody can
    // see. What the action then *does* — lift the suppression, keep the row
    // counted — is asserted directly against
    // `releaseHeldRowForRetry` in `sync_held_rows_test.dart`, because SQLite
    // work started from a tap never completes under `testWidgets`' fake clock.
    final retried = <({String projectId, HeldRow row})>[];
    await pumpScreen(
      tester,
      status: SyncStatus(schedule: const SyncSchedule(), heldCount: 1),
      held: [detail()],
      retry: (projectId, row) async =>
          retried.add((projectId: projectId, row: row)),
    );

    // Scrolled into view first: the explanation above it is a paragraph, and
    // on a 800x600 test surface a longer one pushes the button off the bottom
    // — which `tap` reports as a warning and then fails on, several lines
    // away from the cause.
    await tester.ensureVisible(find.text('Try again'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Try again'));
    await tester.pump();

    expect(retried, hasLength(1));
    expect(retried.single.projectId, projectId);
    expect(retried.single.row.rowKey, 'obs-refused');
  });

  group('SyncHealth.versionRefused headlines its own cause, not a fixed '
      '"Update needed" (task 11.303)', () {
    // **The one a person meets today**, per the brief: rate-limited, on a
    // fully current app, on an ordinary retry. Read aloud, this is what the
    // screen now says: headline "Too many attempts", then "Too many
    // attempts. Wait a few minutes and try again." — nothing about updating
    // anything.
    testWidgets('a rate-limited device is told to wait, not to update', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalRateLimited,
          lastErrorHeadline: 'Too many attempts',
          lastErrorMessage: 'Too many attempts. Wait a few minutes and try '
              'again.',
        ),
      );

      expect(find.text('Too many attempts'), findsOneWidget);
      expect(find.text('Update needed'), findsNothing);
      expect(
        find.text('Too many attempts. Wait a few minutes and try again.'),
        findsOneWidget,
      );
    });

    testWidgets('a device too long offline is told that, not to update', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalCursorTooOld,
          lastErrorHeadline: 'Offline too long to sync',
          lastErrorMessage: 'This device has been offline too long to sync '
              'this project safely.',
        ),
      );

      expect(find.text('Offline too long to sync'), findsOneWidget);
      expect(find.text('Update needed'), findsNothing);
    });

    testWidgets('a project deleted on the server is told that, not to '
        'update', (tester) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalProjectDestroyed,
          lastErrorHeadline: 'Project deleted',
          lastErrorMessage: 'This project was deleted from the server by a '
              'project owner.',
        ),
      );

      expect(find.text('Project deleted'), findsOneWidget);
      expect(find.text('Update needed'), findsNothing);
    });

    /// **Task 11.319 item 3.** The sentence under the headline said nothing
    /// was wrong on the device and was drawn in the error color anyway, and
    /// so was the icon beside the headline. Its neighbor *no longer on this
    /// project* uses neither, for the same reason: somebody decided this.
    /// Two tests rather than one because `pumpScreen` leaves a timer behind
    /// when it is called twice in a test.
    testWidgets('a project deleted on the server is not drawn in the error '
        'color', (tester) async {
      const sentence = 'This project was deleted from the server by a '
          'project owner.';
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalProjectDestroyed,
          lastErrorHeadline: 'Project deleted',
          lastErrorMessage: sentence,
        ),
      );
      final scheme = Theme.of(tester.element(find.text(sentence))).colorScheme;
      expect(tester.widget<Text>(find.text(sentence)).style?.color,
          isNot(scheme.error));
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byType(Card).first,
                matching: find.byType(Icon),
              ).first,
            )
            .color,
        SyncSeverity.quiet.color,
      );
    });

    testWidgets('a version skew is still drawn in the error color', (
      tester,
    ) async {
      const skew = 'This version of TriTrack is too old to sync with the '
          'server. Update the app to continue syncing.';
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalSchemaVersion,
          lastErrorHeadline: 'Update needed',
          lastErrorMessage: skew,
        ),
      );
      final scheme = Theme.of(tester.element(find.text(skew))).colorScheme;
      expect(tester.widget<Text>(find.text(skew)).style?.color, scheme.error);
      expect(
        tester
            .widget<Icon>(
              find.descendant(
                of: find.byType(Card).first,
                matching: find.byType(Icon),
              ).first,
            )
            .color,
        SyncSeverity.fault.color,
      );
    });

    testWidgets('a genuine version skew still reads "Update needed"', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastFailure: SyncFailureCause.refusedWithRemedy,
          lastError: syncRefusalSchemaVersion,
          lastErrorHeadline: 'Update needed',
          lastErrorMessage: 'This version of TriTrack is too old to sync '
              'with the server. Update the app to continue syncing.',
        ),
      );

      expect(find.text('Update needed'), findsOneWidget);
    });

    testWidgets(
      'a remembered refusal from before a restart falls back to the code, '
      'not to "Update needed"',
      (tester) async {
        // No `lastErrorHeadline` — this session has not retried since the
        // app restarted, so only `remembered.stoppedReason` (the durable
        // record) survives. `rate_limited` is a 429, not one of
        // `isTerminal`'s statuses, so it is the one code in the family that
        // cannot even reach here — checked separately in
        // `sync_transport_refusal_test.dart`.
        await pumpScreen(
          tester,
          status: SyncStatus(
            schedule: const SyncSchedule(),
            remembered: RememberedSyncFailure(
              cause: SyncFailureCause.refusedWithRemedy,
              consecutiveFailures: 1,
              recordedAt: DateTime.now().toUtc(),
              stoppedReason: syncRefusalCursorTooOld,
            ),
          ),
        );

        expect(find.text('Offline too long to sync'), findsOneWidget);
        expect(find.text('Update needed'), findsNothing);
      },
    );
  });

  group('how often the app syncs on its own (task 11.59)', () {
    testWidgets('every choice is offered, by name, with one recommended', (
      tester,
    ) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
        ),
      );

      expect(find.text('Sync while TriTrack is open'), findsOneWidget);
      expect(find.text('Every time I open it'), findsOneWidget);
      expect(find.text('Every 15 minutes (recommended)'), findsOneWidget);
      expect(find.text('Hourly'), findsOneWidget);
      expect(find.text('Only when I ask'), findsOneWidget);
    });

    testWidgets('no label on this screen promises background syncing', (
      tester,
    ) async {
      // **The line this task is most likely to get wrong.** Task 10.8 decided
      // there is no background sync, so a control reading "Sync every 15
      // minutes" would describe a mechanism the code does not have — the same
      // defect class tasks 11.54 and 11.57 existed to close, arriving through
      // a new door.
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
        ),
      );

      expect(
        find.textContaining('It does not sync in the background'),
        findsOneWidget,
      );
      expect(
        find.textContaining('while the app is closed, nothing syncs at any '
            'of these settings'),
        findsOneWidget,
      );
    });

    testWidgets('the cellular-data cost is stated on this screen', (
      tester,
    ) async {
      // Automatic sync is not Wi-Fi-only, an "unmetered only" setting needs
      // interface detection and is follow-up scope — so somebody being handed
      // a frequency control gets that sentence beside it.
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
        ),
      );

      expect(find.textContaining('including cellular data'), findsOneWidget);
      expect(
        find.textContaining('There is no Wi-Fi-only setting yet'),
        findsOneWidget,
      );
    });

    testWidgets('picking one records it', (tester) async {
      final pumped = await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
        ),
      );

      await tester.tap(
        find.byKey(const ValueKey('sync_frequency_only_when_i_ask')),
      );
      await tester.pumpAndSettle();

      expect(pumped.controller.frequenciesSet, [SyncFrequency.onlyWhenIAsk]);
    });

    testWidgets(
      'with it off, the card says the waiting records are not going anywhere',
      (tester) async {
        await pumpScreen(
          tester,
          status: SyncStatus(
            schedule: const SyncSchedule(
              frequency: SyncFrequency.onlyWhenIAsk,
            ),
            lastSuccessAt: recentSuccess,
            pendingCount: 2,
          ),
        );

        expect(
          find.textContaining('they stay here until you tap Sync now'),
          findsOneWidget,
        );
      },
    );

    testWidgets('the manual button is offered whatever the setting says', (
      tester,
    ) async {
      // `syncNow` ignores the schedule entirely — the trailhead case task
      // 10.8 was designed around.
      final pumped = await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(frequency: SyncFrequency.onlyWhenIAsk),
          lastSuccessAt: recentSuccess,
        ),
      );

      await tester.tap(find.byKey(const ValueKey('sync_now')));
      await tester.pumpAndSettle();

      expect(pumped.controller.syncNowCalls, 1);
    });
  });

  /// **The dismiss control's home after task 11.189.**
  ///
  /// It was a close button on the app shell's sync bar (task 11.114), on
  /// exactly the two staleness states and no others. The bar is gone —
  /// Michael asked on 2026-09-07 for it to be replaced by one small icon —
  /// and this is the screen that icon taps through to, so this is where the
  /// control came.
  ///
  /// **The criterion did not move with it.** A held record, a rejected
  /// certificate or an ended membership has never had anything here for a
  /// dismiss to silence: none of them goes away by being ignored, and
  /// offering to hide one would be the app's most useful warning wearing a
  /// close button.
  group('dismissing a stale sync (tasks 11.114, 11.189)', () {
    final stale = SyncStatus(
      schedule: const SyncSchedule(),
      lastSuccessAt: DateTime.now().toUtc().subtract(
        const Duration(hours: 30),
      ),
      pendingCount: 12,
    );

    testWidgets('the control is here, and says when the warning comes back',
        (tester) async {
      await pumpScreen(tester, status: stale);

      expect(find.byKey(const ValueKey('dismiss_stale_sync')), findsOneWidget);
      // **In words, on the screen** — not in a `tooltip:` a touchscreen never
      // shows, which is the trap tasks 11.94 and 11.101 pulled this control
      // out of once already. A 12-point strip had no room for the sentence;
      // this screen does.
      expect(find.text('Dismiss until tomorrow morning'), findsOneWidget);
      expect(
        find.textContaining('until 4am tomorrow'),
        findsOneWidget,
        reason: '"24 hours" and "04:00" are facts nobody could infer from the '
            'headline, and this is the one surface with room to say them',
      );
    });

    testWidgets('the copy does not send anybody to a bar that is gone',
        (tester) async {
      // The sentence used to read "Dismissing this on the bar above brings
      // back…". There is no bar above, and copy describing a mechanism the
      // app does not have is the same defect as a message naming the wrong
      // cause.
      await pumpScreen(tester, status: stale);

      expect(find.textContaining('the bar above'), findsNothing);
    });

    testWidgets('it is a real touch target', (tester) async {
      // Task 11.114's own measurement obligation, carried over: on the strip
      // this was a 44-pixel invisible area around an 18-pixel icon, and the
      // arithmetic that produced it went with the strip.
      await pumpScreen(tester, status: stale);

      final size =
          tester.getSize(find.byKey(const ValueKey('dismiss_stale_sync')));
      expect(size.height, greaterThanOrEqualTo(44));
      expect(size.width, greaterThanOrEqualTo(44));
    });

    testWidgets('tapping it dismisses, and says so where they can see it',
        (tester) async {
      final pumped = await pumpScreen(tester, status: stale);

      await tester.tap(find.byKey(const ValueKey('dismiss_stale_sync')));
      await tester.pumpAndSettle();

      expect(pumped.controller.dismissals, 1);
      // The SnackBar is what tells somebody *when* it comes back, at the
      // moment they act — the only moment they are looking.
      expect(find.text('Dismissed until tomorrow morning'), findsOneWidget);
    });

    testWidgets(
      'there is nothing to dismiss on a state that will not go away by itself',
      (tester) async {
        // Stale *and* holding a record the server refused. The held record
        // outranks staleness, and it is not dismissible at any point.
        await pumpScreen(
          tester,
          status: SyncStatus(
            schedule: const SyncSchedule(),
            lastSuccessAt: DateTime.now().toUtc().subtract(
              const Duration(days: 10),
            ),
            heldCount: 1,
          ),
        );

        expect(find.byKey(const ValueKey('dismiss_stale_sync')), findsNothing);
      },
    );
  });
  group(
    'accessRefused speaks to both people it now reaches, and guesses '
    'nothing (task 11.306)',
    () {
      // Task 11.305 made a 403 with no membership row at all read as
      // "access refused" rather than "you left this project" — correct,
      // but it means two different people meet this same card: somebody
      // an owner removed, and somebody signed in on a phone that still
      // holds another person's project. The old wording named only the
      // first person's cause ("the usual reason is that an owner removed
      // you") and offered only the first person's remedy ("ask an
      // owner"). This screen cannot tell the two people apart, so it must
      // not guess, and it must offer both remedies.
      final accessRefused = SyncStatus(
        schedule: const SyncSchedule(),
        lastFailure: SyncFailureCause.accessRefused,
      );

      testWidgets('names no cause, only that the device cannot tell', (
        tester,
      ) async {
        await pumpScreen(tester, status: accessRefused);

        expect(
          find.textContaining('the usual reason is'),
          findsNothing,
          reason: 'a cause it cannot confirm is a guess, not an explanation',
        );
        expect(
          find.textContaining('an owner removed you'),
          findsNothing,
          reason: 'true for one of the two people this screen now reaches, '
              'wrong for the other',
        );
      });

      testWidgets('offers both remedies, ask-an-owner first', (tester) async {
        await pumpScreen(tester, status: accessRefused);

        expect(find.textContaining('ask an owner'), findsOneWidget);
        expect(
          find.textContaining('If this is not your project'),
          findsOneWidget,
        );
        final ownerAt = tester
            .getTopLeft(find.textContaining('ask an owner'))
            .dy;
        final notYoursAt = tester
            .getTopLeft(find.textContaining('If this is not your project'))
            .dy;
        expect(
          ownerAt,
          lessThanOrEqualTo(notYoursAt),
          reason: 'ask an owner is the likelier case and reads first',
        );
      });

      testWidgets('keeps the reassurance, true for both people', (
        tester,
      ) async {
        await pumpScreen(tester, status: accessRefused);

        expect(
          find.textContaining('Nothing on this device has been changed or '
              'lost'),
          findsOneWidget,
        );
      });
    },
  );

  group('one card per record does not survive an import (task 10.87)', () {
    SyncConflict conflict(int i, {required DateTime at, String table = Tables.observations}) =>
        SyncConflict(
          id: i,
          tableName: table,
          rowKey: 'obs-$i/proj-1',
          detectedAtUtc: at,
          localSnapshot: {'latitude': 35.0},
          incomingSnapshot: {'latitude': 0.0},
        );

    testWidgets('1,000 overwrites from one import are one card, and it says '
        'how many it shows', (tester) async {
      final importedAt = DateTime.utc(2026, 9, 13, 10);
      final earlierSync = DateTime.utc(2026, 9, 12, 8);
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
        ),
        conflicts: [
          for (var i = 0; i < 1000; i++) conflict(i, at: importedAt),
          conflict(5000, at: earlierSync, table: Tables.tags),
        ],
      );
      expect(find.byType(ConflictEventCard), findsNWidgets(2));
      expect(find.text('1000 records overwritten'), findsOneWidget);
      expect(find.text('1 record overwritten'), findsOneWidget);
      expect(find.textContaining('1000 bearings'), findsOneWidget);
      expect(find.textContaining('1 tag'), findsOneWidget);
      // Newest event first — the device's clock, not the file's order.
      expect(
        tester.getTopLeft(find.text('1000 records overwritten')).dy,
        lessThan(tester.getTopLeft(find.text('1 record overwritten')).dy),
      );

      await tester.tap(find.text('1000 records overwritten'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Showing the first '
            '${ConflictEventCard.shownPerEvent} of 1000'),
        findsOneWidget,
      );
      expect(find.text('Got it — all 1000'), findsOneWidget);
      // Bounded: the sample, not the thousand.
      expect(find.text('Bearings'), findsNWidgets(ConflictEventCard.shownPerEvent));
    });

    testWidgets('1,000 waiting records draw twenty, state the total and the '
        'order, and offer the rest', (tester) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
          heldCount: 1000,
        ),
        held: [for (var i = 0; i < 1000; i++) detail()],
      );
      expect(find.text('Waiting to sync'), findsOneWidget);
      expect(
        find.text('Showing the first ${BoundedRecordList.shownByDefault} of '
            '1000 records, most recently refused first.'),
        findsOneWidget,
      );
      expect(find.text('Why it is waiting'),
          findsNWidgets(BoundedRecordList.shownByDefault));
      expect(find.text('Show all 1000'), findsOneWidget);
    });

    testWidgets('twenty or fewer are simply listed, with no bound sentence',
        (tester) async {
      await pumpScreen(
        tester,
        status: SyncStatus(
          schedule: const SyncSchedule(),
          lastSuccessAt: recentSuccess,
          heldCount: 3,
        ),
        held: [for (var i = 0; i < 3; i++) detail()],
      );
      expect(find.textContaining('Showing the first'), findsNothing);
      expect(find.text('Why it is waiting'), findsNWidgets(3));
    });
  });

  group(
    'with no project selected (task 11.313) — *Sync now* is not a dead end',
    () {
      Future<ProviderContainer> pumpNoProject(
        WidgetTester tester, {
        List<UndeliveredProjectDeletion> undelivered = const [],
      }) async {
        final container = ProviderContainer(
          overrides: [
            undeliveredProjectDeletionsProvider.overrideWith(
              (ref) async => undelivered,
            ),
          ],
        );
        addTearDown(container.dispose);
        await tester.pumpWidget(
          UncontrolledProviderScope(
            container: container,
            child: const MaterialApp(home: SyncStatusScreen()),
          ),
        );
        await tester.pumpAndSettle();
        return container;
      }

      testWidgets(
        'with nothing pending, says a just-deleted project reaches the '
        'server on its own — the guarantee, not a bare "no project"',
        (tester) async {
          await pumpNoProject(tester);
          expect(find.text('No project is selected.'), findsOneWidget);
          expect(
            find.textContaining(
              'If you just deleted the open project, that has already '
              'reached the server, or will the next time this device has '
              'cell or wifi coverage',
            ),
            findsOneWidget,
          );
        },
      );

      testWidgets(
        'with a deletion still pending, names it and points at Projects '
        'for the undo — the same list the Projects screen already reads',
        (tester) async {
          await pumpNoProject(
            tester,
            undelivered: const [
              UndeliveredProjectDeletion(
                projectId: 'proj-2',
                projectName: 'Elk Study',
                deletedAt: null,
                refusal: null,
                held: null,
              ),
            ],
          );
          expect(
            find.textContaining('1 deletion is still waiting to reach the '
                'server'),
            findsOneWidget,
          );
          // Task 11.339 folded that section into the Trash.
          expect(find.textContaining('restore it from Projects → Trash'),
              findsOneWidget);
          expect(
            find.textContaining('If you just deleted the open project'),
            findsNothing,
            reason: 'the two sentences answer the same question; showing '
                'both would contradict each other',
          );
        },
      );

      testWidgets('several pending deletions are counted, not just named',
          (tester) async {
        await pumpNoProject(
          tester,
          undelivered: const [
            UndeliveredProjectDeletion(
              projectId: 'proj-2',
              projectName: 'Elk Study',
              deletedAt: null,
              refusal: null,
              held: null,
            ),
            UndeliveredProjectDeletion(
              projectId: 'proj-3',
              projectName: 'Owl Survey',
              deletedAt: null,
              refusal: SyncFailureCause.serverRejected,
              held: null,
            ),
          ],
        );
        expect(
          find.textContaining('2 deletions are still waiting to reach the '
              'server'),
          findsOneWidget,
        );
      });
    },
  );
}

class _FakeSyncController extends SyncController {
  _FakeSyncController(this._status);

  final SyncStatus _status;
  int syncNowCalls = 0;
  int dismissals = 0;
  final List<SyncFrequency> frequenciesSet = [];

  @override
  Future<SyncStatus> build() async => _status;

  @override
  Future<void> syncNow() async {
    syncNowCalls++;
  }

  /// Recorded rather than performed. What the real one does — write the
  /// dismissal down and let `SyncStatus.health` fall back to
  /// healthy/offline until 4am — is `sync_provider_test.dart`'s subject;
  /// what this file asks is whether the control on this screen calls it.
  @override
  Future<void> dismissStaleness() async {
    dismissals++;
  }

  @override
  Future<void> setFrequency(SyncFrequency frequency) async {
    frequenciesSet.add(frequency);
    state = AsyncData(
      SyncStatus(
        schedule: _status.schedule.withFrequency(frequency),
        unavailable: _status.unavailable,
        lastSuccessAt: _status.lastSuccessAt,
        pendingCount: _status.pendingCount,
        heldCount: _status.heldCount,
        droppedOnArrivalCount: _status.droppedOnArrivalCount,
      ),
    );
  }
}
