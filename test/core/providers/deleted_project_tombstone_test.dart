import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/core/providers/active_selection_provider.dart';
import 'package:tritrack/core/providers/app_context_provider.dart';
import 'package:tritrack/core/providers/auth_provider.dart';
import 'package:tritrack/core/providers/database_provider.dart';
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
import 'package:tritrack/data/sync/sync_row_receipts.dart';
import 'package:tritrack/data/sync/sync_transport.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../../data/sync/fake_sync_transport.dart';
import '../../support/fake_session_store.dart';
import '../../support/fake_shared_preferences.dart';

/// **A deleted project's tombstone reaches the server** (task 11.289).
///
/// ## What Michael measured, 2026-09-20
///
/// He published a project, confirmed it was on the server, deleted it on the
/// phone, selected a *different* project, synced, and queried the server
/// again: `deleted_at` was still empty. His server held nine live projects and
/// zero tombstones after a month of use.
///
/// ## Why — the project row is the only row whose deletion destroys the scope
/// that would have pushed it
///
/// A sync round is scoped to the **active** project (`SyncController._run`
/// begins `if (projectId == null) return;`), and `ProjectsScreen._deleteProject`
/// sets the active project to null when the deleted project was the open one.
/// Deleting a collar or a bearing is safe — the project stays selected and the
/// tombstone rides out on the next round. Deleting the project itself leaves
/// the tombstone on a project that is never the open one again: not when it
/// was active (active becomes null) and not when it was not (a deleted project
/// is hidden from the list, so nothing can select it). Selecting another
/// project does not help; that round pushes that project's rows.
///
/// This is exactly the trap task 11.57 opened for a **departure** — a closed
/// membership row on a project that is, by definition, no longer the open one
/// — and it is closed the same way: a derivation that finds the stranded row
/// from the data, and a round for that project run from the app's lifecycle
/// hooks rather than from a screen. See `pending_project_change.dart`.
///
/// ## Why "push before clearing the active project" was not the fix
///
/// It fails the case this app is built for: a person deleting a project in
/// the field with no signal. The push cannot happen, the tombstone is
/// stranded exactly as before, and now it looks handled. The tests below
/// therefore cover the offline case first and the online case second.
void main() {
  setUp(installFakeSharedPreferences);

  late AppDatabase db;
  late FakeSyncTransport server;
  const userId = 'user-1';
  const projectId = 'proj-1';
  const otherProjectId = 'proj-2';
  final stamp = DbCodec.encodeUtc(DateTime.utc(2026, 8, 1));

  Map<String, Object?> projectRow(String id, {String ownerId = userId}) => {
    'project_id': id,
    'project_name': id == projectId ? 'ZZ-DELETE-TEST' : 'Elk',
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

  Map<String, Object?> membershipRow(
    String id, {
    required String project,
    String user = userId,
    String role = ownerMembershipRole,
    bool open = true,
  }) => {
    'membership_id': id,
    'project_id': project,
    'user_id': user,
    'join_date': stamp,
    'end_date': open ? null : stamp,
    'role': role,
    'created_at': stamp,
    'updated_at': stamp,
    'revision': 0,
    'last_modified_by': user,
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

  /// Seeds one row on this device **and** on the server, with the receipt a
  /// real publish would have left — so before the test acts, nothing in the
  /// project is pending and every push below carries only what the test did.
  Future<void> seedPublished(
    String table,
    Map<String, Object?> row, {
    required String project,
  }) async {
    await db.raw.insert(table, row);
    server.seedServerRow(table, row);
    await SyncRowReceiptStore.ensureTable(db.raw);
    final spec = syncTablesByName[table]!;
    await SyncRowReceiptStore(db.raw).record(
      projectId: project,
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
    await seedPublished(Tables.users, userRow(userId), project: projectId);
    await seedPublished(
      Tables.projects,
      projectRow(projectId),
      project: projectId,
    );
    await seedPublished(
      Tables.projectMemberships,
      membershipRow('mem-1', project: projectId),
      project: projectId,
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

  /// The device as it stands right after a publish: an address, the project
  /// open, and the project linked.
  Future<void> publishedAndOpen(ProviderContainer container) async {
    await container
        .read(serverConfigProvider.notifier)
        .setUrl('https://tritrack.example.org');
    await container.read(activeProjectIdProvider.notifier).set(projectId);
    await container.read(syncStateStoreProvider).markProjectLinked(projectId);
    await container.read(syncControllerProvider.future);
  }

  /// What `ProjectsScreen._deleteProject` does, without the screen: the
  /// owner's tombstone, then the active project cleared because it was the one
  /// deleted.
  Future<void> deleteTheOpenProject(ProviderContainer container) async {
    final repo = ProjectRepository(db.raw);
    final deleted = await repo.softDeleteById(
      projectId,
      actor: const MutationActor.user(userId),
      deviceId: 'device-A',
    );
    expect(deleted, 1);
    await container.read(activeProjectIdProvider.notifier).set(null);
  }

  Future<List<PendingProjectChange>> stranded(
    ProviderContainer container, {
    String? excludingProjectId,
  }) => findUndeliveredProjectChanges(
    db: db.raw,
    state: container.read(syncStateStoreProvider),
    userId: userId,
    excludingProjectId: excludingProjectId,
  );

  Object? serverDeletedAt() =>
      server.serverRow(Tables.projects, projectId)?['deleted_at'];

  group('deleting the open project, with no signal', () {
    test(
      'the tombstone is stranded on a project no round can reach — and found',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);
        server.permanentFailure = const SyncTransportException('unreachable');

        await deleteTheOpenProject(container);

        // Michael's step, still with no signal: pick a different project and
        // sync. The open project's round is scoped to `proj-2` and carries
        // nothing of `proj-1`; the attempt for `proj-1` cannot get out.
        await db.raw.insert(Tables.projects, projectRow(otherProjectId));
        await db.raw.insert(
          Tables.projectMemberships,
          membershipRow('mem-2', project: otherProjectId),
        );
        await container
            .read(activeProjectIdProvider.notifier)
            .set(otherProjectId);
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked(otherProjectId);
        await container.read(syncControllerProvider.notifier).syncNow();
        expect(serverDeletedAt(), isNull);

        // The derivation is the instrument: the row is pending, on a linked
        // project, and the open project's own round is never going to offer
        // it. This is the state a phone is in for as long as it has no signal,
        // and it must be findable from the data alone.
        final pending = await stranded(
          container,
          excludingProjectId: otherProjectId,
        );
        expect(pending.map((c) => c.projectId), [projectId]);
        expect(pending.single.isDeletion, isTrue);
      },
    );

    test(
      'days later, the first foreground with signal delivers the tombstone',
      () async {
        final container = signedInContainer();
        addTearDown(container.dispose);
        await publishedAndOpen(container);
        server.permanentFailure = const SyncTransportException('unreachable');

        await deleteTheOpenProject(container);

        // Still no signal: the foreground hook runs, fails, and must leave the
        // row pending rather than decide anything about it.
        expect(
          await container
              .read(syncControllerProvider.notifier)
              .deliverPendingProjectChanges(),
          0,
        );
        expect(serverDeletedAt(), isNull);
        expect(await stranded(container), hasLength(1));
        expect(
          await container
              .read(syncStateStoreProvider)
              .isProjectLinked(projectId),
          isTrue,
          reason:
              'unlinking on a failed attempt would strand the tombstone with '
              'nothing left to push it — the trap this exists to open',
        );

        // Signal returns. The next foreground carries it.
        server.permanentFailure = null;
        expect(
          await container
              .read(syncControllerProvider.notifier)
              .deliverPendingProjectChanges(),
          1,
        );
        expect(serverDeletedAt(), isNotNull);
        expect(
          server.pushes.last.rows[Tables.projects]?.single['project_id'],
          projectId,
        );

        // And the launch after that has nothing to do.
        expect(await stranded(container), isEmpty);
        server.pushes.clear();
        expect(
          await container
              .read(syncControllerProvider.notifier)
              .deliverPendingProjectChanges(),
          0,
        );
        expect(server.pushes, isEmpty, reason: 'a confirmed tombstone is not '
            're-offered on every launch');
      },
    );
  });

  group('deleting the open project, with signal', () {
    test('"Sync now" with no project open still delivers it', () async {
      // Michael's exact steps, minus the second project: delete, then sync.
      // Before this task, `syncNow` returned at `if (projectId == null)` and
      // the tombstone never left the phone.
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);

      await deleteTheOpenProject(container);
      expect(serverDeletedAt(), isNull, reason: 'nothing has synced yet');

      await container.read(syncControllerProvider.notifier).syncNow();

      expect(serverDeletedAt(), isNotNull);
      expect(await stranded(container), isEmpty);
    });

    test('"Sync now" with a different project open delivers it too', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);

      await deleteTheOpenProject(container);
      await db.raw.insert(Tables.projects, projectRow(otherProjectId));
      await db.raw.insert(
        Tables.projectMemberships,
        membershipRow('mem-2', project: otherProjectId),
      );
      await container
          .read(activeProjectIdProvider.notifier)
          .set(otherProjectId);
      await container
          .read(syncStateStoreProvider)
          .markProjectLinked(otherProjectId);

      await container.read(syncControllerProvider.notifier).syncNow();

      expect(serverDeletedAt(), isNotNull);
      expect(
        server.pushes.map((p) => p.projectId),
        containsAll([projectId, otherProjectId]),
        reason: 'one round for the stranded project, one for the open one',
      );
    });
  });

  group('the derivation is about the project\'s own row, not only deletion',
      () {
    test('an undo after the tombstone reached the server is delivered too',
        () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      await deleteTheOpenProject(container);
      await container
          .read(syncControllerProvider.notifier)
          .deliverPendingProjectChanges();
      expect(serverDeletedAt(), isNotNull);

      // UNDO on the snackbar. The project is restored locally but is not the
      // open one, so without this the server would keep it deleted — and every
      // teammate would lose it — until somebody happened to select it.
      final restored = await ProjectRepository(db.raw).restoreById(
        projectId,
        actor: const MutationActor.user(userId),
        deviceId: 'device-A',
      );
      expect(restored, 1);
      final pending = await stranded(container);
      expect(pending.map((c) => c.projectId), [projectId]);
      expect(pending.single.isDeletion, isFalse);

      await container
          .read(syncControllerProvider.notifier)
          .deliverPendingProjectChanges();
      expect(serverDeletedAt(), isNull);
    });

    test('the open project\'s own row is left to the ordinary round', () async {
      // A rename of the open project is pending like any other edit and the
      // active-project round owns it. Running a second engine round for the
      // same project from the flush would put two rounds on one project.
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      await ProjectRepository(db.raw).updateById(
        projectId,
        {'project_name': 'Renamed'},
        actor: const MutationActor.user(userId),
        deviceId: 'device-A',
      );

      expect(
        (await stranded(container)).map((c) => c.projectId),
        [projectId],
        reason: 'the row is pending, whichever project is open',
      );
      expect(
        await stranded(container, excludingProjectId: projectId),
        isEmpty,
        reason: 'and the flush leaves the open project to its own round',
      );
      expect(
        await container
            .read(syncControllerProvider.notifier)
            .deliverPendingProjectChanges(),
        0,
      );
    });
  });

  group('what is deliberately not delivered', () {
    test('a deleted project that was never published', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await container
          .read(serverConfigProvider.notifier)
          .setUrl('https://tritrack.example.org');
      // Local only: no link. The server has never heard of it, so there is
      // nothing on the server to tombstone.
      await db.raw.insert(Tables.projects, projectRow(otherProjectId));
      await db.raw.insert(
        Tables.projectMemberships,
        membershipRow('mem-2', project: otherProjectId),
      );
      await ProjectRepository(db.raw).softDeleteById(
        otherProjectId,
        actor: const MutationActor.user(userId),
        deviceId: 'device-A',
      );

      expect(
        (await stranded(container)).map((c) => c.projectId),
        isNot(contains(otherProjectId)),
      );
    });

    test(
      'a departed member\'s local delete of somebody else\'s project',
      () async {
        // Task 11.54's exemption. The row is `Projects`, `owner_user_id`
        // names the owner, and `offer_rules.dart` withholds it — this device
        // removing its own copy must not reach the owner's project. The
        // derivation asks the push's own predicate, so it agrees.
        final container = signedInContainer();
        addTearDown(container.dispose);
        await container
            .read(serverConfigProvider.notifier)
            .setUrl('https://tritrack.example.org');
        await db.raw.insert(Tables.users, userRow('owner-2'));
        await db.raw.insert(
          Tables.projects,
          projectRow(otherProjectId, ownerId: 'owner-2'),
        );
        await db.raw.insert(
          Tables.projectMemberships,
          membershipRow(
            'mem-2',
            project: otherProjectId,
            role: 'contributor',
            open: false,
          ),
        );
        await container
            .read(syncStateStoreProvider)
            .markProjectLinked(otherProjectId);
        final deleted = await ProjectRepository(db.raw).softDeleteById(
          otherProjectId,
          actor: const MutationActor.user(userId),
          deviceId: 'device-A',
          exemption: const MutationExemption.departedMember(otherProjectId),
        );
        expect(deleted, 1);

        expect(
          (await stranded(container)).map((c) => c.projectId),
          isNot(contains(otherProjectId)),
        );
        expect(
          await container
              .read(syncControllerProvider.notifier)
              .deliverPendingProjectChanges(),
          0,
        );
        expect(
          server.pushes.where((p) => p.projectId == otherProjectId),
          isEmpty,
        );
      },
    );

    test('a tombstone the server already confirmed', () async {
      final container = signedInContainer();
      addTearDown(container.dispose);
      await publishedAndOpen(container);
      await deleteTheOpenProject(container);
      await container
          .read(syncControllerProvider.notifier)
          .deliverPendingProjectChanges();

      expect(await stranded(container), isEmpty);
    });
  });
}
