@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.81 — the join code and the owner's approval, which is the
/// security-carrying part.**
///
/// ## What replaced what, and what that did to this file
///
/// The suite this replaces (`invite_service_test.dart`) circled one property:
/// **a code redeems only for a session the server has authenticated as the
/// address the invitation names.** That binding was the whole reason an
/// 8-character code was acceptable — a code read off a whiteboard, forwarded,
/// or overheard on a radio was worth nothing to whoever picked it up.
///
/// **That property is gone on purpose, and its group has no analogue here.** A
/// join code is shared by design; anybody holding it may ask. What carries the
/// security now is one sentence, and almost every test below is a way of asking
/// whether it is true of the server rather than only of the design document:
///
/// > **Holding the code buys the right to ask. Only an owner's approval creates
/// > a membership.**
///
/// The groups that *did* survive are the ones that were never about invitations
/// at all — what a grant writes, and the membership lifecycle. Those are
/// membership law, and they are unchanged.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_join_test';

  const alice = 'user-alice'; // owner of proj-a
  const bob = 'user-bob'; // the person asking to join
  const carol = 'user-carol'; // somebody else entirely
  const projectA = 'proj-a';
  const projectB = 'proj-b';

  const aliceEmail = 'alice@example.org';
  const bobEmail = 'bob@example.org';
  const carolEmail = 'carol@example.org';

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
      for (final (id, email) in [
        (alice, aliceEmail),
        (bob, bobEmail),
        (carol, carolEmail),
      ]) {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.users)} '
          '(user_id, first_name, last_name, email, created_at, updated_at, '
          'revision) '
          r"VALUES ($1, 'Ranger', 'Person', $2, $3, $3, 0)",
          parameters: [id, email, at],
        );
        await tx.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r'VALUES ($1, $2, $3)',
          parameters: [id, email, at],
        );
      }
      for (final project in [projectA, projectB]) {
        await tx.execute(
          'INSERT INTO ${quoted(Tables.projects)} '
          '(project_id, project_name, owner_user_id, creation_date, datum, '
          'created_at, updated_at, revision, coordinate_format, '
          'triangulation_window_minutes) '
          r"VALUES ($1, 'Field', $2, $3, 'WGS84', $3, $3, 0, 'dd', 15)",
          parameters: [project, alice, at],
        );
      }
      await tx.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, role, created_at, '
        'updated_at, revision, last_modified_by) '
        r"VALUES ('m-alice', $1, $2, $3, 'owner', $3, $3, 0, $2)",
        parameters: [projectA, alice, at],
      );
    });
  });

  /// Runs [action] against a [JoinService] inside one transaction, exactly as
  /// the route does — approval decides the request and writes the membership it
  /// grants as one unit.
  Future<T> withService<T>(Future<T> Function(JoinService) action) =>
      connection.runTx(
        (tx) => action(
          JoinService(
            session: tx,
            sync: SyncService(session: tx),
          ),
        ),
      );

  /// Switches joining on for [projectId] and returns its code.
  Future<String> codeFor(String projectId, {int? limit}) => withService(
    (service) async => (await service.updateSettings(
      projectId: projectId,
      updatedBy: alice,
      joiningEnabled: true,
      teamSizeLimit: limit,
    )).code!,
  );

  Future<JoinRequestResult> ask(
    String code, {
    required String userId,
    required String email,
    String? claimedName,
  }) => withService(
    (service) => service.request(
      rawCode: code,
      userId: userId,
      authenticatedEmail: email,
      claimedName: claimedName,
      deviceId: 'device-B',
    ),
  );

  /// Asks on a **fresh, independent connection** rather than the suite's
  /// shared one.
  ///
  /// This is the piece the one-pending-request index needs and none of the
  /// helpers above provide. `connection` is one physical session, so two calls
  /// through it — however they are scheduled from Dart's side, `Future.wait`
  /// included — reach Postgres as one transaction fully finishing before the
  /// next begins: serialized, never actually overlapping. That exercises only
  /// the ordinary "already asked" read, which a read-then-write can satisfy
  /// even when it is not race-safe. Proving the *index* is what closes the gap
  /// needs two statements from two different sessions genuinely in flight at
  /// once, which needs two sockets. Carried over verbatim from task 11.10's
  /// technique, because the race is the same race.
  Future<JoinRequestResult> askOnOwnConnection(
    String code, {
    required String userId,
    required String email,
  }) async {
    final own = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    try {
      await own.execute('SET search_path TO $testSchema');
      return await own.runTx(
        (tx) =>
            JoinService(
              session: tx,
              sync: SyncService(session: tx),
            ).request(
              rawCode: code,
              userId: userId,
              authenticatedEmail: email,
              claimedName: null,
              deviceId: 'device-race',
            ),
      );
    } finally {
      await own.close();
    }
  }

  Future<JoinDecisionResult> approve(
    String requestId, {
    String projectId = projectA,
    ProjectRole role = ProjectRole.contributor,
  }) => withService(
    (service) => service.approve(
      projectId: projectId,
      requestId: requestId,
      role: role,
      decidedBy: alice,
      deviceId: 'device-A',
    ),
  );

  Future<List<Map<String, Object?>>> membershipsOf(
    String projectId,
    String userId,
  ) async {
    final result = await connection.execute(
      'SELECT membership_id, role, end_date, deleted_at, server_seq '
      'FROM ${quoted(Tables.projectMemberships)} '
      r'WHERE project_id = $1 AND user_id = $2 ORDER BY membership_id',
      parameters: [projectId, userId],
    );
    return [for (final row in result) row.toColumnMap()];
  }

  String requestIdOf(JoinRequestResult result) =>
      (result as JoinRequestAccepted).requestId;

  group('the absent settings row means joining is OFF', () {
    // **The single most dangerous line in this whole change**, and the reason
    // it has a group to itself rather than a line in another test.
    //
    // Every project that existed before task 11.81 has no
    // `project_join_settings` row. A convenient "create the row on first read,
    // with joining enabled" would have silently opened **every one of them** to
    // anybody holding a code nobody had ever issued. The design document said
    // not to write that and to assert it; this is the assertion.
    test('a project with no row reports joining off', () async {
      final settings = await withService(
        (service) => service.settingsFor(projectA),
      );
      expect(settings.joiningEnabled, isFalse);
      expect(settings.code, isNull);
      expect(settings.teamSizeLimit, defaultTeamSizeLimit);
    });

    test('reading the settings creates nothing', () async {
      // The `DEFAULT FALSE` in the DDL says nothing about a row that was never
      // inserted, so the read path is what has to be checked. Read twice: if
      // the first read had quietly created a row, the second would be the one
      // that looked innocent.
      await withService((service) => service.settingsFor(projectA));
      await withService((service) => service.settingsFor(projectA));
      final rows = await connection.execute(
        'SELECT count(*) FROM project_join_settings',
      );
      expect(
        rows.first.first,
        0,
        reason:
            'reading join settings created a row, which would mean every '
            'project that predates this feature just acquired one',
      );
    });

    test('no code can be used against a project with no row', () async {
      final result = await ask('ABCD1234', userId: bob, email: bobEmail);
      expect(result, isA<JoinRequestRefused>());
      expect(
        (result as JoinRequestRefused).failure,
        JoinRequestFailure.codeNotValid,
      );
      expect(await membershipsOf(projectA, bob), isEmpty);
    });
  });

  group('the code buys the right to ask, and nothing else', () {
    test('a correct code creates a request and no membership', () async {
      final code = await codeFor(projectA);
      final result = await ask(code, userId: bob, email: bobEmail);

      expect(result, isA<JoinRequestAccepted>());
      expect((result as JoinRequestAccepted).projectName, 'Field');
      expect(
        await membershipsOf(projectA, bob),
        isEmpty,
        reason:
            'holding the code produced a membership, which is the failure '
            'this whole design exists to prevent',
      );
      final pending = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(pending.single.isPending, isTrue);
      // Copied from the session at request time, so the owner's list needs no
      // join against a `Users` row that may not exist.
      expect(pending.single.email, bobEmail);
    });

    test(
      'a shared code works for more than one person — that is the point',
      () async {
        final code = await codeFor(projectA);
        expect(
          await ask(code, userId: bob, email: bobEmail),
          isA<JoinRequestAccepted>(),
        );
        expect(
          await ask(code, userId: carol, email: carolEmail),
          isA<JoinRequestAccepted>(),
        );
        expect(
          await withService((service) => service.listRequests(projectA)),
          hasLength(2),
        );
      },
    );

    test('the code is typeable, and not a UUID', () async {
      final code = await codeFor(projectA);
      expect(code, hasLength(joinCodeLength));
      expect(code.split('').every(joinCodeAlphabet.contains), isTrue);
    });

    test('a typed code survives case, spacing and the O/0 confusion', () async {
      final code = await codeFor(projectA);
      final typed = formatJoinCode(code).toLowerCase().replaceAll('-', ' ');
      expect(
        await ask(typed, userId: bob, email: bobEmail),
        isA<JoinRequestAccepted>(),
      );
    });

    test('two projects never share a code', () async {
      expect(await codeFor(projectA), isNot(await codeFor(projectB)));
    });

    test('a malformed code never reaches the database', () async {
      // Refused before `canonicalizeJoinCode` can be used to time a lookup.
      final result = await ask('not a code', userId: bob, email: bobEmail);
      expect(
        (result as JoinRequestRefused).failure,
        JoinRequestFailure.codeNotValid,
      );
    });
  });

  group('the uniform refusal, and the three exceptions to it', () {
    test('switched off, wrong, and unknown all answer the same', () async {
      // **The existence oracle.** If these differed, somebody sweeping codes
      // would learn which guesses named a real project.
      final code = await codeFor(projectA);
      await withService(
        (service) => service.updateSettings(
          projectId: projectA,
          updatedBy: alice,
          joiningEnabled: false,
        ),
      );

      final failures = <JoinRequestFailure>{};
      for (final attempt in [code, 'ZZZZ9999', 'QQQQ1111']) {
        final result = await ask(attempt, userId: bob, email: bobEmail);
        failures.add((result as JoinRequestRefused).failure);
      }
      expect(failures, {JoinRequestFailure.codeNotValid});
    });

    test('a code for a tombstoned project draws the uniform refusal', () async {
      final code = await codeFor(projectA);
      await connection.execute(
        'UPDATE ${quoted(Tables.projects)} SET deleted_at = \$1 '
        r'WHERE project_id = $2',
        parameters: [at, projectA],
      );
      final result = await ask(code, userId: bob, email: bobEmail);
      expect(
        (result as JoinRequestRefused).failure,
        JoinRequestFailure.codeNotValid,
      );
    });

    test(
      'already a member is told so, because it is a fact about them',
      () async {
        // Answering the uniform refusal here would send a member to the owner
        // for a new code that would do nothing.
        final code = await codeFor(projectA);
        final result = await ask(code, userId: alice, email: aliceEmail);
        expect(
          (result as JoinRequestRefused).failure,
          JoinRequestFailure.alreadyMember,
        );
      },
    );

    test('asking twice is told so', () async {
      final code = await codeFor(projectA);
      await ask(code, userId: bob, email: bobEmail);
      final again = await ask(code, userId: bob, email: bobEmail);
      expect(
        (again as JoinRequestRefused).failure,
        JoinRequestFailure.alreadyRequested,
      );
    });

    test(
      'the one-pending-request rule is the database index, not a read',
      () async {
        // **Task 11.10's race and task 11.10's fix.** Two genuinely concurrent
        // requests on two sockets: the read-then-write above can be satisfied by
        // both before either writes, and only the partial unique index decides
        // it. Losing the race lands on the same refusal the ordinary path gives,
        // so the person sees one answer either way.
        final code = await codeFor(projectA);
        final results = await Future.wait([
          askOnOwnConnection(code, userId: bob, email: bobEmail),
          askOnOwnConnection(code, userId: bob, email: bobEmail),
        ]);
        expect(results.whereType<JoinRequestAccepted>(), hasLength(1));
        final refused = results.whereType<JoinRequestRefused>().single;
        expect(refused.failure, JoinRequestFailure.alreadyRequested);

        final rows = await connection.execute(
          'SELECT count(*) FROM project_join_requests '
          r'WHERE project_id = $1 AND user_id = $2 AND decided_at IS NULL',
          parameters: [projectA, bob],
        );
        expect(rows.first.first, 1);
      },
    );

    test(
      'the team is full counts pending requests as well as members',
      () async {
        // Alice already occupies one place. With a limit of 2, Bob's *pending*
        // request occupies the second, and Carol is refused — which is the
        // behaviour the refusal copy has to explain or nobody can act on it.
        final code = await codeFor(projectA, limit: 2);
        expect(
          await ask(code, userId: bob, email: bobEmail),
          isA<JoinRequestAccepted>(),
        );
        final carolResult = await ask(code, userId: carol, email: carolEmail);
        expect(
          (carolResult as JoinRequestRefused).failure,
          JoinRequestFailure.teamFull,
        );
      },
    );

    test(
      'approving does not need a free place, because pending held one',
      () async {
        // The tidy consequence of counting pending toward the limit: approval
        // converts a request into a member and leaves the total unchanged. If
        // approval also checked the limit, an owner could fill their team and
        // then be unable to admit the very people they were waiting on.
        final code = await codeFor(projectA, limit: 2);
        final asked = await ask(code, userId: bob, email: bobEmail);
        expect(await approve(requestIdOf(asked)), isA<JoinDecisionApplied>());
        expect(await membershipsOf(projectA, bob), hasLength(1));
      },
    );
  });

  group('the claimed name, which is the one caller-supplied string', () {
    test('it is stored and shown to the owner', () async {
      final code = await codeFor(projectA);
      await ask(code, userId: bob, email: bobEmail, claimedName: 'Dana Reyes');
      final pending = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(pending.single.claimedName, 'Dana Reyes');
      // The email beside it is the one the *server* authenticated. The two are
      // separate fields precisely because they are not equally trustworthy.
      expect(pending.single.email, bobEmail);
    });

    test('a bidirectional override is refused', () async {
      // **The attack the owner's pending list is uniquely exposed to.** It is
      // the one screen in this app where somebody decides whether to trust a
      // person by reading a string, and a right-to-left override makes a
      // stranger's name render as a colleague's with nothing to show for it.
      final code = await codeFor(projectA);
      final result = await ask(
        code,
        userId: bob,
        email: bobEmail,
        // U+202E, written as an escape because a literal one is invisible in a
        // diff — which is the whole reason it is refused.
        claimedName: 'Ann\u202EeciovSmith',
      );
      expect(
        (result as JoinRequestRefused).failure,
        JoinRequestFailure.invalidName,
      );
      expect(
        await withService((service) => service.listRequests(projectA)),
        isEmpty,
        reason: 'the refused name was stored anyway',
      );
    });

    test('a control character is refused', () async {
      final code = await codeFor(projectA);
      for (final name in const [
        'Ann\u0000Smith',
        'Ann\nSmith',
        'Ann\u007FSmith',
      ]) {
        final result = await ask(
          code,
          userId: bob,
          email: bobEmail,
          claimedName: name,
        );
        expect(
          (result as JoinRequestRefused).failure,
          JoinRequestFailure.invalidName,
        );
      }
    });

    test('an over-long name is refused at the shared bound', () async {
      // The *same* number `Users.first_name` carries, read from
      // `TextBound.personName` rather than restated — so a name refused on a
      // synced row cannot arrive through this route instead.
      final code = await codeFor(projectA);
      final result = await ask(
        code,
        userId: bob,
        email: bobEmail,
        claimedName: 'a' * (TextBound.personName.maxLength + 1),
      );
      expect(
        (result as JoinRequestRefused).failure,
        JoinRequestFailure.invalidName,
      );
    });

    test('an empty or absent name does not break the request', () async {
      // The email is what identifies. A missing name must render as absent
      // rather than stop somebody joining.
      final code = await codeFor(projectA);
      final result = await ask(
        code,
        userId: bob,
        email: bobEmail,
        claimedName: '   ',
      );
      expect(result, isA<JoinRequestAccepted>());
      final pending = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(
        pending.single.claimedName,
        isNull,
        reason: 'whitespace was stored as a name, which would render as one',
      );
    });

    test('the name is never written onto the granted Users row', () async {
      // **It would be easy and it would be wrong.** That string exists to help
      // an owner recognise somebody at the moment of approval. Letting it
      // become the app's record of who took a bearing would turn a claim into
      // an attribution — the harm §4.17 is about.
      const stranger = 'user-stranger';
      await connection.execute(
        r'INSERT INTO auth_accounts (user_id, email, created_at) '
        r"VALUES ($1, 'stranger@example.org', $2)",
        parameters: [stranger, at],
      );
      final code = await codeFor(projectA);
      final asked = await ask(
        code,
        userId: stranger,
        email: 'stranger@example.org',
        claimedName: 'Totally Legitimate',
      );
      await approve(requestIdOf(asked));

      final users = await connection.execute(
        'SELECT first_name, last_name FROM ${quoted(Tables.users)} '
        r'WHERE user_id = $1',
        parameters: [stranger],
      );
      expect(users.first[0], '');
      expect(users.first[1], '');
    });
  });

  group('what approval writes', () {
    test('the role comes from the approval, never from the code', () async {
      // There is no such thing as a leaked *owner* code, because the code
      // carries no role at all.
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await approve(requestIdOf(asked), role: ProjectRole.viewer);
      expect((await membershipsOf(projectA, bob)).single['role'], 'viewer');
    });

    test(
      'the granted row gets a server_seq, so the next pull delivers it',
      () async {
        final code = await codeFor(projectA);
        final asked = await ask(code, userId: bob, email: bobEmail);
        await approve(requestIdOf(asked));
        expect(
          (await membershipsOf(projectA, bob)).single['server_seq'],
          isNotNull,
        );
      },
    );

    test(
      'the new member gets a Users row so the owner can pull the page',
      () async {
        // Not optional: `Project_Memberships.user_id` is a foreign key into
        // `Users`, and the owner's next pull would otherwise carry a membership
        // naming somebody whose `Users` row is missing — which the client's own
        // foreign key refuses, taking the whole page with it.
        const newcomer = 'user-newcomer';
        await connection.execute(
          r'INSERT INTO auth_accounts (user_id, email, created_at) '
          r"VALUES ($1, 'newcomer@example.org', $2)",
          parameters: [newcomer, at],
        );
        final code = await codeFor(projectA);
        final asked = await ask(
          code,
          userId: newcomer,
          email: 'newcomer@example.org',
        );
        await approve(requestIdOf(asked));

        final users = await connection.execute(
          'SELECT email, server_seq FROM ${quoted(Tables.users)} '
          r'WHERE user_id = $1',
          parameters: [newcomer],
        );
        expect(users, hasLength(1));
        expect(users.first[0], 'newcomer@example.org');
        expect(
          users.first[1],
          isNotNull,
          reason: 'it must also be deliverable',
        );
      },
    );

    test('an existing Users row is made deliverable again', () async {
      // The commoner case: their row has been here for weeks from another
      // project, and is below every existing member's cursor, so it is never
      // delivered again unless its `server_seq` is refreshed.
      final before = await connection.execute(
        'SELECT server_seq FROM ${quoted(Tables.users)} '
        r'WHERE user_id = $1',
        parameters: [bob],
      );
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await approve(requestIdOf(asked));
      final after = await connection.execute(
        'SELECT server_seq FROM ${quoted(Tables.users)} '
        r'WHERE user_id = $1',
        parameters: [bob],
      );
      expect(after.first.first, isNotNull);
      expect(after.first.first, isNot(before.first.first));
    });

    test("a request that is not this project's cannot be approved", () async {
      // One answer for "not yours" and "already decided", so an owner of A
      // cannot probe for B's request ids.
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      final result = await approve(requestIdOf(asked), projectId: projectB);
      expect(
        (result as JoinDecisionRefused).failure,
        JoinDecisionFailure.requestNotOpen,
      );
      expect(await membershipsOf(projectB, bob), isEmpty);
    });

    test('an already-decided request cannot be approved twice', () async {
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await approve(requestIdOf(asked));
      final again = await approve(requestIdOf(asked));
      expect(
        (again as JoinDecisionRefused).failure,
        JoinDecisionFailure.requestNotOpen,
      );
      expect(
        await membershipsOf(projectA, bob),
        hasLength(1),
        reason: 'a second approval wrote a second open membership',
      );
    });

    test('rejection writes nothing and marks the request', () async {
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      final result = await withService(
        (service) => service.reject(
          projectId: projectA,
          requestId: requestIdOf(asked),
          decidedBy: alice,
        ),
      );
      expect(result, isA<JoinDecisionApplied>());
      expect(await membershipsOf(projectA, bob), isEmpty);
      final mine = await withService((service) => service.myRequests(bob));
      expect(mine.single.decision, 'rejected');
    });
  });

  group('rotation', () {
    test('the old code stops working and the new one starts', () async {
      final old = await codeFor(projectA);
      final rotated = await withService(
        (service) => service.rotateCode(
          projectId: projectA,
          rotatedBy: alice,
          clearPending: false,
        ),
      );
      expect(rotated.code, isNot(old));
      expect(
        ((await ask(old, userId: bob, email: bobEmail)) as JoinRequestRefused)
            .failure,
        JoinRequestFailure.codeNotValid,
      );
      expect(
        await ask(rotated.code, userId: bob, email: bobEmail),
        isA<JoinRequestAccepted>(),
      );
    });

    test('pending requests survive by default', () async {
      final code = await codeFor(projectA);
      await ask(code, userId: bob, email: bobEmail);
      final rotated = await withService(
        (service) => service.rotateCode(
          projectId: projectA,
          rotatedBy: alice,
          clearPending: false,
        ),
      );
      expect(rotated.clearedPending, 0);
      final pending = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(pending.single.isPending, isTrue);
    });

    test('clearing marks requests cleared rather than deleting them', () async {
      // So the person's own status read tells them their request is gone,
      // instead of leaving them staring at "pending" forever.
      final code = await codeFor(projectA);
      await ask(code, userId: bob, email: bobEmail);
      final rotated = await withService(
        (service) => service.rotateCode(
          projectId: projectA,
          rotatedBy: alice,
          clearPending: true,
        ),
      );
      expect(rotated.clearedPending, 1);
      final mine = await withService((service) => service.myRequests(bob));
      expect(mine.single.decision, 'cleared');
    });

    test('the code is re-readable afterwards — Security Model 4.2.1', () async {
      // The whole of what the written exception to §4.2 buys: an owner who
      // closed the screen does not have to rotate and re-broadcast to a crew.
      final rotated = await withService(
        (service) => service.rotateCode(
          projectId: projectA,
          rotatedBy: alice,
          clearPending: false,
        ),
      );
      final settings = await withService(
        (service) => service.settingsFor(projectA),
      );
      expect(settings.code, rotated.code);
    });

    test('switching joining off does not clear the queue', () async {
      // It is not a way to dismiss people and must not be described as one.
      // They can still be approved.
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await withService(
        (service) => service.updateSettings(
          projectId: projectA,
          updatedBy: alice,
          joiningEnabled: false,
        ),
      );
      final pending = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(pending.single.isPending, isTrue);
      expect(await approve(requestIdOf(asked)), isA<JoinDecisionApplied>());
    });
  });

  group('re-admission', () {
    Future<JoinDecisionResult> readmit(
      String userId, {
      String projectId = projectA,
      ProjectRole role = ProjectRole.contributor,
    }) => withService(
      (service) => service.readmit(
        projectId: projectId,
        userId: userId,
        role: role,
        decidedBy: alice,
        deviceId: 'device-A',
      ),
    );

    Future<void> admitThenRemove(String userId, String email) async {
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: userId, email: email);
      await approve(requestIdOf(asked));
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} SET end_date = \$1 '
        r'WHERE project_id = $2 AND user_id = $3',
        parameters: [at, projectA, userId],
      );
    }

    test('it reverses a removal, with no code and no request', () async {
      await admitThenRemove(bob, bobEmail);
      expect(await readmit(bob), isA<JoinDecisionApplied>());
      final rows = await membershipsOf(projectA, bob);
      expect(rows, hasLength(2), reason: 'a new stint, not a reopened one');
      expect(rows.where((r) => r['end_date'] == null), hasLength(1));
      expect(
        rows.where((r) => r['end_date'] != null),
        hasLength(1),
        reason: "the prior stint's record is the point of keeping it",
      );
    });

    test('it cannot add a stranger', () async {
      // **The bound that makes it safe**, and it comes from the project's own
      // history rather than from a list somebody maintains.
      final result = await readmit(carol);
      expect(
        (result as JoinDecisionRefused).failure,
        JoinDecisionFailure.notAPastMember,
      );
      expect(await membershipsOf(projectA, carol), isEmpty);
    });

    test('a current member draws the same refusal as a stranger', () async {
      // One answer for both, so this route cannot be used to ask questions
      // about a user id.
      final current = await readmit(alice);
      final stranger = await readmit(carol);
      expect(
        (current as JoinDecisionRefused).failure,
        (stranger as JoinDecisionRefused).failure,
      );
    });

    test('it counts toward the team-size limit', () async {
      await admitThenRemove(bob, bobEmail);
      await withService(
        (service) => service.updateSettings(
          projectId: projectA,
          updatedBy: alice,
          teamSizeLimit: 1,
        ),
      );
      final result = await readmit(bob);
      expect(
        (result as JoinDecisionRefused).failure,
        JoinDecisionFailure.teamFull,
      );
    });
  });

  group('the membership lifecycle', () {
    // **Membership law rather than joining law.** These carried over from the
    // invitation suite unchanged in substance: they were never about how
    // somebody was let in, only about what a grant may and may not do.
    test('one person can hold open memberships in many projects', () async {
      await connection.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, role, created_at, '
        'updated_at, revision, last_modified_by) '
        r"VALUES ('m-alice-b', $1, $2, $3, 'owner', $3, $3, 0, $2)",
        parameters: [projectB, alice, at],
      );
      for (final project in [projectA, projectB]) {
        final code = await codeFor(project);
        final asked = await ask(code, userId: bob, email: bobEmail);
        await approve(requestIdOf(asked), projectId: project);
      }
      expect(await membershipsOf(projectA, bob), hasLength(1));
      expect(await membershipsOf(projectB, bob), hasLength(1));
    });

    test('no second open row for somebody already on the project', () async {
      // `idx_memberships_one_open` (schema v8) is the backstop, and approval
      // catches its unique violation as a typed refusal rather than a 500.
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await approve(requestIdOf(asked));

      // A second request cannot even be made while they hold an open stint,
      // which is the first line of defence.
      final again = await ask(code, userId: bob, email: bobEmail);
      expect(
        (again as JoinRequestRefused).failure,
        JoinRequestFailure.alreadyMember,
      );
      expect(await membershipsOf(projectA, bob), hasLength(1));
    });

    test('renaming a project does not rename it on the screen of somebody '
        'who was turned down', () async {
      // Task 11.79, Michael's decision of 2026-08-31. The name used to be
      // joined live from the `Projects` row every time this route answered, so
      // renaming "Field season" to something specific handed that name to a
      // person the owner had refused. It is frozen onto the request now, the
      // same way the requester's email already was.
      final code = await codeFor(projectA);
      final asked = await ask(code, userId: bob, email: bobEmail);
      await withService(
        (service) => service.reject(
          projectId: projectA,
          requestId: requestIdOf(asked),
          decidedBy: alice,
        ),
      );

      await connection.execute(
        'UPDATE ${quoted(Tables.projects)} '
        r"SET project_name = 'Mexican wolf recovery — den sites' "
        r'WHERE project_id = $1',
        parameters: [projectA],
      );

      final bobsView = await withService((service) => service.myRequests(bob));
      expect(
        bobsView.single.projectName,
        'Field',
        reason:
            'the name this person is shown is the one the project had when '
            'they asked. Anything else hands a rename to somebody the owner '
            'refused',
      );
    });

    test("myRequests names only the caller's own", () async {
      final code = await codeFor(projectA);
      await ask(code, userId: bob, email: bobEmail);
      await ask(code, userId: carol, email: carolEmail);
      final bobsView = await withService((service) => service.myRequests(bob));
      expect(bobsView, hasLength(1));
      expect(bobsView.single.projectName, 'Field');
    });
  });

  group("the owner's view", () {
    test('it lists requests for this project only', () async {
      final codeA = await codeFor(projectA);
      final codeB = await codeFor(projectB);
      await ask(codeA, userId: bob, email: bobEmail);
      await ask(codeB, userId: carol, email: carolEmail);

      final listed = await withService(
        (service) => service.listRequests(projectA),
      );
      expect(listed, hasLength(1));
      expect(listed.single.email, bobEmail);
    });

    test(
      'the counts are members plus pending, and both are reported',
      () async {
        final code = await codeFor(projectA);
        await ask(code, userId: bob, email: bobEmail);
        final settings = await withService(
          (service) => service.settingsFor(projectA),
        );
        expect(settings.memberCount, 1, reason: 'Alice');
        expect(settings.pendingCount, 1, reason: 'Bob, waiting');
        // Rendered as two numbers rather than one, because an owner reading
        // "48 of 50" with no breakdown cannot make sense of a full refusal.
        expect(settings.isFull, isFalse);
      },
    );
  });
}
