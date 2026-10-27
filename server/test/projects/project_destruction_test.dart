@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 11.290: a project scheduled for destruction is destroyed **by the
/// server, on the server's clock**, and stays destroyed.
///
/// The headline test is *the sweep destroys a project once its date has
/// passed, and not before* — the clock is a function the service is handed,
/// so "the date has passed" is a value in the test rather than a wait. The
/// rest establish what "gone" reaches (every row in every project-scoped
/// table, and the server's own bookkeeping for the project), what it leaves
/// (other projects, people, the audit log), that a canceled deletion never
/// runs, and that a destroyed id stays refused so nothing can put it back.
///
/// Watched red first: with `destroyDue` returning an empty sweep, the
/// headline test fails on the `Projects` row still being there, which is the
/// promise this whole task exists to keep.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_project_destruction_test';

  const alice = 'user-alice';
  const bob = 'user-bob';
  const projectA = 'proj-a';
  const projectB = 'proj-b';

  final scheduledOn = DateTime.utc(2026, 9, 20, 9);
  const policy = ProjectDeletionPolicy(grace: Duration(days: 30));

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
    await _seed(connection);
  });

  ProjectDestructionService serviceAt(DateTime now) =>
      ProjectDestructionService(connection, policy: policy, clock: () => now);

  Future<int> count(String table, {String? projectId}) async {
    final result = await connection.execute(
      'SELECT count(*) FROM ${quoted(table)}'
      '${projectId == null ? '' : ' WHERE project_id = \$1'}',
      parameters: projectId == null ? const [] : [projectId],
    );
    return result.first.first! as int;
  }

  Future<bool> projectExists(String id) async =>
      await count(Tables.projects, projectId: id) == 1;

  group('scheduling', skip: databaseSkipReason, () {
    test('sets the date from the server clock and the grace period', () async {
      final standing = await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      expect(standing.isScheduled, isTrue);
      expect(standing.scheduledAt, scheduledOn);
      expect(standing.destroyAt, scheduledOn.add(const Duration(days: 30)));
      expect(standing.graceDays, 30);
      expect(standing.executedAt, isNull);
    });

    test('a second schedule never moves the date', () async {
      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      final later = await serviceAt(
        scheduledOn.add(const Duration(days: 10)),
      ).schedule(projectId: projectA, scheduledBy: alice);
      expect(later.destroyAt, scheduledOn.add(const Duration(days: 30)));
    });

    test('an unscheduled project answers with the grace period only', () async {
      final standing = await serviceAt(scheduledOn).standingFor(projectA);
      expect(standing.isScheduled, isFalse);
      expect(standing.destroyAt, isNull);
      expect(standing.graceDays, 30);
    });

    test('cancel withdraws it, and the project is untouched', () async {
      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      final standing = await serviceAt(scheduledOn).cancel(projectA);
      expect(standing.isScheduled, isFalse);
      // Well past the date it would have had.
      final sweep = await serviceAt(
        scheduledOn.add(const Duration(days: 60)),
      ).destroyDue();
      expect(sweep.projectsDestroyed, 0);
      expect(await projectExists(projectA), isTrue);
      expect(await count(Tables.observations, projectId: projectA), 2);
    });
  });

  group('the sweep', skip: databaseSkipReason, () {
    test(
      'destroys a project once its date has passed, and not before',
      () async {
        await serviceAt(
          scheduledOn,
        ).schedule(projectId: projectA, scheduledBy: alice);

        // The day before: nothing.
        final early = await serviceAt(
          scheduledOn.add(const Duration(days: 29)),
        ).destroyDue();
        expect(early.projectsDestroyed, 0);
        expect(await projectExists(projectA), isTrue);

        // The date: gone.
        final due = await serviceAt(
          scheduledOn.add(const Duration(days: 30)),
        ).destroyDue();
        expect(due.destroyedProjectIds, [projectA]);
        expect(due.rowsDeleted, greaterThan(0));
        expect(
          await projectExists(projectA),
          isFalse,
          reason: 'the Projects row is what "gone" means',
        );
      },
    );

    test(
      '"gone" reaches every row of the project and its bookkeeping',
      () async {
        await serviceAt(
          scheduledOn,
        ).schedule(projectId: projectA, scheduledBy: alice);
        await serviceAt(scheduledOn.add(const Duration(days: 31))).destroyDue();

        for (final table in TombstoneRetentionService.purgeableTables) {
          expect(
            await count(table.name, projectId: projectA),
            0,
            reason: '${table.name} still holds rows of the destroyed project',
          );
        }
        expect(await count('sync_cursors', projectId: projectA), 0);
        expect(await count('tombstone_purge_floor', projectId: projectA), 0);
        expect(await count('project_join_settings', projectId: projectA), 0);
        expect(await count('project_join_requests', projectId: projectA), 0);
      },
    );

    test('"gone" leaves other projects, people and the audit log', () async {
      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      await serviceAt(scheduledOn.add(const Duration(days: 31))).destroyDue();

      expect(await projectExists(projectB), isTrue);
      expect(await count(Tables.observations, projectId: projectB), 1);
      expect(await count(Tables.projectMemberships, projectId: projectB), 1);
      // People are not project data.
      expect(await count(Tables.users), 2);
      // Michael, 2026-09-20: the audit log is out of scope of "gone".
      expect(await count('auth_audit_log'), 1);
    });

    test('a destroyed id stays refused', () async {
      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      await serviceAt(scheduledOn.add(const Duration(days: 31))).destroyDue();
      final service = serviceAt(scheduledOn.add(const Duration(days: 40)));
      expect(await service.wasDestroyed(projectA), isTrue);
      expect(await service.wasDestroyed(projectB), isFalse);
      // The record survives its own subject, with the moment it ran.
      final standing = await service.standingFor(projectA);
      expect(standing.executedAt, scheduledOn.add(const Duration(days: 31)));
      expect(standing.isScheduled, isFalse);
      // And a cancel cannot un-destroy it.
      final afterCancel = await service.cancel(projectA);
      expect(afterCancel.executedAt, isNotNull);
    });

    test(
      'an owner\'s cancel or restore that commits after the sweep read its '
      'list is honored — the sweep re-reads the schedule under a lock '
      '(task 11.302)',
      () async {
        await serviceAt(
          scheduledOn,
        ).schedule(projectId: projectA, scheduledBy: alice);

        // A second connection plays the owner: it withdraws the schedule
        // (what both *cancel* and *restore* do first) and has not committed
        // yet when the sweep starts. The sweep's list is read without a
        // lock, so it still sees project A as due.
        final owner = await Connection.open(
          testDatabaseConfig!.endpoint,
          settings: const ConnectionSettings(sslMode: SslMode.disable),
        );
        addTearDown(owner.close);
        await owner.execute('SET search_path TO $testSchema');
        await owner.execute('BEGIN');
        await owner.execute(
          r'DELETE FROM project_destruction WHERE project_id = $1 '
          'AND executed_at IS NULL',
          parameters: [projectA],
        );

        final sweep = serviceAt(
          scheduledOn.add(const Duration(days: 31)),
        ).destroyDue();
        // Long enough for the sweep to read its list and reach project A;
        // it cannot finish while the owner holds the row.
        await Future<void>.delayed(const Duration(milliseconds: 300));
        await owner.execute('COMMIT');

        final result = await sweep;
        expect(
          result.projectsDestroyed,
          0,
          reason: 'the owner withdrew the schedule; destroying the project '
              'anyway would destroy one its owner was just told was saved',
        );
        expect(await projectExists(projectA), isTrue);
        expect(await count(Tables.observations, projectId: projectA), 2);
      },
    );

    test('runs each due project on its own, in date order', () async {
      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectB, scheduledBy: bob);
      await serviceAt(
        scheduledOn.add(const Duration(days: 1)),
      ).schedule(projectId: projectA, scheduledBy: alice);
      final sweep = await serviceAt(
        scheduledOn.add(const Duration(days: 45)),
      ).destroyDue();
      expect(sweep.destroyedProjectIds, [projectB, projectA]);
      expect(await projectExists(projectA), isFalse);
      expect(await projectExists(projectB), isFalse);
    });
  });

  group('immediate', skip: databaseSkipReason, () {
    test('destroys inside the caller\'s transaction and records it', () async {
      final rows = await connection.runTx(
        (tx) => ProjectDestructionService(
          tx,
          policy: policy,
          clock: () => scheduledOn,
        ).destroy(projectId: projectA, scheduledBy: alice),
      );
      expect(rows, greaterThan(0));
      expect(await projectExists(projectA), isFalse);
      final standing = await serviceAt(scheduledOn).standingFor(projectA);
      expect(standing.executedAt, scheduledOn);
      expect(standing.destroyAt, scheduledOn);
    });
  });

  group('the measurement', skip: databaseSkipReason, () {
    test('reads the rows: nothing scheduled, waiting, overdue', () async {
      final none = await serviceAt(scheduledOn).measure();
      expect(none.scheduled, 0);
      expect(none.overdue, 0);
      expect(none.mostOverdueBy, isNull);

      await serviceAt(
        scheduledOn,
      ).schedule(projectId: projectA, scheduledBy: alice);
      final waiting = await serviceAt(
        scheduledOn.add(const Duration(days: 10)),
      ).measure();
      expect(waiting.scheduled, 1);
      expect(waiting.overdue, 0);

      // The loop did not run: the date passed three days ago.
      final overdue = await serviceAt(
        scheduledOn.add(const Duration(days: 33)),
      ).measure();
      expect(overdue.scheduled, 0);
      expect(overdue.overdue, 1);
      expect(overdue.mostOverdueBy, const Duration(days: 3));

      // Once it has run, the promise is kept and the reading says so.
      await serviceAt(scheduledOn.add(const Duration(days: 33))).destroyDue();
      final kept = await serviceAt(
        scheduledOn.add(const Duration(days: 33)),
      ).measure();
      expect(kept.overdue, 0);
    });
  });

  group('the policy', () {
    test('reads the explicit grace, then the backup keep count, then 30', () {
      expect(
        ProjectDeletionPolicy.fromEnvironment({
          'TRITRACK_PROJECT_DELETION_GRACE_DAYS': '7',
          'TRITRACK_BACKUP_KEEP': '30',
        }).graceDays,
        7,
      );
      expect(
        ProjectDeletionPolicy.fromEnvironment({
          'TRITRACK_PROJECT_DELETION_GRACE_DAYS': '',
          'TRITRACK_BACKUP_KEEP': '14',
        }).graceDays,
        14,
      );
      expect(ProjectDeletionPolicy.fromEnvironment({}).graceDays, 30);
      // The backup number travels separately: a seven-day grace on a server
      // keeping ninety archives must tell the owner ninety, not seven.
      final split = ProjectDeletionPolicy.fromEnvironment({
        'TRITRACK_PROJECT_DELETION_GRACE_DAYS': '7',
        'TRITRACK_BACKUP_KEEP': '90',
      });
      expect(split.graceDays, 7);
      expect(split.backupRetentionDays, 90);
      // Zero is a real answer — "no grace" — not a blank.
      expect(
        ProjectDeletionPolicy.fromEnvironment({
          'TRITRACK_PROJECT_DELETION_GRACE_DAYS': '0',
        }).graceDays,
        0,
      );
    });
  });
}

/// Two people, two projects, and rows in every kind of table the destroy
/// walks: an observation, a tag with a version, an animal on a deployment, a
/// membership, plus the server's own cursor, purge floor, join settings and
/// join request for project A — and one audit row, which must survive.
Future<void> _seed(Connection connection) async {
  final at = DateTime.utc(2026, 8, 1, 12);
  await connection.runTx((tx) async {
    for (final (id, first, email) in [
      ('user-alice', 'Alice', 'alice@example.com'),
      ('user-bob', 'Bob', 'bob@example.com'),
    ]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision) '
        r'VALUES ($1, $2, $3, $4, $5, $5, 0)',
        parameters: [id, first, 'Ranger', email, at],
      );
    }
    for (final (projectId, owner) in [
      ('proj-a', 'user-alice'),
      ('proj-b', 'user-bob'),
    ]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ($1, 'Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
        parameters: [projectId, owner, at],
      );
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, role, created_at, '
        'updated_at, revision) '
        r"VALUES ($1, $2, $3, $4, 'owner', $4, $4, 0)",
        parameters: ['mem-$projectId', projectId, owner, at],
      );
    }
    for (final (id, projectId, user) in [
      ('obs-1', 'proj-a', 'user-alice'),
      ('obs-2', 'proj-a', 'user-alice'),
      ('obs-3', 'proj-b', 'user-bob'),
    ]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.observations)} '
        '(observation_id, project_id, user_id, timestamp_local, '
        'timestamp_utc, timezone_offset, latitude, longitude, '
        'position_source, elevation, altitude_agl, observation_type, '
        'signal_type, signal_strength, created_at, updated_at, revision) '
        r"VALUES ($1, $2, $3, $4, $4, '+00:00', 35.19, -111.65, 'gps_fix', "
        r"2100.0, 0.0, 'directional', 'regular_pulse', 'strong', $4, $4, 1)",
        parameters: [id, projectId, user, at],
      );
    }
    // A tag with a version, and an animal wearing it, in project A.
    await tx.execute(
      'INSERT INTO ${quoted(Tables.tags)} '
      '(tag_id, project_id, frequency_mhz, tag_name, status, lineage_id, '
      'created_at, updated_at, revision) '
      r"VALUES ($1, $2, 160.321, 'Marie', 'active', $1, $3, $3, 0)",
      parameters: ['tag-1', 'proj-a', at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.tagVersions)} '
      '(tag_version_id, project_id, tag_id, effective_from, frequency_mhz, '
      "tag_name, created_at, updated_at, revision) "
      r"VALUES ($1, $2, $3, $4, 160.321, 'Marie', $4, $4, 0)",
      parameters: ['tv-1', 'proj-a', 'tag-1', at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.individuals)} '
      '(individual_id, project_id, name, color_hex, status, lineage_id, '
      'created_at, updated_at, revision) '
      r"VALUES ($1, $2, 'Marie', '#1F77B4', 'active', $1, $3, $3, 0)",
      parameters: ['ind-1', 'proj-a', at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.deployments)} '
      '(deployment_id, project_id, tag_id, individual_id, attached_date, '
      'created_at, updated_at, revision) '
      r'VALUES ($1, $2, $3, $4, $5, $5, $5, 0)',
      parameters: ['dep-1', 'proj-a', 'tag-1', 'ind-1', at],
    );
    // The server's own bookkeeping for project A.
    await tx.execute(
      'INSERT INTO sync_cursors '
      '(user_id, device_id, project_id, acknowledged_seq, last_synced_at) '
      r"VALUES ('user-alice', 'phone', 'proj-a', 5, $1)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO tombstone_purge_floor (project_id, purged_through_seq) '
      "VALUES ('proj-a', 1)",
    );
    await tx.execute(
      'INSERT INTO project_join_settings (project_id, code, joining_enabled) '
      "VALUES ('proj-a', 'ABCDEFGH', TRUE)",
    );
    await tx.execute(
      'INSERT INTO project_join_requests '
      '(request_id, project_id, user_id, email) '
      "VALUES ('req-1', 'proj-a', 'user-bob', 'bob@example.com')",
    );
    await AuthAuditLog(
      tx,
      onError: (type) => throw StateError('audit write failed: $type'),
    ).record(
      AuthAuditEvent.joinApproved,
      userId: 'user-bob',
      outcome: 'proj-a',
    );
  });
}
