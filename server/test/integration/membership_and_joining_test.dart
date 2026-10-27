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

/// **Task 11.2, end to end over a real bound socket**, through the same
/// `createHandler` wiring `bin/server.dart` uses.
///
/// Two things here cannot be tested at unit level and are the reason this file
/// exists:
///
/// 1. **The invitation is what reopens task 10.20's accepted cost.** The
///    row-naming invariant (§4.17) refuses a row naming somebody the project
///    does not already reach, which since task 10.29 means a genuine
///    colleague's imported observations stop replicating until that colleague
///    is *on the project*. Phase 10 gave no way to be on a project. The
///    membership an invitation grants is that way, and the test below is the
///    before-and-after.
/// 2. **What "removal is immediate" actually means.** The mechanism is not
///    session revocation — see the group at the bottom for why using
///    `revokeAllSessionsForUser` here would be wrong.
void main() {
  late Connection connection;

  /// **A connection of its own for the audit log, never the one on loan from a
  /// request's transaction** (task 11.81, and the B5 bug `AuthAuditLog`
  /// records). `postgres` refuses a second statement on a connection while its
  /// own `runTx` is open, so sharing `connection` here would silently lose
  /// every join audit row — and this file's audit test would then be measuring
  /// a harness defect rather than the router.
  late Connection auditConnection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_membership_invites_test';

  final captured = <String, String>{};

  const aliceEmail = 'alice@example.org';
  const bobEmail = 'bob@example.org';
  const carolEmail = 'carol@example.org';
  const projectA = 'proj-a';
  const projectB = 'proj-b';
  const at = '2026-08-01T12:00:00.000Z';

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

    void onAuditError(String type) =>
        fail('audit log write failed and was swallowed: $type');

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
      // **New in task 11.81.** Without this the project router has nowhere to
      // write, and the audit assertion below would be measuring a gap in this
      // harness rather than a gap in the router — a check that cannot tell
      // success from its own failure.
      withAuditLog: (action) =>
          action(AuthAuditLog(auditConnection, onError: onAuditError)),
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

  Future<({String token, String userId})> signIn(
    String email, {
    String deviceId = 'device-A',
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

  Map<String, String> auth(String token) => {
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

  Map<String, Object?> projectRow(String id, String ownerId) => {
    'project_id': id,
    'project_name': 'Elk Study',
    'owner_user_id': ownerId,
    'creation_date': at,
    'datum': 'WGS84',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> ownerMembershipRow(String id, String projectId,
      String ownerId) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': ownerId,
    'join_date': at,
    'role': 'owner',
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> observationRow(
    String id, {
    required String projectId,
    required String userId,
    required String modifiedBy,
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
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-A',
  };

  Future<http.Response> push(
    String token, {
    required String projectId,
    required SyncRows rows,
    String deviceId = 'device-A',
  }) => http.post(
    baseUri.replace(path: '/sync/push'),
    headers: auth(token),
    body: jsonEncode(
      SyncPushRequest(projectId: projectId, deviceId: deviceId, rows: rows)
          .toJson(),
    ),
  );

  Future<http.Response> pull(
    String token, {
    required String projectId,
    String deviceId = 'device-A',
  }) => http.post(
    baseUri.replace(path: '/sync/pull'),
    headers: auth(token),
    body: jsonEncode(
      SyncPullRequest(projectId: projectId, deviceId: deviceId, cursor: 0)
          .toJson(),
    ),
  );

  /// A cursor acknowledgement — a *write*, which is why it is the check that
  /// the closed-membership disclosure (§4.27) did not reopen anything.
  Future<http.Response> ack(
    String token, {
    required String projectId,
    required int cursor,
    String deviceId = 'device-A',
  }) => http.post(
    baseUri.replace(path: '/sync/ack'),
    headers: auth(token),
    body: jsonEncode(
      SyncAckRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  /// Publishes [projectId] owned by the caller, exactly as the app does: the
  /// people first (a global-only push), then the project and its owner
  /// membership.
  Future<void> publish(
    ({String token, String userId}) owner,
    String email,
    String projectId,
  ) async {
    await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.users: [userRow(owner.userId, email)],
      },
    );
    await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.projects: [projectRow(projectId, owner.userId)],
        Tables.projectMemberships: [
          ownerMembershipRow('m-$projectId', projectId, owner.userId),
        ],
      },
    );
  }

  /// Switches joining on for [projectId] and returns its code.
  Future<String> enableJoining(String token, String projectId) async {
    final response = await http.post(
      baseUri.replace(path: '/projects/$projectId/join-settings'),
      headers: auth(token),
      body: jsonEncode({'joining_enabled': true}),
    );
    expect(response.statusCode, 200, reason: response.body);
    return JoinSettings.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).code!;
  }

  Future<http.Response> askToJoin(
    String token,
    String code, {
    String? claimedName,
  }) => http.post(
    baseUri.replace(path: '/projects/join-requests'),
    headers: auth(token),
    body: jsonEncode({
      'code': code,
      if (claimedName != null) 'claimed_name': claimedName,
    }),
  );

  Future<List<JoinRequestSummary>> pendingOn(
    String token,
    String projectId,
  ) async {
    final response = await http.get(
      baseUri.replace(path: '/projects/$projectId/join-requests'),
      headers: auth(token),
    );
    expect(response.statusCode, 200, reason: response.body);
    return JoinRequestListResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).requests;
  }

  Future<http.Response> approve(
    String token,
    String projectId,
    String requestId, {
    String role = 'contributor',
  }) => http.post(
    baseUri.replace(
      path: '/projects/$projectId/join-requests/$requestId/approve',
    ),
    headers: auth(token),
    body: jsonEncode({'role': role}),
  );

  /// The whole sequence: switch joining on, ask, approve. Used where the
  /// membership is scaffolding rather than the subject.
  Future<void> admit(
    ({String token, String userId}) owner,
    ({String token, String userId}) joiner,
    String projectId, {
    String role = 'contributor',
  }) async {
    final code = await enableJoining(owner.token, projectId);
    final asked = await askToJoin(joiner.token, code);
    expect(asked.statusCode, 200, reason: asked.body);
    final requestId = JoinRequestCreatedResponse.fromJson(
      jsonDecode(asked.body) as Map<String, Object?>,
    ).requestId;
    final approved = await approve(
      owner.token,
      projectId,
      requestId,
      role: role,
    );
    expect(approved.statusCode, 200, reason: approved.body);
  }

  group('who may manage joining', skip: databaseSkipReason, () {
    test(
      'a stranger and a project that does not exist draw the same refusal',
      () async {
        // §4.13's first `Violated by:` case — "wrong project, wrong user, and
        // nonexistent are indistinguishable from outside". Compared to each
        // other rather than to an expected constant, so this cannot pass by
        // both branches happening to match one hardcoded value.
        final alice = await signIn(aliceEmail);
        final carol = await signIn(carolEmail, deviceId: 'device-C');
        await publish(alice, aliceEmail, projectA);

        final forbidden = await http.get(
          baseUri.replace(path: '/projects/$projectA/join-settings'),
          headers: auth(carol.token),
        );
        final fictional = await http.get(
          baseUri.replace(path: '/projects/proj-does-not-exist/join-settings'),
          headers: auth(carol.token),
        );
        expect(forbidden.statusCode, fictional.statusCode);
        expect(
          jsonDecode(forbidden.body)['error'],
          jsonDecode(fictional.body)['error'],
        );
        expect(forbidden.statusCode, 403);
      },
    );

    test('an over-long project id is refused on an owner-only route', () async {
      // **Task 11.125, item 2(v), from task 11.119's survey.** The
      // length-and-control-character refusal at the top of `_requireOwner`
      // (`project_routes.dart`) guards all seven owner-only routes and had
      // **never executed** — not in this suite, not in any gate instrument.
      //
      // **What this test does and does not prove, measured rather than
      // argued.** Removing the guard entirely and re-running this test leaves
      // it green: an over-long id that reaches `ProjectAuthorizer.resolve`
      // draws the same 403, because no such project can be owned by anybody.
      // So this is not a detection proof in task 11.77's sense — it executes
      // the branch and asserts the answer a person gets, and the branch's
      // value is that attacker-chosen bytes of unbounded length never reach a
      // database statement, which nothing observable from outside can
      // distinguish. Said here rather than left for the next reader to assume
      // otherwise.
      //
      // Alice owns a real project, so her session is not what draws the
      // refusal; §4.13's requirement that a fabricated project answer exactly
      // as a forbidden one does is what the comparison asserts, applied to an
      // id that names no project at all.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);

      final fictional = await http.get(
        baseUri.replace(path: '/projects/proj-does-not-exist/join-settings'),
        headers: auth(alice.token),
      );
      expect(fictional.statusCode, 403, reason: fictional.body);

      // One past `maxDeviceIdLength`, read from the declaration rather than
      // typed, so raising the bound does not leave this measuring a length
      // that has become legal.
      final tooLong = 'p' * (maxDeviceIdLength + 1);
      final response = await http.get(
        baseUri.replace(path: '/projects/$tooLong/join-settings'),
        headers: auth(alice.token),
      );
      expect(
        response.statusCode,
        fictional.statusCode,
        reason:
            'an over-long project id must answer exactly as a fabricated one: '
            '${response.statusCode} ${response.body}',
      );
      expect(
        jsonDecode(response.body)['error'],
        jsonDecode(fictional.body)['error'],
      );
    });

    test('a control character in the path arrives as text, not as a control '
        'character', () async {
      // **Task 11.125, and this is a finding about `_requireOwner` rather
      // than a test of it.** Its third arm refuses a project id containing a
      // control character, and `project_routes.dart` explains that arm by the
      // NUL byte: Postgres rejects one in `TEXT` mid-statement, which from
      // outside is a bare 500.
      //
      // **A control character cannot be delivered through a path segment.**
      // Measured 2026-09-02: a request for `/projects/proj%00a/join-settings`
      // reaches `_requireOwner` as the eight literal characters `proj%00a` —
      // shelf hands the router the undecoded segment — so `_hasControlCharacter`
      // sees a percent sign, a zero and a zero, and cannot fire. The arm is
      // not wrong; it is unreachable from this direction, and the reachable
      // direction is a project id inside a JSON body, which is a different
      // route's guard.
      //
      // This test pins the arriving shape, so that a future shelf upgrade
      // which starts decoding path segments — and would silently make that arm
      // live, and every id in this app one byte wider — is a failure here
      // rather than a discovery later.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);

      final response = await http.get(
        baseUri.replace(path: '/projects/proj\u0000a/join-settings'),
        headers: auth(alice.token),
      );
      expect(response.statusCode, 403, reason: response.body);
    });

    test('a non-owner cannot switch joining on', () async {
      final alice = await signIn(aliceEmail);
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      await publish(alice, aliceEmail, projectA);

      final response = await http.post(
        baseUri.replace(path: '/projects/$projectA/join-settings'),
        headers: auth(carol.token),
        body: jsonEncode({'joining_enabled': true}),
      );
      expect(response.statusCode, 403);
      final rows = await connection.execute(
        'SELECT count(*) FROM project_join_settings',
      );
      expect(rows.first.first, 0, reason: 'nothing was written');
    });

    test('an owner of one project cannot open another', () async {
      // The §2.4 shape: authenticated, and not authorized *for this project*.
      // The most likely real breach in the whole system is one endpoint that
      // checks the first and forgets the second.
      final alice = await signIn(aliceEmail);
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      await publish(alice, aliceEmail, projectA);
      await publish(carol, carolEmail, projectB);

      final response = await http.post(
        baseUri.replace(path: '/projects/$projectB/join-settings'),
        headers: auth(alice.token),
        body: jsonEncode({'joining_enabled': true}),
      );
      expect(response.statusCode, 403);
    });

    test('an unauthenticated caller reaches none of these routes', () async {
      for (final request in [
        http.get(baseUri.replace(path: '/projects/$projectA/join-settings')),
        http.post(
          baseUri.replace(path: '/projects/$projectA/join-settings'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'joining_enabled': true}),
        ),
        http.post(
          baseUri.replace(path: '/projects/$projectA/join-code/rotate'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode(const <String, Object?>{}),
        ),
        http.get(baseUri.replace(path: '/projects/$projectA/join-requests')),
        http.post(
          baseUri.replace(path: '/projects/join-requests'),
          headers: const {'content-type': 'application/json'},
          body: jsonEncode({'code': 'ABCD2345'}),
        ),
        http.get(baseUri.replace(path: '/projects/join-requests/mine')),
      ]) {
        expect((await request).statusCode, 401);
      }
    });
  });

  group('joining by code and approval', skip: databaseSkipReason, () {
    test('a correct code produces a request and grants nothing', () async {
      // **The assertion the whole design rests on**, asked of a real server.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);

      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final asked = await askToJoin(bob.token, code, claimedName: 'Bob Ranger');
      expect(asked.statusCode, 200, reason: asked.body);

      // He can ask. He still reaches nothing.
      expect((await pull(bob.token, projectId: projectA)).statusCode, 403);
      expect(
        jsonDecode(
          (await http.get(
            baseUri.replace(path: '/projects/mine'),
            headers: auth(bob.token),
          )).body,
        )['projects'],
        isEmpty,
        reason: 'a pending request put the project in his list, which is why '
            'a request must not be a membership row',
      );

      // And the owner sees him, with the authenticated address and the
      // claimed name as two separate things.
      final pending = await pendingOn(alice.token, projectA);
      expect(pending.single.email, normalizeEmail(bobEmail));
      expect(pending.single.claimedName, 'Bob Ranger');
    });

    test('approval is what makes him a member, and he can then pull',
        () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      await admit(alice, bob, projectA);

      expect((await pull(bob.token, projectId: projectA)).statusCode, 200);
      final mine = jsonDecode(
        (await http.get(
          baseUri.replace(path: '/projects/mine'),
          headers: auth(bob.token),
        )).body,
      );
      expect((mine['projects'] as List).single['project_id'], projectA);
      expect((mine['projects'] as List).single['role'], 'contributor');
    });

    test('the code the owner reads out works after a whiteboard round trip',
        () async {
      // The delivery channel is a person. If the displayed form did not work,
      // the feature would fail in exactly the situation it exists for.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);

      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final typed = formatJoinCode(code).toLowerCase();
      expect((await askToJoin(bob.token, typed)).statusCode, 200);
    });

    test('the same code works for the whole crew', () async {
      // **What the old flow could not do**, and the reason for the change: one
      // code per person, typed by the owner, one at a time, did not scale to a
      // real field crew.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);

      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      expect((await askToJoin(bob.token, code)).statusCode, 200);
      expect((await askToJoin(carol.token, code)).statusCode, 200);
      expect(await pendingOn(alice.token, projectA), hasLength(2));
    });

    test('a code for a project with joining off reads like a wrong code',
        () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);
      await http.post(
        baseUri.replace(path: '/projects/$projectA/join-settings'),
        headers: auth(alice.token),
        body: jsonEncode({'joining_enabled': false}),
      );

      final carol = await signIn(carolEmail, deviceId: 'device-C');
      final real = await askToJoin(carol.token, code);
      final nonsense = await askToJoin(carol.token, 'ZZZZ9999');
      expect(real.statusCode, nonsense.statusCode);
      expect(jsonDecode(real.body)['error'], jsonDecode(nonsense.body)['error']);
      expect(real.statusCode, 403);
      expect(jsonDecode(real.body)['error'], joinRefusalCodeNotValid);
      expect((await pull(carol.token, projectId: projectA)).statusCode, 403);
    });

    test('a member asking again is told so', () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      await admit(alice, bob, projectA);

      final code = await enableJoining(alice.token, projectA);
      final again = await askToJoin(bob.token, code);
      expect(again.statusCode, 409);
      expect(jsonDecode(again.body)['error'], joinRefusalAlreadyMember);
    });

    test('a rejected requester is told, rather than left waiting', () async {
      // The class task 11.60 found for removed members, answered here before
      // it could happen a second time.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final asked = await askToJoin(bob.token, code);
      final requestId = JoinRequestCreatedResponse.fromJson(
        jsonDecode(asked.body) as Map<String, Object?>,
      ).requestId;

      final rejected = await http.post(
        baseUri.replace(
          path: '/projects/$projectA/join-requests/$requestId/reject',
        ),
        headers: auth(alice.token),
      );
      expect(rejected.statusCode, 200, reason: rejected.body);

      final mine = MyJoinRequestsResponse.fromJson(
        jsonDecode(
          (await http.get(
            baseUri.replace(path: '/projects/join-requests/mine'),
            headers: auth(bob.token),
          )).body,
        ) as Map<String, Object?>,
      ).requests;
      expect(mine.single.decision, 'rejected');
      expect((await pull(bob.token, projectId: projectA)).statusCode, 403);
    });

    test(
      'the project id is disclosed on an approval and on nothing else',
      () async {
        // **Task 11.83.** The requester's device cannot link and sync a
        // project it cannot name, so an approval carries the id — and a
        // pending or rejected request does not. That asymmetry is the whole
        // disclosure argument for inventory entry 29: an approved requester is
        // a member and `GET /projects/mine` hands them the same id, so this
        // route tells them nothing they could not already read, while somebody
        // the owner has not admitted still learns no project identifier.
        final alice = await signIn(aliceEmail);
        await publish(alice, aliceEmail, projectA);
        final code = await enableJoining(alice.token, projectA);
        final bob = await signIn(bobEmail, deviceId: 'device-B');
        final asked = await askToJoin(bob.token, code);
        expect(asked.statusCode, 200, reason: asked.body);

        Future<MyJoinRequest> mine() async {
          final response = await http.get(
            baseUri.replace(path: '/projects/join-requests/mine'),
            headers: auth(bob.token),
          );
          expect(response.statusCode, 200, reason: response.body);
          return MyJoinRequestsResponse.fromJson(
            jsonDecode(response.body) as Map<String, Object?>,
          ).requests.single;
        }

        final pending = await mine();
        expect(pending.isPending, isTrue);
        expect(
          pending.projectId,
          isNull,
          reason: 'nobody the owner has not admitted learns a project id',
        );

        final requestId = JoinRequestCreatedResponse.fromJson(
          jsonDecode(asked.body) as Map<String, Object?>,
        ).requestId;
        final approved = await approve(alice.token, projectA, requestId);
        expect(approved.statusCode, 200, reason: approved.body);

        final decided = await mine();
        expect(decided.decision, joinDecisionApproved);
        expect(decided.projectId, projectA);
        expect(decided.isApprovedAndNamed, isTrue);
      },
    );

    test('a rejected request still discloses no project id', () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final asked = await askToJoin(bob.token, code);
      final requestId = JoinRequestCreatedResponse.fromJson(
        jsonDecode(asked.body) as Map<String, Object?>,
      ).requestId;
      final rejected = await http.post(
        baseUri.replace(
          path: '/projects/$projectA/join-requests/$requestId/reject',
        ),
        headers: auth(alice.token),
      );
      expect(rejected.statusCode, 200, reason: rejected.body);

      final mine = MyJoinRequestsResponse.fromJson(
        jsonDecode(
          (await http.get(
            baseUri.replace(path: '/projects/join-requests/mine'),
            headers: auth(bob.token),
          )).body,
        ) as Map<String, Object?>,
      ).requests.single;
      expect(mine.decision, joinDecisionRejected);
      expect(mine.projectId, isNull);
      expect(mine.isApprovedAndNamed, isFalse);
    });

    test('the requester reads only their own requests', () async {
      // Keyed on the session and nothing else — inventory entry 29.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      await askToJoin(bob.token, code);
      await askToJoin(carol.token, code);

      final response = await http.get(
        baseUri.replace(path: '/projects/join-requests/mine'),
        headers: auth(bob.token),
      );
      expect(response.statusCode, 200);
      expect(
        response.headers['cache-control'],
        'no-store',
        reason: "somebody's own pending requests are not for a shared cache",
      );
      expect(
        MyJoinRequestsResponse.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        ).requests,
        hasLength(1),
      );
    });

    test('the owner can re-read the join code — Security Model 4.2.1',
        () async {
      // The whole of what the written exception to §4.2 buys. If this ever
      // stops being true, §4.2.1 says the code goes back to a hash.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final code = await enableJoining(alice.token, projectA);

      final response = await http.get(
        baseUri.replace(path: '/projects/$projectA/join-settings'),
        headers: auth(alice.token),
      );
      expect(
        JoinSettings.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        ).code,
        code,
      );
      expect(response.headers['cache-control'], 'no-store');
    });

    test('asking is rate-limited per user, not per source', () async {
      // Per authenticated user, deliberately: the source key §4.4 uses on the
      // unauthenticated routes collapses behind a proxy, and a collapsed key on
      // this route would let one caller stop everyone else joining.
      //
      // **This limit matters more than it did.** Under the old flow a guessed
      // code was worthless without the matching address; now a correct guess
      // confirms a project exists, so this is the only bound on sweeping.
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      final statuses = <int>[];
      for (var i = 0; i < 14; i++) {
        statuses.add(
          (await askToJoin(
            bob.token,
            'ZZZZ99${i.toString().padLeft(2, '0')}',
          )).statusCode,
        );
      }
      expect(statuses.where((s) => s == 429), isNotEmpty);
      // Somebody else is unaffected, which a per-source key could not promise.
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      expect((await askToJoin(carol.token, 'ZZZZ9999')).statusCode, 403);
    });

    test('every join action is written to the audit log', () async {
      // **Finding Q-1's acceptance, superseded.** It was granted while this
      // router only issued invitations; it is now where membership is granted,
      // and Michael settled on 2026-08-31 that a grant must be recorded.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      await admit(alice, bob, projectA);
      await http.post(
        baseUri.replace(path: '/projects/$projectA/join-code/rotate'),
        headers: auth(alice.token),
        body: jsonEncode({'clear_pending': false}),
      );

      final events = await connection.execute(
        'SELECT DISTINCT event FROM auth_audit_log',
      );
      final recorded = {for (final row in events) row.first! as String};
      expect(
        recorded,
        containsAll(<String>[
          AuthAuditEvent.joinRequested.db,
          AuthAuditEvent.joinApproved.db,
          AuthAuditEvent.joiningSwitched.db,
          AuthAuditEvent.joinCodeRotated.db,
        ]),
        reason: 'the project router wrote no audit rows at all before task '
            '11.81 — that was finding Q-1, and this is what closed it',
      );

      // **And never the code itself.** This table has no token column by
      // construction (§4.7), and §4.2.1's exception covers storing the code in
      // `project_join_settings` and nothing else.
      final code = (await connection.execute(
        r'SELECT code FROM project_join_settings WHERE project_id = $1',
        parameters: [projectA],
      )).first.first! as String;
      final all = await connection.execute(
        'SELECT coalesce(outcome, \'\') || coalesce(reason, \'\') '
        'FROM auth_audit_log',
      );
      for (final row in all) {
        expect(row.first! as String, isNot(contains(code)));
      }
    });
  });

  group(
    'the accepted cost from task 10.20 (C-1), closed',
    skip: databaseSkipReason,
    () {
      test(
        'a colleague may be named on shared project data whether or not they '
        'are on the project — but never on a record that names an author',
        () async {
          // **Corrected twice, and the second correction inverts the first
          // half. Both are kept, because the sequence is the record §4.17
          // owes.**
          //
          // *As originally written* it pinned task 11.2's closure of the C-1
          // accepted cost: an invitation was the provenance that let a
          // relayed *observation* naming a colleague land. Finding N-1 is
          // what that cost — the same permission carried a fabricated record
          // as readily as a genuine one, and the Team log and the position
          // estimate's observer provenance both then stated something false.
          // **Task 11.24** therefore moved the before/after onto the tables
          // clause 2 actually served: shared vocabulary with no author.
          //
          // **Task 11.47 removed the before/after altogether**, and this test
          // now asserts that there is none. Clause 2 asked "does this project
          // reach them?" of `last_modified_by`, and that is the wrong
          // question for a column recording who last *edited* shared
          // vocabulary: it is not a reachability edge and not a foreign key,
          // so nothing is disclosed by it. What asking anyway cost was the
          // caller's *own* field data — a bearing using a tag a colleague had
          // renamed was refused along with the tag, and if that colleague was
          // never going to join, refused permanently.
          //
          // **The half that does not move is the one that matters**, and it
          // is why this test is still here: on a record that names an author,
          // an invitation changes nothing, before or after. That is asserted
          // below rather than left implied.
          final alice = await signIn(aliceEmail);
          await publish(alice, aliceEmail, projectA);

          // Bob registers and uploads his own identity row, which is legal
          // under every check: it names nobody but himself.
          final bob = await signIn(bobEmail, deviceId: 'device-B');
          await push(
            bob.token,
            projectId: projectA,
            rows: {
              Tables.users: [userRow(bob.userId, bobEmail)],
            },
            deviceId: 'device-B',
          );

          // Shared project vocabulary: a tag stamped by Bob. Its only
          // person-naming column is the audit column, which is what
          // `MutationRule.anyUser` means — there is no author to fabricate.
          Map<String, Object?> sharedTag() => {
            'tag_id': 'tag-bob-1',
            // Project-scoped since task 11.219 — a tag belongs to one project.
            // Nothing about *this* test changed: `last_modified_by` naming
            // somebody the project does not reach is still the subject, and a
            // tag is still the table with no author column to fabricate.
            'project_id': projectA,
            'lineage_id': 'tag-bob-1',
            'frequency_mhz': 150.1,
            'tag_name': 'Collar',
            'status': 'active',
            'color_hex': '#FF0000',
            'created_at': '2026-08-01T12:00:00.000Z',
            'updated_at': '2026-08-01T12:00:00.000Z',
            'revision': 1,
            'last_modified_by': bob.userId,
            'origin_device_id': 'device-A',
          };

          // And a record that names an author, which must be refused on both
          // sides of the invitation.
          final imported = observationRow(
            'obs-bob-1',
            projectId: projectA,
            userId: bob.userId,
            modifiedBy: alice.userId,
          );

          Future<SyncPushResponse> offerBoth() async =>
              SyncPushResponse.fromJson(
                jsonDecode(
                  (await push(
                    alice.token,
                    projectId: projectA,
                    rows: {
                      Tables.tags: [sharedTag()],
                      Tables.observations: [imported],
                    },
                  )).body,
                ) as Map<String, Object?>,
              );

          final before = await offerBoth();
          expect(
            before.outcomes['${Tables.tags}/tag-bob-1/$projectA'],
            SyncRowOutcome.inserted,
            reason:
                'task 11.47: a tag stamped by somebody the project does not '
                'reach is accepted, because the only thing that name says is '
                'who last edited shared vocabulary — see '
                'MutationRule.replicatesAForeignAuditName',
          );
          expect(
            before.outcomes['${Tables.observations}/obs-bob-1/$projectA'],
            SyncRowOutcome.unauthorized,
          );

          // He joins. This is the only thing that changes.
          await admit(alice, bob, projectA);

          final after = await offerBoth();
          expect(
            after.outcomes['${Tables.tags}/tag-bob-1/$projectA'],
            SyncRowOutcome.lostToServer,
            reason:
                'the second offer is a no-op, and that is itself the point: '
                'the tag landed on the FIRST push, before Bob was a member, '
                'so by now the server already holds an identical copy. Under '
                'the old rule this assertion read `inserted`, because the '
                'first push had been refused and the invitation was what let '
                'it through',
          );
          expect(
            after.outcomes['${Tables.observations}/obs-bob-1/$projectA'],
            SyncRowOutcome.unauthorized,
            reason:
                'task 11.24: membership is provenance for reaching somebody, '
                'never for saying they recorded something. Bob\'s bearings '
                'are Bob\'s device to push',
          );
        },
      );

      test(
        'the new member\'s identity is delivered even though it predates the '
        'owner\'s cursor',
        () async {
          // **The gap `ProjectReachability` recorded as "deliberately left for
          // Phase 11", now reachable — and reachable because of this task.**
          // Reachability narrows *which* global rows a pull may deliver; the
          // `server_seq > cursor` window decides *when*. A `Users` row written
          // before the owner's cursor, which only becomes reachable when its
          // person joins, satisfies the first and fails the second. The owner
          // would then receive a membership row naming somebody whose `Users`
          // row never arrives — and the client's own foreign key would refuse
          // the page, breaking that device's sync rather than one row.
          final alice = await signIn(aliceEmail);
          await publish(alice, aliceEmail, projectA);

          // Bob's identity lands on the server first, at a low sequence.
          final bob = await signIn(bobEmail, deviceId: 'device-B');
          await push(
            bob.token,
            projectId: projectA,
            rows: {
              Tables.users: [userRow(bob.userId, bobEmail)],
            },
            deviceId: 'device-B',
          );

          // Alice then writes something of her own, which takes a *higher*
          // sequence than Bob's identity row. Without this the reproduction is
          // vacuous: her cursor would stop at the last row she was actually
          // shown, which is below Bob's, and his row would still be in her
          // next window for the ordinary reason.
          await push(
            alice.token,
            projectId: projectA,
            rows: {
              Tables.observations: [
                observationRow(
                  'obs-alice',
                  projectId: projectA,
                  userId: alice.userId,
                  modifiedBy: alice.userId,
                ),
              ],
            },
          );

          // Alice catches up, so her cursor is now past it.
          final caughtUp = SyncPullResponse.fromJson(
            jsonDecode(
              (await pull(alice.token, projectId: projectA)).body,
            ) as Map<String, Object?>,
          );
          final cursor = caughtUp.nextCursor;

          await admit(alice, bob, projectA);

          final page = SyncPullResponse.fromJson(
            jsonDecode(
              (await http.post(
                baseUri.replace(path: '/sync/pull'),
                headers: auth(alice.token),
                body: jsonEncode(
                  SyncPullRequest(
                    projectId: projectA,
                    deviceId: 'device-A',
                    cursor: cursor,
                  ).toJson(),
                ),
              )).body,
            ) as Map<String, Object?>,
          );

          expect(
            (page.rows[Tables.projectMemberships] ?? const [])
                .where((row) => row['user_id'] == bob.userId),
            hasLength(1),
            reason: 'the membership arrives',
          );
          expect(
            (page.rows[Tables.users] ?? const [])
                .where((row) => row['user_id'] == bob.userId),
            hasLength(1),
            reason:
                'and so does the person it names, or the row cannot be stored',
          );
        },
      );

      test('membership in one project does not make a name usable in another',
          () async {
        // The exemption widened by exactly one project, not globally.
        final alice = await signIn(aliceEmail);
        await publish(alice, aliceEmail, projectA);
        await publish(alice, aliceEmail, projectB);
        final bob = await signIn(bobEmail, deviceId: 'device-B');
        await push(
          bob.token,
          projectId: projectA,
          rows: {
            Tables.users: [userRow(bob.userId, bobEmail)],
          },
          deviceId: 'device-B',
        );
        await admit(alice, bob, projectA);

        final response = SyncPushResponse.fromJson(
          jsonDecode(
            (await push(
              alice.token,
              projectId: projectB,
              rows: {
                Tables.observations: [
                  observationRow(
                    'obs-bob-b',
                    projectId: projectB,
                    userId: bob.userId,
                    modifiedBy: alice.userId,
                  ),
                ],
              },
            )).body,
          ) as Map<String, Object?>,
        );
        expect(
          response.outcomes['${Tables.observations}/obs-bob-b/$projectB'],
          SyncRowOutcome.unauthorized,
        );
      });
    },
  );

  group('a membership row nobody granted', skip: databaseSkipReason, () {
    test('cannot be pushed by the device it would benefit', () async {
      // A client-side check only stops honest paths; this is the hostile one.
      // The row is refused because it is authorization state naming somebody
      // the project's owners did not name — §4.17's "authorization state is not
      // field data" clause, which is why redemption writes the row server-side
      // instead of teaching the push path an exemption.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final carol = await signIn(carolEmail, deviceId: 'device-C');

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.projectMemberships: [
            {
              'membership_id': 'm-forged',
              'project_id': projectA,
              'user_id': carol.userId,
              'join_date': at,
              'role': 'owner',
              'created_at': at,
              'updated_at': at,
              'revision': 1,
              'last_modified_by': carol.userId,
              'origin_device_id': 'device-C',
            },
          ],
        },
        deviceId: 'device-C',
      );
      // Refused at the project level before any row is judged, and
      // indistinguishably from a project that does not exist.
      expect(response.statusCode, 403);
      final rows = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE user_id = $1',
        parameters: [carol.userId],
      );
      expect(rows.first.first, 0);
    });

    test('cannot be pushed by a contributor already on the project', () async {
      // The harder case: Carol is a real member, so the project-level gate
      // passes and the row-level rule is what has to refuse. `projectOwner`
      // governs this table.
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final carol = await signIn(carolEmail, deviceId: 'device-C');
      await admit(alice, carol, projectA);

      final response = SyncPushResponse.fromJson(
        jsonDecode(
          (await push(
            carol.token,
            projectId: projectA,
            rows: {
              Tables.projectMemberships: [
                {
                  'membership_id': 'm-self-promoted',
                  'project_id': projectA,
                  'user_id': carol.userId,
                  'join_date': at,
                  'role': 'owner',
                  'created_at': at,
                  'updated_at': at,
                  'revision': 1,
                  'last_modified_by': carol.userId,
                  'origin_device_id': 'device-C',
                },
              ],
            },
            deviceId: 'device-C',
          )).body,
        ) as Map<String, Object?>,
      );
      expect(
        response.outcomes[
            '${Tables.projectMemberships}/m-self-promoted/$projectA'],
        SyncRowOutcome.unauthorized,
      );
      final owners = await connection.runTx(
        (tx) => ProjectAuthorizer.resolve(
          tx,
          projectId: projectA,
          userId: carol.userId,
        ),
      );
      // The default role `createInvite` issues. Carol is still exactly what
      // the invitation made her — task 11.3 split Phase 10's single `member`
      // into the two rungs, and neither is `owner`.
      expect(owners, ProjectAccess.contributor);
    });
  });

  group('removal, and what it does not reach', skip: databaseSkipReason, () {
    test('takes effect on the removed member\'s very next request', () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      await admit(alice, bob, projectA);
      expect((await pull(bob.token, projectId: projectA)).statusCode, 200);

      // Alice ends the stint the way the app does — an ordinary update to the
      // membership row, authorized by the `projectOwner` rule.
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1 WHERE project_id = $2 AND user_id = $3',
        parameters: ['2026-09-01T00:00:00.000Z', projectA, bob.userId],
      );

      // **Bob's session is untouched and unexpired.** It still works — for
      // everything he is still entitled to. What stopped is his access to this
      // project, because the server resolves that from membership on every
      // request and caches no decision (§4.3's reason for database-backed
      // sessions).
      //
      // **What "stopped" means changed on 2026-08-29 (task 11.60, §4.27), and
      // this asserts the new shape rather than a status code.** The pull now
      // succeeds and carries exactly one thing: Bob's own closed membership
      // row, so his device can say *you were removed* instead of *the server
      // is refusing access*, and can then delete its copy through the path
      // that already exists. None of the project reaches him — that is what
      // the row-level assertions below are for, and they are the property this
      // test was always about. A bare `403` was only ever the shape that
      // property happened to take.
      final after = await pull(bob.token, projectId: projectA);
      expect(after.statusCode, 200, reason: after.body);
      final page = SyncPullResponse.fromJson(
        jsonDecode(after.body) as Map<String, Object?>,
      );
      expect(
        page.rows.keys,
        [Tables.projectMemberships],
        reason:
            'the disclosure carried a table other than the one it is for — '
            'project data has reached somebody who is no longer a member',
      );
      final disclosed = page.rows[Tables.projectMemberships]!;
      expect(disclosed, hasLength(1));
      expect(disclosed.single['user_id'], bob.userId);
      expect(disclosed.single['end_date'], isNotNull);

      // And the writes are refused exactly as before. The disclosure is a
      // read; it must not have reopened anything.
      expect(
        (await ack(bob.token, projectId: projectA, cursor: 1)).statusCode,
        403,
      );
    });

    test(
      'removal from one project leaves the person\'s other projects alone',
      () async {
        // **The trap this test exists to catch.** §4.3 names
        // `revokeAllSessionsForUser` as "what task 11.2's member removal
        // calls", written when a user had exactly one project. Calling it here
        // would sign a field tech out of the two other studies they are on
        // because one of them ended — the assumption Phase 11 forbids.
        final alice = await signIn(aliceEmail);
        final carol = await signIn(carolEmail, deviceId: 'device-C');
        await publish(alice, aliceEmail, projectA);
        await publish(carol, carolEmail, projectB);

        final bob = await signIn(bobEmail, deviceId: 'device-B');
        await admit(alice, bob, projectA);
        await admit(carol, bob, projectB);
        expect((await pull(bob.token, projectId: projectA)).statusCode, 200);
        expect((await pull(bob.token, projectId: projectB)).statusCode, 200);

        await connection.execute(
          'UPDATE ${quoted(Tables.projectMemberships)} '
          r'SET end_date = $1 WHERE project_id = $2 AND user_id = $3',
          parameters: ['2026-09-01T00:00:00.000Z', projectA, bob.userId],
        );

        // Ended on A: the only thing he gets back is his own closed row on A
        // (task 11.60, §4.27).
        final endedProject = SyncPullResponse.fromJson(
          jsonDecode(
                (await pull(bob.token, projectId: projectA)).body,
              )
              as Map<String, Object?>,
        );
        expect(endedProject.rows.keys, [Tables.projectMemberships]);
        expect(
          endedProject.rows[Tables.projectMemberships]!.single['end_date'],
          isNotNull,
        );
        expect(
          (await pull(bob.token, projectId: projectB)).statusCode,
          200,
          reason:
              'one project ending must not end the others — a field tech on '
              'three concurrent studies is the normal case, not an edge case',
        );
        // **And B is a real sync, not a disclosure.** Distinguishing the two
        // matters here more than anywhere: since 11.60 both answer `200`, so a
        // status code alone would pass this test even if removal from A had
        // silently ended B as well.
        final stillOn = SyncPullResponse.fromJson(
          jsonDecode(
                (await pull(bob.token, projectId: projectB)).body,
              )
              as Map<String, Object?>,
        );
        expect(
          stillOn.rows.keys,
          contains(Tables.projects),
          reason:
              'project B came back as a membership-only page, which is what a '
              'removed member gets — so removal from A ended B too',
        );
      },
    );

    test('a removed member can be put back, as a new stint', () async {
      final alice = await signIn(aliceEmail);
      await publish(alice, aliceEmail, projectA);
      final bob = await signIn(bobEmail, deviceId: 'device-B');
      await admit(alice, bob, projectA);
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1 WHERE project_id = $2 AND user_id = $3',
        parameters: ['2026-09-01T00:00:00.000Z', projectA, bob.userId],
      );

      // **Under task 11.81 the owner puts them back directly**, with no code
      // and no request — see `POST /projects/<id>/members/readmit`. That is a
      // better answer than the one this test used to check: re-admitting
      // somebody the owner already trusts no longer makes them go and redeem a
      // code. The role is chosen at re-admission, so the returning stint can
      // differ from the one before.
      final readmitted = await http.post(
        baseUri.replace(path: '/projects/$projectA/members/readmit'),
        headers: auth(alice.token),
        body: jsonEncode({'user_id': bob.userId, 'role': 'viewer'}),
      );
      expect(readmitted.statusCode, 200, reason: readmitted.body);

      final rows = await connection.execute(
        'SELECT role, end_date FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1 AND user_id = $2 ORDER BY end_date NULLS LAST',
        parameters: [projectA, bob.userId],
      );
      expect(rows, hasLength(2));
      expect(rows.last[1], isNull, reason: 'the new stint is open');
      expect(rows.last[0], 'viewer', reason: 'and carries the new role');
      expect((await pull(bob.token, projectId: projectA)).statusCode, 200);
    });
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
