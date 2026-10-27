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

/// Task 11.290, over a real bound socket: an owner schedules a project's
/// destruction, **every member** sees the date in `GET /projects/mine`, the
/// owner can cancel, "delete now" destroys inside the request, and a
/// destroyed id refuses every later sync request with a code the app can
/// name — including the push that would otherwise re-establish it.
///
/// The sweep itself is `test/projects/project_destruction_test.dart`; this
/// file is about the wire.
void main() {
  late Connection connection;
  // The audit log writes on its own connection, as `bin/server.dart` gives
  // it one: a route's transaction and an audit write on the same connection
  // would deadlock on `runTx`.
  late Connection auditConnection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_project_destruction_routes_test';

  final captured = <String, String>{};

  const aliceEmail = 'alice@example.org';
  const bobEmail = 'bob@example.org';
  const carolEmail = 'carol@example.org';
  const projectA = 'proj-a';
  const fictional = 'proj-does-not-exist';
  const at = '2026-08-01T12:00:00.000Z';
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
  }) => {
    'project_id': id,
    'project_name': name,
    'owner_user_id': ownerId,
    'creation_date': at,
    'datum': 'WGS84',
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': ownerId,
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

  Future<http.Response> ack(
    String token, {
    required String projectId,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/ack'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncAckRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: 1,
      ).toJson(),
    ),
  );

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
    final established = await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.projects: [projectRow(projectId, owner.userId)],
        Tables.projectMemberships: [
          membershipRow(
            'm-$projectId',
            projectId: projectId,
            userId: owner.userId,
          ),
        ],
        Tables.observations: [
          observationRow('obs-1', projectId: projectId, userId: owner.userId),
        ],
      },
    );
    expect(established.statusCode, 200, reason: established.body);
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

  /// Walks [email] onto [projectId] as a contributor through the real join
  /// code and a real approval, as `member_authorization_test.dart` does.
  Future<({String token, String userId})> joinAsContributor(
    ({String token, String userId}) owner,
    String email, {
    required String projectId,
    required String deviceId,
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
      body: jsonEncode({'role': 'contributor'}),
    );
    expect(approved.statusCode, 200, reason: approved.body);
    return member;
  }

  Future<http.Response> deletion(
    String token,
    String projectId, {
    ProjectDeletionAction? action,
    Object? rawBody,
  }) => action == null && rawBody == null
      ? http.get(
          baseUri.replace(path: '/projects/$projectId/deletion'),
          headers: authHeaders(token),
        )
      : http.post(
          baseUri.replace(path: '/projects/$projectId/deletion'),
          headers: authHeaders(token),
          body: jsonEncode(rawBody ?? {'action': action!.wire}),
        );

  ProjectDeletionStanding standingOf(http.Response response) {
    expect(response.statusCode, 200, reason: response.body);
    return ProjectDeletionStanding.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    );
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

  Future<int> countRows(String table, String projectId) async {
    final result = await connection.execute(
      'SELECT count(*) FROM ${quoted(table)} WHERE project_id = \$1',
      parameters: [projectId],
    );
    return result.first.first! as int;
  }

  Future<List<String>> auditEvents(String projectId) async {
    final result = await connection.execute(
      r'SELECT event FROM auth_audit_log WHERE outcome = $1 ORDER BY id',
      parameters: [projectId],
    );
    return [for (final row in result) row.first! as String];
  }

  // ---- the tests ----------------------------------------------------------

  group('scheduling and the countdown', skip: databaseSkipReason, () {
    test('the owner reads the grace period before committing', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      final standing = standingOf(await deletion(alice.token, projectA));
      expect(standing.isScheduled, isFalse);
      expect(standing.graceDays, 30);
      expect(standing.backupRetentionDays, 30);
    });

    test(
      'the server sets the date, and every member sees it in /projects/mine',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final bob = await joinAsContributor(
          alice,
          bobEmail,
          projectId: projectA,
          deviceId: 'phone-b',
        );

        final before = DateTime.now().toUtc();
        final standing = standingOf(
          await deletion(
            alice.token,
            projectA,
            action: ProjectDeletionAction.schedule,
          ),
        );
        expect(standing.isScheduled, isTrue);
        final destroyAt = standing.destroyAt!;
        // The server's clock plus the server's grace, whatever the body said
        // — the body said nothing about dates at all.
        expect(
          destroyAt.difference(before),
          greaterThanOrEqualTo(const Duration(days: 30)),
        );
        expect(
          destroyAt.difference(before),
          lessThan(const Duration(days: 30, minutes: 5)),
        );

        // The owner's list and the contributor's list carry the same date.
        for (final person in [alice, bob]) {
          final listed = (await mine(person.token)).single;
          expect(listed.projectId, projectA);
          expect(
            listed.destroyAt,
            destroyAt,
            reason: 'every member is told, not only the owner',
          );
        }
        expect(
          await auditEvents(projectA),
          contains('project_deletion_scheduled'),
        );
      },
    );

    test('a second schedule answers the same date', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      final first = standingOf(
        await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        ),
      );
      final second = standingOf(
        await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        ),
      );
      expect(second.destroyAt, first.destroyAt);
    });

    test('cancel clears the date for every member', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      final bob = await joinAsContributor(
        alice,
        bobEmail,
        projectId: projectA,
        deviceId: 'phone-b',
      );
      await deletion(
        alice.token,
        projectA,
        action: ProjectDeletionAction.schedule,
      );
      final standing = standingOf(
        await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.cancel,
        ),
      );
      expect(standing.isScheduled, isFalse);
      for (final person in [alice, bob]) {
        expect((await mine(person.token)).single.destroyAt, isNull);
      }
      expect(await countRows(Tables.observations, projectA), 1);
      expect(
        await auditEvents(projectA),
        contains('project_deletion_canceled'),
      );
    });
  });

  group('who may', skip: databaseSkipReason, () {
    test(
      'a contributor is refused identically to a stranger and to a fictional '
      'project',
      () async {
        final alice = await signIn(aliceEmail, deviceId: 'phone-a');
        await publish(alice, aliceEmail, projectA);
        final bob = await joinAsContributor(
          alice,
          bobEmail,
          projectId: projectA,
          deviceId: 'phone-b',
        );
        final carol = await signIn(carolEmail, deviceId: 'phone-c');

        final asContributor = await deletion(
          bob.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        );
        final asStranger = await deletion(
          carol.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        );
        final asFictional = await deletion(
          alice.token,
          fictional,
          action: ProjectDeletionAction.schedule,
        );
        for (final refused in [asContributor, asStranger, asFictional]) {
          expect(refused.statusCode, 403);
          expect(errorCode(refused), 'forbidden');
        }
        // Nobody who was refused scheduled anything.
        expect((await mine(alice.token)).single.destroyAt, isNull);

        // Nor may they cancel the owner's schedule, or read it.
        await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.schedule,
        );
        expect(
          (await deletion(
            bob.token,
            projectA,
            action: ProjectDeletionAction.cancel,
          )).statusCode,
          403,
        );
        expect((await deletion(bob.token, projectA)).statusCode, 403);
        expect((await mine(bob.token)).single.destroyAt, isNotNull);
      },
    );

    test('a body without a recognisable action is refused', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      for (final body in [
        <String, Object?>{},
        {'action': 'destroy_everything'},
        {'action': 3},
        {'destroy_at': '2020-01-01T00:00:00Z'},
      ]) {
        final response = await deletion(alice.token, projectA, rawBody: body);
        expect(response.statusCode, 400, reason: response.body);
      }
      expect((await mine(alice.token)).single.destroyAt, isNull);
    });
  });

  group('delete now', skip: databaseSkipReason, () {
    test('destroys the project in the request, and the id then refuses every '
        'sync request with a code the app can name', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      final bob = await joinAsContributor(
        alice,
        bobEmail,
        projectId: projectA,
        deviceId: 'phone-b',
      );

      final standing = standingOf(
        await deletion(
          alice.token,
          projectA,
          action: ProjectDeletionAction.immediate,
        ),
      );
      expect(standing.executedAt, isNotNull);
      expect(await countRows(Tables.projects, projectA), 0);
      expect(await countRows(Tables.observations, projectA), 0);
      expect(await countRows(Tables.projectMemberships, projectA), 0);
      expect(await mine(alice.token), isEmpty);
      expect(await mine(bob.token), isEmpty);
      expect(await auditEvents(projectA), contains('project_destroyed'));

      // Every later request about the project, from either device, draws
      // the named refusal — not the bare `forbidden` a removed member
      // reads as "an owner may have removed you".
      for (final person in [alice, bob]) {
        final pulled = await pull(person.token, projectId: projectA);
        expect(pulled.statusCode, 403, reason: pulled.body);
        expect(errorCode(pulled), syncRefusalProjectDestroyed);
        final acked = await ack(person.token, projectId: projectA);
        expect(acked.statusCode, 403);
        expect(errorCode(acked), syncRefusalProjectDestroyed);
      }

      // The owner's route refuses too: there is no project to own.
      expect((await deletion(alice.token, projectA)).statusCode, 403);
    });

    test('the owner\'s own device cannot re-establish the project by pushing '
        'its Projects row', () async {
      final alice = await signIn(aliceEmail, deviceId: 'phone-a');
      await publish(alice, aliceEmail, projectA);
      await deletion(
        alice.token,
        projectA,
        action: ProjectDeletionAction.immediate,
      );

      // Exactly the push an offline owner's device makes on its next round
      // when it held a pending rename: a valid Projects row naming itself
      // as owner, for an id the server no longer holds. Without the guard
      // this is a publish and the project comes back.
      final resurrection = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.projects: [
            projectRow(projectA, alice.userId, name: 'Renamed', revision: 1),
          ],
          Tables.projectMemberships: [
            membershipRow(
              'm-$projectA',
              projectId: projectA,
              userId: alice.userId,
            ),
          ],
        },
      );
      expect(resurrection.statusCode, 403, reason: resurrection.body);
      expect(errorCode(resurrection), syncRefusalProjectDestroyed);
      expect(
        await countRows(Tables.projects, projectA),
        0,
        reason: 'the destroyed id must stay retired',
      );

      // A push of nothing but the person's own row says nothing about the
      // project and is still accepted — the first request of a publish
      // has this shape and must work against any id.
      final globalOnly = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.users: [userRow(alice.userId, aliceEmail)],
        },
      );
      expect(globalOnly.statusCode, 200, reason: globalOnly.body);
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
