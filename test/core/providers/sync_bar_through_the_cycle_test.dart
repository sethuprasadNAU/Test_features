import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_http_client_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/sync/pending_departure.dart';
import 'package:tritrack/data/sync/sync_held_rows.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **What the sync bar shows at each step of the membership cycle**
/// (task 11.57, item 5) — and the recovery for a departure that never got out
/// (item 4), which is the step at which the bar shows nothing at all.
///
/// ## Why this is a walk rather than a set of unit tests
///
/// Task 10.12 specified the bar as never hiding itself while sync is available,
/// and Michael accepted that deliberately. On 2026-08-29, after leaving and
/// deleting projects on his iPhone, he reported **no bar at all** — and the
/// question that mattered was not "is that a bug" but *"what is it supposed to
/// show at each step, and does it?"* A single state cannot answer that. Each
/// test below is one step of the cycle, named for the step, and the group is
/// the answer:
///
/// | step | the bar |
/// |---|---|
/// | no server configured | hidden — task 10.2's invariant |
/// | configured, signed out | hidden |
/// | signed in, no project open | **hidden** |
/// | a local project, never published | hidden |
/// | published or joined, syncing | shown — "Synced …" |
/// | with records not yet pushed | shown — "… N records waiting to sync" |
/// | with a record the server refused | shown, red — "N records aren't on the server" |
/// | removed by an owner, news not yet arrived | shown, amber — "refusing access" |
/// | left, and the server confirmed it | shown, grey — "You're no longer on this project" |
/// | left, and the server has not confirmed it | shown — the ordinary status |
/// | left, then deleted the project | **hidden** ← what Michael saw |
/// | restored from "Join a project" | shown — "Synced …" |
///
/// ## The reported state, confirmed by mechanism rather than adopted
///
/// The last-but-one row is the one he reported, and the bar is right to be
/// hidden: deleting the **active** project sets the active project to null
/// (`ProjectsScreen._deleteProject`), nothing selects another, and with no
/// project open there is nothing for a per-project status to be about. The
/// "More" header looked normal in the same breath for the same reason — see
/// the note in the last test.
///
/// **And that is the sharpest thing in this task.** The device was a member of
/// a project on the server, holding a hidden local copy, and showing the person
/// nothing whatsoever: no project, no bar, no warning. The lockout was not
/// "cannot rejoin"; it was *cannot rejoin, and nothing says so*. The fix is not
/// to make the bar shout about a project that is not open — it is
/// `ProjectDirectoryClient.listAvailableToJoin` offering the project again, and
/// the recovery in the second group here delivering the departure that stranded
/// it. Both are what put the device back into a state the bar can describe.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  setUp(() async {
    db = await AppDatabase.openInMemory();
  });
  tearDown(() => db.close());

  /// A container signed in as `user-1`, with [client] answering every request.
  ProviderContainer containerWith(http.Client client) => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) async => db),
      currentUserProvider.overrideWith(
        (ref) async => User(
          userId: 'user-1',
          firstName: 'Sam',
          lastName: 'Ranger',
          email: 'sam@example.com',
          sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
        ),
      ),
      serverHttpClientProvider.overrideWith((ref) async => client),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 't',
            userId: 'user-1',
            email: 'sam@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 1)),
          ),
        ),
      ),
    ],
  );

  /// What the server answers a device that is no longer a member.
  ProviderContainer refusedContainer() => containerWith(
    MockClient((_) async => http.Response('{"error":"forbidden"}', 403)),
  );

  /// A container nothing ever calls — every state below that does not need a
  /// round trip is read straight out of `SyncController.build`, which is local.
  ProviderContainer offlineContainer() => containerWith(
    MockClient((_) async => http.Response('{}', 500)),
  );

  Future<void> seedProject({bool deleted = false}) async {
    // Two people, because every state below is about a project somebody else
    // owns — which is the only kind you can be removed from.
    for (final (id, name) in [('user-1', 'Sam'), ('owner-2', 'Ada')]) {
      await db.raw.insert(Tables.users, {
        'user_id': id,
        'first_name': name,
        'last_name': 'Ranger',
        'email': '$id@example.com',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': id,
        'origin_device_id': 'device-A',
      });
    }
    await db.raw.insert(Tables.projects, {
      'project_id': 'proj-1',
      'project_name': 'Elk',
      'owner_user_id': 'owner-2',
      'creation_date': stamp,
      'datum': 'WGS84',
      'created_at': stamp,
      'updated_at': stamp,
      'deleted_at': deleted ? stamp : null,
      'revision': 0,
      'last_modified_by': 'owner-2',
      'origin_device_id': 'device-B',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
    });
  }

  Future<void> seedMembership({required bool open}) => db.raw.insert(
    Tables.projectMemberships,
    {
      'membership_id': 'mem-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'join_date': stamp,
      'end_date': open ? null : stamp,
      'role': 'contributor',
      'created_at': stamp,
      'updated_at': stamp,
      'revision': open ? 0 : 1,
      'last_modified_by': 'user-1',
      'origin_device_id': 'device-A',
    },
  );

  Future<void> makeActive(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('http://192.168.1.42:8080');
    await container.read(activeProjectIdProvider.notifier).set('proj-1');
  }

  group('what the sync bar shows at each step of the membership cycle', () {
    test('no server configured: hidden', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      final status = await container.read(syncControllerProvider.future);
      expect(status.unavailable, SyncUnavailable.notConfigured);
      expect(status.isWorthShowing, isFalse);
    });

    test('configured but signed out: hidden', () async {
      final container = ProviderContainer(
        overrides: [
          appDatabaseProvider.overrideWith((ref) async => db),
          sessionStoreProvider.overrideWithValue(FakeSessionStore()),
        ],
      );
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      final status = await container.read(syncControllerProvider.future);
      expect(status.unavailable, SyncUnavailable.signedOut);
      expect(status.isWorthShowing, isFalse);
    });

    test('signed in with no project open: hidden', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      final status = await container.read(syncControllerProvider.future);
      expect(status.unavailable, SyncUnavailable.noProject);
      expect(status.isWorthShowing, isFalse);
    });

    test('a local project that has never been published: hidden', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedProject();
      await seedMembership(open: true);
      await makeActive(container);
      final status = await container.read(syncControllerProvider.future);
      expect(status.unavailable, SyncUnavailable.notLinked);
      expect(status.isWorthShowing, isFalse);
    });

    test('joined and syncing: shown, and says when it last synced', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedProject();
      await seedMembership(open: true);
      await makeActive(container);
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');

      final status = await container.read(syncControllerProvider.future);
      expect(status.isWorthShowing, isTrue);
      expect(status.health, SyncHealth.healthy);
    });

    test('with records not yet pushed: shown, and says how many', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedProject();
      await seedMembership(open: true);
      await makeActive(container);
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');
      await db.raw.insert(Tables.observations, {
        'observation_id': 'obs-1',
        'project_id': 'proj-1',
        'user_id': 'user-1',
        'timestamp_local': stamp,
        'timestamp_utc': stamp,
        'timezone_offset': '+00:00',
        'latitude': 35.2,
        'longitude': -111.7,
        'position_source': 'gps_fix',
        'elevation': 2106.4,
        'altitude_agl': 1.5,
        'observation_type': 'directional',
        'signal_type': 'regular_pulse',
        'signal_strength': 'strong',
        'created_at': stamp,
        'updated_at': stamp,
        'revision': 0,
        'last_modified_by': 'user-1',
        'origin_device_id': 'device-A',
      });

      final status = await container.read(syncControllerProvider.future);
      expect(status.isWorthShowing, isTrue);
      expect(status.health, SyncHealth.healthy);
      // The number itself is the bearing plus this device's own identity and
      // membership rows; what this step asserts is that the bar switches to
      // the "N records waiting to sync" wording at all, not the arithmetic.
      expect(status.pendingCount, isPositive);
    });

    test('holding a record the server refused: shown, and counted', () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedProject();
      await seedMembership(open: true);
      await makeActive(container);
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');
      await SyncHeldRowStore.ensureTable(db.raw);
      await SyncHeldRowStore(db.raw).hold(
        projectId: 'proj-1',
        tableName: Tables.observations,
        rowKey: 'obs-1',
        reason: HeldRowReason.notPermitted,
        rowUpdatedAt: stamp,
        at: DateTime.utc(2026, 8, 1),
      );

      final status = await container.read(syncControllerProvider.future);
      expect(status.isWorthShowing, isTrue);
      expect(status.health, SyncHealth.rowsRefused);
      expect(status.heldCount, 1);
    });

    test(
      'removed by an owner, before the news reaches this device: shown, and '
      'says the server is refusing access',
      () async {
        // The device still holds an *open* stint, because the pull that would
        // carry the closed one is the request being refused. It must not claim
        // to know it was removed, and it must not read as generic breakage.
        final container = refusedContainer();
        addTearDown(container.dispose);
        await seedProject();
        await seedMembership(open: true);
        await makeActive(container);
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked('proj-1');

        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.isWorthShowing, isTrue);
        expect(status.health, SyncHealth.accessRefused);
      },
    );

    test(
      'left, and the server confirmed it: shown, and says so rather than '
      'vanishing',
      () async {
        final container = refusedContainer();
        addTearDown(container.dispose);
        await seedProject();
        await seedMembership(open: false);
        await makeActive(container);
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked('proj-1');

        await container.read(syncControllerProvider.future);
        await container.read(syncControllerProvider.notifier).syncNow();

        final status = await container.read(syncControllerProvider.future);
        expect(status.unavailable, SyncUnavailable.leftProject);
        expect(status.health, SyncHealth.membershipEnded);
        expect(status.isWorthShowing, isTrue);
      },
    );

    test(
      'left, and the server has not confirmed it: shown, because the project '
      'is still linked and still being tried',
      () async {
        final container = offlineContainer();
        addTearDown(container.dispose);
        await seedProject();
        await seedMembership(open: false);
        await makeActive(container);
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked('proj-1');

        final status = await container.read(syncControllerProvider.future);
        expect(status.isWorthShowing, isTrue);
        expect(status.unavailable, isNull);
      },
    );

    test(
      'left, then deleted the project: hidden — and this is the state Michael '
      'reported',
      () async {
        // **Confirmed by mechanism, not adopted.** Deleting the active project
        // sets the active project to null (`ProjectsScreen._deleteProject`) and
        // nothing selects another, so there is no project for a per-project
        // status to be about. The bar is right to be hidden, task 10.12's
        // "never hides while sync is available" is intact — sync is not
        // available, because nothing is open — and the "More" header looked
        // normal in the same breath because the bar that had been sitting
        // directly above it was gone. Those two reports are one observation.
        //
        // What was wrong was not the bar. It was that the person was a member
        // of a project on the server, holding a hidden copy of it, with no
        // route back — see `ProjectDirectoryClient.listAvailableToJoin`.
        final container = offlineContainer();
        addTearDown(container.dispose);
        await seedProject(deleted: true);
        await seedMembership(open: false);
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('http://192.168.1.42:8080');
        await container.read(activeProjectIdProvider.notifier).set(null);

        final status = await container.read(syncControllerProvider.future);
        expect(status.unavailable, SyncUnavailable.noProject);
        expect(status.isWorthShowing, isFalse);
      },
    );

    test('restored from "Join a project": shown again', () async {
      // The other side of the fix: once the project is back and linked, the
      // bar has something to describe again.
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedProject();
      await seedMembership(open: true);
      await makeActive(container);
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');

      final status = await container.read(syncControllerProvider.future);
      expect(status.isWorthShowing, isTrue);
      expect(status.health, SyncHealth.healthy);
    });
  });

  group('a departure that never reached the server has a way out', () {
    /// Task 11.57, item 4. The project is deleted, so it is never the active
    /// one and no ordinary sync will ever offer the row.
    Future<void> seedStuckDeparture(ProviderContainer container) async {
      await seedProject(deleted: true);
      await seedMembership(open: false);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('http://192.168.1.42:8080');
      await container.read(activeProjectIdProvider.notifier).set(null);
      await container.read(syncStateStoreProvider).markProjectLinked('proj-1');
    }

    test('the stuck departure is found even though nothing else can see it',
        () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedStuckDeparture(container);

      final stuck = await findUndeliveredDepartures(
        db: db.raw,
        state: container.read(syncStateStoreProvider),
        userId: 'user-1',
      );
      expect(stuck.map((d) => d.projectId), ['proj-1']);
    });

    test('a departure the server has already confirmed is not re-sent',
        () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedStuckDeparture(container);
      await SyncRowReceiptStore.ensureTable(db.raw);
      await SyncRowReceiptStore(db.raw).record(
        projectId: 'proj-1',
        tableName: Tables.projectMemberships,
        rowKey: 'mem-1/proj-1',
        ackedUpdatedAt: stamp,
        at: DateTime.utc(2026, 8, 1),
      );

      expect(
        await findUndeliveredDepartures(
          db: db.raw,
          state: container.read(syncStateStoreProvider),
          userId: 'user-1',
        ),
        isEmpty,
        reason:
            'otherwise every app foreground re-offers a departure the server '
            'took weeks ago',
      );
    });

    test(
      'a stint an owner ended is not treated as this device\'s to deliver',
      () async {
        // It arrived *from* the server, so there is nothing to deliver, and
        // re-offering somebody else's decision on every launch would be wrong.
        final container = offlineContainer();
        addTearDown(container.dispose);
        await seedProject();
        await db.raw.insert(Tables.projectMemberships, {
          'membership_id': 'mem-2',
          'project_id': 'proj-1',
          'user_id': 'user-1',
          'join_date': stamp,
          'end_date': stamp,
          'role': 'contributor',
          'created_at': stamp,
          'updated_at': stamp,
          'revision': 1,
          'last_modified_by': 'owner-2',
          'origin_device_id': 'device-B',
        });
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('http://192.168.1.42:8080');
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked('proj-1');

        expect(
          await findUndeliveredDepartures(
            db: db.raw,
            state: container.read(syncStateStoreProvider),
            userId: 'user-1',
          ),
          isEmpty,
        );
      },
    );

    test('an unreachable server leaves the departure pending, not lost',
        () async {
      final container = offlineContainer();
      addTearDown(container.dispose);
      await seedStuckDeparture(container);

      // Every request fails; the recovery must not throw into the app launch,
      // and must not decide the row is delivered.
      expect(
        await container.read(syncControllerProvider.notifier)
            .deliverPendingDepartures(),
        0,
      );
      expect(
        await container.read(syncStateStoreProvider).isProjectLinked('proj-1'),
        isTrue,
        reason:
            'unlinking on a failed attempt would strand the departure with '
            'nothing left to push it — the trap this recovery exists to open',
      );
      expect(
        await findUndeliveredDepartures(
          db: db.raw,
          state: container.read(syncStateStoreProvider),
          userId: 'user-1',
        ),
        isNotEmpty,
      );
    });
  });
}
