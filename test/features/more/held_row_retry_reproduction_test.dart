import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/retry_policy.dart';
import 'package:tritrack/core/providers/sync_held_rows_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/sync/held_row_details.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_schedule.dart';
import 'package:tritrack/features/more/screens/sync_status_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_shared_preferences.dart';

/// Task 11.236 — **"Try again" released the held record and then lied about
/// it.**
///
/// [heldRowRetryProvider] is auto-disposing, and the status screen reads it
/// bare — `ref.read(heldRowRetryProvider)(...)` — a read with no listener
/// behind it. The closure it returns used to `ref.invalidate` and
/// `ref.read(syncControllerProvider.notifier)` **after** the database write
/// that releases the row, so a probe calling it exactly as the screen does
/// threw *"Cannot use the Ref of heldRowRetryProvider after it has been
/// disposed"* — the same class of exception task 11.235 found on the tag
/// database's + button. Nothing was lost (the write had already committed),
/// but the screen said nothing, so a person watching it had no way to tell a
/// silent success from a worse failure.
///
/// **Nothing here overrides `heldRowRetryProvider` itself.** That is the
/// whole point — the file next door (`sync_status_screen_test.dart`) always
/// does, which is exactly why it never saw this. `syncHeldRowDetailsProvider`
/// is overridden only because resolving a real held row's record label needs
/// a matching `Observations` row this fixture has no reason to build; the
/// database, and the provider under test, are real.
void main() {
  setUp(installFakeSharedPreferences);

  const projectId = 'proj-retry';

  final heldRow = HeldRow(
    id: 1,
    tableName: Tables.observations,
    rowKey: 'obs-1',
    reason: HeldRowReason.notPermitted,
    heldUpdatedAt: '2026-09-01T12:00:00.000Z',
    firstHeldAtUtc: DateTime.utc(2026, 9, 1, 12),
    lastRefusedAtUtc: DateTime.utc(2026, 9, 1, 12),
    refusalCount: 1,
  );

  final detail = HeldRowDetail(
    held: heldRow,
    recordLabel: 'A bearing, 2026-09-01 12:00',
    heldBy: 'This record says somebody else made it.',
    whatYouCanDo: 'Nothing. Their own device sends it when it syncs.',
    recordExists: true,
  );

  /// Records `syncNow()` calls without touching the network — the real
  /// [heldRowRetryProvider] calls into this through its own `.notifier`
  /// watch, so this is the only thing standing between the test and a real
  /// sync round.
  final controllerCalls = <String>[];

  Future<ProviderContainer> deviceWithHeldRow(WidgetTester tester) async {
    late AppDatabase db;
    await tester.runAsync(() async {
      db = await AppDatabase.openInMemory();
      await SyncHeldRowStore.ensureTable(db.raw);
      await SyncHeldRowStore(db.raw).hold(
        projectId: projectId,
        tableName: heldRow.tableName,
        rowKey: heldRow.rowKey,
        reason: heldRow.reason,
        rowUpdatedAt: heldRow.heldUpdatedAt,
        at: heldRow.lastRefusedAtUtc,
      );
    });

    final container = ProviderContainer(
      retry: appRetryPolicy,
      overrides: [
        appDatabaseProvider.overrideWith((ref) async => db),
        syncHeldRowDetailsProvider(
          projectId,
        ).overrideWith((ref) async => [detail]),
        syncControllerProvider.overrideWith(
          () => _RecordingSyncController(controllerCalls),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    return container;
  }

  /// **`pumpAndSettle` alone does not wait for the real SQLite work this
  /// screen's providers do** — it only re-pumps frames, and a real database
  /// read needs the real event loop to tick, which nothing here gives it
  /// without `runAsync`. This polls with real delays between pumps instead,
  /// the same shape `pumpInAppShell` uses, and fails with a sentence rather
  /// than hanging if the screen never finishes loading (task 11.236 item 3's
  /// rule, applied to this file rather than only to `currentProjectProvider`).
  Future<void> pumpScreen(WidgetTester tester, ProviderContainer container) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    return tester.runAsync(() async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: SyncStatusScreen()),
        ),
      );
      await tester.pump();
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (find.byType(CircularProgressIndicator).evaluate().isNotEmpty) {
        if (DateTime.now().isAfter(deadline)) {
          throw TestFailure(
            'pumpScreen: SyncStatusScreen was still showing a spinner after '
            '15s — a provider it watches never resolved.',
          );
        }
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
  }

  testWidgets(
    'Try again releases the row and starts a sync, through the screen\'s own '
    'path — not the provider called directly',
    (tester) async {
      controllerCalls.clear();
      final container = await deviceWithHeldRow(tester);
      await pumpScreen(tester, container);

      await tester.runAsync(() async {
        await tester.tap(find.text('Try again'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
      });

      expect(
        tester.takeException(),
        isNull,
        reason: 'the phone saw the spinner stop and nothing else — the '
            'exception was "Cannot use the Ref of heldRowRetryProvider '
            'after it has been disposed", thrown after the release write, '
            'unhandled',
      );
      expect(
        controllerCalls,
        ['syncNow'],
        reason: '"Try again" is releaseHeldRowForRetry() then syncNow(); if '
            'the closure died on the release write finishing, syncNow was '
            'never reached',
      );
      await tester.runAsync(() async {
        final released = await SyncHeldRowStore(
          (await container.read(appDatabaseProvider.future)).raw,
        ).held(projectId);
        expect(
          released.single.heldUpdatedAt,
          isNull,
          reason: 'the release write itself must still have happened even '
              'if everything after it in the old closure did not',
        );
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  testWidgets(
    'a retry that cannot finish says so, rather than leaving the spinner '
    'stop in silence',
    (tester) async {
      final container = ProviderContainer(
        retry: appRetryPolicy,
        overrides: [
          appDatabaseProvider.overrideWith(
            (ref) async => throw StateError('the database is unavailable'),
          ),
          syncHeldRowDetailsProvider(
            projectId,
          ).overrideWith((ref) async => [detail]),
          syncControllerProvider.overrideWith(
            () => _RecordingSyncController(<String>[]),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(activeProjectIdProvider.notifier).set(projectId);
      await pumpScreen(tester, container);

      await tester.runAsync(() async {
        await tester.tap(find.text('Try again'));
        await Future<void>.delayed(const Duration(milliseconds: 600));
        await tester.pump();
      });

      expect(
        find.text(kHeldRowRetryFailedMessage),
        findsOneWidget,
        reason: 'a tap that cannot finish must say so — a silent failure is '
            'half of task 11.236\'s defect',
      );
      expect(find.textContaining('StateError'), findsNothing);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}

class _RecordingSyncController extends SyncController {
  _RecordingSyncController(this._calls);

  final List<String> _calls;

  @override
  Future<SyncStatus> build() async => SyncStatus(
    schedule: const SyncSchedule(),
    lastSuccessAt: DateTime.now().toUtc().subtract(const Duration(hours: 1)),
  );

  @override
  Future<void> syncNow() async {
    _calls.add('syncNow');
  }
}
