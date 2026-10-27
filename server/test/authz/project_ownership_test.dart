@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.1 — co-equal owners and ownership transfer, server-side.**
///
/// Task 8.4 anchored the `owner` rule to `Projects.owner_user_id` on the
/// explicit grounds that with no transfer feature the column and
/// `Project_Memberships` could not diverge. They can now. Enforcement is the
/// project's open `role='owner'` membership rows, resolved by the shared
/// [resolveProjectOwners] so that this server and every client answer the
/// question with one function rather than two implementations.
///
/// The membership rows here are seeded in SQL rather than pushed. That is not
/// a shortcut around the boundary: task 10.20's row-naming invariant refuses a
/// membership row naming anyone but the caller, deliberately, and task 11.2's
/// invitation record is the provenance meant to reopen it. Until then, an
/// owner grant reaches the server the way these rows do.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_ownership_test';

  const alice = 'user-alice'; // creator of proj-a
  const bob = 'user-bob'; // granted co-equal owner of proj-a
  const carol = 'user-carol'; // contributor on proj-a, never an owner
  const projectA = 'proj-a';

  const at = '2026-08-20T00:00:00.000Z';

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
    await connection.runTx((tx) async {
      for (final (id, name) in [
        (alice, 'Alice'),
        (bob, 'Bob'),
        (carol, 'Carol'),
      ]) {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.users)} '
          '(user_id, first_name, last_name, email, created_at, updated_at, '
          'revision) '
          r'VALUES ($1, $2, $3, $4, $5, $5, 0)',
          parameters: [id, name, 'Ranger', '$id@example.org', at],
        );
        await tx.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r'VALUES ($1, $2, $3)',
          parameters: [id, '$id@example.org', at],
        );
      }
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ($1, 'Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
        parameters: [projectA, alice, at],
      );
    });
  });

  /// Seeds one membership row directly. [endDate] closes the stint.
  Future<void> seedMembership(
    String membershipId, {
    required String userId,
    String role = 'owner',
    String? endDate,
    String? deletedAt,
  }) => connection.execute(
    'INSERT INTO ${quoted(Tables.projectMemberships)} '
    '(membership_id, project_id, user_id, join_date, end_date, role, '
    'created_at, updated_at, deleted_at, revision, last_modified_by, '
    'origin_device_id) '
    r'VALUES ($1, $2, $3, $4, $5, $6, $4, $4, $7, 0, $3, $8)',
    parameters: [
      membershipId,
      projectA,
      userId,
      at,
      endDate,
      role,
      deletedAt,
      'device-A',
    ],
  );

  Map<String, Object?> membershipRow(
    String membershipId, {
    required String userId,
    required String modifiedBy,
    String role = 'owner',
    String? endDate,
    int revision = 1,
  }) => {
    'membership_id': membershipId,
    'project_id': projectA,
    'user_id': userId,
    'join_date': at,
    'end_date': endDate,
    'role': role,
    'created_at': at,
    'updated_at': '2026-08-21T00:00:00.000Z',
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-A',
  };

  /// [modifiedBy] must be the pusher: task 10.20's naming invariant refuses an
  /// update that changes who a row names, and `last_modified_by` is one of
  /// those names. Passing it explicitly keeps every refusal below attributable
  /// to the ownership rule rather than to a fixture that forged an audit
  /// column.
  Map<String, Object?> projectRow({
    required String name,
    required String modifiedBy,
  }) => {
    'project_id': projectA,
    'project_name': name,
    'owner_user_id': alice,
    'creation_date': at,
    'datum': 'WGS84',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
    'created_at': at,
    'updated_at': '2026-08-21T00:00:00.000Z',
    'revision': 1,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-A',
  };

  Future<PushResult> pushAs(String userId, SyncRows rows) =>
      connection.runTx((tx) async {
        final access = await ProjectAuthorizer.resolve(
          tx,
          projectId: projectA,
          userId: userId,
        );
        return SyncService(session: tx).applyPush(
          projectId: projectA,
          rows: rows,
          authorizer: RowAuthorizer(
            session: tx,
            projectId: projectA,
            userId: userId,
            access: access,
          ),
        );
      });

  Future<ProjectAccess> accessOf(String userId) => connection.runTx(
    (tx) =>
        ProjectAuthorizer.resolve(tx, projectId: projectA, userId: userId),
  );

  Future<String?> storedEndDate(String membershipId) async {
    final result = await connection.execute(
      'SELECT end_date FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE membership_id = $1',
      parameters: [membershipId],
    );
    return result.isEmpty ? null : result.first.first?.toString();
  }

  Future<String?> storedProjectName() async {
    final result = await connection.execute(
      'SELECT project_name FROM ${quoted(Tables.projects)} '
      r'WHERE project_id = $1',
      parameters: [projectA],
    );
    return result.first.first as String?;
  }

  group('project access', skip: databaseSkipReason, () {
    test('with no membership rows the creator column still answers', () async {
      // The bootstrap fallback, and the reason 488 pre-11.1 server tests still
      // pass unchanged: their fixture seeds projects with no memberships at
      // all, exactly like a project created before task 8.4 or one mid-publish.
      expect(await accessOf(alice), ProjectAccess.owner);
      expect(await accessOf(bob), ProjectAccess.none);
    });

    test('co-equal owners both resolve as owner', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-bob', userId: bob);
      expect(await accessOf(alice), ProjectAccess.owner);
      expect(await accessOf(bob), ProjectAccess.owner);
    });

    test('a creator who transferred the project away is no longer an owner',
        () async {
      // `Projects.owner_user_id` still names Alice — 11.1 keeps it as the
      // creator/audit record. It no longer decides.
      await seedMembership('m-alice', userId: alice, endDate: at);
      await seedMembership('m-bob', userId: bob);
      expect(await accessOf(alice), ProjectAccess.none);
      expect(await accessOf(bob), ProjectAccess.owner);
    });

    test('a contributor is a member, not an owner', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-carol', userId: carol, role: 'contributor');
      expect(await accessOf(carol), ProjectAccess.contributor);
    });

    test('a tombstoned membership grants nothing', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-carol', userId: carol, deletedAt: at);
      expect(await accessOf(carol), ProjectAccess.none);
    });
  });

  group('the owner rule over Projects rows', skip: databaseSkipReason, () {
    setUp(() async {
      if (testDatabaseConfig == null) return;
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-bob', userId: bob);
      await seedMembership('m-carol', userId: carol, role: 'contributor');
    });

    test('a co-equal owner may rewrite the project row', () async {
      final result = await pushAs(bob, {
        Tables.projects: [projectRow(name: 'Renamed by Bob', modifiedBy: bob)],
      });
      expect(
        result.outcomes['${Tables.projects}/$projectA'],
        SyncRowOutcome.updated,
      );
      expect(await storedProjectName(), 'Renamed by Bob');
    });

    test('a contributor may not', () async {
      final result = await pushAs(carol, {
        Tables.projects: [projectRow(name: 'Renamed by Carol', modifiedBy: carol)],
      });
      expect(
        result.outcomes['${Tables.projects}/$projectA'],
        SyncRowOutcome.unauthorized,
      );
      expect(await storedProjectName(), 'Field');
    });

    test('a departed creator may not, though the column still names them',
        () async {
      // The assertion Phase 8's rule could not have made: Alice is
      // `owner_user_id`, is still a member (demoted to contributor on the way
      // out), and must be refused anyway.
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r"SET role = 'contributor' WHERE membership_id = 'm-alice'",
      );
      final result = await pushAs(alice, {
        Tables.projects: [projectRow(name: 'Renamed by the ex-owner', modifiedBy: alice)],
      });
      expect(
        result.outcomes['${Tables.projects}/$projectA'],
        SyncRowOutcome.unauthorized,
      );
      expect(await storedProjectName(), 'Field');
    });
  });

  group('the projectOwner rule over membership rows', skip: databaseSkipReason,
      () {
    test('a co-equal owner may change another member\'s role', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-bob', userId: bob);
      await seedMembership('m-carol', userId: carol, role: 'contributor');

      final result = await pushAs(bob, {
        Tables.projectMemberships: [
          membershipRow(
            'm-carol',
            userId: carol,
            modifiedBy: bob,
            role: 'viewer',
          ),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-carol/$projectA'],
        SyncRowOutcome.updated,
      );
    });

    test('a contributor may not promote themselves', () async {
      // Task 8.4's original reason for the rule, re-proven under 11.1's
      // resolution: the answer must not change because the lookup did.
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-carol', userId: carol, role: 'contributor');

      final result = await pushAs(carol, {
        Tables.projectMemberships: [
          membershipRow(
            'm-carol',
            userId: carol,
            modifiedBy: carol,
            role: 'owner',
          ),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-carol/$projectA'],
        SyncRowOutcome.unauthorized,
      );
    });
  });

  group('the last-owner guard', skip: databaseSkipReason, () {
    test('the only owner cannot end their own membership', () async {
      await seedMembership('m-alice', userId: alice);
      final result = await pushAs(alice, {
        Tables.projectMemberships: [
          membershipRow('m-alice', userId: alice, modifiedBy: alice,
              endDate: '2026-08-21T00:00:00.000Z'),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-alice/$projectA'],
        SyncRowOutcome.unauthorized,
      );
      expect(await storedEndDate('m-alice'), isNull);
    });

    test('nor demote themselves out of ownership', () async {
      // Same hole, one column over. The guard keys on what confers ownership,
      // not on which field the push happened to change.
      await seedMembership('m-alice', userId: alice);
      final result = await pushAs(alice, {
        Tables.projectMemberships: [
          membershipRow('m-alice', userId: alice, modifiedBy: alice,
              role: 'contributor'),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-alice/$projectA'],
        SyncRowOutcome.unauthorized,
      );
    });

    test('with a second owner, the first may leave', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-bob', userId: bob);
      final result = await pushAs(alice, {
        Tables.projectMemberships: [
          membershipRow('m-alice', userId: alice, modifiedBy: alice,
              endDate: '2026-08-21T00:00:00.000Z'),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-alice/$projectA'],
        SyncRowOutcome.updated,
      );
      expect(await accessOf(alice), ProjectAccess.none);
      expect(await accessOf(bob), ProjectAccess.owner);
    });

    test('two owners cannot both leave in one push', () async {
      // The case only the server can catch: two devices, each ending a
      // different owner membership while offline. Each is legitimate alone.
      // A push authorizes every row before writing any of them, so without
      // within-push bookkeeping both would see the other still open.
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-bob', userId: bob);
      final result = await pushAs(alice, {
        Tables.projectMemberships: [
          membershipRow('m-alice', userId: alice, modifiedBy: alice,
              endDate: '2026-08-21T00:00:00.000Z'),
          membershipRow('m-bob', userId: bob, modifiedBy: alice,
              endDate: '2026-08-21T00:00:00.000Z'),
        ],
      });
      final outcomes = [
        result.outcomes['${Tables.projectMemberships}/m-alice/$projectA'],
        result.outcomes['${Tables.projectMemberships}/m-bob/$projectA'],
      ];
      expect(outcomes.where((o) => o == SyncRowOutcome.updated), hasLength(1));
      expect(
        outcomes.where((o) => o == SyncRowOutcome.unauthorized),
        hasLength(1),
      );
      // And the project still has an owner, which is the property that matters.
      expect(await accessOf(alice) == ProjectAccess.owner ||
          await accessOf(bob) == ProjectAccess.owner, isTrue);
    });

    test('ending a contributor membership is never guarded', () async {
      await seedMembership('m-alice', userId: alice);
      await seedMembership('m-carol', userId: carol, role: 'contributor');
      final result = await pushAs(alice, {
        Tables.projectMemberships: [
          membershipRow('m-carol', userId: carol, modifiedBy: alice,
              role: 'contributor', endDate: '2026-08-21T00:00:00.000Z'),
        ],
      });
      expect(
        result.outcomes['${Tables.projectMemberships}/m-carol/$projectA'],
        SyncRowOutcome.updated,
      );
    });
  });
}
