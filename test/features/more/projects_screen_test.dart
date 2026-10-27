import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/membership_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/device_id_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/project_link_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/project_membership.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/features/more/screens/projects_screen.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/fixtures.dart';
import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';
import '../../support/project_row_menu.dart';

/// Task 8.3: the Delete affordance is gated to the project owner, with the
/// reason surfaced via a [Tooltip] rather than a silently-missing button.
///
/// **Task 11.1 updated these rather than bypassing them.** Through Phase 8 the
/// gate read `Projects.owner_user_id`, so the test needed no database at all —
/// a plain `allProjectsProvider` override carried the whole answer. Ownership
/// is now the project's open `owner` memberships, so these seed a real
/// in-memory database and the rows that confer it. That is what makes the last
/// two cases below expressible: a co-equal second owner, and a creator who
/// transferred the project away and is still named in the column.
///
/// `ownedProjectIdsProvider` is DB-backed, and the screen shows a spinner
/// until it resolves — which `pumpAndSettle` would never settle — so each case
/// pre-resolves it inside `runAsync`, holding it alive with `listen` because
/// an `@riverpod`-generated provider is autoDispose.
Future<ProviderContainer> _seed({
  required String signedInAs,
  required List<ProjectMembership> memberships,
  // Task 11.42's back-to-back-deletes test needs a second row to delete —
  // `allProjectsProvider` is a fixed override rather than DB-derived, so a
  // project inserted straight into the database would never show up in the
  // list otherwise.
  bool withSecondProject = false,
  // Task 11.289's test needs a server to deliver a tombstone to, and a
  // session to deliver it as; every other case here has neither and reaches
  // no network.
  FakeSyncTransport? server,
}) async {
  final project = sampleProject(id: 'project-1', ownerUserId: 'user-owner');
  final secondProject = sampleProject(id: 'project-2', ownerUserId: 'user-owner');
  final container = ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) => AppDatabase.openInMemory()),
      allProjectsProvider.overrideWith(
        (ref) async => [project, if (withSecondProject) secondProject],
      ),
      currentUserProvider.overrideWith(
        (ref) async => sampleUser(id: signedInAs, email: '$signedInAs@x.com'),
      ),
      if (server != null) ...[
        serverTransportProvider.overrideWith((ref) async => server),
        sessionStoreProvider.overrideWithValue(
          FakeSessionStore(
            StoredSession(
              token: 'not-a-real-token',
              userId: signedInAs,
              email: '$signedInAs@x.com',
              expiresAt: DateTime.now().add(const Duration(days: 30)),
            ),
          ),
        ),
      ],
    ],
  );
  final db = (await container.read(appDatabaseProvider.future)).raw;
  for (final id in {'user-owner', 'user-second', 'user-successor', signedInAs}) {
    await db.insert(Tables.users, sampleUser(id: id, email: '$id@x.com').toColumns());
  }
  await db.insert(Tables.projects, project.toColumns());
  for (final membership in memberships) {
    await db.insert(Tables.projectMemberships, membership.toColumns());
  }
  if (withSecondProject) {
    await db.insert(Tables.projects, secondProject.toColumns());
    for (final membership in memberships) {
      await db.insert(
        Tables.projectMemberships,
        sampleMembership(
          id: '${membership.membershipId}-2',
          projectId: secondProject.projectId,
          userId: membership.userId,
          role: membership.role,
        ).toColumns(),
      );
    }
  }
  container.listen(ownedProjectIdsProvider, (_, _) {});
  await container.read(ownedProjectIdsProvider.future);
  // Same treatment, same reason (task 11.54): the row's Delete control now
  // also asks whether the signed-in person has *left* this project, which is
  // a second DB-backed set the screen spins on until it resolves.
  container.listen(departedProjectIdsProvider, (_, _) {});
  // Task 11.237 added a third: the read-only snapshots, which the list
  // labels.
  container.listen(snapshotProjectIdsProvider, (_, _) {});
  // Task 11.238 added a fourth: projects this person is a member of but that
  // have never been linked, which the list also labels.
  container.listen(unsyncedMemberProjectIdsProvider, (_, _) {});
  await container.read(departedProjectIdsProvider.future);
  await container.read(snapshotProjectIdsProvider.future);
  await container.read(unsyncedMemberProjectIdsProvider.future);
  return container;
}

Future<void> _pump(WidgetTester tester, ProviderContainer container) async {
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: ProjectsScreen()),
    ),
  );
  await tester.pumpAndSettle();
}

/// **Task 11.99 moved these controls into a labelled menu**, so the assertions
/// changed shape and the property did not. Each of the cases below used to
/// read `IconButton.onPressed` on a bare `delete_outline` glyph and the text of
/// its `Tooltip`; they now open the row's menu and read whether the
/// `Delete project` item can be chosen, and what it says when it cannot. The
/// reason for the change is that a tooltip is invisible on a touchscreen — the
/// explanation task 11.12 requires was, on a phone, not being given at all.
Future<ProjectMenuItem> _delete(WidgetTester tester) async =>
    (await readProjectMenu(tester))['Move to Trash']!;

void main() {
  setUp(installFakeSharedPreferences);

  testWidgets(
    'a current non-owner member cannot delete a project, and is told why',
    (tester) async {
      // A real membership row for `user-other`, not merely its absence —
      // task 11.238 found the fixture this test used to have (`user-other`
      // with no membership row at all) was actually the read-only-snapshot
      // case, not "a current member who is not an owner." Both used to be
      // refused, so nothing here noticed; they are not refused the same way
      // any more, so this test now seeds the case its name describes.
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-other',
          memberships: [
            sampleMembership(userId: 'user-owner'),
            sampleMembership(
              id: 'membership-other',
              userId: 'user-other',
              role: ProjectRole.contributor,
            ),
          ],
        );
      });
      addTearDown(container.dispose);

      await _pump(tester, container);

      expect(
        await _delete(tester),
        (
          enabled: false,
          note: 'Only a project owner can move this project to the Trash.',
        ),
        reason: 'the reason is on the item, where a phone can show it',
      );
    },
  );

  testWidgets('the owner can delete a project, with no explanation shown', (tester) async {
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-owner',
        memberships: [sampleMembership(userId: 'user-owner')],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect(await _delete(tester), (enabled: true, note: null));
  });

  testWidgets('a co-equal second owner can delete it too', (tester) async {
    // Task 11.1: `owner_user_id` names one person, so Phase 8's rule could not
    // express this case at all — the second owner would have been refused a
    // delete they are fully entitled to.
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-second',
        memberships: [
          sampleMembership(userId: 'user-owner'),
          sampleMembership(id: 'membership-2', userId: 'user-second'),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    expect((await _delete(tester)).enabled, isTrue);
  });

  testWidgets('a creator who transferred the project away is no longer an owner, but may still remove their copy', (tester) async {
    // The column still names them — 11.1 keeps `owner_user_id` populated as
    // the creator/audit record. It no longer authorizes, which is the point:
    // under Phase 8's rule this person kept delete rights over a project they
    // had handed on.
    late ProviderContainer container;
    await tester.runAsync(() async {
      container = await _seed(
        signedInAs: 'user-owner',
        memberships: [
          sampleMembership(
            userId: 'user-owner',
            endDate: DateTime.utc(2026, 8, 17),
          ),
          sampleMembership(id: 'membership-2', userId: 'user-successor'),
        ],
      );
    });
    addTearDown(container.dispose);

    await _pump(tester, container);

    // **They may still delete it, and that is task 11.54 rather than a
    // loosening of 11.1's rule.** Ownership no longer authorizes them —
    // nothing here changes that. What changed is that a *past member* of a
    // project may remove their own copy of it from their own device, which is
    // exactly the state a creator who handed the project on is in. Before
    // 11.54 they could neither take part in it nor get rid of it.
    expect(await _delete(tester), (enabled: true, note: null));
  });

  group('deleting a project you have left (task 11.54)', () {
    // Found by Michael on real hardware, 2026-08-29, running the
    // leave-a-project checks for the first time: the project stayed in the
    // list with the leave control correctly gone and the delete control
    // greyed out, so he could neither take part in it nor get rid of it.

    testWidgets('a past member is offered the control', (tester) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-other',
          memberships: [
            sampleMembership(userId: 'user-owner'),
            sampleMembership(
              id: 'membership-past',
              userId: 'user-other',
              endDate: DateTime.utc(2026, 8, 20),
            ),
          ],
        );
      });
      addTearDown(container.dispose);

      await _pump(tester, container);

      expect(await _delete(tester), (enabled: true, note: null));
    });

  });

  group('deleting a snapshot you were never a member of (task 11.238)', () {
    // Before this task, "somebody who was never on the project" and "a
    // departed member" were both refused by `_deleteProject`, so nothing
    // distinguished them. `MutationExemption.snapshotHolder` is the
    // difference: a snapshot holder was never here at all, and now they may
    // remove their local copy the same way a departed member always could.

    testWidgets(
      'a snapshot holder is offered the control, with the snapshot\'s own '
      'warning',
      (tester) async {
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await _seed(
            signedInAs: 'user-other',
            memberships: [sampleMembership(userId: 'user-owner')],
          );
        });
        addTearDown(container.dispose);

        await _pump(tester, container);

        expect(await _delete(tester), (enabled: true, note: null));

        await tapProjectMenuItem(tester, 'Move to Trash');

        // Its own note, not the departed-member warning next door: nothing
        // here was ever stranded, because every edit on a snapshot is
        // refused (task 11.237) — there was never anything to sync.
        expect(
          find.textContaining("you were never a member of it on this device"),
          findsOneWidget,
        );
        expect(
          find.textContaining('untouched wherever it actually lives'),
          findsOneWidget,
        );
        expect(find.textContaining('never reached the server'), findsNothing);
      },
    );
  });

  group('the undo bar after deleting a project (task 11.42)', () {
    // Observed on macOS, 2026-08-27: the white undo bar never went away.
    //
    // **Root cause, found by reproducing it in isolation before touching this
    // screen at all**: `SnackBar.persist` defaults to `true` whenever an
    // `action` is set (Material 3's own default — "if the snackbar action is
    // not null, the snackbar will persist as well"), and the dismiss timer's
    // callback is a no-op while `persist` is true. So `duration: Duration(
    // seconds: 6)` here was never in effect; every one of this app's undo bars
    // set a duration and none of them knew it did nothing. The fix is
    // `persist: false`, asserted below by actually letting the fake clock run
    // rather than by reading the source.
    //
    // **Established separately, because "the bar is stale" and "the delete is
    // in limbo" are different findings**: `_deleteProject` awaits
    // `repo.softDeleteById` before the snackbar is ever shown, so the delete
    // is already committed by the time the bar appears — confirmed below by
    // reading the row back mid-bar, before any timeout or navigation. The bug
    // was cosmetic; nothing was ever in limbo.
    testWidgets('times out on its own rather than staying forever', (
      tester,
    ) async {
      late ProviderContainer container;
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
        );
        // Pre-resolved for the same reason `tag_database_screen_test.dart`
        // does: this reads through a platform channel with no result
        // pending until it is asked for once, and asking for it lazily from
        // inside a tap handler races `pumpAndSettle`.
        await container.read(deviceIdProvider.future);
      });
      addTearDown(container.dispose);
      await _pump(tester, container);

      await tester.runAsync(() async {
        await tapProjectMenuItem(tester, 'Move to Trash');
        await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash'));
        // Real delay, *not* followed by a pump — both load-bearing.
        //
        // The delay: the confirm-to-write chain does real, non-cached
        // database I/O, and nothing schedules a new frame while it is in
        // flight, so pumping immediately would see nothing pending and
        // "settle" before the write — and the snackbar it triggers — ever
        // happen (same pattern as `tag_database_screen_test.dart`).
        //
        // No `pumpAndSettle` in this block, though that file's does: this
        // undo bar's dismiss timeout is a `dart:async Timer` (task 11.42's
        // fix — `persist: false`), created once the entrance animation
        // completes, and `runAsync` runs pumps in the *real* zone. A pump
        // that completed the entrance animation from inside here would
        // create that `Timer` bound to real wall-clock time — one nothing
        // later in this test, which only advances the *fake* clock, could
        // ever reach. Found by reproducing it in isolation: the identical
        // widget, tapped the identical way, times out correctly outside
        // `runAsync` and never does inside it.
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pumpAndSettle();

      expect(find.textContaining('moved to Trash'), findsOneWidget);
      expect(find.text('UNDO'), findsOneWidget);

      // The delete is already committed at this point — not waiting on the
      // bar, and not undone by it timing out. Read inside `runAsync`: real
      // sqflite I/O started outside it never completes under this binding's
      // fake clock.
      await tester.runAsync(() async {
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final rows = await db.query(
          Tables.projects,
          where: 'project_id = ?',
          whereArgs: ['project-1'],
        );
        expect(rows.single['deleted_at'], isNotNull);
      });

      // Small stepped pumps, not one big jump: `flutter_test`'s fake clock
      // delivers one frame per `pump()` call, and a reverse (exit) animation
      // kicked off mid-`elapse()` needs a following frame of its own to
      // actually finish — a single large `pump(Duration(seconds: 7))` can
      // read as "still showing" even once the fix is correct. This is
      // `pumpAndSettle`'s own default stepping, done explicitly so the loop
      // is legible as "wait past the 6-second duration," not as a magic
      // number. 90 steps (9s) rather than 60 (6s), with margin to spare.
      for (var i = 0; i < 90; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.text('UNDO'),
        findsNothing,
        reason:
            'the undo bar must time out on its own — persist defaulted to '
            'true the moment this SnackBar got an action, which made '
            '`duration` silently dead',
      );
    });

    testWidgets(
      'a second delete shortly after the first replaces its undo bar rather '
      'than queuing behind it',
      (tester) async {
        // The failure mode `clearSnackBars()` (already in `_deleteProject`)
        // exists to prevent: back-to-back deletes stacking undo bars behind
        // each other, which reads as "never goes away" for a different
        // reason than task 11.42's actual one (persist defaulting to true).
        // Kept as a test in its own right now that the real cause is fixed,
        // so this property does not silently depend on it. Two projects, so
        // the second delete is a distinct row rather than re-deleting the
        // first.
        late ProviderContainer container;
        await tester.runAsync(() async {
          container = await _seed(
            signedInAs: 'user-owner',
            memberships: [sampleMembership(userId: 'user-owner')],
            withSecondProject: true,
          );
          await container.read(deviceIdProvider.future);
        });
        addTearDown(container.dispose);
        await _pump(tester, container);

        await tester.runAsync(() async {
          await tapProjectMenuItem(tester, 'Move to Trash');
          await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();

          await tapProjectMenuItem(tester, 'Move to Trash');
          await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash'));
          await Future<void>.delayed(const Duration(milliseconds: 300));
          await tester.pumpAndSettle();
        });

        // Not two — `clearSnackBars()` replaced the first bar with the
        // second rather than queuing behind it, which is what would read as
        // "stuck" for a different reason than task 11.42's actual one.
        expect(find.text('UNDO'), findsOneWidget);
      },
    );
  });

  /// **Task 11.289.** The project row is the only row whose deletion destroys
  /// the sync scope that would have pushed it — the active project becomes
  /// null, and a deleted project can never be selected again. The durable fix
  /// is the app's foreground hook (`deleted_project_tombstone_test.dart`);
  /// this asserts the screen's own part of it, which is an immediate attempt
  /// the moment the delete commits, so a person with signal does not have to
  /// background the app to have the deletion land.
  group('deleting a published project (task 11.289)', () {
    testWidgets('offers the tombstone to the server at once, from the list', (
      tester,
    ) async {
      late ProviderContainer container;
      final server = FakeSyncTransport()
        ..sessionUserId = 'user-owner'
        ..sessionEmail = 'user-owner@x.com';
      await tester.runAsync(() async {
        container = await _seed(
          signedInAs: 'user-owner',
          memberships: [sampleMembership(userId: 'user-owner')],
          server: server,
        );
        await container.read(deviceIdProvider.future);
        // Published: the server holds the row, this device holds the receipt
        // and the link. Nothing is pending before the tap.
        final db = (await container.read(appDatabaseProvider.future)).raw;
        final row = (await db.query(
          Tables.projects,
          where: 'project_id = ?',
          whereArgs: ['project-1'],
        )).single;
        server.seedServerRow(Tables.projects, row);
        await SyncRowReceiptStore.ensureTable(db);
        await SyncRowReceiptStore(db).record(
          projectId: 'project-1',
          tableName: Tables.projects,
          rowKey: 'project-1',
          ackedUpdatedAt: row['updated_at'] as String?,
          at: DateTime.now().toUtc(),
        );
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('https://tritrack.example.org');
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked('project-1');
        // Pre-resolved, for the reason `deviceIdProvider` is above and
        // `sync_bar_states_end_to_end_test.dart`'s `activate` does the same:
        // a `SyncController` first touched from inside the tap handler has
        // its `build` continuations scheduled on this binding's fake clock,
        // where they run only on a pump — measured while writing this test as
        // a ten-minute hang with the push never made. `keepAlive`, so no
        // listener is needed to hold it.
        await container.read(syncControllerProvider.future);
        // Task 11.290: the list asks the server for deletion countdowns when
        // it opens, through the same transport providers the delete below
        // pushes through. Resolved here, on the real clock, for the reason
        // the controller is: first touched from the post-frame callback,
        // their continuations land on the fake clock and the push below
        // waits on them for ever.
        container.listen(projectDeletionNoticesProvider, (_, _) {});
        await container.read(projectDeletionNoticesProvider.future);
        await container.read(serverTransportProvider.future);
        await container
            .read(projectDeletionNoticesProvider.notifier)
            .refreshFromServer();
        // Task 11.294: the third provider task 11.290 put on this screen,
        // and the one it did not pre-resolve here. `ProjectsScreen.build`
        // watches `undeliveredProjectDeletionsProvider`, which reads the
        // database (`findUndeliveredProjectChanges` → `SyncEngine.wouldOffer`).
        // First touched from `pumpWidget` below, its build ran on the fake
        // clock — not hanging, because nothing waited on it, but advancing
        // one database statement per pump and otherwise only when a real
        // reply arrived. Every sqflite statement outside a transaction
        // creates a 10-second lock-warning `Timer` in the caller's zone and
        // cancels it once the statement holds the lock. When the build was
        // still unfinished as the `runAsync` block below ended — measured:
        // red in 5 of 5 full-suite runs, 0 of 5 alone, and in 11 probed runs
        // red exactly when the provider was `AsyncLoading` at that moment —
        // the end-of-block microtask flush issued its next statement behind
        // the delivery round's real-clock statements, the round could not
        // release the lock before the binding's pending-timer check, and the
        // test failed with "A Timer is still pending". Resolved here, on the
        // real clock, the way the sibling `project_deletion_from_list_test`
        // does; the widget then watches a provider that has nothing left to
        // do. `listen` because it is autoDispose.
        container.listen(undeliveredProjectDeletionsProvider, (_, _) {});
        await container.read(undeliveredProjectDeletionsProvider.future);
      });
      addTearDown(container.dispose);
      await _pump(tester, container);
      expect(
        server.serverRow(Tables.projects, 'project-1')?['deleted_at'],
        isNull,
      );

      // Task 11.294: the round does not end at the push. It pulls, writes
      // its receipt, re-derives the pending set and — when the tombstone
      // landed — invalidates `undeliveredProjectDeletionsProvider`, all on
      // the real clock. Waiting only for the push left that tail running
      // into the tree's teardown; a rebuilt provider is the round's last
      // observable act, so that is what this waits for.
      var rebuilds = 0;
      await tester.runAsync(() async {
        container.listen(undeliveredProjectDeletionsProvider, (_, next) {
          if (next is AsyncData) rebuilds++;
        });
        await tapProjectMenuItem(tester, 'Move to Trash');
        await tester.tap(find.widgetWithText(FilledButton, 'Move to Trash'));
        // Real delay, for the reason the undo-bar test above gives: the
        // confirm-to-write-to-push chain is real I/O and schedules no frame.
        // Polled rather than a fixed wait so a slow machine does not turn a
        // correct build red; bounded so a broken one goes red rather than
        // hanging.
        final deadline = DateTime.now().add(const Duration(seconds: 5));
        while ((server.pushCalls == 0 || rebuilds == 0) &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
      });

      expect(
        server.serverRow(Tables.projects, 'project-1')?['deleted_at'],
        isNotNull,
        reason:
            'the delete committed and there was signal, so the tombstone '
            'should be on the server before the undo bar has even timed out',
      );
      expect(
        server.pushes.single.projectId,
        'project-1',
        reason: 'one round, for the deleted project — not for whatever is open',
      );
      expect(
        rebuilds,
        greaterThan(0),
        reason:
            'the delivery ends by invalidating the undelivered-deletions list; '
            'no rebuild within the deadline means the round never finished',
      );
      expect(
        container.read(undeliveredProjectDeletionsProvider).requireValue,
        isEmpty,
        reason:
            'the server took the tombstone, so the "Deleted here, not yet on '
            'the server" list (task 11.290) must not name this project',
      );
    });
  });
}
