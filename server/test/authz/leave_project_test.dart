@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.28 part 1: leaving a project, and eighteen ways of not doing it.**
///
/// `Project_Memberships` is [MutationRule.projectOwner] — the row *is* somebody's
/// rights, so an owner writes it and nobody else. Task 11.28 adds one exception:
/// a person may set `end_date` on their own currently-open row. This file is
/// that exception under attack.
///
/// **The shape of the mistake it is looking for**, named in the task brief and
/// found on this exact surface by task 11.9's eighteen probes, is an exception
/// that *also* permits ending somebody else's membership — or that permits
/// ending your own while quietly carrying something else along in the same row.
/// So the permitting tests are three and the refusing tests are the rest, and
/// each refusal names the column or the condition it turns on.
///
/// Every push here is one the client would never send: the app's own
/// `ProjectMembershipRepository.leaveProject` cannot express most of them,
/// because it takes a project and an actor and finds the row itself. That is
/// exactly why they are tested here — the client's narrowness is a property of
/// the app, and the boundary has to hold against a device that does not have it.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_leave_project_test';

  const alice = 'user-alice'; // owner of projectA
  const bob = 'user-bob'; // contributor on projectA
  const cara = 'user-cara'; // viewer on projectA
  const projectA = 'proj-a';
  const at = '2026-08-01T12:00:00.000Z';
  const later = '2026-08-20T09:00:00.000Z';

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
      for (final (id, name, email) in [
        (alice, 'Alice', 'alice@example.com'),
        (bob, 'Bob', 'bob@example.com'),
        (cara, 'Cara', 'cara@example.com'),
      ]) {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.users)} '
          '(user_id, first_name, last_name, email, created_at, updated_at, '
          'revision) '
          r'VALUES ($1, $2, $3, $4, $5, $5, 0)',
          parameters: [id, name, 'Ranger', email, at],
        );
        await tx.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r'VALUES ($1, $2, $3)',
          parameters: [id, email, at],
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

  /// The membership row as the server holds it, in wire shape.
  ///
  /// Built the way the client builds a push row — every declared column,
  /// string timestamps — so a test can change exactly one field and push the
  /// result. `revision` is bumped by the caller because a write that does not
  /// move the clock is a no-op the merge refuses before authorization runs,
  /// and a no-op proves nothing about permission.
  Map<String, Object?> membershipRow({
    required String userId,
    required String role,
    String? endDate,
    int revision = 0,
    String? modifiedBy,
    String membershipId = '',
    String projectId = projectA,
  }) => {
    'membership_id': membershipId.isEmpty ? 'mem-$userId' : membershipId,
    'project_id': projectId,
    'user_id': userId,
    'join_date': at,
    'end_date': endDate,
    'role': role,
    'created_at': at,
    'updated_at': endDate == null ? at : later,
    'deleted_at': null,
    'revision': revision,
    'last_modified_by': modifiedBy ?? userId,
    'origin_device_id': 'device-$userId',
  };

  Future<void> seedMembership({
    required String userId,
    required String role,
    String? membershipId,
  }) async {
    final row = membershipRow(
      userId: userId,
      role: role,
      membershipId: membershipId ?? '',
    );
    await connection.execute(
      'INSERT INTO ${quoted(Tables.projectMemberships)} '
      '(membership_id, project_id, user_id, join_date, end_date, role, '
      'created_at, updated_at, deleted_at, revision, last_modified_by, '
      'origin_device_id) '
      r'VALUES ($1, $2, $3, $4, NULL, $5, $6, $6, NULL, 0, $3, $7)',
      parameters: [
        row['membership_id'],
        projectA,
        userId,
        at,
        role,
        at,
        row['origin_device_id'],
      ],
    );
  }

  Future<PushResult> pushAs(
    String userId,
    List<Map<String, Object?>> rows, {
    String projectId = projectA,
  }) => connection.runTx((tx) async {
    final access = await ProjectAuthorizer.resolve(
      tx,
      projectId: projectId,
      userId: userId,
    );
    return SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: {Tables.projectMemberships: rows},
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: access,
      ),
    );
  });

  SyncRowOutcome? outcomeFor(PushResult result, String membershipId) =>
      result.outcomes['${Tables.projectMemberships}/$membershipId/$projectA'];

  /// The stored `end_date`, or null. The assertion that actually matters:
  /// an outcome map says what the server *decided*, and this says what it did.
  Future<Object?> storedEndDate(String membershipId) async {
    final result = await connection.execute(
      'SELECT end_date FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE membership_id = $1 AND project_id = $2',
      parameters: [membershipId, projectA],
    );
    return result.isEmpty ? null : result.first.first;
  }

  Future<Object?> storedRole(String membershipId) async {
    final result = await connection.execute(
      'SELECT role FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE membership_id = $1 AND project_id = $2',
      parameters: [membershipId, projectA],
    );
    return result.isEmpty ? null : result.first.first;
  }

  group('a person may leave', skip: databaseSkipReason, () {
    setUp(() async {
      if (testDatabaseConfig == null) return;
      await seedMembership(userId: alice, role: 'owner');
      await seedMembership(userId: bob, role: 'contributor');
      await seedMembership(userId: cara, role: 'viewer');
    });

    test('a contributor ends their own membership', () async {
      final result = await pushAs(bob, [
        membershipRow(
          userId: bob,
          role: 'contributor',
          endDate: later,
          revision: 1,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.updated);
      expect(await storedEndDate('mem-$bob'), isNotNull);
    });

    test('a viewer ends their own membership', () async {
      // The rung that matters most. A `viewer` writes nothing in a project —
      // `RowAuthorizer._authorizeRole` refuses every project-scoped row before
      // the rule table is consulted — so without an explicit exception the
      // person least able to contribute would also be the one person who could
      // never get off the project.
      final result = await pushAs(cara, [
        membershipRow(
          userId: cara,
          role: 'viewer',
          endDate: later,
          revision: 1,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$cara'), SyncRowOutcome.updated);
      expect(await storedEndDate('mem-$cara'), isNotNull);
    });

    test('an owner leaves while another owner remains', () async {
      // Promote Cara's existing row rather than opening a second one for her:
      // `idx_memberships_one_open` (task 11.10) refuses two open rows for one
      // (project, user) pair, which is the same invariant a real promotion
      // honours by updating in place.
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r"SET role = 'owner' WHERE membership_id = $1",
        parameters: ['mem-$cara'],
      );
      final result = await pushAs(alice, [
        membershipRow(userId: alice, role: 'owner', endDate: later,
            revision: 1),
      ]);
      expect(outcomeFor(result, 'mem-$alice'), SyncRowOutcome.updated);
      expect(await storedEndDate('mem-$alice'), isNotNull);
    });

    test('a viewer still cannot write anything else in the project', () async {
      // The exception must not become a general one. Same caller, same push
      // shape, one table over — and `Tag_Versions` is the newest project-scoped
      // table, so this also checks the exception did not widen by table.
      final result = await connection.runTx((tx) async {
        final access = await ProjectAuthorizer.resolve(
          tx,
          projectId: projectA,
          userId: cara,
        );
        return SyncService(session: tx).applyPush(
          projectId: projectA,
          rows: {
            Tables.triangulationSessions: [
              {
                'session_id': 'sess-1',
                'project_id': projectA,
                'session_name': 'forged',
                'start_time': at,
                'created_at': at,
                'updated_at': at,
                'revision': 0,
                'last_modified_by': cara,
                'origin_device_id': 'device-$cara',
              },
            ],
          },
          authorizer: RowAuthorizer(
            session: tx,
            projectId: projectA,
            userId: cara,
            access: access,
          ),
        );
      });
      expect(
        result.outcomes['${Tables.triangulationSessions}/sess-1/$projectA'],
        SyncRowOutcome.unauthorized,
      );
    });
  });

  group('and may end nobody else', skip: databaseSkipReason, () {
    setUp(() async {
      if (testDatabaseConfig == null) return;
      await seedMembership(userId: alice, role: 'owner');
      await seedMembership(userId: bob, role: 'contributor');
      await seedMembership(userId: cara, role: 'viewer');
    });

    test("a contributor cannot end a colleague's membership", () async {
      // The mistake the task brief names: an exception that reads "a
      // membership row is being ended" instead of "*your* membership row is
      // being ended".
      final result = await pushAs(bob, [
        membershipRow(
          userId: cara,
          role: 'viewer',
          endDate: later,
          revision: 1,
          modifiedBy: bob,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$cara'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$cara'), isNull);
    });

    test("a contributor cannot end an owner's membership", () async {
      final result = await pushAs(bob, [
        membershipRow(
          userId: alice,
          role: 'owner',
          endDate: later,
          revision: 1,
          modifiedBy: bob,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$alice'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$alice'), isNull);
    });

    test('a viewer cannot end anybody', () async {
      final result = await pushAs(cara, [
        membershipRow(
          userId: bob,
          role: 'contributor',
          endDate: later,
          revision: 1,
          modifiedBy: cara,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test(
      'rewriting the row to name yourself does not make it yours',
      () async {
        // The takeover shape, aimed at the departure exception: claim Cara's
        // membership row is Bob's, then end it. The predicate reads the
        // **stored** `user_id`, so the claim is irrelevant — and the naming
        // invariant refuses the reattribution independently.
        final row = membershipRow(
          userId: bob,
          role: 'viewer',
          endDate: later,
          revision: 1,
        );
        row['membership_id'] = 'mem-$cara';
        final result = await pushAs(bob, [row]);
        expect(outcomeFor(result, 'mem-$cara'), SyncRowOutcome.unauthorized);
        expect(await storedEndDate('mem-$cara'), isNull);
      },
    );

    test('a stranger cannot end a member of a project they are not on',
        () async {
      // No membership at all, so `ProjectAuthorizer` answers `none` — the
      // exception never gets a chance to be wrong, and the route would have
      // refused the whole push before this. Asserted anyway: the exception is
      // one `||` away from the ownership rule, and "the layer above catches
      // it" is the reasoning that ages worst.
      await connection.execute(
        'DELETE FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE user_id = $1',
        parameters: [bob],
      );
      final result = await pushAs(bob, [
        membershipRow(
          userId: cara,
          role: 'viewer',
          endDate: later,
          revision: 1,
          modifiedBy: bob,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$cara'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$cara'), isNull);
    });
  });

  group('and may not carry anything else along', skip: databaseSkipReason, () {
    setUp(() async {
      if (testDatabaseConfig == null) return;
      await seedMembership(userId: alice, role: 'owner');
      await seedMembership(userId: bob, role: 'contributor');
    });

    test('leaving is not a promotion', () async {
      // The row is closed by the same write, so the forged `owner` would confer
      // nothing live — but it would make the project's own record say Bob was
      // an owner between two dates, which is what a permit report and a
      // publication read. Attribution, not privilege, and refused for the same
      // reason task 11.24 refused the other kind.
      final result = await pushAs(bob, [
        membershipRow(userId: bob, role: 'owner', endDate: later, revision: 1),
      ]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedRole('mem-$bob'), 'contributor');
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('leaving is not a tombstone', () async {
      // A closed stint is the record that somebody collected data on this
      // project between two dates. Erasing it is a different act from ending
      // it, and it stays owner-only.
      final row = membershipRow(
        userId: bob,
        role: 'contributor',
        endDate: later,
        revision: 1,
      );
      row['deleted_at'] = later;
      final result = await pushAs(bob, [row]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('a tombstone alone, with no end date, is not a departure', () async {
      final row = membershipRow(userId: bob, role: 'contributor', revision: 1);
      row['deleted_at'] = later;
      row['updated_at'] = later;
      final result = await pushAs(bob, [row]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
    });

    test('leaving cannot re-date the stint', () async {
      final row = membershipRow(
        userId: bob,
        role: 'contributor',
        endDate: later,
        revision: 1,
      );
      row['join_date'] = '2020-01-01T00:00:00.000Z';
      final result = await pushAs(bob, [row]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('leaving cannot rewrite created_at', () async {
      final row = membershipRow(
        userId: bob,
        role: 'contributor',
        endDate: later,
        revision: 1,
      );
      row['created_at'] = '2020-01-01T00:00:00.000Z';
      final result = await pushAs(bob, [row]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('a departure must name the caller as the one who did it', () async {
      // Task 11.24's rule, which the exception composes with rather than
      // replaces: the audit column is a claim about who performed *this*
      // change, and this change is the caller's.
      final result = await pushAs(bob, [
        membershipRow(
          userId: bob,
          role: 'contributor',
          endDate: later,
          revision: 1,
          modifiedBy: alice,
        ),
      ]);
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('an already-ended stint cannot be reopened', () async {
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1, revision = 1 WHERE membership_id = $2',
        parameters: [later, 'mem-$bob'],
      );
      final row = membershipRow(userId: bob, role: 'contributor', revision: 2);
      row['updated_at'] = '2026-08-21T09:00:00.000Z';
      final result = await pushAs(bob, [row]);
      // Rejoining is an approved join request, which the server authors itself. A
      // person who left must not be able to let themselves back in.
      expect(outcomeFor(result, 'mem-$bob'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$bob'), isNotNull);
    });

    test('a departure cannot be turned into a new grant', () async {
      // Leave, then insert a fresh open row for yourself as owner. The insert
      // path is unchanged by task 11.28 and still requires the caller to be a
      // current owner (`_authorizeGrantingInsert` condition 2), so the second
      // half is refused whether or not the first half succeeded.
      final leave = await pushAs(bob, [
        membershipRow(
          userId: bob,
          role: 'contributor',
          endDate: later,
          revision: 1,
        ),
      ]);
      expect(outcomeFor(leave, 'mem-$bob'), SyncRowOutcome.updated);

      final result = await pushAs(bob, [
        membershipRow(
          userId: bob,
          role: 'owner',
          membershipId: 'mem-bob-2',
          revision: 0,
        ),
      ]);
      expect(outcomeFor(result, 'mem-bob-2'), SyncRowOutcome.unauthorized);
    });

    test('a departure cannot move the row to another project', () async {
      // Belt and braces: the cross-project claim check refuses this before the
      // exception is reached, and the immutable-column rule would refuse it
      // after. Both are asserted because the first one is documented as
      // unreachable-but-kept, and an unreachable check is one refactor from
      // being the only one.
      final row = membershipRow(
        userId: bob,
        role: 'contributor',
        endDate: later,
        revision: 1,
        projectId: 'proj-elsewhere',
      );
      final result = await pushAs(bob, [row]);
      expect(
        result.outcomes['${Tables.projectMemberships}/mem-$bob/proj-elsewhere'],
        SyncRowOutcome.unauthorized,
      );
      expect(await storedEndDate('mem-$bob'), isNull);
    });

    test('a malformed end date is not a departure', () async {
      final row = membershipRow(
        userId: bob,
        role: 'contributor',
        endDate: later,
        revision: 1,
      );
      row['end_date'] = 12345;
      final result = await pushAs(bob, [row]);
      expect(outcomeFor(result, 'mem-$bob'), isNot(SyncRowOutcome.updated));
      expect(await storedEndDate('mem-$bob'), isNull);
    });
  });

  group('and cannot empty a project of owners', skip: databaseSkipReason, () {
    setUp(() async {
      if (testDatabaseConfig == null) return;
      await seedMembership(userId: alice, role: 'owner');
      await seedMembership(userId: bob, role: 'contributor');
    });

    test('the last owner cannot leave', () async {
      // The rule task 11.9 verified, now reachable by a second route. A
      // project with no owner has nobody who can add one, change its settings
      // or hand it on, and on a laptop server there is no operator to appeal
      // to.
      final result = await pushAs(alice, [
        membershipRow(userId: alice, role: 'owner', endDate: later,
            revision: 1),
      ]);
      expect(outcomeFor(result, 'mem-$alice'), SyncRowOutcome.unauthorized);
      expect(await storedEndDate('mem-$alice'), isNull);
    });

    test('two owners leaving in one push: the second is refused', () async {
      // 11.9's batch case, now with departures rather than removals. One push
      // has one caller, so the two rows cannot both be self-departures — the
      // first is Alice leaving, the second is Alice removing Cara, which she
      // may do as an owner. The `_ownershipsRemovedThisPush` bookkeeping is
      // what stops the pair from vouching for each other.
      await seedMembership(
        userId: cara,
        role: 'owner',
        membershipId: 'mem-cara-owner',
      );
      final result = await pushAs(alice, [
        membershipRow(userId: alice, role: 'owner', endDate: later,
            revision: 1),
        membershipRow(
          userId: cara,
          role: 'owner',
          endDate: later,
          revision: 1,
          membershipId: 'mem-cara-owner',
          modifiedBy: alice,
        ),
      ]);
      final outcomes = [
        outcomeFor(result, 'mem-$alice'),
        outcomeFor(result, 'mem-cara-owner'),
      ];
      expect(outcomes.where((o) => o == SyncRowOutcome.updated), hasLength(1));
      expect(
        outcomes.where((o) => o == SyncRowOutcome.unauthorized),
        hasLength(1),
      );
      // And whichever way round it landed, somebody still owns the project.
      final owners = await connection.execute(
        'SELECT COUNT(*) FROM ${quoted(Tables.projectMemberships)} '
        r"WHERE project_id = $1 AND role = 'owner' AND end_date IS NULL "
        'AND deleted_at IS NULL',
        parameters: [projectA],
      );
      expect(owners.first.first, 1);
    });
  });

  group('the exception is declared against the schema', () {
    test('every mutable column exists on Project_Memberships', () {
      assertDepartureColumnsExist();
    });

    test('the guard fires on a column that does not exist', () {
      // The check has to have been made to fail once, or it is not known to
      // work — the same rule `assertEveryGlobalTableDeclaresItsScope` and task
      // 11.25's structural guards follow.
      expect(
        () => assertDepartureColumnsExist(
          mutableColumns: const {'end_date', 'not_a_column'},
        ),
        throwsA(isA<StateError>()),
      );
    });

    test('a new column lands on the immutable side by default', () {
      // The direction that matters. Every column of the table that is not
      // explicitly declared mutable must be one a departure may not touch, so
      // adding a column to this table cannot silently widen what leaving does.
      final declared = tableSpecsByName[Tables.projectMemberships]!.columnNames
          .toSet();
      expect(
        departureImmutableColumns,
        declared.difference(departureMutableColumns),
      );
      expect(departureImmutableColumns, contains('role'));
      expect(departureImmutableColumns, contains('deleted_at'));
      expect(departureImmutableColumns, contains('user_id'));
    });
  });
}
