@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 10.10's acceptance criteria, against real Postgres.
///
/// Two users, each owning one project, is the whole fixture — which is the
/// point: cross-project isolation is fully testable in Phase 10 without teams,
/// and it is what Security Gate B checks.
///
/// Every test here crafts a request the *client* would never send. That is the
/// distinction the task turns on: Phase 8's rules run in the app and are
/// advisory UX, so the only meaningful test of the server's rules is one that
/// bypasses the client entirely.
/// The outcome for the row `table`/[id] names, whichever project it was pushed
/// under.
///
/// Since task 10.35 the protocol keys a row by every primary-key column
/// joined — `(<id>, project_id)` for the six project-scoped data tables — so an
/// outcome key now carries a project segment. These tests address rows by id,
/// because the id is what each test is *about*; this resolves the rest.
///
/// It throws rather than picking one if the id is ambiguous, so a test that
/// deliberately pushes the same id into two projects (several below do) cannot
/// silently read the wrong project's outcome. Where the project matters to the
/// assertion, pass it explicitly.
SyncRowOutcome? outcomeFor(
  PushResult result,
  String table,
  String id, {
  String? project,
}) {
  if (project != null) return result.outcomes['$table/$id/$project'];
  final exact = result.outcomes['$table/$id'];
  if (exact != null) return exact;
  final matches = result.outcomes.keys
      .where((key) => key.startsWith('$table/$id/'))
      .toList();
  if (matches.isEmpty) return null;
  if (matches.length > 1) {
    throw StateError(
      'ambiguous outcome for $table/$id across projects: $matches — '
      'pass `project:` to say which one is meant',
    );
  }
  return result.outcomes[matches.single];
}

void main() {
  late Connection connection;
  const testSchema = 'tritrack_authz_test';

  const alice = 'user-alice';
  const bob = 'user-bob';
  const projectA = 'proj-a'; // owned by alice
  const projectB = 'proj-b'; // owned by bob

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

  Map<String, Object?> observation(
    String id, {
    required String projectId,
    required String userId,
    int revision = 1,
    String? notes,
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': '2026-08-01T12:00:00.000Z',
    'timestamp_utc': '2026-08-01T12:00:00.000Z',
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'notes': notes,
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  /// A row of `Actual_Tag_Locations` — task 11.93's shape, `anyUser` but
  /// still naming somebody (who found the collar, in [finder]). Shared by
  /// both the naming-invariant group and the correction-behaviour group
  /// below, since both push it against the same tag.
  Map<String, Object?> truthPoint({
    String id = 'loc-11-93',
    required String finder,
    int revision = 1,
    double precision = 10.0,
    String modifiedBy = 'user-alice',
  }) => {
    'location_id': id,
    'project_id': 'proj-a',
    'tag_id': 'tag-11-93',
    'timestamp_local': '2026-08-01T12:00:00.000Z',
    'timestamp_utc': '2026-08-01T12:00:00.000Z',
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'uncertainty_radius': precision,
    'user_id': finder,
    'position_source': 'gps_fix',
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-0${revision + 1}T12:00:00.000Z',
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-A',
  };

  /// The collar [truthPoint] is about, pushed in the same batch so the
  /// reference resolves — `syncTables` orders `Tags` before
  /// `Actual_Tag_Locations`.
  ///
  /// Since task 11.219 the reference is composite, `(tag_id, project_id)`, so
  /// this row must claim the same project as the truth point that names it.
  List<Map<String, Object?>> theTag() => [
    {
      'tag_id': 'tag-11-93',
      'project_id': projectA,
      'lineage_id': 'tag-11-93',
      'frequency_mhz': 150.1,
      'tag_name': 'Coco',
      'status': 'active',
      'color_hex': '#FF0000',
      'created_at': '2026-08-01T12:00:00.000Z',
      'updated_at': '2026-08-01T12:00:00.000Z',
      'revision': 1,
      'last_modified_by': 'user-alice',
      'origin_device_id': 'device-A',
    },
  ];

  /// Pushes [rows] to [projectId] as [userId], resolving that caller's real
  /// project access the same way the route does.
  Future<PushResult> pushAs(
    String userId, {
    required String projectId,
    required SyncRows rows,
  }) => connection.runTx((tx) async {
    final access = await ProjectAuthorizer.resolve(
      tx,
      projectId: projectId,
      userId: userId,
    );
    return SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: rows,
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: access,
      ),
    );
  });

  Future<({SyncRows rows, int nextCursor, int remaining})> pull(
    String projectId, {
    int cursor = 0,
  }) => connection.runTx(
    (tx) => SyncService(
      session: tx,
    ).pull(projectId: projectId, cursor: cursor, batchSize: 500),
  );

  Future<String?> storedNotes(String observationId) async {
    final result = await connection.execute(
      'SELECT notes FROM ${quoted(Tables.observations)} '
      r'WHERE observation_id = $1',
      parameters: [observationId],
    );
    return result.isEmpty ? null : result.first.first as String?;
  }

  group('project-level access', skip: databaseSkipReason, () {
    test('a stranger has no access to a project they do not own', () async {
      final access = await connection.runTx(
        (tx) => ProjectAuthorizer.resolve(tx, projectId: projectA, userId: bob),
      );
      expect(access, ProjectAccess.none);
      expect(access.permitsSync, isFalse);
    });

    test('an owner has access', () async {
      final access = await connection.runTx(
        (tx) =>
            ProjectAuthorizer.resolve(tx, projectId: projectA, userId: alice),
      );
      expect(access, ProjectAccess.owner);
    });

    test('an unknown project is absent, and absent grants nothing', () async {
      // It used to grant sync, for the publish case — and that is what made a
      // fabricated project id answer 200-empty while a forbidden one answered
      // 403 (Gate C finding C-2). Publish is now permitted by the *shape of
      // the request* that establishes the project, in `createSyncRouter`, not
      // by the project's absence. See the existence-oracle group in
      // `test/integration/publish_and_join_test.dart`.
      final access = await connection.runTx(
        (tx) => ProjectAuthorizer.resolve(
          tx,
          projectId: 'never-published',
          userId: alice,
        ),
      );
      expect(access, ProjectAccess.absent);
      expect(
        access.permitsSync,
        isFalse,
        reason: 'absent must be indistinguishable from none at this layer',
      );
    });
  });

  group('cross-project isolation', skip: databaseSkipReason, () {
    test('a row claiming another project is refused', () async {
      // Alice pushes to her own project but labels the row with Bob's.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-x', projectId: projectB, userId: alice),
          ],
        },
      );
      expect(
        outcomeFor(result, Tables.observations, 'obs-x'),
        SyncRowOutcome.unauthorized,
      );
      expect(result.applied, 0);
    });

    test('reusing another project\'s row id creates a new row, and cannot '
        'touch theirs', () async {
      // **This assertion flipped in task 10.35, and the flip is the fix.**
      //
      // The shape is the same: Bob's existing observation id, pushed under
      // Alice's project. It used to be refused with `crossProjectCapture`,
      // because primary keys were global and Alice's push would otherwise have
      // *updated Bob's row* — moving it into her project.
      //
      // Keys are now `(observation_id, project_id)`, so Alice's push does not
      // address Bob's row at all. It addresses a row of her own that happens to
      // share an id, and inserting it is correct: that is exactly what happens
      // when someone saves a colleague's shared observation, which keeps the
      // sender's id by design (task 6.3) and lands in the receiver's project.
      // Refusing it was what made that workflow permanently unsyncable.
      //
      // The safety property is unchanged and is what this test now pins: Bob's
      // row does not move and does not change. It is enforced structurally now
      // rather than by a check — the server cannot see his row to write it —
      // which is strictly stronger than the check it replaced.
      await pushAs(
        bob,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation('obs-bob', projectId: projectB, userId: bob),
          ],
        },
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation(
              'obs-bob',
              projectId: projectA,
              userId: alice,
              revision: 99,
              notes: 'captured',
            ),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-bob', project: projectA),
        SyncRowOutcome.inserted,
      );

      // Bob's row: still his, still in his project, still unmodified. Checked
      // by addressing it with the *full* key, since the id alone now names two
      // rows — which is the whole point.
      final bobRow = await connection.execute(
        'SELECT project_id, user_id, notes, revision '
        'FROM ${quoted(Tables.observations)} '
        r"WHERE observation_id = 'obs-bob' AND project_id = "
        "'$projectB'",
      );
      expect(bobRow, hasLength(1));
      expect(bobRow.first[0], projectB, reason: 'row must not have moved');
      expect(bobRow.first[1], bob, reason: 'attribution must not have changed');
      expect(bobRow.first[2], isNull, reason: 'notes must not have changed');
      expect(bobRow.first[3], 1, reason: 'revision must not have moved');

      // And Alice's is a genuinely separate row, not a relabelling of his.
      final aliceRow = await connection.execute(
        'SELECT user_id, notes FROM ${quoted(Tables.observations)} '
        r"WHERE observation_id = 'obs-bob' AND project_id = "
        "'$projectA'",
      );
      expect(aliceRow, hasLength(1));
      expect(aliceRow.first[0], alice);
      expect(aliceRow.first[1], 'captured');
    });

    test('a pull for one project returns nothing from the other', () async {
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-a', projectId: projectA, userId: alice),
          ],
        },
      );
      await pushAs(
        bob,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation('obs-b', projectId: projectB, userId: bob),
          ],
        },
      );

      final page = await pull(projectA);
      final ids = (page.rows[Tables.observations] ?? const [])
          .map((r) => r['observation_id'])
          .toSet();
      expect(ids, {'obs-a'});
      expect(
        (page.rows[Tables.projects] ?? const []).map((r) => r['project_id']),
        everyElement(projectA),
      );
    });

    test('a pull does not leak the server user directory', () async {
      // The regression this task exists for: before 10.10, global tables were
      // filtered by `server_seq > cursor` and nothing else, so pulling any
      // project returned every Users row on the server — every registered
      // person's name, and their whole address history through User_Emails.
      // Both users' rows are pushed through sync so each carries a
      // `server_seq` and is genuinely eligible for delivery — otherwise the
      // cursor window would hide Bob's row and the test would pass for the
      // wrong reason.
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [_userRow(alice, 'Alice')],
          Tables.observations: [
            observation('obs-a', projectId: projectA, userId: alice),
          ],
        },
      );
      await pushAs(
        bob,
        projectId: projectB,
        rows: {
          Tables.users: [_userRow(bob, 'Bob')],
          Tables.observations: [
            observation('obs-b', projectId: projectB, userId: bob),
          ],
        },
      );

      final page = await pull(projectA);
      final users = (page.rows[Tables.users] ?? const [])
          .map((r) => r['user_id'])
          .toSet();
      expect(
        users,
        isNot(contains(bob)),
        reason:
            'pulling one project must not disclose the server user '
            'directory',
      );
      expect(
        users,
        contains(alice),
        reason:
            "the project's own users must still arrive, or the client "
            'merger gets a dangling foreign key',
      );
    });
  });

  group('cross-project isolation, single user', skip: databaseSkipReason, () {
    // Task 10.15's narrower half of the same guarantee: one person owning
    // two of their *own* projects still gets no bleed-through between them.
    // The multi-user case above already proves the row/pull scoping is keyed
    // on project_id, not on "some other user's row" — this proves that
    // holds even when the same user_id is the author on both sides, where a
    // check that (incorrectly) scoped by user_id instead of project_id would
    // pass by accident.
    const projectC = 'proj-c'; // also owned by alice

    setUp(() async {
      if (testDatabaseConfig == null) return;
      final at = DateTime.utc(2026, 8, 1, 12);
      await connection.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ($1, 'Second Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
        parameters: [projectC, alice, at],
      );
    });

    test(
      'a row pushed to project A never appears in project C\'s pull',
      () async {
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-a', projectId: projectA, userId: alice),
            ],
          },
        );
        await pushAs(
          alice,
          projectId: projectC,
          rows: {
            Tables.observations: [
              observation('obs-c', projectId: projectC, userId: alice),
            ],
          },
        );

        final pageA = await pull(projectA);
        final pageC = await pull(projectC);

        expect(
          (pageA.rows[Tables.observations] ?? const []).map(
            (r) => r['observation_id'],
          ),
          {'obs-a'},
        );
        expect(
          (pageC.rows[Tables.observations] ?? const []).map(
            (r) => r['observation_id'],
          ),
          {'obs-c'},
        );
      },
    );

    test('labelling a project-A row as project C is refused even though alice '
        'owns both', () async {
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-x', projectId: projectC, userId: alice),
          ],
        },
      );
      expect(
        outcomeFor(result, Tables.observations, 'obs-x'),
        SyncRowOutcome.unauthorized,
      );
      expect(result.applied, 0);
    });

    test(
      'one user\'s two projects each keep their own row under a shared id',
      () async {
        // **Renamed and inverted by task 10.35 — and this test is why the bump
        // happened.** It used to read "project C's own row cannot be captured by
        // relabelling it into project A" and asserted a refusal.
        //
        // But look at what it actually does: one user, who legitimately writes to
        // both projects, pushes the same observation id into each. That is not an
        // attack — it is byte-for-byte the benign case of saving a colleague's
        // shared observation into a second project, which keeps the sender's id
        // (task 6.3). The refusal it asserted as correct was the mechanism that
        // made that workflow permanently unsyncable, and no amount of project
        // membership could have lifted it. The passing test *was* the bug.
        //
        // With project-scoped keys the two pushes address two different rows, so
        // both land and neither disturbs the other. The property worth pinning is
        // the isolation, not the refusal.
        await pushAs(
          alice,
          projectId: projectC,
          rows: {
            Tables.observations: [
              observation('obs-shared-id', projectId: projectC, userId: alice),
            ],
          },
        );

        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation(
                'obs-shared-id',
                projectId: projectA,
                userId: alice,
                revision: 99,
                notes: 'moved',
              ),
            ],
          },
        );

        expect(
          outcomeFor(
            result,
            Tables.observations,
            'obs-shared-id',
            project: projectA,
          ),
          SyncRowOutcome.inserted,
        );

        // Two rows, one per project, each with its own contents.
        final stored = await connection.execute(
          'SELECT project_id, notes FROM ${quoted(Tables.observations)} '
          r"WHERE observation_id = 'obs-shared-id' ORDER BY project_id",
        );
        expect(stored, hasLength(2));
        expect(stored.map((r) => r[0]), [projectA, projectC]);
        expect(stored.first[1], 'moved', reason: "project A's own copy");
        expect(
          stored.last[1],
          isNull,
          reason: "project C's row must be untouched by a write to project A",
        );

        // And a pull for each project sees only its own — the isolation that
        // used to be enforced by the refusal is now a property of the key.
        final pageA = await pull(projectA);
        final pageC = await pull(projectC);
        expect(
          (pageA.rows[Tables.observations] ?? const [])
              .where((r) => r['observation_id'] == 'obs-shared-id')
              .map((r) => r['notes']),
          ['moved'],
        );
        expect(
          (pageC.rows[Tables.observations] ?? const [])
              .where((r) => r['observation_id'] == 'obs-shared-id')
              .map((r) => r['notes']),
          [null],
        );
      },
    );
  });

  group('the rule table, enforced', skip: databaseSkipReason, () {
    test('one user cannot mutate another user\'s observation', () async {
      // Bob's observation, in Bob's project. Alice is made a member so that
      // project access is not what stops her — the row rule has to.
      await pushAs(
        bob,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation('obs-bob', projectId: projectB, userId: bob),
          ],
        },
      );
      await _addMember(connection, projectId: projectB, userId: alice);

      final result = await pushAs(
        alice,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation(
              'obs-bob',
              projectId: projectB,
              userId: bob,
              revision: 99,
              notes: 'forged',
            ),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-bob'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedNotes('obs-bob'), isNull);
    });

    test('claiming a row as your own does not grant you the row', () async {
      // The takeover shape: rewrite `user_id` to yourself in the pushed copy.
      // Authorization reads the *stored* row, so this changes nothing.
      await pushAs(
        bob,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation('obs-bob', projectId: projectB, userId: bob),
          ],
        },
      );
      await _addMember(connection, projectId: projectB, userId: alice);

      final result = await pushAs(
        alice,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observation(
              'obs-bob',
              projectId: projectB,
              userId: alice,
              revision: 99,
              notes: 'stolen',
            ),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-bob'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedNotes('obs-bob'), isNull);
    });

    test('a member cannot grant themselves a role', () async {
      // Privilege escalation, and the reason projectOwner resolves the real
      // owner by query instead of inferring "not the owner" as a null.
      await _addMember(connection, projectId: projectB, userId: alice);

      final result = await pushAs(
        alice,
        projectId: projectB,
        rows: {
          Tables.projectMemberships: [
            {
              'membership_id': 'mem-escalate',
              'project_id': projectB,
              'user_id': alice,
              'role': 'owner',
              'join_date': '2026-08-01T12:00:00.000Z',
              'end_date': null,
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 1,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projectMemberships, 'mem-escalate'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('a non-owner cannot rewrite the project row', () async {
      await _addMember(connection, projectId: projectB, userId: alice);

      final result = await pushAs(
        alice,
        projectId: projectB,
        rows: {
          Tables.projects: [
            {
              'project_id': projectB,
              'project_name': 'Seized',
              'owner_user_id': alice,
              'creation_date': '2026-08-01T12:00:00.000Z',
              'datum': 'WGS84',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 99,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
              'coordinate_format': 'dd',
              'triangulation_window_minutes': 15,
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projects, projectB),
        SyncRowOutcome.unauthorized,
      );
      final owner = await connection.execute(
        'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: [projectB],
      );
      expect(owner.first.first, bob);
    });

    test('one user cannot overwrite another user\'s profile', () async {
      // Users is global — it has no project_id, so a cross-project check
      // cannot catch this one. Only the author rule can.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [
            {
              'user_id': bob,
              'first_name': 'Hijacked',
              'last_name': 'Name',
              'email': 'attacker@example.com',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 99,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.users, bob),
        SyncRowOutcome.unauthorized,
      );
      final stored = await connection.execute(
        'SELECT first_name FROM ${quoted(Tables.users)} '
        r'WHERE user_id = $1',
        parameters: [bob],
      );
      expect(stored.first.first, 'Bob');
    });
  });

  group('the replication exemption stays narrow', skip: databaseSkipReason, () {
    // The colleague is someone **this project already reaches**, which after
    // task 10.29 is the only way a row may name anyone but its pusher. Before
    // 10.29 there was a second way — an identity the server had never heard of
    // — and that clause was finding D-1's registration-status oracle; the
    // group below pins its removal.
    //
    // Reachability is seeded straight into the tables rather than pushed,
    // because Phase 10 has no wire request that produces it: an owner cannot
    // add a member (see 'an owner cannot add someone else to their project'),
    // so this is the Phase 11 state the exemption exists *for*, the same way
    // `ProjectAccess.contributor` was modelled before anything could reach it.
    const colleague = 'user-colleague';

    setUp(() async {
      if (testDatabaseConfig == null) return;
      await connection.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision) '
        r"VALUES ($1, 'Colleague', 'Ranger', 'colleague@example.com', $2, $2, "
        '0)',
        parameters: [colleague, DateTime.utc(2026, 8, 1, 12)],
      );
      await _addMember(connection, projectId: projectA, userId: colleague);
    });

    /// A push carrying an observation authored by [colleague] — which is how
    /// the app pushes imported work once its author is on the project.
    Future<PushResult> publishImported({int revision = 1, String? notes}) =>
        pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation(
                'obs-imported',
                projectId: projectA,
                userId: colleague,
                revision: revision,
                notes: notes,
              ),
            ],
          },
        );

    test(
      'an owner may NOT introduce an observation authored by someone else '
      '(task 11.24 flipped this)',
      () async {
        // **This test used to assert `inserted`, and the flip is the fix.**
        // The exemption was written for Phase 6's import: a user imports
        // observations authored elsewhere and the project carries them once
        // their author is someone it reaches. Finding N-1 is what that costs
        // — the same permission that carries a colleague's genuine record
        // carries a fabricated one, and the Team log and the position
        // estimate's observer provenance then both state something false.
        //
        // The colleague's record is not lost. It is held on the relaying
        // device, counted and explained (task 10.28), and it reaches the
        // server when its own author pushes it, which is the only device
        // entitled to say they made it.
        final result = await publishImported();

        expect(
          outcomeFor(result, Tables.observations, 'obs-imported'),
          SyncRowOutcome.unauthorized,
        );
      },
    );

    test('and may not edit it either', () async {
      final result = await publishImported(revision: 99, notes: 'edited');

      expect(
        outcomeFor(result, Tables.observations, 'obs-imported'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedNotes('obs-imported'), isNull);
    });

    test(
      'shared project vocabulary still replicates — the narrowing is by rule, '
      'not by table',
      () async {
        // The positive control for the flip above, and the reason the fix is
        // keyed on `MutationRule.namesRowAuthor` rather than applied to every
        // table. An `anyUser` table's only user column is the audit column;
        // a first publish carrying a colleague-stamped session must still
        // land, or a published project's own tags and sessions start
        // cascading into refused observations.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.triangulationSessions: [
              {
                'session_id': 'sess-imported',
                'project_id': projectA,
                'tag_id': 'tag-shared',
                'label': 'imported',
                'started_at_local': '2026-08-01T12:00:00.000Z',
                'started_at_utc': '2026-08-01T12:00:00.000Z',
                'started_at_offset': '+00:00',
                'notes': null,
                'created_at': '2026-08-01T12:00:00.000Z',
                'updated_at': '2026-08-01T12:00:00.000Z',
                'revision': 1,
                'last_modified_by': colleague,
                'origin_device_id': 'device-A',
              },
            ],
            // One row where there were two: the tag carries the project
            // that the `Project_Tags` link used to state (task 11.219).
            Tables.tags: [
              _tagRow('tag-shared', projectId: projectA,
                  modifiedBy: colleague),
            ],
          },
        );

        expect(
          outcomeFor(
            result,
            Tables.triangulationSessions,
            'sess-imported',
            project: projectA,
          ),
          SyncRowOutcome.inserted,
        );
      },
    );

    test('re-offering an unchanged row needs no permission', () async {
      // A device re-offers rows it merely carries on every sync (the push
      // watermark is timestamp-based, not an exact pending set). Those are
      // no-ops, and treating them as authorization failures would make normal
      // sync look like an attack. Seeded directly rather than pushed, since
      // the push that would have created it is now refused — and seeded at a
      // revision the server's copy wins on, so that what makes this a no-op
      // is the *merge decision*, which is what `authorizeWrite` actually
      // consults, rather than an incidental column-for-column match.
      await connection.execute(
        'INSERT INTO ${quoted(Tables.observations)} '
        '(observation_id, project_id, user_id, timestamp_local, '
        'timestamp_utc, timezone_offset, latitude, longitude, '
        'position_source, elevation, altitude_agl, observation_type, '
        'signal_type, signal_strength, created_at, updated_at, revision) '
        r"VALUES ('obs-imported', $1, $2, $3, $3, '+00:00', 35.19, -111.65, "
        r"'gps_fix', 2100, 0, 'directional', 'regular_pulse', 'strong', "
        r'$4, $4, 99)',
        parameters: [
          projectA,
          colleague,
          '2026-08-01T12:00:00.000Z',
          DateTime.utc(2026, 8, 1, 12),
        ],
      );

      final result = await publishImported();

      expect(
        outcomeFor(result, Tables.observations, 'obs-imported'),
        SyncRowOutcome.lostToServer,
      );
    });
  });

  // Findings from task 10.10's Security Gate B review. Each of these passed
  // authorization before the fix it pins.
  group('Gate B regressions', skip: databaseSkipReason, () {
    // `modifiedBy` is a parameter rather than a constant because
    // `last_modified_by` is a user column like any other: a caller stamping a
    // *different* user into it is naming someone, and the task 10.20 invariant
    // refuses that. Bob's tags say Bob, which is what his client would send.
    Map<String, Object?> tag(
      String id, {
      required String projectId,
      String name = 'Tag',
      String modifiedBy = alice,
    }) => {
      'tag_id': id,
      'project_id': projectId,
      'lineage_id': id,
      'frequency_mhz': 150.1,
      'tag_name': name,
      'status': 'active',
      'color_hex': '#FF0000',
      'created_at': '2026-08-01T12:00:00.000Z',
      'updated_at': '2026-08-01T12:00:00.000Z',
      'revision': 1,
      'last_modified_by': modifiedBy,
      'origin_device_id': 'device-A',
    };

    // `linkTag` is gone with `Project_Tags` (task 11.219): pushing the tag
    // into a project *is* putting it in that project now, so there is no
    // second step to seed.

    test(
      'a stranger cannot overwrite a tag belonging to another project — '
      'closed by construction since task 11.219',
      () async {
        // **The finding, and what happened to it.** Gate B found that `Tags`
        // was global *and* `MutationRule.anyUser`, so neither the project
        // checks nor the rule table applied to it: any authenticated caller
        // could rewrite or tombstone any tag on the server. Task 10.10's fix
        // was a *check* — `_authorizeTagReferences` refused a tag the caller's
        // project could not already reach — and this test asserted the refusal.
        //
        // **Task 11.219 removed the check by removing the collision.** `Tags`
        // is keyed `(tag_id, project_id)`, so alice pushing bob's `tag_id` into
        // her own project names a **different row**, and accepting it is
        // correct: two people must be able to hold the same tag id.
        //
        // The two lines that make it true, named rather than assumed:
        // `SyncService._findRow` builds its lookup from `SyncTable.primaryKey`,
        // which includes `project_id`, so it can only ever return a row from
        // the project the request names; and `RowAuthorizer._decide`'s scope
        // check refuses a row whose `project_id` is not that project.
        //
        // **What is asserted is the harm, not the verdict**: bob's row is
        // unchanged, and alice's push landed as her own — which is also this
        // group's positive control, since a change that refused every tag write
        // would otherwise leave the whole group green.
        await pushAs(
          bob,
          projectId: projectB,
          rows: {
            Tables.tags: [
              tag('tag-bob', projectId: projectB, name: 'Bob Tag',
                  modifiedBy: bob),
            ],
          },
        );

        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: [
              {
                ...tag('tag-bob', projectId: projectA, name: 'DESTROYED'),
                'revision': 999,
              },
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.tags, 'tag-bob', project: projectA),
          SyncRowOutcome.inserted,
          reason: 'a row of her own in her own project',
        );
        Future<String?> nameIn(String projectId) async {
          final rows = await connection.execute(
            'SELECT tag_name FROM ${quoted(Tables.tags)} '
            r'WHERE tag_id = $1 AND project_id = $2',
            parameters: ['tag-bob', projectId],
          );
          return rows.isEmpty ? null : rows.first.first as String?;
        }

        expect(
          await nameIn(projectB),
          'Bob Tag',
          reason: 'the row Gate B was about is untouched — and the project is '
              'named in the query, because a lookup on tag_id alone could now '
              'answer about either copy',
        );
        expect(await nameIn(projectA), 'DESTROYED');
      },
    );

    // **Two tests are deleted here (task 11.220), and this is the record of
    // what they proved.**
    //
    // *"an unlinked tag still syncs, so the tag database is not broken"* was
    // the permissive half of Gate B's fix: a tag referenced by no project was
    // nobody's, and had to keep replicating between one person's own devices,
    // so the refusal above could not be written as "refuse every tag whose
    // project you are not in". **There is no unlinked tag on the wire.**
    // `Tags.project_id` is `NOT NULL` and `RowAuthorizer._decide`'s scope check
    // refuses a row that does not claim the request's project, so the state it
    // protected cannot be pushed, stored or pulled. Its successor is this
    // device's own tag library, which is deliberately not a synced table —
    // `kTagLibraryTable` in `lib/data/db/schema.dart` says so and is in neither
    // `syncTables` nor `tableSpecs`. **The positive control it also provided is
    // not lost:** the test above now asserts alice's own tag write lands.
    //
    // *"a project cannot link itself to another project's tag"* proved that
    // pushing a `Project_Tags` row claiming a stranger's tag was refused,
    // because a reference is also a read — pull delivered the global rows a
    // project referenced, so a link would have handed over that tag's frequency
    // and deployment notes. **The operation does not exist**: there is no link
    // table, and nothing widens what a project may read.
    //
    // **That property is guarded, and better than this test guarded it.**
    // `sync_tables_test.dart`'s *"the tables where creating a row is itself a
    // grant are the two that carry a permission"* derives the set over
    // `syncTables` and pins it to `Projects` and `Project_Memberships` — so the
    // day somebody adds a link-shaped table back, that assertion goes red
    // whether or not anybody thinks to write a push for it. A pinned set
    // derived from the declarations beats a single hand-written push, which is
    // why this is a deletion rather than a restatement.

    test(
      'naming a stranger in last_modified_by does not disclose them',
      () async {
        // `last_modified_by` is a free-text audit column and a foreign key on
        // neither side, so treating it as a reachability edge let a caller have
        // any user's profile and address history delivered on the next pull.
        await pushAs(
          bob,
          projectId: projectB,
          rows: {
            Tables.users: [_userRow(bob, 'Bob')],
          },
        );

        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [_userRow(alice, 'Alice')],
            Tables.observations: [
              {
                ...observation('obs-a', projectId: projectA, userId: alice),
                'last_modified_by': bob,
              },
            ],
          },
        );

        final page = await pull(projectA);
        expect(
          (page.rows[Tables.users] ?? const []).map((r) => r['user_id']),
          isNot(contains(bob)),
        );
        expect(
          (page.rows[Tables.userEmails] ?? const []).map((r) => r['user_id']),
          isNot(contains(bob)),
        );
      },
    );

    test('an address-history row cannot be inserted for someone else', () async {
      // The identity-forgery path: the client merger treats a matching prior
      // email as proof two user ids are the same person, so an attacker-chosen
      // address on a victim's id re-attributes the victim's rows on merge.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.userEmails: [
            {
              'user_email_id': 'ue-forged',
              'user_id': bob,
              'email': 'attacker@example.com',
              'is_current': 1,
              'recorded_at': '2026-08-01T12:00:00.000Z',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 1,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.userEmails, 'ue-forged'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an owner cannot add someone else to their project', () async {
      // Phase 10 has no invitation flow. An unsolicited membership row would
      // put an attacker-controlled project in a stranger's join list and make
      // that stranger's Users row reachable. Task 11.2 relaxes this.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.projectMemberships: [
            {
              'membership_id': 'mem-unsolicited',
              'project_id': projectA,
              'user_id': bob,
              'role': 'viewer',
              'join_date': '2026-08-01T12:00:00.000Z',
              'end_date': null,
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 1,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projectMemberships, 'mem-unsolicited'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an owner may still record their own membership', () async {
      // The legitimate case the rule above must not break: every publish
      // carries the owner's own membership row.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.projectMemberships: [
            {
              'membership_id': 'mem-own',
              'project_id': projectA,
              'user_id': alice,
              'role': 'owner',
              'join_date': '2026-08-01T12:00:00.000Z',
              'end_date': null,
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 1,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projectMemberships, 'mem-own'),
        SyncRowOutcome.inserted,
      );
    });
  });

  // Security Gate C, finding C-1 (`TriTrack_Security_Model.md` §7.3, B1a–B1d).
  // Four live reproductions of one omission: authorization reasoned about who
  // *owned* a row and never about who the row *named*. Each test below is one
  // of the four, written from the recorded reproduction.
  group('Gate C — the row-naming invariant (C-1)', skip: databaseSkipReason, () {
    /// A colleague whose observations were imported from a share payload and
    /// who has never touched this server — no `Users` row, no account. Naming
    /// them is replication; naming Bob is not.
    const carol = 'user-carol';

    Map<String, Object?> nonDetection(
      String id, {
      required String projectId,
      required String userId,
      int revision = 1,
      String? notes,
    }) => {
      'non_detection_id': id,
      'project_id': projectId,
      'user_id': userId,
      'timestamp_local': '2026-08-01T12:00:00.000Z',
      'timestamp_utc': '2026-08-01T12:00:00.000Z',
      'timezone_offset': '+00:00',
      'latitude': 35.19,
      'longitude': -111.65,
      'position_accuracy_m': null,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'tag_ids_listened_for': '[]',
      'notes': notes,
      'created_at': '2026-08-01T12:00:00.000Z',
      'updated_at': '2026-08-01T12:00:00.000Z',
      'deleted_at': null,
      'revision': revision,
      'last_modified_by': userId,
      'origin_device_id': 'device-A',
    };

    Future<String?> storedUserId(String table, String key, String id) async {
      final result = await connection.execute(
        'SELECT user_id FROM ${quoted(table)} WHERE $key = \$1',
        parameters: [id],
      );
      return result.isEmpty ? null : result.first.first as String?;
    }

    test('B1a — an observation may not name a user the server holds', () async {
      // The recorded reproduction: an authenticated user pushes into *their
      // own* project an observation whose user_id names a victim they have no
      // relationship to. `user_id` is a reachability edge, so the attacker's
      // next pull returns the victim's Users row and address history.
      final before = await pull(projectA);
      expect(
        (before.rows[Tables.users] ?? const []).map((r) => r['user_id']),
        isNot(contains(bob)),
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-forged', projectId: projectA, userId: bob),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-forged'),
        SyncRowOutcome.unauthorized,
      );
      final after = await pull(projectA);
      expect(
        (after.rows[Tables.users] ?? const []).map((r) => r['user_id']),
        isNot(contains(bob)),
        reason: 'the victim must not become reachable from a foreign project',
      );
      expect(
        (after.rows[Tables.userEmails] ?? const []).map((r) => r['user_id']),
        isNot(contains(bob)),
        reason: 'nor may their prior address history',
      );
    });

    test('B1b — the same through Non_Detections', () async {
      // Recorded separately because a fix aimed at Observations would not
      // close it — which is exactly why this is one invariant over
      // `SyncTable.userColumns` rather than a patch per table.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.nonDetections: [
            nonDetection('nd-forged', projectId: projectA, userId: bob),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.nonDetections, 'nd-forged'),
        SyncRowOutcome.unauthorized,
      );
      final after = await pull(projectA);
      expect(
        (after.rows[Tables.users] ?? const []).map((r) => r['user_id']),
        isNot(contains(bob)),
      );
    });

    test('B1c — an owner may not hand their project to a stranger', () async {
      // Authorization compares the *stored* row, correctly (§4.12) — but that
      // means at the instant of the check the attacker still owns the project,
      // so rewriting owner_user_id to a victim passed. The attacker keeps
      // access through their own membership row and the victim becomes
      // reachable.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.projects: [
            {
              'project_id': projectA,
              'project_name': 'Field',
              'owner_user_id': bob,
              'creation_date': '2026-08-01T12:00:00.000Z',
              'datum': 'WGS84',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 99,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
              'coordinate_format': 'dd',
              'triangulation_window_minutes': 15,
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projects, projectA),
        SyncRowOutcome.unauthorized,
      );
      final owner = await connection.execute(
        'SELECT owner_user_id FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: [projectA],
      );
      expect(owner.first.first, alice);
    });

    test('B1d — authorship cannot be rewritten after the fact', () async {
      // The severest of the four, and a different class: integrity, not
      // disclosure. The attacker authors a row legitimately, then stamps
      // someone else's name on it — choosing the coordinates, the time and the
      // notes — and is locked out of the row they fabricated, so there is no
      // later edit of theirs to point at.
      final created = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-own', projectId: projectA, userId: alice),
          ],
        },
      );
      expect(
        outcomeFor(created, Tables.observations, 'obs-own'),
        SyncRowOutcome.inserted,
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation(
              'obs-own',
              projectId: projectA,
              userId: bob,
              revision: 2,
              notes: 'FABRICATED: victim reported this animal here',
            ),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-own'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedUserId(Tables.observations, 'observation_id', 'obs-own'),
        alice,
      );
      expect(await storedNotes('obs-own'), isNull);
    });

    test('B1d — nor rewritten to a user the server has never seen', () async {
      // Reattribution is an integrity failure, and a fabricated attribution is
      // a fabricated attribution whether or not the named person has an
      // account here. Since task 10.29 that is true on the way in as well —
      // the insert side no longer treats an unknown id as a free pass either —
      // but this pins the update side, where it has always been true.
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-own', projectId: projectA, userId: alice),
          ],
        },
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [_userRow(carol, 'Carol')],
          Tables.observations: [
            observation(
              'obs-own',
              projectId: projectA,
              userId: carol,
              revision: 2,
              notes: 'FABRICATED',
            ),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-own'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedUserId(Tables.observations, 'observation_id', 'obs-own'),
        alice,
      );
    });

    test('an update may not re-stamp last_modified_by onto someone '
        'else', () async {
      // `last_modified_by` is a user column like any other. It is not a
      // reachability edge (Gate B settled that), so this one is integrity
      // only: an audit trail that can be pointed at an arbitrary colleague is
      // not an audit trail.
      await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-own', projectId: projectA, userId: alice),
          ],
        },
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            {
              ...observation(
                'obs-own',
                projectId: projectA,
                userId: alice,
                revision: 2,
                notes: 'edited',
              ),
              'last_modified_by': bob,
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.observations, 'obs-own'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedNotes('obs-own'), isNull);
    });

    test('a first publish no longer carries an unknown colleague', () async {
      // **Corrected at task 10.29, and corrected upward.** This test used to
      // assert `inserted` here — the "the server has never heard of them"
      // clause — and it was that assertion, not an oversight, that carried
      // finding D-1's registration-status oracle: the same push naming a
      // registered id answered `unauthorized`, so the outcome map read out a
      // stranger's account status. The seam is gone and the answer is now the
      // same either way; the equivalence itself is pinned in the D-1 group
      // below.
      //
      // The cost is real and deliberate: an imported colleague's work stops
      // syncing until that colleague is on the project (task 11.2's invitation
      // record). Nothing is lost — `SyncHeldRowStore` holds the refused rows on
      // the device and explains them (task 10.28).
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [_userRow(carol, 'Carol')],
          Tables.observations: [
            observation('obs-carol', projectId: projectA, userId: carol),
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.users, carol),
        SyncRowOutcome.unauthorized,
      );
      expect(
        outcomeFor(result, Tables.observations, 'obs-carol'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedUserId(Tables.observations, 'observation_id', 'obs-carol'),
        isNull,
        reason: 'and nothing was written',
      );
    });

    test('a push may still name a colleague already in the project — but '
        'only on a table whose rows do not name an author', () async {
      // **Task 11.24 split this test's answer in two, and the split is
      // finding N-1.** Clause 2 says someone this project already reaches
      // discloses nothing by being named again, which is still true and is
      // still what it is for. What it never answered is *attribution*, and
      // on a table whose rule names an author that is the whole question —
      // so clause 2 no longer vouches there. It does still vouch on the
      // shared tables, which is what keeps replication working.
      //
      // Seeded rather than pushed because Phase 10 has no request that adds
      // a member — see 'an owner cannot add someone else to their project'.
      await connection.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision) '
        r"VALUES ($1, 'Carol', 'Ranger', 'carol@example.com', $2, $2, 0)",
        parameters: [carol, DateTime.utc(2026, 8, 1, 12)],
      );
      await _addMember(connection, projectId: projectA, userId: carol);

      final forged = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observation('obs-carol-2', projectId: projectA, userId: carol),
          ],
        },
      );
      expect(
        outcomeFor(forged, Tables.observations, 'obs-carol-2'),
        SyncRowOutcome.unauthorized,
        reason: 'an observation names its author, and that must be the caller',
      );

      final shared = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.tags: [
            _tagRow('tag-carol', projectId: projectA, modifiedBy: carol),
          ],
        },
      );
      expect(
        outcomeFor(shared, Tables.tags, 'tag-carol'),
        SyncRowOutcome.inserted,
        reason:
            'clause 2 still serves shared project vocabulary — without this '
            'the test above would pass on a server that refused everything',
      );
    });

    test('replication is still refused for authorization state', () async {
      // The membership rule Gate B added by table name is now a consequence of
      // the invariant: `Project_Memberships` is governed by `projectOwner`, an
      // authorization-state rule, and authorization state is never something
      // replication legitimately carries with someone else's name on it — not
      // even an unknown someone.
      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [_userRow(carol, 'Carol')],
          Tables.projectMemberships: [
            {
              'membership_id': 'mem-phantom',
              'project_id': projectA,
              'user_id': carol,
              'role': 'viewer',
              'join_date': '2026-08-01T12:00:00.000Z',
              'end_date': null,
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-01T12:00:00.000Z',
              'revision': 1,
              'last_modified_by': alice,
              'origin_device_id': 'device-A',
            },
          ],
        },
      );

      expect(
        outcomeFor(result, Tables.projectMemberships, 'mem-phantom'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an account with no profile cannot have one planted under '
        'it', () async {
      // A caller must not be able to publish a `Users` row of their own
      // composition under a real account's id and have it delivered as that
      // person's profile. This was the reason the old seam checked
      // `auth_accounts` as well as `Users`; it is now covered by the flat rule
      // that a row may only name the caller or someone the project reaches, so
      // it survives as a case rather than as a clause.
      await connection.execute(
        r'INSERT INTO auth_accounts (user_id, email, created_at) '
        r'VALUES ($1, $2, now())',
        parameters: ['user-dave', 'dave@example.com'],
      );

      final result = await pushAs(
        alice,
        projectId: projectA,
        rows: {
          Tables.users: [_userRow('user-dave', 'NotDave')],
        },
      );

      expect(
        outcomeFor(result, Tables.users, 'user-dave'),
        SyncRowOutcome.unauthorized,
      );
    });
  });

  // Gate C's fourth re-run (task 10.25) found the row-naming invariant
  // enforceable on `user_id` and unenforced on the column beside it. The client
  // merger dedups people by email and then rewrites every identity column on
  // the page, so a forged address is a forged id — C-1's harm, reached one
  // column over. Task 10.55.
  group(
    'Gate C fourth re-run — the email-claim invariant (I-4)',
    skip: databaseSkipReason,
    () {
      Future<String?> storedEmail(String userId) async {
        final result = await connection.execute(
          'SELECT email FROM ${quoted(Tables.users)} '
          r'WHERE user_id = $1',
          parameters: [userId],
        );
        return result.isEmpty ? null : result.first.first as String?;
      }

      test('I-4 — a caller cannot claim a colleague\'s address on their '
          'own Users row', () async {
        // The live repro, verbatim: alice names nobody but herself, which every
        // check before this one permits, and claims bob's address. On the next
        // pull bob's device would fold alice's id onto bob's and re-attribute
        // every row on the page.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [
              {..._userRow(alice, 'Alice'), 'email': 'bob@example.com'},
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.users, alice),
          SyncRowOutcome.unauthorized,
        );
        expect(await storedEmail(alice), 'alice@example.com');
      });

      test('nor an address this server has never authenticated', () async {
        // The same refusal for an address belonging to nobody here. Converging
        // the two is what stops the outcome map answering "is this address
        // registered?" — D-1's shape, on the email column.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [
              {..._userRow(alice, 'Alice'), 'email': 'alice@fieldstation.test'},
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.users, alice),
          SyncRowOutcome.unauthorized,
        );
        expect(await storedEmail(alice), 'alice@example.com');
      });

      test('a caller\'s own profile still syncs on their authenticated '
          'address', () async {
        // The control. A refusal that also refused the ordinary case would be
        // a broken sync wearing a security fix's clothes.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [
              {..._userRow(alice, 'Alice'), 'last_name': 'Fieldsworth'},
            ],
          },
        );

        expect(outcomeFor(result, Tables.users, alice), SyncRowOutcome.updated);
        final stored = await connection.execute(
          'SELECT last_name FROM ${quoted(Tables.users)} '
          r'WHERE user_id = $1',
          parameters: [alice],
        );
        expect(stored.first.first, 'Fieldsworth');
      });

      test('case and surrounding whitespace do not make it a different '
          'address', () async {
        // The comparison normalizes both sides, because the merger's dedup
        // does — matching on the raw string would refuse a legitimate row and,
        // worse, would let ` Bob@Example.com ` past a check that the client
        // then treats as bob.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [
              {..._userRow(alice, 'Alice'), 'email': '  Alice@Example.COM '},
            ],
          },
        );

        expect(outcomeFor(result, Tables.users, alice), SyncRowOutcome.updated);
      });

      test('an address-history row is refused even for yourself', () async {
        // `User_Emails` is unverifiable by construction — a new address is a
        // new account here, so the server has no record that alice once used
        // this mailbox — and the merger's prior-email tiers are the same remap
        // tier 1 is. So the server carries only identity it authenticated;
        // address history stays in backup files, where nothing claims to have
        // checked it. The existing sibling test covers the same row aimed at
        // someone else.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.userEmails: [
              {
                'user_email_id': 'ue-alice-prior',
                'user_id': alice,
                'email': 'alice.ranger@oldlab.example',
                'is_current': 0,
                'recorded_at': '2026-08-01T12:00:00.000Z',
                'created_at': '2026-08-01T12:00:00.000Z',
                'updated_at': '2026-08-01T12:00:00.000Z',
                'revision': 1,
                'last_modified_by': alice,
                'origin_device_id': 'device-A',
              },
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.userEmails, 'ue-alice-prior'),
          SyncRowOutcome.unauthorized,
        );
      });

      test('the boundary is the address, not the table', () async {
        // The complement, so the refusal above is read as what it is. A
        // `User_Emails` row naming the caller's *current* authenticated address
        // still lands — it asserts nothing their `Users` row does not already
        // say. What stops replicating is address *history*, which is the part
        // the server cannot vouch for.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.userEmails: [
              {
                'user_email_id': 'ue-alice-current',
                'user_id': alice,
                'email': 'alice@example.com',
                'is_current': 1,
                'recorded_at': '2026-08-01T12:00:00.000Z',
                'created_at': '2026-08-01T12:00:00.000Z',
                'updated_at': '2026-08-01T12:00:00.000Z',
                'revision': 1,
                'last_modified_by': alice,
                'origin_device_id': 'device-A',
              },
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.userEmails, 'ue-alice-current'),
          SyncRowOutcome.inserted,
        );
      });
    },
  );

  // Security Gate C's re-run (task 10.25) found the per-row `outcomes` map
  // answering the question task 10.21 had just stopped the HTTP status code
  // from answering. Every test here is an equivalence: it asserts that two
  // pushes differing *only* in a fact about the server's contents come back
  // with the same answer. A test that merely pinned each answer separately is
  // what let this survive two gates — both assertions were right about
  // authorization, and together they were the oracle.
  group(
    'Gate C re-run — the per-row existence oracle (D-1)',
    skip: databaseSkipReason,
    () {
      const registered = bob; // has a Users row and (below) an account
      const accountOnly = 'user-dave'; // signed in here, never published
      const neverSeen = 'user-erin'; // this server has never heard of them

      Map<String, Object?> tag(
        String id, {
        required String projectId,
        String modifiedBy = alice,
      }) => {
        'tag_id': id,
        'project_id': projectId,
        'lineage_id': id,
        'frequency_mhz': 150.1,
        'tag_name': 'Tag',
        'status': 'active',
        'color_hex': '#FF0000',
        'created_at': '2026-08-01T12:00:00.000Z',
        'updated_at': '2026-08-01T12:00:00.000Z',
        'revision': 1,
        'last_modified_by': modifiedBy,
        'origin_device_id': 'device-A',
      };

      /// A tag version naming [tagId]. **This is the row that inherited
      /// `Project_Tags`' place in arm (b) below** — the one whose whole content
      /// is "a tag, in a project", so if any answer about a tag id could still
      /// fork it would fork here.
      Map<String, Object?> version(
        String id, {
        required String tagId,
        required String projectId,
        String modifiedBy = alice,
      }) => {
        'tag_version_id': id,
        'project_id': projectId,
        'tag_id': tagId,
        'effective_from': '2026-08-01T12:00:00.000Z',
        'frequency_mhz': 150.1,
        'pulse_rate': null,
        'pulse_pattern': null,
        'tag_name': 'Tag',
        'created_at': '2026-08-01T12:00:00.000Z',
        'updated_at': '2026-08-01T12:00:00.000Z',
        'revision': 1,
        'last_modified_by': modifiedBy,
        'origin_device_id': 'device-A',
      };

      /// Bob's project genuinely holds `tag-bob`. One row since task 11.219 —
      /// the tag's own `project_id` is what the link row used to say. Pushed as
      /// Bob rather than seeded so the fixture itself proves the ordinary
      /// create-and-use flow works.
      Future<void> giveBobATag() async {
        final result = await pushAs(
          bob,
          projectId: projectB,
          rows: {
            Tables.tags: [
              tag('tag-bob', projectId: projectB, modifiedBy: bob),
            ],
          },
        );
        expect(
          result.outcomes.values,
          everyElement(SyncRowOutcome.inserted),
          reason:
              'the fixture must actually land, or the tests below prove '
              'nothing about a *claimed* tag',
        );
      }

      setUp(() async {
        if (testDatabaseConfig == null) return;
        // `registered` is bob, whose account the shared fixture already seeds
        // (task 10.55 needs every caller to have one). Named here anyway, and
        // idempotently, because this group's argument is about *which* of these
        // three the server knows — spelling that out beats reading it off
        // another function.
        await connection.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r'VALUES ($1, $2, now()), ($3, $4, now()) '
          r'ON CONFLICT (user_id) DO NOTHING',
          parameters: [
            accountOnly,
            'dave@example.com',
            registered,
            'bob@example.com',
          ],
        );
      });

      /// Alice pushes an observation of her own, into her own project, whose
      /// `user_id` names [named]. The row's own primary key is fresh every time,
      /// so the only thing that varies between calls is a fact about [named].
      Future<SyncRowOutcome?> nameInObservation(String named) async {
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-$named', projectId: projectA, userId: named),
            ],
          },
        );
        return outcomeFor(
          result,
          Tables.observations,
          'obs-$named',
          project: projectA,
        );
      }

      test('arm (a) — a stranger\'s registration status does not show '
          'through', () async {
        // The recorded three-way. `unauthorized` for a registered user and
        // `inserted` for an unknown one made the outcome map a clean read of
        // whether a person — identified by a `user_id` that travels in every
        // share payload, every CSV export and the `last_modified_by` of every
        // synced row — has an account on this server.
        expect(
          await nameInObservation(registered),
          SyncRowOutcome.unauthorized,
        );
        expect(
          await nameInObservation(accountOnly),
          SyncRowOutcome.unauthorized,
        );
        expect(await nameInObservation(neverSeen), SyncRowOutcome.unauthorized);
      });

      test('arm (a) — nor through a Users row that merely loses', () async {
        // The third value in the three-way, and the one that survived task
        // 10.20 untouched: a push that changes nothing needed no permission, so
        // a stale copy of a registered user's row came back `lost_to_server`
        // while an unknown id came back `inserted`. "The server already holds
        // that" is an answer about a row this caller may not see.
        Future<SyncRowOutcome?> offerStale(String named) async {
          final result = await pushAs(
            alice,
            projectId: 'proj-fabricated',
            rows: {
              // revision 0 and the seed's own timestamps: this loses the merge
              // outright where a row exists, so nothing is mutated.
              Tables.users: [
                {..._userRow(named, 'Whoever'), 'revision': 0},
              ],
            },
          );
          return outcomeFor(result, Tables.users, named);
        }

        expect(await offerStale(registered), SyncRowOutcome.unauthorized);
        expect(await offerStale(neverSeen), SyncRowOutcome.unauthorized);
      });

      test('arm (b) — a tag id\'s existence does not show through', () async {
        // Bob's project holds a tag; the other id names nothing at all. Both
        // observations are Alice's own, in Alice's own project, with fresh keys.
        await giveBobATag();

        Future<SyncRowOutcome?> useTag(String tagId) async {
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.observations: [
                {
                  ...observation(
                    'obs-$tagId',
                    projectId: projectA,
                    userId: alice,
                  ),
                  'tag_id': tagId,
                },
              ],
            },
          );
          return outcomeFor(
            result,
            Tables.observations,
            'obs-$tagId',
            project: projectA,
          );
        }

        expect(await useTag('tag-bob'), SyncRowOutcome.unauthorized);
        expect(await useTag('tag-nowhere'), SyncRowOutcome.unauthorized);
        // **The equivalence is unchanged; what enforces it moved (task
        // 11.219).** It used to be `RowAuthorizer._authorizeTagReferences` —
        // the rule that a tag reference is also a read of a global row, so a
        // tag the caller's project could not already reach was refused. That
        // method is deleted. What refuses both arms now is that
        // `Observations.(tag_id, project_id)` references `Tags`, and projectA
        // holds neither id, so both rows point at nothing this server has:
        // `RowAuthorizer._authorizeReferences`, the ordinary dangling-reference
        // rule. **A stronger position for D-1, not a weaker one** — the old
        // rule had to be told which columns named a tag, and this one cannot
        // tell "another project holds it" from "nobody does", because the
        // lookup is scoped and never sees the other project at all.
      });

      test('arm (b) — nor through the row whose whole content is a tag',
          () async {
        // **This was *"nor through the link that would claim it"*, and the row
        // it probed no longer exists (task 11.219).** `Project_Tags` was the one
        // row the server let name a tag its project could not already reach —
        // that is what a link *was* — so it was the one place the answer about
        // a tag id could still have forked, and this test proved it did not.
        //
        // **Deleting it would have left arm (b) resting on `Observations`
        // alone**, which carries a bearing's own data and is therefore not the
        // interesting shape: the shape that worries D-1 is a row that is
        // *nothing but* a claim about a tag, because such a row's refusal has
        // no other cause to hide behind. `Tag_Versions` is that row now, so it
        // is what this test probes.
        //
        // The first half is the derived claim, and it is why there is no third
        // shape to check: **every table that declares `tagColumns` is
        // project-scoped**, so no row in the schema can name a tag outside its
        // own project. Derived over `syncTables` rather than listed, and it
        // refuses an empty set — a search that matched no table and a schema
        // with no tag-bearing table would otherwise be indistinguishable, and
        // only one of those is true.
        final tagBearing = [
          for (final table in syncTables)
            if (table.tagColumns.isNotEmpty) table,
        ];
        expect(
          tagBearing,
          isNotEmpty,
          reason: 'no table declares tagColumns, which cannot be right — this '
              'assertion would otherwise pass by measuring nothing',
        );
        expect(
          [
            for (final table in tagBearing)
              if (table.projectScopeColumn == null) table.name,
          ],
          isEmpty,
          reason: 'a global table naming a tag would be a row that can claim a '
              'tag outside any project, which is the shape Project_Tags was and '
              'the shape arm (b) exists to keep out of the schema',
        );

        // And the live half, on the surviving row shape.
        await giveBobATag();

        Future<SyncRowOutcome?> claim(String tagId) async {
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.tagVersions: [
                version('ver-$tagId', tagId: tagId, projectId: projectA),
              ],
            },
          );
          return outcomeFor(
            result,
            Tables.tagVersions,
            'ver-$tagId',
            project: projectA,
          );
        }

        expect(await claim('tag-bob'), SyncRowOutcome.unauthorized);
        expect(await claim('tag-nowhere'), SyncRowOutcome.unauthorized);
      });

      test('a new tag still syncs — created and used in one push', () async {
        // The flow the strictness above must not break, in the shape
        // `SyncEngine` sends it: a tag the server has never seen and an
        // observation using it, in one request.
        //
        // **Two rows where there were three, and the reason it works changed
        // (task 11.219).** The `Project_Tags` link is gone, and so is what the
        // old comment named: *"none of the three is reachable from the project
        // at the moment it is authorized — the whole batch is judged against one
        // pre-push snapshot — so this is what the push's own established-tag set
        // exists for."* `RowAuthorizer._establishedThisPush` is deleted. Both
        // rows claim projectA, so the scope check answers each on its own and
        // there is nothing to establish. What still needs the batch order is the
        // foreign key: `Tags` precedes `Observations` in `syncTables`.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: [tag('tag-new', projectId: projectA)],
            Tables.observations: [
              {
                ...observation('obs-new', projectId: projectA, userId: alice),
                'tag_id': 'tag-new',
              },
            ],
          },
        );

        expect(
          outcomeFor(result, Tables.tags, 'tag-new'),
          SyncRowOutcome.inserted,
        );
        expect(
          outcomeFor(result, Tables.observations, 'obs-new'),
          SyncRowOutcome.inserted,
        );
      });

      test('a new tag still syncs — one table per request, as publish '
          'sends it', () async {
        // The other shape: `ProjectPublisher` slices a project one table at a
        // time, so each of these lands in its own transaction and nothing the
        // previous request knew is carried into the next.
        //
        // **This used to be three requests and is two (task 11.219).** The
        // middle one was the `Project_Tags` link, and the old comment said what
        // made it the hard case: *"the link request has to work against a tag
        // that is on the server and orphaned."* An orphaned tag is not a state
        // any more. What is left is still worth replaying, because it is the
        // sequence that shipped broken once: a tag committed in one transaction
        // and referenced from a later one, where nothing in the second request
        // can vouch for anything.
        final tags = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: [tag('tag-pub', projectId: projectA)],
          },
        );
        expect(
          outcomeFor(tags, Tables.tags, 'tag-pub'),
          SyncRowOutcome.inserted,
        );

        final observations = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              {
                ...observation('obs-pub', projectId: projectA, userId: alice),
                'tag_id': 'tag-pub',
              },
            ],
          },
        );
        expect(
          outcomeFor(observations, Tables.observations, 'obs-pub'),
          SyncRowOutcome.inserted,
        );
      });

      test('arm (c) — a row id already taken in another project is '
          'indistinguishable from a free one', () async {
        // **Arm (c) is closed as of task 10.35, and this test was inverted to
        // say so.** It used to be named "the residual: a client-chosen key still
        // reveals whether it is taken" and it pinned the leak deliberately, with
        // a note that closing it meant project-scoped primary keys — "a schema
        // change filed under Phase 10's Discovered Scope." That change is task
        // 10.35, and this is the test it was written to fail.
        //
        // The leak was that a key someone else's project already held answered
        // `unauthorized` while a free key answered `inserted`, so an ordinary
        // authenticated caller could ask "does this record id exist anywhere on
        // this server?" one row at a time. Keys are now `(id, project_id)`, so
        // there is no collision to observe: Alice's push is a row of her own
        // either way, and the server never looks outside her project.
        //
        // Written as an equivalence, matching arms (a) and (b) above — the claim
        // is not "both answer `inserted`" but "both answer *the same thing*",
        // which is what closes an oracle. Asserting the specific value too, since
        // converging on a refusal would close the oracle by breaking ordinary row
        // creation, and that would be a regression rather than a fix.
        await pushAs(
          bob,
          projectId: projectB,
          rows: {
            Tables.observations: [
              observation('obs-bob', projectId: projectB, userId: bob),
            ],
          },
        );

        final taken = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-bob', projectId: projectA, userId: alice),
            ],
          },
        );
        final free = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observations: [
              observation('obs-free', projectId: projectA, userId: alice),
            ],
          },
        );

        final takenOutcome = outcomeFor(
          taken,
          Tables.observations,
          'obs-bob',
          project: projectA,
        );
        final freeOutcome = outcomeFor(
          free,
          Tables.observations,
          'obs-free',
          project: projectA,
        );

        expect(
          takenOutcome,
          freeOutcome,
          reason:
              'a taken key and a free one must answer identically, or the '
              'answer is itself the disclosure',
        );
        expect(
          takenOutcome,
          SyncRowOutcome.inserted,
          reason:
              'and they must converge on acceptance — converging on a '
              'refusal would close the oracle by breaking row creation',
        );

        // Bob's row is untouched, in Bob's project, still his — unchanged from
        // when this test pinned the leak, and now guaranteed by the key rather
        // than by a check that had to notice.
        final stored = await connection.execute(
          'SELECT project_id, user_id FROM ${quoted(Tables.observations)} '
          r'WHERE observation_id = $1 AND project_id = $2',
          parameters: ['obs-bob', projectB],
        );
        expect(stored.first.toColumnMap(), {
          'project_id': projectB,
          'user_id': bob,
        });
        expect(taken.lost, isEmpty);

        // Alice got her own row, in her own project, rather than a share of his.
        final aliceCopy = await connection.execute(
          'SELECT user_id FROM ${quoted(Tables.observations)} '
          r'WHERE observation_id = $1 AND project_id = $2',
          parameters: ['obs-bob', projectA],
        );
        expect(aliceCopy.first[0], alice);
      });
    },
  );

  group(
    'conflict reporting does not become a read primitive',
    skip: databaseSkipReason,
    () {
      test('a losing global row is not disclosed to a non-author', () async {
        // Push a deliberately stale copy of Bob's Users row: it loses, and the
        // conflict report would otherwise hand back the server's full copy,
        // including his email, to anyone who knows his user id.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.users: [
              {
                'user_id': bob,
                'first_name': 'Probe',
                'last_name': 'Probe',
                'email': 'probe@example.com',
                'created_at': '2026-08-01T12:00:00.000Z',
                'updated_at': '2020-01-01T00:00:00.000Z',
                'revision': 0,
                'last_modified_by': alice,
                'origin_device_id': 'device-A',
              },
            ],
          },
        );

        expect(
          result.lost.where((l) => l.table == Tables.users),
          isEmpty,
          reason: 'a non-author must not receive the row back',
        );
      });
    },
  );

  group(
    'the malformed-governing-column backstop, exercised directly '
    '(task 10.68)',
    skip: databaseSkipReason,
    () {
      // §12.6's J-4 class (typed input the envelope layer never sees) also
      // reaches through row content: `_governingValue` (`row_authorizer.dart`)
      // resolved `MutationRule.author`/`.owner`'s governing column with an
      // unchecked `row[column] as String?`. `RowAuthorizer._governingValue`
      // now refuses it explicitly (`DenialReason.malformedGoverningColumn`)
      // — see the class doc on `malformedGoverningColumn` for why coercing it
      // to `null` instead would turn the refusal into a bypass.
      //
      // These tests call `RowAuthorizer.authorizeWrite` directly rather than
      // through `pushAs`/`SyncService`, so — unlike the route-level tests
      // below — they do not pass through `RowValidator` at all. Task 10.67
      // added `identityColumn()` type checks to shared validation that now
      // refuse a non-string `user_id`/`owner_user_id` *before* authorization
      // ever sees the row on the real push path, which is correct (refusing
      // earlier is strictly better) but means the route-level tests can no
      // longer tell this backstop apart from validation's. Calling the
      // authorizer directly, with a row validation would reject, is what
      // keeps this backstop independently exercised regardless of what
      // validation does or stops doing.
      test('author rule: a non-string user_id on a new row is refused', () async {
        final access = await connection.runTx(
          (tx) =>
              ProjectAuthorizer.resolve(tx, projectId: projectA, userId: alice),
        );
        final verdict = await connection.runTx(
          (tx) => RowAuthorizer(
            session: tx,
            projectId: projectA,
            userId: alice,
            access: access,
          ).authorizeWrite(
            table: syncTablesByName[Tables.observations]!,
            incoming: {
              ...observation('obs-bad-user', projectId: projectA, userId: alice),
              'user_id': 12345,
            },
            existing: null,
            changesStoredRow: true,
          ),
        );
        expect(verdict.isAllowed, isFalse);
        expect(verdict.reason, DenialReason.malformedGoverningColumn);
      });

      test(
        'owner rule: a non-string owner_user_id on a new row is refused',
        () async {
          const projectId = 'proj-crash-test';
          // **`ProjectAccess.owner`, not the resolved answer, and task 11.3 is
          // why.** The project does not exist, so resolving gives `absent` —
          // and `absent` now means "no role here", which the gradient refuses
          // before the row's contents are looked at. That is not a change of
          // behaviour on the wire: `sync_routes.dart` substitutes `owner` for
          // exactly this row, a first publish establishing the project, and
          // refuses the push outright otherwise. So `owner` is the access this
          // row is judged under in production, and judging it under `absent`
          // here would test a path the route cannot produce — and would let
          // the role refusal stand in for the type backstop this group exists
          // to prove fires.
          final verdict = await connection.runTx(
            (tx) => RowAuthorizer(
              session: tx,
              projectId: projectId,
              userId: alice,
              access: ProjectAccess.owner,
            ).authorizeWrite(
              table: syncTablesByName[Tables.projects]!,
              incoming: {
                'project_id': projectId,
                'project_name': 'Crash Test',
                'owner_user_id': 12345,
                'creation_date': '2026-08-01T12:00:00.000Z',
                'datum': 'WGS84',
                'created_at': '2026-08-01T12:00:00.000Z',
                'updated_at': '2026-08-01T12:00:00.000Z',
                'revision': 0,
                'coordinate_format': 'dd',
                'triangulation_window_minutes': 15,
              },
              existing: null,
              changesStoredRow: true,
            ),
          );
          expect(verdict.isAllowed, isFalse);
          expect(verdict.reason, DenialReason.malformedGoverningColumn);
        },
      );
    },
  );

  group(
    'a malformed governing column is refused by validation before '
    'authorization ever sees it (task 10.64, retargeted by 10.68)',
    skip: databaseSkipReason,
    () {
      // These were task 10.64's original tests, asserting `unauthorized`
      // straight off the route. Task 10.67 added `RowValidator.identityColumn`
      // type checks that now catch both shapes first, so the route reports
      // `invalid` — validation's refusal, not authorization's. The backstop
      // these used to be the only coverage of is proved directly, with
      // validation bypassed, in the group above; these stay to pin what a
      // real client actually observes on the wire.
      test(
        'author rule: a new Observations row with a non-string user_id',
        () async {
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.observations: [
                {
                  ...observation('obs-bad-user', projectId: projectA, userId: alice),
                  'user_id': 12345,
                },
              ],
            },
          );
          expect(
            outcomeFor(result, Tables.observations, 'obs-bad-user', project: projectA),
            SyncRowOutcome.invalid,
            reason:
                'RowValidator (task 10.67) now refuses a non-string user_id '
                'before authorization runs; see the direct RowAuthorizer '
                'test above for the backstop this used to exercise',
          );
        },
      );

      test(
        'owner rule: a brand-new Projects row with a non-string owner_user_id',
        () async {
          final result = await pushAs(
            alice,
            projectId: 'proj-crash-test',
            rows: {
              Tables.projects: [
                {
                  'project_id': 'proj-crash-test',
                  'project_name': 'Crash Test',
                  'owner_user_id': 12345,
                  'creation_date': '2026-08-01T12:00:00.000Z',
                  'datum': 'WGS84',
                  'created_at': '2026-08-01T12:00:00.000Z',
                  'updated_at': '2026-08-01T12:00:00.000Z',
                  'revision': 0,
                  'coordinate_format': 'dd',
                  'triangulation_window_minutes': 15,
                },
              ],
            },
          );
          expect(
            result.outcomes['${Tables.projects}/proj-crash-test'],
            SyncRowOutcome.invalid,
            reason:
                'RowValidator (task 10.67) now refuses a non-string '
                'owner_user_id before authorization runs; see the direct '
                'RowAuthorizer test above for the backstop this used to '
                'exercise',
          );
        },
      );
    },
  );

  // ==========================================================================
  // Task 11.24 / 11.93 — a record naming somebody must name the caller.
  // ==========================================================================
  //
  // Before task 11.93 these were one derivation: `MutationRule.namesRowAuthor`
  // was both "governed by an author rule" and "names somebody" — the two
  // questions had the same answer for every table. `Actual_Tag_Locations`
  // broke that (it names a finder and is `anyUser`), and 11.93 answered with
  // a second, separately-derived group rather than widening the first, which
  // would have pulled in `Projects` and `Project_Memberships` for reasons
  // that have nothing to do with naming.
  //
  // Task 11.96 asked whether the two become one derivation over
  // `SyncTable.identityUserColumns`. For the naming invariant itself — a
  // forged identity column is refused, whichever rule governs the row — yes:
  // the group below derives its affected set from `identityUserColumns` minus
  // `MutationRule.isAuthorizationState` (which excludes `Projects` and
  // `Project_Memberships` for the reason above), and that is exactly the
  // union of the two former sets. What does **not** unify is what a table's
  // rule permits once the name is honest: an author-ruled table refuses
  // everyone but the author outright, while `Actual_Tag_Locations` stays
  // `anyUser` and only the identity column is locked. That half has no
  // equivalent among the author-ruled tables, so it stays in its own group
  // below rather than being forced into this one.

  group(
    'a row naming somebody who is not the row\'s authorization state must '
    'name the caller',
    skip: databaseSkipReason,
    () {
      const colleague = 'user-bob';

      setUp(() async {
        if (testDatabaseConfig == null) return;
        // Bob is a contributor on Alice's project, so `ProjectReachability`
        // names him — which is precisely the state finding N-1 exploits. Every
        // refusal below therefore has to come from the naming rule and not
        // from Bob being a stranger.
        await _addMember(connection, projectId: projectA, userId: colleague);
      });

      /// One row per table naming somebody without that table being its own
      /// authorization state, built under [userId]'s name. `Projects` and
      /// `Project_Memberships` are excluded ([MutationRule.isAuthorizationState])
      /// — a forged owner or membership is a different attack, covered by
      /// "the rule table, enforced" above.
      ///
      /// **Keyed by table so a table with no builder fails the suite.** The
      /// assertion below is the point of this group: task 11.9 named two
      /// tables, task 11.23 read the code and found a third, and a hand-kept
      /// list here would have gone on measuring the first two. A table that
      /// declares an identity column and has no entry here is a red test, not
      /// a silent gap.
      final builders = <String, Map<String, Object?> Function(String)>{
        Tables.observations: (userId) =>
            observation('obs-forged', projectId: projectA, userId: userId),
        Tables.observationExclusions: (userId) => {
          'exclusion_id': 'excl-forged',
          'project_id': projectA,
          'observation_id': 'obs-any',
          'user_id': userId,
          'kind': 'superseded',
          'superseded_by_observation_id': null,
          'reason': 'not my words',
          'created_at': '2026-08-01T12:00:00.000Z',
          'updated_at': '2026-08-01T12:00:00.000Z',
          'revision': 1,
          'last_modified_by': userId,
          'origin_device_id': 'device-A',
        },
        Tables.nonDetections: (userId) => {
          'non_detection_id': 'nd-forged',
          'project_id': projectA,
          'user_id': userId,
          'tag_ids_listened_for': 'tag-1',
          'timestamp_local': '2026-08-01T12:00:00.000Z',
          'timestamp_utc': '2026-08-01T12:00:00.000Z',
          'timezone_offset': '+00:00',
          'latitude': 35.19,
          'longitude': -111.65,
          'position_source': 'gps_fix',
          'elevation': 2100.0,
          'altitude_agl': 0.0,
          'notes': null,
          'created_at': '2026-08-01T12:00:00.000Z',
          'updated_at': '2026-08-01T12:00:00.000Z',
          'revision': 1,
          'last_modified_by': userId,
          'origin_device_id': 'device-A',
        },
        // Global, and closed by §4.18's authenticated-address rule rather
        // than by this one. Covered anyway: "another rule already handles it"
        // is a claim, and the suite should be the thing that checks it.
        Tables.users: (userId) => _userRow(userId, 'Forged'),
        Tables.userEmails: (userId) => {
          'user_email_id': 'ue-forged',
          'user_id': userId,
          'email': 'bob@example.com',
          'recorded_at': '2026-08-01T12:00:00.000Z',
          'created_at': '2026-08-01T12:00:00.000Z',
          'updated_at': '2026-08-01T12:00:00.000Z',
          'revision': 1,
          'last_modified_by': userId,
          'origin_device_id': 'device-A',
        },
        // Task 11.93: `anyUser`, and still names somebody. The write gate
        // this table leaves open — anybody may correct the point, nobody may
        // rewrite who found it — has no analogue among the tables above and
        // is exercised in the group below instead.
        Tables.actualTagLocations: (userId) => truthPoint(finder: userId),
      };

      /// The id a table's forged row can be found under afterward, and
      /// whether that lookup needs a project segment — see [outcomeFor].
      /// `Tables.users`' primary key *is* its identity column, so its id is
      /// the value being forged, not a fixed string like the others.
      String idFor(String table, String forgedAs) => table == Tables.users
          ? forgedAs
          : const {
              Tables.observations: 'obs-forged',
              Tables.observationExclusions: 'excl-forged',
              Tables.nonDetections: 'nd-forged',
              Tables.userEmails: 'ue-forged',
              Tables.actualTagLocations: 'loc-11-93',
            }[table]!;

      bool needsProject(String table) =>
          syncTablesByName[table]!.projectScopeColumn != null;

      /// Rows a table's push needs alongside its own, in `pushAs`'s `rows`
      /// map — only `Actual_Tag_Locations` references a tag that has to
      /// exist first.
      Map<String, List<Map<String, Object?>>> companionRows(String table) =>
          table == Tables.actualTagLocations ? {Tables.tags: theTag()} : {};

      test('every table naming somebody it is not the authorization state '
          'for has a case here', () {
        final declared = {
          for (final table in syncTables)
            if (table.identityUserColumns.isNotEmpty &&
                !tableMutationRules[table.name]!.isAuthorizationState)
              table.name,
        };
        expect(
          builders.keys.toSet(),
          declared,
          reason:
              'The set of tables a forged name can be filed under is every '
              'table with an identity column that is not itself the row\'s '
              'authorization state — `SyncTable.identityUserColumns` minus '
              '`MutationRule.isAuthorizationState` — not a list somebody '
              'maintains. A table on one side and not the other means either '
              'an unprobed table (finding N-1 lived on one of those for '
              'three rounds) or a stale case measuring nothing.',
        );
      }, skip: null);

      for (final table in builders.keys) {
        test('a contributor cannot file a $table row under a teammate\'s '
            'name', () async {
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              ...companionRows(table),
              table: [builders[table]!(colleague)],
            },
          );
          expect(
            outcomeFor(
              result,
              table,
              idFor(table, colleague),
              project: needsProject(table) ? projectA : null,
            ),
            SyncRowOutcome.unauthorized,
            reason:
                '$table names somebody in an identity column, so the row '
                'must name the caller',
          );
        });
      }

      test('and can still file its own', () async {
        for (final table in [
          Tables.observations,
          Tables.observationExclusions,
          Tables.nonDetections,
          Tables.actualTagLocations,
        ]) {
          // Alice's own `Users`/`User_Emails` rows already exist from _seed,
          // so pushing them again would be an update, not the insert this
          // positive control checks for — that is why those two tables are
          // not in this loop even though they are in [builders].
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              ...companionRows(table),
              table: [builders[table]!(alice)],
            },
          );
          expect(
            outcomeFor(
              result,
              table,
              idFor(table, alice),
              project: needsProject(table) ? projectA : null,
            ),
            SyncRowOutcome.inserted,
            reason:
                'the positive control: a refusal of $table for everybody '
                'would pass the attack above while measuring nothing',
          );
        }
      });
    },
  );

  // ==========================================================================
  // Task 11.93 — a truth point stays shared once its finder is named.
  // ==========================================================================
  //
  // The naming invariant itself (a forged finder is refused) is covered by
  // the group above. What is unique to `Actual_Tag_Locations` — the write
  // gate it leaves open — has no analogue among the author-ruled tables and
  // stays here rather than being forced into that derivation.

  group(
    'task 11.93 — a truth point names its finder and is still shared',
    skip: databaseSkipReason,
    () {
      const colleague = 'user-bob';

      setUp(() async {
        if (testDatabaseConfig == null) return;
        // Bob is a contributor on Alice's project, so `ProjectReachability`
        // names him. Every refusal below therefore comes from the naming rule
        // and not from Bob being a stranger — the same care task 11.24 took.
        await _addMember(connection, projectId: projectA, userId: colleague);
      });

      // **The gate this task was forbidden to tighten, at the boundary.**
      //
      // The person who saw the pride and the person driving the truck may not
      // be the same person, so a colleague must be able to correct a point
      // somebody else found. If the server refused this, recording the finder
      // would have quietly become a permission — which is exactly what
      // Michael ruled out.
      test('a contributor may correct a point somebody else found', () async {
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: theTag(),
            Tables.actualTagLocations: [truthPoint(finder: alice)],
          },
        );

        final result = await pushAs(
          colleague,
          projectId: projectA,
          rows: {
            Tables.actualTagLocations: [
              truthPoint(
                finder: alice,
                revision: 2,
                precision: 40.0,
                // Who made *this* change, which is Bob — a different fact from
                // who found the collar, and the one the audit column carries.
                modifiedBy: colleague,
              ),
            ],
          },
        );
        expect(
          outcomeFor(result, Tables.actualTagLocations, 'loc-11-93',
              project: projectA),
          SyncRowOutcome.updated,
        );

        final stored = await connection.execute(
          'SELECT user_id, uncertainty_radius, last_modified_by '
          'FROM ${quoted(Tables.actualTagLocations)} '
          r'WHERE location_id = $1',
          parameters: ['loc-11-93'],
        );
        expect(
          stored.first[0],
          alice,
          reason: 'Bob corrected the figure; he did not become the person who '
              'found the collar',
        );
        expect(stored.first[1], 40.0);
        expect(stored.first[2], colleague);
      });

      test('but cannot rewrite who found it', () async {
        await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: theTag(),
            Tables.actualTagLocations: [truthPoint(finder: alice)],
          },
        );

        final result = await pushAs(
          colleague,
          projectId: projectA,
          rows: {
            Tables.actualTagLocations: [
              truthPoint(finder: colleague, revision: 2, modifiedBy: colleague),
            ],
          },
        );
        expect(
          outcomeFor(result, Tables.actualTagLocations, 'loc-11-93',
              project: projectA),
          SyncRowOutcome.unauthorized,
          reason: 'reattribution: taking credit for finding a collar somebody '
              'else found is the same defect as signing their name to it',
        );
      });
    },
  );

  group(
    'task 11.24 — an update must say the caller made it',
    skip: databaseSkipReason,
    () {
      setUp(() async {
        if (testDatabaseConfig == null) return;
        await _addMember(connection, projectId: projectA, userId: 'user-bob');
        await connection.execute(
          'INSERT INTO ${quoted(Tables.observationExclusions)} '
          '(exclusion_id, project_id, observation_id, user_id, kind, '
          'reason, created_at, updated_at, revision, last_modified_by) '
          r"VALUES ('excl-1', $1, 'obs-1', $2, 'superseded', 'mine', $3, $3, "
          r'1, $2)',
          parameters: [projectA, 'user-bob', DateTime.utc(2026, 8, 1, 12)],
        );
      });

      Map<String, Object?> withdrawal({required String modifiedBy}) => {
        'exclusion_id': 'excl-1',
        'project_id': projectA,
        'observation_id': 'obs-1',
        'user_id': 'user-bob',
        'kind': 'superseded',
        'superseded_by_observation_id': null,
        'reason': 'mine',
        'created_at': '2026-08-01T12:00:00.000Z',
        'updated_at': '2026-08-02T12:00:00.000Z',
        'deleted_at': '2026-08-02T12:00:00.000Z',
        'revision': 2,
        'last_modified_by': modifiedBy,
        'origin_device_id': 'device-A',
      };

      test(
        'an owner withdrawing a contributor\'s mark cannot leave the '
        'contributor\'s name on the withdrawal',
        () async {
          // This is task 11.18's "…then withdrawn by *name*" sentence in the
          // Team log. The forgery is not a rewrite — it is leaving the audit
          // column exactly as stored, which every other clause permits by
          // design and which an insert-only fix for N-1 would not have
          // touched.
          final result = await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.observationExclusions: [
                withdrawal(modifiedBy: 'user-bob'),
              ],
            },
          );
          expect(
            outcomeFor(
              result,
              Tables.observationExclusions,
              'excl-1',
              project: projectA,
            ),
            SyncRowOutcome.unauthorized,
          );
        },
      );

      test('the same withdrawal, stamped honestly, still works', () async {
        // Task 11.15's whole purpose: a mark whose author has left the
        // project must still be withdrawable by an owner. A fix that broke
        // this would trade one wrong record for an unrecoverable one.
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.observationExclusions: [withdrawal(modifiedBy: alice)],
          },
        );
        expect(
          outcomeFor(
            result,
            Tables.observationExclusions,
            'excl-1',
            project: projectA,
          ),
          SyncRowOutcome.updated,
        );
      });
    },
  );

  group(
    'task 11.24 — owner-only rules the app claims, checked at the server',
    skip: databaseSkipReason,
    () {
      setUp(() async {
        if (testDatabaseConfig == null) return;
        await _addMember(connection, projectId: projectA, userId: 'user-bob');
        // One insert since task 11.219, not two: the tag's own `project_id`
        // says what the `Project_Tags` link used to say.
        await connection.execute(
          'INSERT INTO ${quoted(Tables.tags)} '
          '(tag_id, project_id, lineage_id, frequency_mhz, tag_name, '
          'status, color_hex, created_at, updated_at, revision, '
          'last_modified_by) '
          r"VALUES ('tag-1', $1, 'tag-1', 150.1, 'Collar', 'active', "
          r"'#FF0000', $2, $2, 1, $3)",
          parameters: [
            projectA,
            DateTime.utc(2026, 8, 1, 12),
            alice,
          ],
        );
      });

      /// The stored `tag-1`, changed. **`deletedAt` is what tombstones it**,
      /// and that route is the one the app has no button for.
      ///
      /// **`status` takes a `TagStatus`, not the link table's vocabulary.**
      /// These tests used to set `Project_Tags.status` to `'inactive'`, which
      /// was that table's own two-valued flag; `Tags.status` is
      /// `active | recovered | lost | malfunction`, so *taking a tag out of the
      /// project* is `'recovered'` — the collar came back off the animal. An
      /// `'inactive'` value here is refused as `invalid` by `RowValidator`
      /// before authorization is consulted at all, which is how this was
      /// found.
      Map<String, Object?> retune({
        required String modifiedBy,
        required int revision,
        String status = 'active',
        String? deletedAt,
      }) => {
        ..._tagRow('tag-1', projectId: projectA, modifiedBy: modifiedBy),
        'tag_name': 'Collar',
        'status': status,
        'deleted_at': deletedAt,
        'revision': revision,
      };

      // **All four tests below moved from `Project_Tags` to `Tags` (task
      // 11.219), and one of them changed its answer.** Task 11.24's finding was
      // that taking a tag out of a project was owner-only in the app and
      // unchecked at the server; the rule lived in `DenialReason
      // .removeTagRequiresOwner`, about the link row being deactivated or
      // tombstoned. **That reason was absorbed into `changeTagRequiresOwner`**,
      // whose doc comment records why: a tag belongs to one project now, so
      // removing it from that project *is* changing it, and one rule covers
      // both routes.

      test(
        'a contributor cannot take a tag out of the project',
        () async {
          final result = await pushAs(
            'user-bob',
            projectId: projectA,
            rows: {
              Tables.tags: [
                retune(modifiedBy: 'user-bob', status: 'recovered', revision: 2),
              ],
            },
          );
          expect(
            outcomeFor(result, Tables.tags, 'tag-1', project: projectA),
            SyncRowOutcome.unauthorized,
          );
        },
      );

      test(
        'nor tombstone it, which is the route the app has no button for',
        () async {
          // **The route worth keeping most.** The app has no method that
          // tombstones a tag, so this is reachable only by a crafted push or by
          // a device editing its own SQLite file — which §4.23 says is always
          // possible. It used to be a second clause because `Project_Tags` was
          // `MutationRule.anyUser` and a tombstone slipped past the status
          // check; it is the same rule as the status change now, and it is
          // asserted separately anyway because "the same rule covers both" is a
          // claim about code that a test should not have to take on trust.
          final result = await pushAs(
            'user-bob',
            projectId: projectA,
            rows: {
              Tables.tags: [
                retune(
                  modifiedBy: 'user-bob',
                  revision: 2,
                  deletedAt: '2026-08-02T12:00:00.000Z',
                ),
              ],
            },
          );
          expect(
            outcomeFor(result, Tables.tags, 'tag-1', project: projectA),
            SyncRowOutcome.unauthorized,
          );
        },
      );

      test('an owner still can', () async {
        final result = await pushAs(
          alice,
          projectId: projectA,
          rows: {
            Tables.tags: [
              retune(modifiedBy: alice, status: 'recovered', revision: 2),
            ],
          },
        );
        expect(
          outcomeFor(result, Tables.tags, 'tag-1', project: projectA),
          SyncRowOutcome.updated,
        );
      });

      test(
        'and a contributor may NOT put it back — task 11.219 moved where the '
        'asymmetry falls',
        () async {
          // **This test's expectation is inverted, and the inversion is a real
          // change in what a contributor may do rather than a repair.**
          //
          // It used to read *"a contributor may still put a tag back — only the
          // subtraction is reserved"*, and it passed: reactivating a
          // `Project_Tags` link was additive and unblocking, on the same rung as
          // creating a tag, so it deliberately did not inherit the owner-only
          // removal rule.
          //
          // Task 11.219 moved the asymmetry. It is no longer *add versus
          // remove*; it is **create versus change** — `_authorizeTagLifecycle`
          // lets a contributor create a tag and reserves every change to an
          // existing one for an owner. Un-retiring a tag is a change to an
          // existing row, so it is now owner-only.
          //
          // **What that costs a person, stated rather than left to be
          // discovered:** a contributor who finds a tag somebody retired cannot
          // un-retire it. They can create a new tag, or ask an owner. That is a
          // narrowing 11.219 did not call out, and it is recorded in Discovered
          // Scope under task 11.220 so somebody decides whether it is wanted
          // rather than inheriting it.
          //
          // The outcome below was measured on 2026-09-10, not predicted.
          await pushAs(
            alice,
            projectId: projectA,
            rows: {
              Tables.tags: [
                retune(modifiedBy: alice, status: 'recovered', revision: 2),
              ],
            },
          );

          final result = await pushAs(
            'user-bob',
            projectId: projectA,
            rows: {
              Tables.tags: [retune(modifiedBy: 'user-bob', revision: 3)],
            },
          );
          expect(
            outcomeFor(result, Tables.tags, 'tag-1', project: projectA),
            SyncRowOutcome.unauthorized,
            reason:
                'a contributor changing an existing tag is refused whichever '
                'direction the change goes — see changeTagRequiresOwner',
          );
          final stored = await connection.execute(
            'SELECT status FROM ${quoted(Tables.tags)} '
            r"WHERE tag_id = 'tag-1' AND project_id = $1",
            parameters: [projectA],
          );
          expect(
            stored.single.first,
            'recovered',
            reason: 'positive control: the tag really was retired first, so the '
                'refusal above is about putting it back and not about a row '
                'that was never changed',
          );
        },
      );

      test(
        'the exclusion rung is judged on the STORED kind, not the pushed one',
        () async {
          // A demoted owner's own `excluded` mark. Withdrawing it honestly is
          // refused; before task 11.24 the same withdrawal with `kind`
          // flipped to `superseded` in the same row was accepted — one row
          // that both escaped the rung and rewrote what the mark said it was.
          await connection.execute(
            'INSERT INTO ${quoted(Tables.observationExclusions)} '
            '(exclusion_id, project_id, observation_id, user_id, kind, '
            'created_at, updated_at, revision, last_modified_by) '
            r"VALUES ('excl-x', $1, 'obs-1', $2, 'excluded', $3, $3, 1, $2)",
            parameters: [projectA, 'user-bob', DateTime.utc(2026, 8, 1, 12)],
          );

          final result = await pushAs(
            'user-bob',
            projectId: projectA,
            rows: {
              Tables.observationExclusions: [
                {
                  'exclusion_id': 'excl-x',
                  'project_id': projectA,
                  'observation_id': 'obs-1',
                  'user_id': 'user-bob',
                  'kind': 'superseded',
                  'superseded_by_observation_id': null,
                  'reason': null,
                  'created_at': '2026-08-01T12:00:00.000Z',
                  'updated_at': '2026-08-02T12:00:00.000Z',
                  'deleted_at': '2026-08-02T12:00:00.000Z',
                  'revision': 2,
                  'last_modified_by': 'user-bob',
                  'origin_device_id': 'device-A',
                },
              ],
            },
          );
          expect(
            outcomeFor(
              result,
              Tables.observationExclusions,
              'excl-x',
              project: projectA,
            ),
            SyncRowOutcome.unauthorized,
          );
        },
      );
    },
  );
}

/// A `Tags` row, for fixtures that need shared project vocabulary.
///
/// `projectId` is required since task 11.219 — a tag belongs to one project and
/// the column is `NOT NULL`. Required rather than defaulted so a fixture cannot
/// silently be about a project nobody named.
Map<String, Object?> _tagRow(
  String id, {
  required String projectId,
  required String modifiedBy,
}) => {
  'tag_id': id,
  'project_id': projectId,
  'lineage_id': id,
  'frequency_mhz': 150.1,
  'tag_name': 'Collar $id',
  'status': 'active',
  'color_hex': '#FF0000',
  'created_at': '2026-08-01T12:00:00.000Z',
  'updated_at': '2026-08-01T12:00:00.000Z',
  'revision': 1,
  'last_modified_by': modifiedBy,
  'origin_device_id': 'device-A',
};

// **`_projectTagRow` is gone (task 11.219).** It built the row that linked a
// global tag into a project, and there is no global tag to link — a tag is
// created inside the project that holds it, so `_tagRow`'s `projectId` is what
// that row used to say.

Map<String, Object?> _userRow(String userId, String firstName) => {
  'user_id': userId,
  'first_name': firstName,
  'last_name': 'Ranger',
  'email': '${firstName.toLowerCase()}@example.com',
  'created_at': '2026-08-01T12:00:00.000Z',
  'updated_at': '2026-08-01T12:00:00.000Z',
  'revision': 1,
  'last_modified_by': userId,
  'origin_device_id': 'device-A',
};

/// Seeds an open membership.
///
/// **The default role is `contributor`, and task 11.3 changed it from
/// `viewer`.** Every caller of this helper is testing something the *rule
/// table* must refuse — forging a colleague's observation, granting yourself a
/// role, rewriting the project row — and a `viewer` is now refused before the
/// rule table is consulted at all ([RowAuthorizer._authorizeRole]). Leaving the
/// default at `viewer` would have left those tests green for a reason none of
/// them is about, which is the vacuous pass this project keeps finding in its
/// own instruments. A contributor is the hardest member to refuse, so it is the
/// one these fixtures use.
Future<void> _addMember(
  Connection connection, {
  required String projectId,
  required String userId,
  String role = 'contributor',
}) async {
  final at = DateTime.utc(2026, 8, 1, 12);
  await connection.execute(
    'INSERT INTO ${quoted(Tables.projectMemberships)} '
    '(membership_id, project_id, user_id, role, join_date, created_at, '
    'updated_at, revision) '
    r'VALUES ($1, $2, $3, $4, $5, $5, $5, 0)',
    parameters: ['mem-$projectId-$userId', projectId, userId, role, at],
  );
}

Future<void> _seed(Connection connection) async {
  final at = DateTime.utc(2026, 8, 1, 12);
  await connection.runTx((tx) async {
    for (final (id, name, email) in [
      ('user-alice', 'Alice', 'alice@example.com'),
      ('user-bob', 'Bob', 'bob@example.com'),
    ]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision) '
        r'VALUES ($1, $2, $3, $4, $5, $5, 0)',
        parameters: [id, name, 'Ranger', email, at],
      );
      // The account behind the profile. Seeded because a caller with a session
      // always has one — and since task 10.55 the server checks a pushed
      // `Users.email` against it, so a fixture without accounts would be a
      // fixture where nobody's own profile can sync.
      await tx.execute(
        r'INSERT INTO auth_accounts (user_id, email, created_at) '
        r'VALUES ($1, $2, $3)',
        parameters: [id, email, at],
      );
    }
    for (final (project, owner) in [
      ('proj-a', 'user-alice'),
      ('proj-b', 'user-bob'),
    ]) {
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projects)} '
        '(project_id, project_name, owner_user_id, creation_date, datum, '
        'created_at, updated_at, revision, coordinate_format, '
        'triangulation_window_minutes) '
        r"VALUES ($1, 'Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
        parameters: [project, owner, at],
      );
    }
  });
}
