import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:tritrack/app.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/join_request_watcher.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/sync/restored_project_arrival.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack/routing/app_router.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **What every device does on its next sync after an owner restores a
/// project** (task 11.302) — decided in writing in
/// `restored_project_arrival.dart` and Security Model §4.28.1, asserted here.
///
/// An owner's restore clears the project's tombstone **on the server**. Every
/// device that already believed the project gone holds that tombstone, and
/// the project is hidden there — never the active one, so no ordinary sync
/// round would ever fetch it back. The brief named the three devices whose
/// answer had to be decided rather than discovered:
///
/// 1. **The owner's own phone**, which deleted the project and sent the
///    tombstone. It gets the project back, and is told it restored it.
/// 2. **A member's phone**, which lost the project without being told when
///    the tombstone arrived. It gets the project back with every record, and
///    is told who restored it — by name — because a project reappearing
///    unexplained reads exactly like the fault that made it disappear.
/// 3. **A phone holding records in the project it never sent.** They go up
///    on the same trip that brings the project back.
///
/// And, as carefully, what is **not** brought back: a deletion this device
/// has not yet delivered (its own undo owns that), a deletion the server
/// refused, a copy this device is not syncing, and a project the server has
/// not restored. A device with nothing to bring back reaches no server.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;
  const me = 'user-1';
  const owner = 'user-2';
  const projectId = 'proj-1';
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));
  final deletedStamp = DbCodec.encodeUtc(DateTime.utc(2026, 9, 20, 9, 30));

  Map<String, Object?> userRow(String id, String first, String last) => {
    'user_id': id,
    'first_name': first,
    'last_name': last,
    'email': '$id@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> projectRow({required String ownerId}) => {
    'project_id': projectId,
    'project_name': 'Elk Study',
    'owner_user_id': ownerId,
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> membershipRow(String id, String userId, String role) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': userId,
    'join_date': stamp,
    'end_date': null,
    'role': role,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> observationRow(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': me,
    'timestamp_local': stamp,
    'timestamp_utc': stamp,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 1,
    'last_modified_by': me,
    'origin_device_id': 'device-A',
  };

  /// One row on this device and on the server, with the receipt a real
  /// publish would have left — so nothing is pending before the test acts.
  Future<void> seedPublished(String table, Map<String, Object?> row) async {
    await db.raw.insert(table, row);
    server.seedServerRow(table, row);
    await SyncRowReceiptStore.ensureTable(db.raw);
    final spec = syncTablesByName[table]!;
    await SyncRowReceiptStore(db.raw).record(
      projectId: projectId,
      tableName: table,
      rowKey: spec.primaryKey.map((c) => row[c]).join('/'),
      ackedUpdatedAt: row['updated_at']! as String,
      at: DateTime.utc(2026, 8, 1),
    );
  }

  setUp(() async {
    db = await AppDatabase.openInMemory();
    server = FakeSyncTransport()
      ..sessionUserId = me
      ..sessionEmail = '$me@example.com';
  });
  tearDown(() => db.close());

  ProviderContainer signedInContainer({List<Override> extra = const []}) =>
      ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) async => db),
          serverTransportProvider.overrideWith((ref) async => server),
          currentUserProvider.overrideWith(
            (ref) async => User(
              userId: me,
              firstName: 'Sam',
              lastName: 'Ranger',
              email: '$me@example.com',
              sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
            ),
          ),
          sessionStoreProvider.overrideWithValue(
            FakeSessionStore(
              StoredSession(
                token: 'not-a-real-token',
                userId: me,
                email: '$me@example.com',
                expiresAt: DateTime.now().add(const Duration(days: 30)),
              ),
            ),
          ),
          ...extra,
        ],
      );

  Future<void> linkedAndOpen(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  /// **A member's device**: user-1 is a contributor on user-2's project,
  /// published and in sync, with one bearing of their own on it.
  Future<void> seedMemberDevice(ProviderContainer container) async {
    await seedPublished(Tables.users, userRow(me, 'Sam', 'Ranger'));
    await seedPublished(Tables.users, userRow(owner, 'Robin', 'Owner'));
    await seedPublished(Tables.projects, projectRow(ownerId: owner));
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-owner', owner, ownerMembershipRole),
    );
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-me', me, 'contributor'),
    );
    await seedPublished(Tables.observations, observationRow('obs-1'));
    await linkedAndOpen(container);
  }

  /// The owner deletes the project on *their* phone and it reaches the
  /// server — which, seen from this member's device, is a new tombstone on
  /// the server that `/projects/mine` no longer lists.
  void ownerDeletesOnTheirPhone() {
    final row = server.serverRow(Tables.projects, projectId)!;
    server.seedServerRow(Tables.projects, {
      ...row,
      'deleted_at': deletedStamp,
      'updated_at': deletedStamp,
      'revision': 1,
      'last_modified_by': owner,
    });
    server.serverProjects.removeWhere((p) => p.projectId == projectId);
  }

  Future<Map<String, Object?>> localProject() async =>
      (await db.raw.query(
        Tables.projects,
        where: 'project_id = ?',
        whereArgs: [projectId],
      )).single;

  /// Everything [ProjectRestoration] announces from here on in this test.
  List<RestoredProjectArrival> listenForRestores() {
    final heard = <RestoredProjectArrival>[];
    void listener(List<RestoredProjectArrival> arrivals) =>
        heard.addAll(arrivals);
    ProjectRestoration.addListener(listener);
    addTearDown(() => ProjectRestoration.removeListener(listener));
    return heard;
  }

  Future<List<RestoredProjectArrival>> bringBack(
    ProviderContainer container,
  ) => container.read(syncControllerProvider.notifier).bringBackRestoredProjects();

  group('a member\'s device', () {
    test(
      'lost the project when the tombstone arrived, gets it back with every '
      'record on its next sync after the restore, and is told who did it',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedMemberDevice(container);

        ownerDeletesOnTheirPhone();
        // The member's next round, while the project is still their open
        // one, pulls the tombstone. The project is now hidden on this device
        // and they move on to something else.
        await container.read(syncControllerProvider.notifier).syncNow();
        expect((await localProject())['deleted_at'], isNotNull);
        await container.read(activeProjectIdProvider.notifier).set(null);
        expect(
          (await container.read(allProjectsProvider.future)).map(
            (p) => p.projectId,
          ),
          isNot(contains(projectId)),
        );

        // Before any restore: the device asks, is told nothing, and changes
        // nothing.
        expect(await bringBack(container), isEmpty);
        expect((await localProject())['deleted_at'], isNotNull);

        // The owner restores it — on the server, from their own phone.
        server.restoreServerProject(projectId, restoredBy: owner);
        server.serverProjects
          ..removeWhere((p) => p.projectId == projectId)
          ..add(
            const ProjectSummary(
              projectId: projectId,
              projectName: 'Elk Study',
              ownerUserId: owner,
              role: 'contributor',
            ),
          );

        final announced = listenForRestores();
        final arrivals = await bringBack(container);
        expect(arrivals.map((a) => a.projectId), [projectId]);
        expect(arrivals.single.restoredBy, owner);
        expect(announced.map((a) => a.projectId), [projectId]);
        expect(
          announced.single.restoredByName,
          'Robin Owner',
          reason: 'named, not "an owner" — the member did not do this and '
              'needs to know who did',
        );
        expect((await localProject())['deleted_at'], isNull);
        expect(
          (await container.read(allProjectsProvider.future)).map(
            (p) => p.projectId,
          ),
          contains(projectId),
        );
        final bearings = await db.raw.query(
          Tables.observations,
          where: 'project_id = ?',
          whereArgs: [projectId],
        );
        expect(bearings, hasLength(1), reason: 'nothing in it was lost');

        // And the next foreground has nothing left to do — and asks nobody.
        final asked = server.listMyProjectsCalls;
        expect(await bringBack(container), isEmpty);
        expect(server.listMyProjectsCalls, asked);
      },
    );

    test(
      'with the project still open — Michael\'s Mac on 2026-09-24 — the '
      'open project\'s own round brings it back, and that route announces '
      'it too',
      () async {
        // A tombstone arriving by sync hides the project but does not close
        // it, so a member who had it open keeps syncing it. The restore then
        // lands through the ordinary round, not the foreground check — the
        // route that said nothing on the device look.
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedMemberDevice(container);
        ownerDeletesOnTheirPhone();
        await container.read(syncControllerProvider.notifier).syncNow();
        expect((await localProject())['deleted_at'], isNotNull);
        expect(
          await container.read(activeProjectIdProvider.future),
          projectId,
          reason: 'the premise: still the open project',
        );

        server.restoreServerProject(projectId, restoredBy: owner);
        final announced = listenForRestores();
        // The ordinary automatic round an hour later — not the foreground
        // check, not Sync now.
        await container
            .read(syncStateStoreProvider)
            .setLastAttemptAt(
              DateTime.now().toUtc().subtract(const Duration(hours: 1)),
            );
        container.invalidate(syncControllerProvider);
        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncIfDue();

        expect((await localProject())['deleted_at'], isNull);
        expect(announced.map((a) => a.projectId), [projectId]);
        expect(announced.single.restoredByName, 'Robin Owner');
      },
    );

    test(
      'holding a record it never sent: the record goes up on the same trip '
      'that brings the project back',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedMemberDevice(container);
        ownerDeletesOnTheirPhone();
        await container.read(syncControllerProvider.notifier).syncNow();
        await container.read(activeProjectIdProvider.notifier).set(null);
        expect((await localProject())['deleted_at'], isNotNull);

        // A bearing recorded here that never reached the server — the state
        // a round leaves when it is cut off between its push pages, and the
        // one the brief asked about by name. With the project hidden, no
        // round would ever carry it.
        await db.raw.insert(Tables.observations, observationRow('obs-unsent'));
        expect(
          server.serverRow(Tables.observations, 'obs-unsent/$projectId'),
          isNull,
        );

        server.restoreServerProject(projectId, restoredBy: owner);
        final arrivals = await bringBack(container);
        expect(arrivals.map((a) => a.projectId), [projectId]);
        expect(
          server.serverRow(Tables.observations, 'obs-unsent/$projectId'),
          isNotNull,
          reason: 'the round that brings the project back pushes first',
        );
      },
    );
  });

  group('the owner\'s own device', () {
    Future<void> seedOwnerDevice(ProviderContainer container) async {
      await seedPublished(Tables.users, userRow(me, 'Sam', 'Ranger'));
      await seedPublished(Tables.projects, projectRow(ownerId: me));
      await seedPublished(
        Tables.projectMemberships,
        membershipRow('mem-me', me, ownerMembershipRole),
      );
      await linkedAndOpen(container);
      server.serverProjects.add(
        const ProjectSummary(
          projectId: projectId,
          projectName: 'Elk Study',
          ownerUserId: me,
          role: ownerMembershipRole,
        ),
      );
    }

    /// What the Projects list's *Delete* does, and task 11.289's delivery.
    Future<void> deleteAndDeliver(ProviderContainer container) async {
      await ProjectRepository(db.raw).softDeleteById(
        projectId,
        actor: const MutationActor.user(me),
        deviceId: 'device-A',
      );
      await container.read(activeProjectIdProvider.notifier).set(null);
      await container
          .read(syncControllerProvider.notifier)
          .deliverPendingProjectChanges();
    }

    test(
      'which deleted it gets it back once it is restored — here or from any '
      'other device — and is told it restored it',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedOwnerDevice(container);
        await deleteAndDeliver(container);
        expect(
          server.serverRow(Tables.projects, projectId)!['deleted_at'],
          isNotNull,
        );
        // The real server leaves a tombstoned project off `/projects/mine`.
        server.serverProjects.removeWhere((p) => p.projectId == projectId);

        expect(await bringBack(container), isEmpty);
        expect((await localProject())['deleted_at'], isNotNull);

        server.restoreServerProject(projectId, restoredBy: me);
        final arrivals = await bringBack(container);
        expect(arrivals.map((a) => a.projectId), [projectId]);
        expect(
          arrivals.single.restoredBy,
          me,
          reason: 'the app leaves a restore by this same account unsaid',
        );
        expect((await localProject())['deleted_at'], isNull);
      },
    );
  });

  group('what is deliberately not brought back', () {
    test('a device holding no deleted project asks no server', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedMemberDevice(container);
      expect(await bringBack(container), isEmpty);
      expect(server.listMyProjectsCalls, 0);
    });

    test(
      'a deletion this device has not delivered yet — the server lists the '
      'project live because it never got the tombstone, not because anybody '
      'restored it',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await seedPublished(Tables.users, userRow(me, 'Sam', 'Ranger'));
        await seedPublished(Tables.projects, projectRow(ownerId: me));
        await seedPublished(
          Tables.projectMemberships,
          membershipRow('mem-me', me, ownerMembershipRole),
        );
        await linkedAndOpen(container);
        server.serverProjects.add(
          const ProjectSummary(
            projectId: projectId,
            projectName: 'Elk Study',
            ownerUserId: me,
            role: ownerMembershipRole,
          ),
        );
        await ProjectRepository(db.raw).softDeleteById(
          projectId,
          actor: const MutationActor.user(me),
          deviceId: 'device-A',
        );
        await container.read(activeProjectIdProvider.notifier).set(null);

        expect(await bringBack(container), isEmpty);
        expect(
          (await localProject())['deleted_at'],
          isNotNull,
          reason: 'bringing it back here would undo the person\'s delete '
              'behind their back; the Projects list\'s own undo owns it',
        );
        expect(server.listMyProjectsCalls, 0);
      },
    );

    test('a deletion the server refused', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedPublished(Tables.users, userRow(me, 'Sam', 'Ranger'));
      await seedPublished(Tables.projects, projectRow(ownerId: me));
      await seedPublished(
        Tables.projectMemberships,
        membershipRow('mem-me', me, ownerMembershipRole),
      );
      await linkedAndOpen(container);
      server
        ..serverProjects.add(
          const ProjectSummary(
            projectId: projectId,
            projectName: 'Elk Study',
            ownerUserId: me,
            role: ownerMembershipRole,
          ),
        )
        ..refuseRows['${Tables.projects}/$projectId'] =
            SyncRowOutcome.unauthorized;
      await ProjectRepository(db.raw).softDeleteById(
        projectId,
        actor: const MutationActor.user(me),
        deviceId: 'device-A',
      );
      await container.read(activeProjectIdProvider.notifier).set(null);
      await container
          .read(syncControllerProvider.notifier)
          .deliverPendingProjectChanges();
      final pulls = server.pullCalls;

      expect(await bringBack(container), isEmpty);
      expect((await localProject())['deleted_at'], isNotNull);
      // **Not asked about at all.** The merge would keep this tombstone
      // anyway — it outranks the server's untouched row — so what the
      // exclusion buys is not correctness here but the question: without it
      // the device would ask the server, and run a round, on every
      // foreground for a deletion the Projects list is already showing as
      // refused, with its own undo beside it.
      expect(server.listMyProjectsCalls, 0);
      expect(server.pullCalls, pulls);
    });

    test('a copy this device is not syncing', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedMemberDevice(container);
      ownerDeletesOnTheirPhone();
      await container.read(syncControllerProvider.notifier).syncNow();
      await container.read(activeProjectIdProvider.notifier).set(null);
      await container.read(syncStateStoreProvider).clear(projectId);

      server.restoreServerProject(projectId, restoredBy: owner);
      expect(await bringBack(container), isEmpty);
      expect(
        (await localProject())['deleted_at'],
        isNotNull,
        reason: 'an unlinked copy comes back through the join screen\'s '
            'Restore, which is a person\'s choice (task 11.57)',
      );
      expect(server.listMyProjectsCalls, 0);
    });

    test('a project the server has not restored: one question, no round', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedMemberDevice(container);
      ownerDeletesOnTheirPhone();
      await container.read(syncControllerProvider.notifier).syncNow();
      await container.read(activeProjectIdProvider.notifier).set(null);
      final pushes = server.pushCalls;
      final pulls = server.pullCalls;

      expect(await bringBack(container), isEmpty);
      expect(server.listMyProjectsCalls, 1);
      expect(server.pushCalls, pushes);
      expect(server.pullCalls, pulls);
      expect((await localProject())['deleted_at'], isNotNull);
    });

    test('with no signal: nothing changes and nothing throws', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await seedMemberDevice(container);
      ownerDeletesOnTheirPhone();
      await container.read(syncControllerProvider.notifier).syncNow();
      await container.read(activeProjectIdProvider.notifier).set(null);
      server
        ..restoreServerProject(projectId, restoredBy: owner)
        ..permanentFailure = const SyncTransportException('unreachable');

      expect(await bringBack(container), isEmpty);
      expect((await localProject())['deleted_at'], isNotNull);

      server.permanentFailure = null;
      expect(
        (await bringBack(container)).map((a) => a.projectId),
        [projectId],
        reason: 'the next foreground with signal finishes it',
      );
    });
  });

  group('the app says so, with nobody touching a screen', () {
    testWidgets(
      'opening TriTrack brings a restored project back and names who '
      'restored it',
      (tester) async {
        final container = signedInContainer(
          extra: [
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
            joinRequestWatcherProvider.overrideWith(_QuietJoinWatcher.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await seedMemberDevice(container);
          ownerDeletesOnTheirPhone();
          await container.read(syncControllerProvider.notifier).syncNow();
          await container.read(activeProjectIdProvider.notifier).set(null);
          server.restoreServerProject(projectId, restoredBy: owner);

          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const TriTrackApp(),
            ),
          );
          for (var i = 0; i < 240; i++) {
            if (find
                .textContaining('is back in your projects')
                .evaluate()
                .isNotEmpty) {
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        });

        expect(
          find.text(
            '"Elk Study" is back in your projects. Robin Owner had deleted '
            'it and has restored it on the server, with everything in it.',
          ),
          findsOneWidget,
        );
        expect((await tester.runAsync(localProject))!['deleted_at'], isNull);
      },
    );

    /// The app already open when the owner restores, the project still the
    /// open one, and the person pulling the Projects list to refresh — which
    /// runs *Sync now*. The route Michael's Mac took on 2026-09-24, when the
    /// project came back and nothing was said. Before the announcement moved
    /// into the merge, this test fails on the missing sentence.
    testWidgets(
      'already open, pull-to-refresh after the restore: the sentence is shown',
      (tester) async {
        final container = signedInContainer(
          extra: [
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
            joinRequestWatcherProvider.overrideWith(_QuietJoinWatcher.new),
          ],
        );
        addTearDown(container.dispose);
        const sentence =
            '"Elk Study" is back in your projects. Robin Owner had deleted '
            'it and has restored it on the server, with everything in it.';

        await tester.runAsync(() async {
          await seedMemberDevice(container);
          ownerDeletesOnTheirPhone();
          await container.read(syncControllerProvider.notifier).syncNow();
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const TriTrackApp(),
            ),
          );
          // Let the launch's foreground chain run and find nothing restored.
          for (var i = 0; i < 40; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
          expect(find.text(sentence), findsNothing);

          server.restoreServerProject(projectId, restoredBy: owner);
          await container.read(syncControllerProvider.notifier).syncNow();
          for (var i = 0; i < 240; i++) {
            if (find.text(sentence).evaluate().isNotEmpty) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        });

        expect(find.text(sentence), findsOneWidget);
      },
    );

    testWidgets(
      'a restore made by this same account says nothing — the person did it '
      'and was told where they did it',
      (tester) async {
        final container = signedInContainer(
          extra: [
            appRouterProvider.overrideWithValue(
              GoRouter(
                routes: [
                  GoRoute(path: '/', builder: (_, _) => const Scaffold()),
                ],
              ),
            ),
            joinRequestWatcherProvider.overrideWith(_QuietJoinWatcher.new),
          ],
        );
        addTearDown(container.dispose);

        await tester.runAsync(() async {
          await seedMemberDevice(container);
          ownerDeletesOnTheirPhone();
          await container.read(syncControllerProvider.notifier).syncNow();
          await container.read(activeProjectIdProvider.notifier).set(null);
          // Restored from this account's other device.
          server.restoreServerProject(projectId, restoredBy: me);
          await tester.pumpWidget(
            UncontrolledProviderScope(
              container: container,
              child: const TriTrackApp(),
            ),
          );
          for (var i = 0; i < 240; i++) {
            final back = (await localProject())['deleted_at'] == null;
            if (back) break;
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 25));
            await tester.pump();
          }
        });

        expect((await tester.runAsync(localProject))!['deleted_at'], isNull);
        expect(find.textContaining('is back in your projects'), findsNothing);
      },
    );
  });
}

class _QuietJoinWatcher extends JoinRequestWatcher {
  @override
  JoinWatch build() => const JoinWatch();

  @override
  Future<void> checkOnForeground() async {}
}
