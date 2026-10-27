import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
import 'package:tritrack/core/providers/project_deletion_provider.dart';
import 'package:tritrack/core/providers/server_config_provider.dart';
import 'package:tritrack/core/providers/server_transport_provider.dart';
import 'package:tritrack/core/providers/sync_provider.dart';
import 'package:tritrack/data/auth/session_store.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/models/sync_meta.dart';
import 'package:tritrack/data/models/user.dart';
import 'package:tritrack/data/repositories/mutation_authorization.dart';
import 'package:tritrack/data/repositories/project_repository.dart';
import 'package:tritrack/data/sync/pending_project_change.dart';
import 'package:tritrack/data/sync/project_deletion_notice.dart';
import 'package:tritrack/data/sync/sync_failure.dart';
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **The device's side of a project's destruction** (task 11.290).
///
/// The server owns the schedule; this is what the phone does with it. Four
/// things, each a test below:
///
/// 1. The countdown is **learned from `/projects/mine` and kept**, so the
///    Projects list is right offline; a cancel takes it down.
/// 2. An owner's *delete now* records the destruction here at once and
///    unlinks the project, keeping every record.
/// 3. **A device offline across the deletion keeps its records** — Michael's
///    decision — and its next round is told why: the server's named refusal
///    becomes a notice, the project is unlinked, and nothing is deleted.
/// 4. A local delete the server refuses is **visible**, as task 11.289 asked:
///    the refusal is remembered against the project, and the derivation that
///    feeds the Projects list's "not yet on the server" section carries it.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;
  const userId = 'user-1';
  const projectId = 'proj-1';
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  Map<String, Object?> projectRow(String id) => {
    'project_id': id,
    'project_name': 'Ponui kiwi',
    'owner_user_id': userId,
    'creation_date': stamp,
    'datum': 'WGS84',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> membershipRow(String id, {required String project}) => {
    'membership_id': id,
    'project_id': project,
    'user_id': userId,
    'join_date': stamp,
    'end_date': null,
    'role': ownerMembershipRole,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> userRow(String id) => {
    'user_id': id,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': '$id@example.com',
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': id,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> observationRow(String id) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
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
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Future<void> seedPublished(String table, Map<String, Object?> row) async {
    await db.raw.insert(table, row);
    server.seedServerRow(table, row);
    await SyncRowReceiptStore.ensureTable(db.raw);
    final spec = syncTablesByName[table]!;
    await SyncRowReceiptStore(db.raw).record(
      projectId: projectId,
      tableName: table,
      rowKey: spec.primaryKey.map((c) => row[c]).join('/'),
      ackedUpdatedAt: stamp,
      at: DateTime.utc(2026, 8, 1),
    );
  }

  setUp(() async {
    db = await AppDatabase.openInMemory();
    server = FakeSyncTransport()
      ..sessionUserId = userId
      ..sessionEmail = '$userId@example.com';
    await seedPublished(Tables.users, userRow(userId));
    await seedPublished(Tables.projects, projectRow(projectId));
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-1', project: projectId),
    );
    await seedPublished(Tables.observations, observationRow('obs-1'));
    await seedPublished(Tables.observations, observationRow('obs-2'));
    server.serverProjects.add(
      const ProjectSummary(
        projectId: projectId,
        projectName: 'Ponui kiwi',
        ownerUserId: userId,
        role: ownerMembershipRole,
      ),
    );
  });
  tearDown(() => db.close());

  ProviderContainer signedInContainer() => ProviderContainer(
    overrides: [
      appDatabaseProvider.overrideWith((ref) async => db),
      serverTransportProvider.overrideWith((ref) async => server),
      currentUserProvider.overrideWith(
        (ref) async => User(
          userId: userId,
          firstName: 'Sam',
          lastName: 'Ranger',
          email: '$userId@example.com',
          sync: SyncMeta.initial(now: DateTime.utc(2026, 8, 1)),
        ),
      ),
      sessionStoreProvider.overrideWithValue(
        FakeSessionStore(
          StoredSession(
            token: 'not-a-real-token',
            userId: userId,
            email: '$userId@example.com',
            expiresAt: DateTime.now().add(const Duration(days: 30)),
          ),
        ),
      ),
    ],
  );

  Future<void> publishedAndOpen(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  Future<int> localObservations() async =>
      (await db.raw.query(Tables.observations)).length;

  group('the countdown', () {
    test('is learned from the directory and kept for the list', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      final notices = container.read(projectDeletionNoticesProvider.notifier);

      // Nothing scheduled: nothing held.
      await notices.refreshFromServer();
      expect(await notices.future, isEmpty);

      // The owner schedules it on another device; this one asks.
      final destroyAt = DateTime.utc(2026, 10, 20, 9);
      server.scheduledDeletions[projectId] = ProjectDeletionStanding(
        graceDays: 30,
        backupRetentionDays: 30,
        scheduledAt: DateTime.utc(2026, 9, 20, 9),
        destroyAt: destroyAt,
      );
      await notices.refreshFromServer();
      final held = (await notices.future)[projectId]!;
      expect(held.destroyAt, destroyAt);
      expect(held.executed, isFalse);
      expect(held.daysLeftAt(DateTime.utc(2026, 10, 1, 9)), 19);
      expect(held.daysLeftAt(DateTime.utc(2026, 10, 19, 12)), 1);

      // It survives a rebuild: read straight back from the store, which is
      // what the list does when it opens with no signal.
      final stored = await container
          .read(syncStateStoreProvider)
          .deletionNotices();
      expect(stored[projectId]?.destroyAt, destroyAt);

      // The owner cancels; the countdown comes down.
      server.scheduledDeletions.remove(projectId);
      await notices.refreshFromServer();
      expect(await notices.future, isEmpty);
    });

    test(
      'is settled by asking the server when the project leaves the listing '
      '— the row Michael saw not update',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);
        final notices = container.read(
          projectDeletionNoticesProvider.notifier,
        );
        final store = container.read(syncStateStoreProvider);

        // Counting down on this phone…
        server.scheduledDeletions[projectId] = ProjectDeletionStanding(
          graceDays: 0,
          backupRetentionDays: 30,
          scheduledAt: DateTime.utc(2026, 9, 20, 9),
          destroyAt: DateTime.utc(2026, 9, 20, 9),
        );
        await notices.refreshFromServer();
        expect((await notices.future)[projectId]?.executed, isFalse);

        // …the sweep runs on the server, so the directory stops listing it.
        // This phone does not have the project open, so no sync round will
        // ever ask about it; the Projects list must.
        server.destroyProject(projectId, at: DateTime.utc(2026, 9, 20, 10));
        await container.read(activeProjectIdProvider.notifier).set(null);
        await notices.refreshFromServer();

        final held = (await notices.future)[projectId];
        expect(held, isNotNull);
        expect(
          held!.executed,
          isTrue,
          reason: 'the server names the project as destroyed when asked',
        );
        expect(await store.isProjectLinked(projectId), isFalse);
        expect(await localObservations(), 2);
      },
    );

    test('a project that merely left the listing keeps its notice', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      final notices = container.read(projectDeletionNoticesProvider.notifier);
      server.scheduledDeletions[projectId] = ProjectDeletionStanding(
        graceDays: 30,
        backupRetentionDays: 30,
        scheduledAt: DateTime.utc(2026, 9, 20),
        destroyAt: DateTime.utc(2026, 10, 20),
      );
      await notices.refreshFromServer();
      // Removed from the project by an owner: the listing drops it and the
      // server answers a bare forbidden. Nothing here may claim it was
      // destroyed.
      server.serverProjects.clear();
      server.closedMembershipProjects.add(projectId);
      await notices.refreshFromServer();
      expect((await notices.future)[projectId]?.executed, isFalse);
    });

    test('is not learned when the server cannot be reached', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      server.scheduledDeletions[projectId] = ProjectDeletionStanding(
        graceDays: 30,
        backupRetentionDays: 30,
        scheduledAt: DateTime.utc(2026, 9, 20),
        destroyAt: DateTime.utc(2026, 10, 20),
      );
      server.permanentFailure = const SyncTransportException('unreachable');
      final notices = container.read(projectDeletionNoticesProvider.notifier);
      // Must not throw — a lifecycle hook calls this.
      await notices.refreshFromServer();
      expect(await notices.future, isEmpty);
    });
  });

  group('the owner acts from this device', () {
    test('schedule writes the server\'s date; cancel removes it', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      final notices = container.read(projectDeletionNoticesProvider.notifier);

      final standing = await notices.standing(projectId);
      expect(standing.graceDays, 30);
      expect(standing.isScheduled, isFalse);

      final scheduled = await notices.act(
        projectId,
        ProjectDeletionAction.schedule,
      );
      expect(scheduled.isScheduled, isTrue);
      expect((await notices.future)[projectId]?.destroyAt, scheduled.destroyAt);
      expect(server.deletionRequests, [
        (projectId, ProjectDeletionAction.schedule),
      ]);

      await notices.act(projectId, ProjectDeletionAction.cancel);
      expect(await notices.future, isEmpty);
    });

    test(
      'delete now records the destruction, unlinks, and keeps every record',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);
        final notices = container.read(projectDeletionNoticesProvider.notifier);
        final store = container.read(syncStateStoreProvider);

        final result = await notices.act(
          projectId,
          ProjectDeletionAction.immediate,
        );
        expect(result.executedAt, isNotNull);
        expect(server.destroyedProjects, {projectId});

        final held = (await notices.future)[projectId]!;
        expect(held.executed, isTrue);
        expect(await store.isProjectLinked(projectId), isFalse);
        // Michael's decision: nothing on the device is touched.
        expect(await localObservations(), 2);
        expect(
          (await db.raw.query(Tables.projects)).single['deleted_at'],
          isNull,
        );
      },
    );
  });

  group('a device offline across the deletion', () {
    test('keeps its records, is told why on its next round, and stops '
        'offering them', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      final store = container.read(syncStateStoreProvider);

      // A bearing recorded out of signal, then the sweep runs on the server
      // while the phone is still away.
      await db.raw.insert(Tables.observations, observationRow('obs-3'));
      server.destroyProject(projectId, at: DateTime.utc(2026, 10, 20, 9));

      // Signal returns: the ordinary round.
      final controller = container.read(syncControllerProvider.notifier);
      await controller.syncNow();
      final status = container.read(syncControllerProvider).value!;

      // Told, in the app's own words for this cause.
      expect(status.lastFailure, SyncFailureCause.refusedWithRemedy);
      expect(
        status.lastErrorMessage,
        contains('deleted from the server by a project owner'),
      );
      expect(
        status.lastErrorMessage,
        contains('records on this device are kept'),
      );

      // Recorded for the Projects list, and the project unlinked so no
      // foreground keeps offering rows to a refusal.
      final held = await store.deletionNotice(projectId);
      expect(held, isNotNull);
      expect(held!.executed, isTrue);
      expect(await store.isProjectLinked(projectId), isFalse);

      // Nothing deleted, nothing hidden: the three bearings, the unsynced
      // one included, are exactly where they were.
      expect(await localObservations(), 3);
      expect(
        (await db.raw.query(Tables.projects)).single['deleted_at'],
        isNull,
      );
    });
  });

  group('a local delete the server refuses (task 11.289\'s question)', () {
    test(
      'is remembered against the project and derived for the list',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);

        // The owner deletes the open project; the server refuses the tombstone
        // — the case 11.289 could not surface: ownership differs, or the
        // server is too old. Modelled as a flat 403 on push.
        final repo = ProjectRepository(db.raw);
        await repo.softDeleteById(
          projectId,
          actor: const MutationActor.user(userId),
          deviceId: 'device-A',
        );
        await container.read(activeProjectIdProvider.notifier).set(null);
        server.permanentFailure = const SyncTransportException(
          'forbidden',
          statusCode: 403,
        );

        final delivered = await container
            .read(syncControllerProvider.notifier)
            .deliverPendingProjectChanges();
        expect(delivered, 0);

        final rows = await container.read(
          undeliveredProjectDeletionsProvider.future,
        );
        expect(rows.map((r) => r.projectId), [projectId]);
        expect(rows.single.projectName, 'Ponui kiwi');
        expect(
          rows.single.wasRefused,
          isTrue,
          reason: 'a 403 is a refusal, and the row has to say so',
        );

        // No signal is not a refusal: the row is waiting, not refused.
        server.permanentFailure = const SyncTransportException('unreachable');
        container
            .read(projectChangeRefusalsProvider.notifier)
            .forget(projectId);
        await container
            .read(syncControllerProvider.notifier)
            .deliverPendingProjectChanges();
        final waiting = await container.read(
          undeliveredProjectDeletionsProvider.future,
        );
        expect(waiting.single.wasRefused, isFalse);
      },
    );
  });

  group('a local delete the server refuses row by row', () {
    test(
      'the held tombstone is derived for the list — task 11.289\'s actual case',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);

        // The server records somebody else as the owner: the push is
        // accepted as a request and the one row comes back `unauthorized`,
        // so the engine holds it and it is no longer pending. Before this
        // task, that row was invisible everywhere.
        server.refuseRows['${Tables.projects}/$projectId'] =
            SyncRowOutcome.unauthorized;
        final repo = ProjectRepository(db.raw);
        await repo.softDeleteById(
          projectId,
          actor: const MutationActor.user(userId),
          deviceId: 'device-A',
        );
        await container.read(activeProjectIdProvider.notifier).set(null);
        await container
            .read(syncControllerProvider.notifier)
            .deliverPendingProjectChanges();

        // Not pending any more — which is exactly why the flush cannot show it.
        expect(
          await findUndeliveredProjectChanges(
            db: db.raw,
            state: container.read(syncStateStoreProvider),
            userId: userId,
          ),
          isEmpty,
        );
        final rows = await container.read(
          undeliveredProjectDeletionsProvider.future,
        );
        expect(rows.map((r) => r.projectId), [projectId]);
        expect(rows.single.held, isNotNull);
        expect(rows.single.wasRefused, isTrue);
      },
    );
  });

  group('the notice itself', () {
    test('survives a round trip, and drops what it cannot read', () {
      final notice = ProjectDeletionNotice(
        destroyAt: DateTime.utc(2026, 10, 20, 9),
        learnedAt: DateTime.utc(2026, 9, 21, 8),
      );
      final decoded = ProjectDeletionNotice.decodeAll(
        ProjectDeletionNotice.encodeAll({
          'p': notice,
          'q': notice.markExecuted(DateTime.utc(2026, 10, 21)),
        }),
      );
      expect(decoded['p']!.destroyAt, notice.destroyAt);
      expect(decoded['p']!.executed, isFalse);
      expect(decoded['q']!.executed, isTrue);
      expect(ProjectDeletionNotice.decodeAll('not json'), isEmpty);
      expect(
        ProjectDeletionNotice.decodeAll('{"p": {"destroy_at": 5}}'),
        isEmpty,
      );
      expect(ProjectDeletionNotice.decodeAll(null), isEmpty);
    });

    test('counts days the way a person does', () {
      final notice = ProjectDeletionNotice(
        destroyAt: DateTime.utc(2026, 10, 20, 9),
        learnedAt: DateTime.utc(2026, 9, 20, 9),
      );
      expect(notice.daysLeftAt(DateTime.utc(2026, 9, 20, 9)), 30);
      // Twelve hours out is still a day a person has, not zero.
      expect(notice.daysLeftAt(DateTime.utc(2026, 10, 19, 21)), 1);
      expect(notice.daysLeftAt(DateTime.utc(2026, 10, 20, 9)), 0);
      expect(notice.isPastAt(DateTime.utc(2026, 10, 20, 9)), isTrue);
      expect(notice.isPastAt(DateTime.utc(2026, 10, 20, 8, 59)), isFalse);
      // Never negative, however late the device is.
      expect(notice.daysLeftAt(DateTime.utc(2026, 12, 1)), 0);
    });
  });
}
