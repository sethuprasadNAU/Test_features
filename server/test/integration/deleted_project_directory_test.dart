@Tags(['postgres'])
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 11.292, over a real bound socket: **a project an owner deleted in the
/// app reaches nowhere** — task 11.289 carries the deletion to the server as
/// a tombstone, `GET /projects/mine` leaves a tombstoned project out for
/// everybody, and task 11.290's destruction could only be reached from a
/// list. `GET /projects/deleted/mine` is the complement: the tombstones the
/// caller sent, on projects the server records them as owner of, and nothing
/// else.
///
/// Three things are measured here rather than argued:
///
/// 1. **What the route lists, and for whom.** Exactly the owner's own
///    tombstones; a contributor, a co-owner who did not delete it, and a
///    stranger each get an empty list. Security Model §4.28 states the rule;
///    this is its live half.
/// 2. **That every row is actionable.** The existing `/projects/<id>/deletion`
///    routes admit an owner to a *tombstoned* project — `ProjectAuthorizer`
///    never reads `Projects.deleted_at` — so the countdown appears on the new
///    listing and "delete now" empties it. Nothing about this had been
///    measured before; it was read from the resolver and is asserted here.
/// 3. **That §4.13 still holds for a tombstoned id.** Task 11.290 measured a
///    *destroyed* id (the one written exception); nobody had measured a
///    *tombstoned* one. A stranger asking about a tombstoned project is
///    answered identically to a fictional one on the deletion route and on
///    pull — no named refusal, no different status.
///
/// The field-set half — that a row carries exactly the four fields §4.28's
/// second table names — is `test/documentation/project_directory_field_set_test.dart`
/// on the model, and asserted on the live wire here.
void main() {
  late Connection connection;
  late Connection auditConnection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_deleted_project_directory_test';

  final captured = <String, String>{};

  const aliceEmail = 'alice@example.org';
  const bobEmail = 'bob@example.org';
  const carolEmail = 'carol@example.org';
  const projectA = 'proj-a';
  const projectB = 'proj-b';
  const fictional = 'proj-does-not-exist';
  const at = '2026-08-01T12:00:00.000Z';
  const deletedStamp = '2026-09-20T09:30:00.000Z';
  const policy = ProjectDeletionPolicy(grace: Duration(days: 30));

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    auditConnection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await auditConnection.close();
    await connection.close();
  });

  setUp(() async {
    if (testDatabaseConfig == null) return;
    captured.clear();
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await auditConnection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);

    EmailSender sender() => _CapturingSender(captured);

    final handler = createHandler(
      withAuthService: <T>(action) => connection.runTx(
        (tx) => action(
          AuthService(
            session: tx,
            emailSender: sender(),
            linkBaseUrl: 'http://test',
          ),
        ),
      ),
      withSyncContext: (request, action) async {
        final token = bearerToken(request);
        if (token == null) return _unauthorized();
        return connection.runTx((tx) async {
          final auth = AuthService(
            session: tx,
            emailSender: sender(),
            linkBaseUrl: 'http://test',
          );
          final activeSession = await auth.validateSession(token);
          if (activeSession == null) return _unauthorized();
          return action(
            SyncContext(
              sync: SyncService(session: tx),
              cursors: CursorStore(tx),
              session: activeSession,
              trafficLog: SyncTrafficLogStore(tx),
            ),
          );
        });
      },
      withAuditLog: (action) => auditConnection.runTx(
        (tx) => action(
          AuthAuditLog(
            tx,
            onError: (type) => throw StateError('audit write failed: $type'),
          ),
        ),
      ),
      deletionPolicy: policy,
    );

    server = await shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
    baseUri = Uri.parse('http://${server.address.address}:${server.port}');
  });

  tearDown(() => server.close(force: true));

  // ---- harness ------------------------------------------------------------

  Future<({String token, String userId})> signIn(
    String email, {
    required String deviceId,
  }) async {
    await http.post(
      baseUri.replace(path: '/auth/magic-link'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
    final token = Uri.parse(captured[email]!).queryParameters['token']!;
    final redeemed =
        jsonDecode(
              (await http.post(
                baseUri.replace(path: '/auth/redeem'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'token': token, 'device_id': deviceId}),
              )).body,
            )
            as Map<String, Object?>;
    return (
      token: redeemed['session_token']! as String,
      userId: redeemed['user_id']! as String,
    );
  }

  Map<String, String> authHeaders(String token) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $token',
  };

  Map<String, Object?> userRow(String userId, String email) => {
    'user_id': userId,
    'first_name': 'Ranger',
    'last_name': 'Person',
    'email': email,
    'created_at': at,
    'updated_at': at,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> projectRow(
    String id,
    String ownerId, {
    String name = 'Elk Study',
    int revision = 0,
    String? deletedAt,
    String? lastModifiedBy,
  }) => {
    'project_id': id,
    'project_name': name,
    'owner_user_id': ownerId,
    'creation_date': at,
    'datum': 'WGS84',
    'created_at': at,
    'updated_at': deletedAt ?? at,
    'deleted_at': deletedAt,
    'revision': revision,
    'last_modified_by': lastModifiedBy ?? ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> membershipRow(
    String id, {
    required String projectId,
    required String userId,
  }) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': userId,
    'join_date': at,
    'end_date': null,
    'role': 'owner',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': userId,
    'origin_device_id': 'device-X',
  };

  Map<String, Object?> observationRow(
    String id, {
    required String projectId,
    required String userId,
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'timestamp_local': at,
    'timestamp_utc': at,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': at,
    'updated_at': at,
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Future<http.Response> push(
    String token, {
    required String projectId,
    required SyncRows rows,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/push'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPushRequest(
        projectId: projectId,
        deviceId: deviceId,
        rows: rows,
      ).toJson(),
    ),
  );

  Future<http.Response> pull(
    String token, {
    required String projectId,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/pull'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncPullRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: 0,
      ).toJson(),
    ),
  );

  Future<void> publish(
    ({String token, String userId}) owner,
    String email,
    String projectId, {
    String name = 'Elk Study',
  }) async {
    await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.users: [userRow(owner.userId, email)],
      },
    );
    final established = await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.projects: [projectRow(projectId, owner.userId, name: name)],
        Tables.projectMemberships: [
          membershipRow(
            'm-$projectId',
            projectId: projectId,
            userId: owner.userId,
          ),
        ],
        Tables.observations: [
          observationRow(
            'obs-$projectId',
            projectId: projectId,
            userId: owner.userId,
          ),
        ],
      },
    );
    expect(established.statusCode, 200, reason: established.body);
  }

  /// What task 11.289's flush sends: the owner's own `Projects` row again,
  /// tombstoned, revision bumped, audit name the caller's.
  Future<void> tombstone(
    ({String token, String userId}) by,
    String projectId, {
    required String ownerId,
    String name = 'Elk Study',
    String deletedAt = deletedStamp,
  }) async {
    final response = await push(
      by.token,
      projectId: projectId,
      rows: {
        Tables.projects: [
          projectRow(
            projectId,
            ownerId,
            name: name,
            revision: 1,
            deletedAt: deletedAt,
            lastModifiedBy: by.userId,
          ),
        ],
      },
    );
    expect(response.statusCode, 200, reason: response.body);
    final outcome = SyncPushResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).outcomes['${Tables.projects}/$projectId'];
    expect(outcome, SyncRowOutcome.updated, reason: response.body);
  }

  Future<String> enableJoining(String token, String projectId) async {
    final response = await http.post(
      baseUri.replace(path: '/projects/$projectId/join-settings'),
      headers: authHeaders(token),
      body: jsonEncode({'joining_enabled': true}),
    );
    expect(response.statusCode, 200, reason: response.body);
    return JoinSettings.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).code!;
  }

  /// Walks [email] onto [projectId] in [role] through the real join code and
  /// a real approval — the only way the server ever writes a membership.
  Future<({String token, String userId})> joinAs(
    ({String token, String userId}) owner,
    String email, {
    required String projectId,
    required String deviceId,
    required String role,
  }) async {
    final member = await signIn(email, deviceId: deviceId);
    final code = await enableJoining(owner.token, projectId);
    final asked = await http.post(
      baseUri.replace(path: '/projects/join-requests'),
      headers: authHeaders(member.token),
      body: jsonEncode({'code': code}),
    );
    expect(asked.statusCode, 200, reason: asked.body);
    final requestId = JoinRequestCreatedResponse.fromJson(
      jsonDecode(asked.body) as Map<String, Object?>,
    ).requestId;
    final approved = await http.post(
      baseUri.replace(
        path: '/projects/$projectId/join-requests/$requestId/approve',
      ),
      headers: authHeaders(owner.token),
      body: jsonEncode({'role': role}),
    );
    expect(approved.statusCode, 200, reason: approved.body);
    return member;
  }

  Future<http.Response> deletion(
    String token,
    String projectId, {
    ProjectDeletionAction? action,
  }) => action == null
      ? http.get(
          baseUri.replace(path: '/projects/$projectId/deletion'),
          headers: authHeaders(token),
        )
      : http.post(
          baseUri.replace(path: '/projects/$projectId/deletion'),
          headers: authHeaders(token),
          body: jsonEncode({'action': action.wire}),
        );

  Future<http.Response> deletedMineRaw(String token) => http.get(
    baseUri.replace(path: '/projects/deleted/mine'),
    headers: authHeaders(token),
  );

  Future<List<DeletedProjectSummary>> deletedMine(String token) async {
    final response = await deletedMineRaw(token);
    expect(response.statusCode, 200, reason: response.body);
    return DeletedProjectDirectoryResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).projects;
  }

  Future<List<ProjectSummary>> mine(String token) async {
    final response = await http.get(
      baseUri.replace(path: '/projects/mine'),
      headers: authHeaders(token),
    );
    expect(response.statusCode, 200, reason: response.body);
    return ProjectDirectoryResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).projects;
  }

  String? errorCode(http.Response response) =>
      (jsonDecode(response.body) as Map<String, Object?>)['error'] as String?;

  /// Task 11.302: the owner's *restore*, on the same route as schedule,
  /// cancel and delete-now.
  Future<http.Response> restore(String token, String projectId) => http.post(
    baseUri.replace(path: '/projects/$projectId/deletion'),
    headers: authHeaders(token),
    body: jsonEncode({'action': 'restore'}),
  );

  /// An incremental pull from [cursor] — what a device that already holds
  /// the project asks on its next round.
  Future<SyncPullResponse> pullFrom(
    String token, {
    required String projectId,
    required int cursor,
    String deviceId = 'device-X',
  }) async {
    final response = await http.post(
      baseUri.replace(path: '/sync/pull'),
      headers: authHeaders(token),
      body: jsonEncode(
        SyncPullRequest(
          projectId: projectId,
          deviceId: deviceId,
          cursor: cursor,
        ).toJson(),
      ),
    );
    expect(response.statusCode, 200, reason: response.body);
    return SyncPullResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
  }

  /// The server's own `Projects` row, read straight from the table — a
  /// reference the route under test does not supply.
  Future<Map<String, Object?>?> storedProject(String projectId) async {
    final result = await connection.execute(
      'SELECT deleted_at, revision, last_modified_by, server_seq '
      'FROM ${quoted(Tables.projects)} WHERE project_id = \$1',
      parameters: [projectId],
    );
    return result.isEmpty ? null : result.first.toColumnMap();
  }

  Future<List<String>> auditEvents(String projectId) async {
    final result = await auditConnection.execute(
      r'SELECT event FROM auth_audit_log WHERE outcome = $1 ORDER BY id',
      parameters: [projectId],
    );
    return [for (final row in result) row.first! as String];
  }

  /// **The restore's population is the listing's, derived rather than
  /// restated** (task 11.302's acceptance). What [caller] is expected to be
  /// able to do is read off the listing's own answer for them, never written
  /// into the test: if the project is on their `GET /projects/deleted/mine`,
  /// the restore must succeed; if it is not, it must be refused exactly as a
  /// stranger is, and the tombstone must still stand afterwards. [listed] is
  /// the fixture's premise, asserted first so a fixture that stopped meaning
  /// what its name says fails here rather than passing vacuously.
  Future<void> expectRestoreFollowsListing(
    ({String token, String userId}) caller,
    String projectId, {
    required bool listed,
    required String because,
  }) async {
    final isListed = (await deletedMine(
      caller.token,
    )).any((p) => p.projectId == projectId);
    expect(isListed, listed, reason: 'fixture premise: $because');
    final before = await storedProject(projectId);
    final response = await restore(caller.token, projectId);
    if (isListed) {
      expect(response.statusCode, 200, reason: '$because: ${response.body}');
      expect((await storedProject(projectId))!['deleted_at'], isNull);
    } else {
      expect(response.statusCode, 403, reason: '$because: ${response.body}');
      expect(errorCode(response), 'forbidden', reason: because);
      expect(
        await storedProject(projectId),
        before,
        reason: '$because: a refused restore must change nothing',
      );
    }
  }

  // ---- the tests ----------------------------------------------------------

  group('what the route lists', skip: databaseSkipReason, () {
    test(
      'a project the owner deleted leaves /projects/mine and appears on '
      '/projects/deleted/mine, with exactly the four documented fields',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA, name: 'Elk Study');
        await publish(alice, aliceEmail, projectB, name: 'Owl Survey');
        expect(await deletedMine(alice.token), isEmpty);

        await tombstone(alice, projectA, ownerId: alice.userId);

        expect((await mine(alice.token)).map((p) => p.projectId), [projectB]);

        final raw = await deletedMineRaw(alice.token);
        expect(raw.statusCode, 200, reason: raw.body);
        expect(
          raw.headers['cache-control'],
          'no-store',
          reason: 'a list of somebody\'s projects must not be cached (§4.7)',
        );
        final rows =
            (jsonDecode(raw.body) as Map<String, Object?>)['projects']!
                as List;
        expect(rows, hasLength(1));
        final row = rows.single as Map<String, Object?>;
        // The live half of §4.28's second table. The model-side half is
        // `test/documentation/project_directory_field_set_test.dart`.
        expect(
          row.keys.toSet(),
          {'project_id', 'project_name', 'deleted_at', 'destroy_at'},
          reason:
              'a row of GET /projects/deleted/mine carries exactly the four '
              'fields Security Model §4.28 names. A fifth is a disclosure '
              'decision that amends that section first.',
        );
        expect(row['project_id'], projectA);
        expect(row['project_name'], 'Elk Study');
        expect(
          DateTime.parse(row['deleted_at']! as String).toUtc(),
          DateTime.parse(deletedStamp),
        );
        expect(row['destroy_at'], isNull);
      },
    );

    test('a project the owner brought back leaves the list again', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      await tombstone(alice, projectA, ownerId: alice.userId);
      expect(await deletedMine(alice.token), hasLength(1));

      // UNDO on the phone: the same row, deleted_at cleared, revision up.
      final restored = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.projects: [
            projectRow(projectA, alice.userId, revision: 2),
          ],
        },
      );
      expect(restored.statusCode, 200, reason: restored.body);
      expect(await deletedMine(alice.token), isEmpty);
      expect((await mine(alice.token)).map((p) => p.projectId), [projectA]);
    });
  });

  group('who is told — §4.28\'s narrow set', skip: databaseSkipReason, () {
    test(
      'a contributor, a co-owner who did not delete it, and a stranger each '
      'get an empty list; only the owner who sent the tombstone sees it',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final bob = await joinAs(
          alice,
          bobEmail,
          projectId: projectA,
          deviceId: 'phone-b',
          role: 'owner',
        );
        final carol = await signIn(carolEmail, deviceId: 'phone-c');

        await tombstone(alice, projectA, ownerId: alice.userId);

        expect(
          (await deletedMine(alice.token)).map((p) => p.projectId),
          [projectA],
        );
        // Bob is an owner of the same project, so `_requireOwner` would admit
        // him to its deletion routes — but he did not delete it, and this
        // list is the caller's own act, not the project's history.
        expect(await deletedMine(bob.token), isEmpty);
        expect(await deletedMine(carol.token), isEmpty);

        // And the same shape with a contributor, who is not an owner at all.
        await publish(alice, aliceEmail, projectB, name: 'Owl Survey');
        final dave = await joinAs(
          alice,
          'dave@example.org',
          projectId: projectB,
          deviceId: 'phone-d',
          role: 'contributor',
        );
        await tombstone(alice, projectB, ownerId: alice.userId);
        expect(await deletedMine(dave.token), isEmpty);
        expect(
          (await deletedMine(alice.token)).map((p) => p.projectId),
          containsAll([projectA, projectB]),
        );
      },
    );

    test(
      'an owner demoted after deleting is no longer told — the row would '
      'name a project the deletion routes refuse them',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final bob = await joinAs(
          alice,
          bobEmail,
          projectId: projectA,
          deviceId: 'phone-b',
          role: 'owner',
        );
        await tombstone(alice, projectA, ownerId: alice.userId);
        expect(await deletedMine(alice.token), hasLength(1));

        // Bob, still an owner, makes Alice a contributor: the same membership
        // row, role changed, revision up. Bob stays the project's open owner,
        // so the last-owner guard lets it through.
        final demoted = await push(
          bob.token,
          projectId: projectA,
          rows: {
            Tables.projectMemberships: [
              {
                ...membershipRow(
                  'm-$projectA',
                  projectId: projectA,
                  userId: alice.userId,
                ),
                'role': 'contributor',
                'revision': 1,
                'updated_at': deletedStamp,
                'last_modified_by': bob.userId,
              },
            ],
          },
        );
        expect(demoted.statusCode, 200, reason: demoted.body);
        expect(
          SyncPushResponse.fromJson(
            jsonDecode(demoted.body) as Map<String, Object?>,
          ).outcomes['${Tables.projectMemberships}/m-$projectA/$projectA'],
          SyncRowOutcome.updated,
          reason: demoted.body,
        );

        // She sent the tombstone, and the server no longer records her as an
        // owner: the listing and `_requireOwner` agree about her.
        expect(await deletedMine(alice.token), isEmpty);
        expect((await deletion(alice.token, projectA)).statusCode, 403);
      },
    );

    test('a signed-out bearer is refused, like every authenticated read', () async {
      final response = await http.get(
        baseUri.replace(path: '/projects/deleted/mine'),
        headers: authHeaders('not-a-session'),
      );
      expect(response.statusCode, 401);
    });
  });

  group('every row is actionable', skip: databaseSkipReason, () {
    test(
      'the owner schedules a tombstoned project through the existing '
      'deletion route, sees the date on the listing, and "delete now" '
      'empties it',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        await tombstone(alice, projectA, ownerId: alice.userId);

        // The resolver never reads `Projects.deleted_at`, so a tombstoned
        // project still resolves to `owner` for its owner. Measured, not
        // read off the resolver's comment.
        final read = await deletion(alice.token, projectA);
        expect(read.statusCode, 200, reason: read.body);

        final scheduled = await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        );
        expect(scheduled.statusCode, 200, reason: scheduled.body);
        final standing = ProjectDeletionStanding.fromJson(
          jsonDecode(scheduled.body) as Map<String, Object?>,
        );
        expect(standing.destroyAt, isNotNull);

        final listed = (await deletedMine(alice.token)).single;
        expect(listed.projectId, projectA);
        expect(listed.destroyAt, standing.destroyAt);

        final now = await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.immediate,
        );
        expect(now.statusCode, 200, reason: now.body);
        // Destroyed: no `Projects` row is left to list.
        expect(await deletedMine(alice.token), isEmpty);
        final rows = await connection.execute(
          'SELECT count(*) FROM ${quoted(Tables.projects)} '
          r'WHERE project_id = $1',
          parameters: [projectA],
        );
        expect(rows.first.first, 0);
        final retired = await connection.execute(
          r'SELECT executed_at FROM project_destruction WHERE project_id = $1',
          parameters: [projectA],
        );
        expect(retired.first.first, isNotNull);
      },
    );
  });

  group('restoring — task 11.302', skip: databaseSkipReason, () {
    test(
      'the population that may restore is exactly the population the '
      'listing shows: a co-owner who did not delete it, a contributor, a '
      'stranger, an owner demoted after deleting and a tombstone with no '
      'audit name are all refused; the owner who deleted it is not',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final bob = await joinAs(
          alice,
          bobEmail,
          projectId: projectA,
          deviceId: 'phone-b',
          role: 'owner',
        );
        final dave = await joinAs(
          alice,
          'dave@example.org',
          projectId: projectA,
          deviceId: 'phone-d',
          role: 'contributor',
        );
        final carol = await signIn(carolEmail, deviceId: 'phone-c');
        await tombstone(alice, projectA, ownerId: alice.userId);

        await expectRestoreFollowsListing(
          bob,
          projectA,
          listed: false,
          because: 'a co-owner who did not delete it',
        );
        await expectRestoreFollowsListing(
          dave,
          projectA,
          listed: false,
          because: 'a contributor',
        );
        await expectRestoreFollowsListing(
          carol,
          projectA,
          listed: false,
          because: 'a stranger',
        );
        await expectRestoreFollowsListing(
          alice,
          projectA,
          listed: true,
          because: 'the owner who deleted it',
        );

        // A tombstone with no audit name — what a build older than the
        // stamp sent. The listing leaves it to the operator path, and so
        // must the restore.
        await publish(alice, aliceEmail, projectB, name: 'Owl Survey');
        await tombstone(alice, projectB, ownerId: alice.userId, name: 'Owl Survey');
        await connection.execute(
          'UPDATE ${quoted(Tables.projects)} SET last_modified_by = NULL '
          r'WHERE project_id = $1',
          parameters: [projectB],
        );
        await expectRestoreFollowsListing(
          alice,
          projectB,
          listed: false,
          because: 'a tombstone the server cannot attribute to anybody',
        );
      },
    );

    test('an owner demoted after deleting cannot restore it either', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      final bob = await joinAs(
        alice,
        bobEmail,
        projectId: projectA,
        deviceId: 'phone-b',
        role: 'owner',
      );
      await tombstone(alice, projectA, ownerId: alice.userId);
      final demoted = await push(
        bob.token,
        projectId: projectA,
        rows: {
          Tables.projectMemberships: [
            {
              ...membershipRow(
                'm-$projectA',
                projectId: projectA,
                userId: alice.userId,
              ),
              'role': 'contributor',
              'revision': 1,
              'updated_at': deletedStamp,
              'last_modified_by': bob.userId,
            },
          ],
        },
      );
      expect(demoted.statusCode, 200, reason: demoted.body);
      await expectRestoreFollowsListing(
        alice,
        projectA,
        listed: false,
        because: 'an owner demoted after deleting',
      );
    });

    test(
      'a restore reaches every member: the project is listed for them '
      'again, and their next incremental pull carries a row that outranks '
      'the tombstone they hold, with every record still there',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final dave = await joinAs(
          alice,
          'dave@example.org',
          projectId: projectA,
          deviceId: 'phone-d',
          role: 'contributor',
        );
        // Deleted on a phone whose clock runs a day fast — so the tombstone
        // every device holds is stamped *later* than the server's own clock
        // will stamp the restore. A restore that won only on the timestamp
        // would lose to it here; it has to win on the revision.
        final fastClock = DateTime.now()
            .toUtc()
            .add(const Duration(days: 1))
            .toIso8601String();
        await tombstone(
          alice,
          projectA,
          ownerId: alice.userId,
          deletedAt: fastClock,
        );

        // Dave's device syncs after the deletion: it receives the tombstone,
        // and the project is on no list of his.
        final beforeRestore = await pullFrom(
          dave.token,
          projectId: projectA,
          cursor: 0,
          deviceId: 'phone-d',
        );
        final heldTombstone = beforeRestore.rows[Tables.projects]!.single;
        expect(heldTombstone['deleted_at'], isNotNull);
        expect(await mine(dave.token), isEmpty);

        final restored = await restore(alice.token, projectA);
        expect(restored.statusCode, 200, reason: restored.body);

        expect(
          (await mine(dave.token)).map((p) => p.projectId),
          [projectA],
          reason: 'the member\'s device finds the project listed again — the '
              'signal the app uses to go and fetch it',
        );
        final next = await pullFrom(
          dave.token,
          projectId: projectA,
          cursor: beforeRestore.nextCursor,
          deviceId: 'phone-d',
        );
        final row = next.rows[Tables.projects]?.single;
        expect(
          row,
          isNotNull,
          reason: 'the restored row must re-enter the member\'s delta window; '
              'a restore below every cursor reaches nobody',
        );
        expect(row!['deleted_at'], isNull);
        expect(row['last_modified_by'], alice.userId);
        expect(
          MergeResolver.incomingWins(row, heldTombstone),
          isTrue,
          reason: 'under the shared merge rule the restored row must beat the '
              'tombstone every device already holds, or the pull lands and '
              'the project stays hidden',
        );
        // And nothing was lost on the way.
        final everything = await pullFrom(
          dave.token,
          projectId: projectA,
          cursor: 0,
          deviceId: 'phone-d',
        );
        expect(everything.rows[Tables.observations], hasLength(1));
        expect(await deletedMine(alice.token), isEmpty);
        expect(await auditEvents(projectA), contains('project_restored'));
      },
    );

    test(
      'restoring a project scheduled for destruction withdraws the '
      'schedule in the same act, and the sweep then leaves it alone',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        await tombstone(alice, projectA, ownerId: alice.userId);
        final scheduled = await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        );
        expect(scheduled.statusCode, 200, reason: scheduled.body);

        final restored = await restore(alice.token, projectA);
        expect(restored.statusCode, 200, reason: restored.body);
        final standing = ProjectDeletionStanding.fromJson(
          jsonDecode(restored.body) as Map<String, Object?>,
        );
        expect(standing.destroyAt, isNull);
        expect(standing.executedAt, isNull);
        expect((await mine(alice.token)).single.destroyAt, isNull);

        final sweep = await ProjectDestructionService(
          connection,
          policy: policy,
          clock: () => DateTime.now().toUtc().add(const Duration(days: 90)),
        ).destroyDue();
        expect(sweep.projectsDestroyed, 0);
        expect(await storedProject(projectA), isNotNull);
      },
    );

    test(
      'restoring a project that is not deleted changes nothing — a retry '
      'after a lost answer is not an error',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        await tombstone(alice, projectA, ownerId: alice.userId);
        expect((await restore(alice.token, projectA)).statusCode, 200);
        final once = await storedProject(projectA);

        final again = await restore(alice.token, projectA);
        expect(again.statusCode, 200, reason: again.body);
        expect(
          await storedProject(projectA),
          once,
          reason: 'a second restore must not bump the revision or the '
              'server_seq: that would redeliver the row to every device',
        );
        expect(
          (await auditEvents(projectA)).where((e) => e == 'project_restored'),
          hasLength(1),
        );
      },
    );

    test(
      'a destroyed project cannot be restored: the route refuses it as it '
      'refuses a stranger, and pull names it destroyed — which is how the '
      'app tells the two apart',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        await tombstone(alice, projectA, ownerId: alice.userId);
        final destroyed = await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.immediate,
        );
        expect(destroyed.statusCode, 200, reason: destroyed.body);

        final refused = await restore(alice.token, projectA);
        expect(refused.statusCode, 403, reason: refused.body);
        expect(errorCode(refused), 'forbidden');
        final probe = await pull(alice.token, projectId: projectA);
        expect(probe.statusCode, 403, reason: probe.body);
        expect(errorCode(probe), syncRefusalProjectDestroyed);
      },
    );
  });

  group('§4.13 holds for a tombstoned id', skip: databaseSkipReason, () {
    test(
      'a stranger is answered identically for a tombstoned project and a '
      'fictional one — on the deletion route and on pull',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        await tombstone(alice, projectA, ownerId: alice.userId);
        final carol = await signIn(carolEmail, deviceId: 'phone-c');

        for (final probe in [
          (await deletion(carol.token, projectA), 'deletion, tombstoned'),
          (await deletion(carol.token, fictional), 'deletion, fictional'),
          (
            await deletion(
              carol.token,
              projectA,
              action: ProjectDeletionAction.schedule,
            ),
            'schedule, tombstoned',
          ),
          (
            await deletion(
              carol.token,
              fictional,
              action: ProjectDeletionAction.schedule,
            ),
            'schedule, fictional',
          ),
          (await restore(carol.token, projectA), 'restore, tombstoned'),
          (await restore(carol.token, fictional), 'restore, fictional'),
          (await pull(carol.token, projectId: projectA), 'pull, tombstoned'),
          (await pull(carol.token, projectId: fictional), 'pull, fictional'),
        ]) {
          expect(probe.$1.statusCode, 403, reason: probe.$2);
          expect(
            errorCode(probe.$1),
            'forbidden',
            reason:
                '${probe.$2}: a tombstoned id must draw the bare refusal, '
                'not a named one — only a *destroyed* id is named, and only '
                'because a publish could otherwise resurrect it (§4.13).',
          );
        }
        // Nothing the stranger did scheduled or restored anything.
        expect((await deletedMine(alice.token)).single.destroyAt, isNull);
      },
    );
  });
}

Response _unauthorized() => Response(
  401,
  body: jsonEncode({'error': 'unauthorized'}),
  headers: const {'content-type': 'application/json'},
);

class _CapturingSender implements EmailSender {
  _CapturingSender(this.captured);
  final Map<String, String> captured;

  @override
  void sendMagicLink({
    required String email,
    required String url,
    required DateTime expiresAt,
    void Function(bool delivered)? onOutcome,
  }) {
    captured[email] = url;
  }
}
