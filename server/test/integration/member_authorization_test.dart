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

/// **Task 11.3, over a real bound socket**, through the same `createHandler`
/// wiring `bin/server.dart` uses, with real magic-link sign-ins and real
/// invitations.
///
/// Three things are being proved here and none of them can be proved below the
/// HTTP layer, which is why this file exists rather than more cases in
/// `test/authz/authorization_test.dart`:
///
/// 1. **The role gradient is the server's, not the app's.** Every write below
///    is an HTTP request. Nothing here goes through a screen, a repository or a
///    provider, so a control that lives only in the UI cannot make a single one
///    of these pass. "A `viewer` who can write because only the UI stopped them
///    is not a viewer."
/// 2. **A membership row pushed directly.** Tasks 11.1 and 11.2 each check
///    their own insert path inside the app; neither binds a device that skips
///    the app and puts the row on the wire. The group below does exactly that,
///    from every rung of the gradient and from outside the project.
/// 3. **Cross-project isolation, endpoint by endpoint.** Not a sample — the
///    complete list of routes that take a project-scoped identifier, each
///    compared against a *fabricated* project id rather than against a
///    hard-coded status, so the test cannot pass by both branches happening to
///    match one expected constant (§4.13).
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_member_authz_test';

  final captured = <String, String>{};

  const aliceEmail = 'alice@example.org';
  const bobEmail = 'bob@example.org';
  const carolEmail = 'carol@example.org';
  const daveEmail = 'dave@example.org';
  const projectA = 'proj-a';
  const projectB = 'proj-b';
  const fictional = 'proj-does-not-exist';
  const at = '2026-08-01T12:00:00.000Z';

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
    captured.clear();
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
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

  Map<String, Object?> membershipRow(
    String id, {
    required String projectId,
    required String userId,
    String role = 'owner',
    int revision = 0,
  }) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': userId,
    'join_date': at,
    'end_date': null,
    'role': role,
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': 'device-X',
  };

  /// Task 11.7's supersede/exclude mark. `kind` is what decides who may write
  /// it, which is the point of the group below.
  Map<String, Object?> exclusionRow(
    String id, {
    required String projectId,
    required String observationId,
    required String userId,
    required String kind,
    String? supersededBy,
    int revision = 1,
    String? deletedAt,
    String? modifiedBy,
  }) => {
    'exclusion_id': id,
    'project_id': projectId,
    'observation_id': observationId,
    'user_id': userId,
    'kind': kind,
    'superseded_by_observation_id': supersededBy,
    'reason': null,
    'created_at': at,
    'updated_at': at,
    'deleted_at': deletedAt,
    'revision': revision,
    'last_modified_by': modifiedBy ?? userId,
    'origin_device_id': 'device-X',
  };

  Map<String, Object?> observationRow(
    String id, {
    required String projectId,
    required String userId,
    required String modifiedBy,
    String? tagId,
    int revision = 1,
    String? notes,
  }) => {
    'observation_id': id,
    'project_id': projectId,
    'user_id': userId,
    'tag_id': tagId,
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
    'notes': notes,
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-X',
  };

  /// Task 11.32: what a tag read at a moment.
  /// A tag version. `projectId` is required since task 11.219 — a version is
  /// a version of *one project's* tag, and the row is keyed
  /// `(tag_version_id, project_id)`.
  Map<String, Object?> tagVersionRow(
    String id, {
    required String tagId,
    required String projectId,
    required String modifiedBy,
    String name = 'Tag',
    double frequencyMhz = 150.1,
    int revision = 1,
  }) => {
    'tag_version_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'effective_from': at,
    'frequency_mhz': frequencyMhz,
    'pulse_rate': null,
    'pulse_pattern': null,
    'tag_name': name,
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-X',
  };

  /// A tag. **`projectId` is required, and that is task 11.219's whole
  /// change** — a tag belongs to one project, the column is `NOT NULL`, and
  /// the row is keyed `(tag_id, project_id)`. Making it required rather than
  /// defaulted is deliberate: a call site that forgets which project a tag is
  /// in is the bug this schema exists to make impossible to write.
  ///
  /// `lineage_id` defaults to the tag's own id, which is what both migrations
  /// do for a tag that was never copied — see `TAG_COPY_ON_ADD_DESIGN.md`
  /// §2.3. **Nothing in the server reads it**, and
  /// `assertSealedColumnsFeedNoReachability` is what keeps that true.
  Map<String, Object?> tagRow(
    String id, {
    required String projectId,
    required String modifiedBy,
    String name = 'Tag',
    int revision = 1,
    String? lineageId,
  }) => {
    'tag_id': id,
    'project_id': projectId,
    'lineage_id': lineageId ?? id,
    'copied_at': null,
    'frequency_mhz': 150.1,
    'tag_name': name,
    'status': 'active',
    'color_hex': '#FF0000',
    'created_at': at,
    'updated_at': at,
    'revision': revision,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-X',
  };

  // **`projectTagRow` is gone (task 11.219).** It built the junction row that
  // linked a global tag into a project. There is no global tag to link:
  // `tagRow` now carries the project itself, so the row that used to make a
  // tag reachable and the row that *is* the tag are one row.

  Map<String, Object?> estimateRow(
    String id, {
    required String projectId,
    required String tagId,
    required String modifiedBy,
  }) => {
    'position_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'timestamp_local': at,
    'timestamp_utc': at,
    'timezone_offset': '+00:00',
    'latitude': 35.19,
    'longitude': -111.65,
    'semi_major_axis': 120.0,
    'semi_minor_axis': 80.0,
    'rotation_angle': 30.0,
    'method': 'lenth_mle',
    'observation_ids_used': 'obs-1',
    'created_at': at,
    'updated_at': at,
    'revision': 1,
    'last_modified_by': modifiedBy,
    'origin_device_id': 'device-X',
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
      SyncPushRequest(projectId: projectId, deviceId: deviceId, rows: rows)
          .toJson(),
    ),
  );

  Future<http.Response> pull(
    String token, {
    required String projectId,
    int cursor = 0,
    String deviceId = 'device-X',
  }) => http.post(
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

  Future<http.Response> ack(
    String token, {
    required String projectId,
    int cursor = 1,
    String deviceId = 'device-X',
  }) => http.post(
    baseUri.replace(path: '/sync/ack'),
    headers: authHeaders(token),
    body: jsonEncode(
      SyncAckRequest(
        projectId: projectId,
        deviceId: deviceId,
        cursor: cursor,
      ).toJson(),
    ),
  );

  /// The per-row outcome for `table/key`, from a 200 push.
  SyncRowOutcome? outcome(http.Response response, String reference) {
    expect(response.statusCode, 200, reason: response.body);
    return SyncPushResponse.fromJson(
      jsonDecode(response.body) as Map<String, Object?>,
    ).outcomes[reference];
  }

  /// Publishes [projectId] owned by [owner], exactly as the app does: the
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
    final established = await push(
      owner.token,
      projectId: projectId,
      rows: {
        Tables.projects: [projectRow(projectId, owner.userId)],
        Tables.projectMemberships: [
          membershipRow('m-$projectId', projectId: projectId,
              userId: owner.userId),
        ],
      },
    );
    expect(established.statusCode, 200, reason: established.body);
  }

  /// Switches joining on for [projectId] and returns its code.
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

  /// Signs [email] in and walks them onto [projectId] at [role] **through the
  /// real join code and a real approval** (task 11.81).
  ///
  /// Nothing is seeded straight into the tables: the membership these tests are
  /// about has to be the one the product actually produces, or the gradient is
  /// being tested against a fixture rather than against the feature. That
  /// requirement did not change when the mechanism did — only the three calls
  /// it takes to satisfy it.
  Future<({String token, String userId})> joinAs(
    ({String token, String userId}) owner,
    String email, {
    required String projectId,
    required String role,
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
      body: jsonEncode({'role': role}),
    );
    expect(approved.statusCode, 200, reason: approved.body);
    return member;
  }

  /// The stored name of one project's copy of a tag.
  ///
  /// **`projectId` is required, and leaving it out would have been a real
  /// defect rather than an inconvenience.** Two projects may now hold a tag
  /// with the same `tag_id` — that is what a copy is — so a query on `tag_id`
  /// alone can answer about the wrong row, and every assertion below that says
  /// "the victim's tag is untouched" would be satisfiable by reading the
  /// attacker's own copy.
  Future<String?> storedTagName(
    String tagId, {
    required String projectId,
  }) async {
    final rows = await connection.execute(
      'SELECT tag_name FROM ${quoted(Tables.tags)} '
      r'WHERE tag_id = $1 AND project_id = $2',
      parameters: [tagId, projectId],
    );
    return rows.isEmpty ? null : rows.first.first as String?;
  }

  Future<int> countRows(String table, String projectId) async {
    final rows = await connection.execute(
      'SELECT count(*) FROM ${quoted(table)} WHERE project_id = \$1',
      parameters: [projectId],
    );
    return rows.first.first! as int;
  }

  // ---- the gradient -------------------------------------------------------

  group('the role gradient, enforced server-side', skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;
    late ({String token, String userId}) viewer;
    late ({String token, String userId}) contributor;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
      viewer = await joinAs(
        alice,
        bobEmail,
        projectId: projectA,
        role: 'viewer',
        deviceId: 'device-B',
      );
      contributor = await joinAs(
        alice,
        carolEmail,
        projectId: projectA,
        role: 'contributor',
        deviceId: 'device-C',
      );
    });

    test('a viewer may read the project', () async {
      // The whole of what a viewer was granted. If this ever fails, the
      // gradient has been applied to the wrong verb.
      final response = await pull(viewer.token, projectId: projectA);
      expect(response.statusCode, 200, reason: response.body);
      final page = SyncPullResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      );
      expect(
        page.rows[Tables.projects],
        isNotEmpty,
        reason: 'a viewer who cannot see the project has been given nothing',
      );
    });

    test('and may acknowledge what they read', () async {
      expect((await ack(viewer.token, projectId: projectA)).statusCode, 200);
    });

    test('a viewer cannot record an observation of their own', () async {
      final response = await push(
        viewer.token,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observationRow(
              'obs-viewer',
              projectId: projectA,
              userId: viewer.userId,
              modifiedBy: viewer.userId,
            ),
          ],
        },
      );
      // A per-row refusal, not a transport-level 403: the device holds the row
      // and explains it (task 10.28) rather than reporting a failed sync.
      expect(
        outcome(response, '${Tables.observations}/obs-viewer/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(await countRows(Tables.observations, projectA), 0);
    });

    test(
      'nor write any of the shared tables the rule table lets everyone write',
      () async {
        // `anyUser`'s narrowing, which is the half with no author column to
        // stop a viewer. Every one of these is a table where
        // `MutationRule.permits` returns true for anybody who gets this far.
        //
        // **`Project_Tags` used to hold the first slot and its place is taken
        // by `Tags` and `Tag_Versions` (task 11.219).** Those two were global
        // tables when this list was written, so `_authorizeRole` skipped them
        // and they could not be listed here; they are project-scoped now, so
        // they belong in exactly this enumeration. The tags group below is
        // where the *reasoning* about a viewer and a tag lives — this is the
        // list, and its job is to be complete.
        final response = await push(
          viewer.token,
          projectId: projectA,
          rows: {
            Tables.tags: [
              tagRow('tag-viewer', projectId: projectA,
                  modifiedBy: viewer.userId),
            ],
            Tables.tagVersions: [
              tagVersionRow('ver-viewer', tagId: 'tag-viewer',
                  projectId: projectA, modifiedBy: viewer.userId),
            ],
            Tables.triangulationSessions: [
              {
                'session_id': 'sess-viewer',
                'project_id': projectA,
                'tag_id': 'tag-1',
                'started_at_local': at,
                'started_at_utc': at,
                'started_at_offset': '+00:00',
                'created_at': at,
                'updated_at': at,
                'revision': 1,
                'last_modified_by': viewer.userId,
                'origin_device_id': 'device-B',
              },
            ],
            Tables.estimatedPositions: [
              estimateRow('pos-viewer', projectId: projectA, tagId: 'tag-1',
                  modifiedBy: viewer.userId),
            ],
            Tables.actualTagLocations: [
              {
                'location_id': 'loc-viewer',
                'project_id': projectA,
                'tag_id': 'tag-1',
                'timestamp_local': at,
                'timestamp_utc': at,
                'timezone_offset': '+00:00',
                'latitude': 35.19,
                'longitude': -111.65,
                'uncertainty_radius': 10.0,
                'created_at': at,
                'updated_at': at,
                'revision': 1,
                'last_modified_by': viewer.userId,
                'origin_device_id': 'device-B',
              },
            ],
          },
          deviceId: 'device-B',
        );
        for (final reference in [
          '${Tables.tags}/tag-viewer/$projectA',
          '${Tables.tagVersions}/ver-viewer/$projectA',
          '${Tables.triangulationSessions}/sess-viewer/$projectA',
          '${Tables.estimatedPositions}/pos-viewer/$projectA',
          '${Tables.actualTagLocations}/loc-viewer/$projectA',
        ]) {
          expect(
            outcome(response, reference),
            SyncRowOutcome.unauthorized,
            reason: '$reference was written by a viewer',
          );
        }
      },
    );

    test('but a viewer may still push their own profile', () async {
      // Their identity is theirs, not the project's, and refusing it would
      // leave somebody unable to correct their own name because of a role in
      // somebody else's study.
      final response = await push(
        viewer.token,
        projectId: projectA,
        rows: {
          Tables.users: [
            {...userRow(viewer.userId, bobEmail), 'first_name': 'Bob'},
          ],
        },
        deviceId: 'device-B',
      );
      expect(
        outcome(response, '${Tables.users}/${viewer.userId}'),
        anyOf(SyncRowOutcome.inserted, SyncRowOutcome.updated),
      );
    });

    test('a contributor may record an observation', () async {
      final response = await push(
        contributor.token,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observationRow(
              'obs-carol',
              projectId: projectA,
              userId: contributor.userId,
              modifiedBy: contributor.userId,
            ),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.observations}/obs-carol/$projectA'),
        SyncRowOutcome.inserted,
      );
    });

    test('a contributor cannot touch another member\'s observation', () async {
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
      final response = await push(
        contributor.token,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observationRow(
              'obs-alice',
              projectId: projectA,
              userId: alice.userId,
              modifiedBy: alice.userId,
              revision: 99,
              notes: 'rewritten',
            ),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.observations}/obs-alice/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      final stored = await connection.execute(
        'SELECT notes FROM ${quoted(Tables.observations)} '
        r'WHERE observation_id = $1',
        parameters: ['obs-alice'],
      );
      expect(stored.first.first, isNull, reason: 'the field record stands');
    });

    test(
      'a contributor cannot change the project settings or anyone\'s role',
      () async {
        final response = await push(
          contributor.token,
          projectId: projectA,
          rows: {
            Tables.projects: [
              {
                ...projectRow(projectA, alice.userId),
                'project_name': 'Seized',
                'revision': 9,
              },
            ],
            Tables.projectMemberships: [
              {
                ...membershipRow('m-$projectA', projectId: projectA,
                    userId: alice.userId, role: 'viewer'),
                'revision': 9,
                'last_modified_by': contributor.userId,
              },
            ],
          },
          deviceId: 'device-C',
        );
        expect(
          outcome(response, '${Tables.projects}/$projectA'),
          SyncRowOutcome.unauthorized,
        );
        expect(
          outcome(response,
              '${Tables.projectMemberships}/m-$projectA/$projectA'),
          SyncRowOutcome.unauthorized,
        );
      },
    );

    test('an owner may do all of it', () async {
      final response = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.projects: [
            {
              ...projectRow(projectA, alice.userId),
              'project_name': 'Renamed By Owner',
              'revision': 9,
            },
          ],
          Tables.observations: [
            observationRow(
              'obs-owner',
              projectId: projectA,
              userId: alice.userId,
              modifiedBy: alice.userId,
            ),
          ],
          Tables.estimatedPositions: [
            estimateRow('pos-owner', projectId: projectA, tagId: 'tag-owner',
                modifiedBy: alice.userId),
          ],
          // **One row where there used to be two.** "An owner may add a tag
          // to the project" was a `Tags` insert plus the `Project_Tags` link
          // that made it reachable; under copy-on-add the tag is created
          // inside the project and the insert is the whole operation.
          Tables.tags: [
            tagRow('tag-owner', projectId: projectA,
                modifiedBy: alice.userId),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.projects}/$projectA'),
        SyncRowOutcome.updated,
      );
      for (final reference in [
        '${Tables.observations}/obs-owner/$projectA',
        '${Tables.estimatedPositions}/pos-owner/$projectA',
        '${Tables.tags}/tag-owner/$projectA',
      ]) {
        expect(outcome(response, reference), SyncRowOutcome.inserted,
            reason: reference);
      }
    });

    test(
      'the client and the server resolve the same role from the same rows',
      () async {
        // One definition, `resolveProjectRole`, is what stops the app offering
        // a write the server will refuse — and stops it hiding one the server
        // would allow. Asked here against the rows an actual invitation wrote.
        final rows = (await connection.execute(
          'SELECT user_id, role, end_date, deleted_at '
          'FROM ${quoted(Tables.projectMemberships)} '
          r'WHERE project_id = $1',
          parameters: [projectA],
        )).map((row) => row.toColumnMap()).toList();

        ProjectRole? roleOf(String userId) => resolveProjectRole(
          membershipRows: rows,
          creatorUserId: alice.userId,
          userId: userId,
        );
        expect(roleOf(alice.userId), ProjectRole.owner);
        expect(roleOf(contributor.userId), ProjectRole.contributor);
        expect(roleOf(viewer.userId), ProjectRole.viewer);
        expect(roleOf('nobody'), isNull);

        for (final (user, expected) in [
          (alice.userId, ProjectAccess.owner),
          (contributor.userId, ProjectAccess.contributor),
          (viewer.userId, ProjectAccess.viewer),
          ('nobody', ProjectAccess.none),
        ]) {
          expect(
            await connection.runTx(
              (tx) => ProjectAuthorizer.resolve(
                tx,
                projectId: projectA,
                userId: user,
              ),
            ),
            expected,
            reason: 'the server disagrees with the shared resolution for $user',
          );
        }
      },
    );
  });

  // ---- membership inserts, pushed directly --------------------------------

  group('a membership row put straight on the wire', skip: databaseSkipReason,
      () {
    late ({String token, String userId}) alice;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
    });

    Future<SyncRowOutcome?> pushMembership(
      ({String token, String userId}) as, {
      required String membershipId,
      required String userId,
      required String role,
      String deviceId = 'device-X',
    }) async {
      final response = await push(
        as.token,
        projectId: projectA,
        rows: {
          Tables.projectMemberships: [
            membershipRow(membershipId, projectId: projectA, userId: userId,
                role: role),
          ],
        },
        deviceId: deviceId,
      );
      return outcome(
        response,
        '${Tables.projectMemberships}/$membershipId/$projectA',
      );
    }

    test('a contributor cannot promote themselves to owner', () async {
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');
      expect(
        await pushMembership(carol, membershipId: 'm-grab',
            userId: carol.userId, role: 'owner', deviceId: 'device-C'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await connection.runTx((tx) => ProjectAuthorizer.resolve(
          tx, projectId: projectA, userId: carol.userId)),
        ProjectAccess.contributor,
      );
    });

    test('nor to contributor a second time, which is the pair invariant',
        () async {
      // Not an escalation, and refused anyway. Two open rows for one (project,
      // user) pair make role lookup arbitrary — `findForUser` takes the first
      // row it finds — so somebody could end up with permissions nobody
      // granted. Task 11.10's partial unique index backstops the concurrent
      // case; this is the check that produces a legible answer.
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');
      expect(
        await pushMembership(carol, membershipId: 'm-second',
            userId: carol.userId, role: 'contributor', deviceId: 'device-C'),
        SyncRowOutcome.unauthorized,
      );
      final open = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1 AND user_id = $2 AND end_date IS NULL',
        parameters: [projectA, carol.userId],
      );
      expect(open.first.first, 1);
    });

    test('a viewer cannot grant themselves anything', () async {
      final bob = await joinAs(alice, bobEmail, projectId: projectA,
          role: 'viewer', deviceId: 'device-B');
      expect(
        await pushMembership(bob, membershipId: 'm-viewer-grab',
            userId: bob.userId, role: 'owner', deviceId: 'device-B'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an owner cannot add somebody else by pushing a row', () async {
      // The point of task 11.2's design: adding a member is invite redemption,
      // where the **server** writes the row from the invitation's own project
      // and role. The push path therefore needs no exemption, and must not
      // grow one — a pushed row would name its own role, its own user and its
      // own project.
      final dave = await signIn(daveEmail, deviceId: 'device-D');
      expect(
        await pushMembership(alice, membershipId: 'm-planted',
            userId: dave.userId, role: 'contributor'),
        SyncRowOutcome.unauthorized,
      );
      expect(await countRows(Tables.projectMemberships, projectA), 1);
    });

    test('nor a second one for themselves', () async {
      expect(
        await pushMembership(alice, membershipId: 'm-extra',
            userId: alice.userId, role: 'owner'),
        SyncRowOutcome.unauthorized,
      );
    });

    test(
      'a stranger is turned away before any row is looked at',
      () async {
        // A `Project_Memberships` row is project-scoped, so this push touches
        // the project and the route refuses it outright — and refuses it
        // identically for a project that does not exist.
        final dave = await signIn(daveEmail, deviceId: 'device-D');
        final forbidden = await push(
          dave.token,
          projectId: projectA,
          rows: {
            Tables.projectMemberships: [
              membershipRow('m-stranger', projectId: projectA,
                  userId: dave.userId, role: 'owner'),
            ],
          },
          deviceId: 'device-D',
        );
        final imaginary = await push(
          dave.token,
          projectId: fictional,
          rows: {
            Tables.projectMemberships: [
              membershipRow('m-stranger', projectId: fictional,
                  userId: dave.userId, role: 'owner'),
            ],
          },
          deviceId: 'device-D',
        );
        expect(forbidden.statusCode, imaginary.statusCode);
        expect(forbidden.statusCode, 403);
        expect(await countRows(Tables.projectMemberships, projectA), 1);
      },
    );

    test('two membership rows in one push cannot both slip past the invariant',
        () async {
      // A push is authorized row by row against one pre-push snapshot, so
      // without within-push bookkeeping both of these would see a project with
      // no open membership for Alice and both be allowed — the two open rows
      // for one pair the invariant exists to prevent. Aimed at a project that
      // does not exist yet, which is the bootstrap door and the only one this
      // path leaves open.
      final dave = await signIn(daveEmail, deviceId: 'device-D');
      await push(
        dave.token,
        projectId: 'proj-double',
        rows: {
          Tables.users: [userRow(dave.userId, daveEmail)],
        },
        deviceId: 'device-D',
      );
      final response = await push(
        dave.token,
        projectId: 'proj-double',
        rows: {
          Tables.projects: [projectRow('proj-double', dave.userId)],
          Tables.projectMemberships: [
            membershipRow('m-one', projectId: 'proj-double',
                userId: dave.userId),
            membershipRow('m-two', projectId: 'proj-double',
                userId: dave.userId),
          ],
        },
        deviceId: 'device-D',
      );
      final outcomes = [
        outcome(response, '${Tables.projectMemberships}/m-one/proj-double'),
        outcome(response, '${Tables.projectMemberships}/m-two/proj-double'),
      ];
      expect(
        outcomes.where((o) => o == SyncRowOutcome.inserted),
        hasLength(1),
        reason: 'exactly one bootstrap row may land',
      );
      expect(outcomes, contains(SyncRowOutcome.unauthorized));
      final open = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1 AND user_id = $2 AND end_date IS NULL',
        parameters: ['proj-double', dave.userId],
      );
      expect(open.first.first, 1);
    });

    test('the one insert that is still allowed is a project\'s own bootstrap',
        () async {
      // `publish` in `setUp` already did it, which is what makes the refusals
      // above meaningful rather than a blanket "no membership row ever lands".
      final rows = await connection.execute(
        'SELECT user_id, role FROM ${quoted(Tables.projectMemberships)} '
        r'WHERE project_id = $1',
        parameters: [projectA],
      );
      expect(rows, hasLength(1));
      expect(rows.first[0], alice.userId);
      expect(rows.first[1], 'owner');
    });

    test('and redemption still works, because the server writes that row',
        () async {
      final bob = await joinAs(alice, bobEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-B');
      expect(
        await connection.runTx((tx) => ProjectAuthorizer.resolve(
          tx, projectId: projectA, userId: bob.userId)),
        ProjectAccess.contributor,
      );
    });
  });

  // ---- cross-project isolation, one verdict per endpoint ------------------

  group('cross-project isolation, endpoint by endpoint',
      skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;
    late ({String token, String userId}) bob;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      // Alice owns A. Bob owns B. Each is a fully legitimate, authenticated,
      // project-holding user — which is the point: the question is never
      // "is this caller authenticated" but "authorized for *this* project".
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      bob = await signIn(bobEmail, deviceId: 'device-B');
      await publish(alice, aliceEmail, projectA);
      await publish(bob, bobEmail, projectB);
      await push(
        bob.token,
        projectId: projectB,
        rows: {
          Tables.observations: [
            observationRow('obs-secret', projectId: projectB,
                userId: bob.userId, modifiedBy: bob.userId, notes: 'den site'),
          ],
        },
        deviceId: 'device-B',
      );
    });

    /// Asserts that Alice gets the same answer for **Bob's** project as for a
    /// project id nobody has ever created.
    ///
    /// Compared against each other rather than against a hard-coded status, so
    /// this cannot pass by both branches happening to match one constant —
    /// §4.13's requirement is that the two are indistinguishable, not that
    /// they are any particular number.
    Future<void> sameAsFictional(
      String label,
      Future<http.Response> Function(String projectId) call,
    ) async {
      final forbidden = await call(projectB);
      final imaginary = await call(fictional);
      expect(forbidden.statusCode, imaginary.statusCode, reason: label);
      // The error *code*, not the whole body: the project routes attach a
      // per-request `trace_id`, which differs between any two requests by
      // design and is the one field that must not be compared.
      expect(_errorCode(forbidden), _errorCode(imaginary), reason: label);
      expect(
        forbidden.statusCode,
        403,
        reason: '$label answered ${forbidden.statusCode}, not a refusal',
      );
    }

    test('POST /sync/push', () async {
      await sameAsFictional(
        'push',
        (projectId) => push(
          alice.token,
          projectId: projectId,
          rows: {
            Tables.observations: [
              observationRow('obs-intrusion', projectId: projectId,
                  userId: alice.userId, modifiedBy: alice.userId),
            ],
          },
        ),
      );
      expect(await countRows(Tables.observations, projectB), 1,
          reason: 'only Bob\'s own row');
    });

    test('POST /sync/pull', () async {
      await sameAsFictional(
        'pull',
        (projectId) => pull(alice.token, projectId: projectId),
      );
    });

    test('POST /sync/ack', () async {
      await sameAsFictional(
        'ack',
        (projectId) => ack(alice.token, projectId: projectId),
      );
    });

    test(
      'POST /sync/pull carrying a cursor another account earned on the same '
      'device is refused identically, and records no position (task 11.304)',
      () async {
        // Signing out leaves every project's cursor on the phone — task
        // 11.304 measured it — so when Bob signs out of a device and Alice
        // signs in on it, the first pull Alice's session makes for Bob's
        // project carries Bob's cursor, from Bob's device id. The cursor is
        // a statement about what that phone's database holds, and this test
        // is the server-side half of the question that decided the task:
        // does a position one account reached let another account past the
        // membership check, or leave a trace as if it had?
        final bobPage = SyncPullResponse.fromJson(
          jsonDecode(
            (await pull(bob.token, projectId: projectB, deviceId: 'device-B'))
                .body,
          ) as Map<String, Object?>,
        );
        final inherited = bobPage.nextCursor;
        expect(inherited, greaterThan(0), reason: 'Bob has synced something');

        await sameAsFictional(
          'pull with an inherited cursor',
          (projectId) => pull(
            alice.token,
            projectId: projectId,
            cursor: inherited,
            deviceId: 'device-B',
          ),
        );

        // The pull route records the client's position (task 11.291) — but
        // only past the membership check, so a refused caller leaves no row
        // saying they were ever at that position on that project.
        final recorded = await connection.execute(
          r'SELECT project_id, acknowledged_seq FROM sync_cursors '
          r'WHERE user_id = $1 AND device_id = $2',
          parameters: [alice.userId, 'device-B'],
        );
        expect(
          recorded,
          isEmpty,
          reason:
              'a refused pull must not record a cursor for the refused caller',
        );
      },
    );

    // **Task 11.81 replaced three invitation routes with six join routes, and
    // this group's premise is that it lists every project-scoped route rather
    // than a sample.** So all six are here, not the two somebody found most
    // interesting. A route missing from this list is a route nobody ever asked
    // the cross-project question of.

    test('GET /projects/<id>/join-settings', () async {
      await sameAsFictional(
        'read join settings',
        (projectId) => http.get(
          baseUri.replace(path: '/projects/$projectId/join-settings'),
          headers: authHeaders(alice.token),
        ),
      );
    });

    test('POST /projects/<id>/join-settings', () async {
      await sameAsFictional(
        'change join settings',
        (projectId) => http.post(
          baseUri.replace(path: '/projects/$projectId/join-settings'),
          headers: authHeaders(alice.token),
          body: jsonEncode({'joining_enabled': true, 'team_size_limit': 999}),
        ),
      );
      // **And it changed nothing**, which is the half a status code cannot
      // show: a 403 that had still written the row would leave Bob's project
      // open to anyone holding a code.
      final settings = await connection.execute(
        'SELECT count(*) FROM project_join_settings WHERE project_id = \$1',
        parameters: [projectB],
      );
      expect(
        settings.first.first,
        0,
        reason: 'Alice switched joining on for a project she is not in',
      );
    });

    test('POST /projects/<id>/join-code/rotate', () async {
      // Bob switches joining on first, so the row Alice is aiming at exists.
      // Otherwise "nothing happened" would be indistinguishable from "refused
      // for the wrong reason".
      final bobsCode = await enableJoining(bob.token, projectB);

      await sameAsFictional(
        'rotate the join code',
        (projectId) => http.post(
          baseUri.replace(path: '/projects/$projectId/join-code/rotate'),
          headers: authHeaders(alice.token),
          body: jsonEncode({'clear_pending': true}),
        ),
      );
      final after = (await connection.execute(
        'SELECT code FROM project_join_settings WHERE project_id = \$1',
        parameters: [projectB],
      )).first.first;
      expect(
        after,
        bobsCode,
        reason: "Alice rotated another project's join code, which would have "
            "killed the code on that crew's whiteboard",
      );
    });

    test('GET /projects/<id>/join-requests', () async {
      await sameAsFictional(
        'list join requests',
        (projectId) => http.get(
          baseUri.replace(path: '/projects/$projectId/join-requests'),
          headers: authHeaders(alice.token),
        ),
      );
    });

    test('POST /projects/<id>/join-requests/<requestId>/approve', () async {
      // A real pending request on Bob's project, so Alice is naming something
      // that exists. **This is the most serious of the six**: approval is the
      // one place on this server where one person's action creates another
      // person's access.
      final code = await enableJoining(bob.token, projectB);
      final dave = await signIn(daveEmail, deviceId: 'device-dave');
      final asked = await http.post(
        baseUri.replace(path: '/projects/join-requests'),
        headers: authHeaders(dave.token),
        body: jsonEncode({'code': code}),
      );
      expect(asked.statusCode, 200, reason: asked.body);
      final requestId = JoinRequestCreatedResponse.fromJson(
        jsonDecode(asked.body) as Map<String, Object?>,
      ).requestId;

      await sameAsFictional(
        'approve a join request',
        (projectId) => http.post(
          baseUri.replace(
            path: '/projects/$projectId/join-requests/$requestId/approve',
          ),
          headers: authHeaders(alice.token),
          body: jsonEncode({'role': 'owner'}),
        ),
      );
      final decided = await connection.execute(
        'SELECT decided_at FROM project_join_requests WHERE request_id = \$1',
        parameters: [requestId],
      );
      expect(
        decided.first.first,
        isNull,
        reason: 'Alice decided a join request in a project she is not in',
      );
      final granted = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
        'WHERE project_id = \$1 AND user_id = \$2',
        parameters: [projectB, dave.userId],
      );
      expect(
        granted.first.first,
        0,
        reason: 'Alice granted somebody a membership in Bob project',
      );
    });

    test('POST /projects/<id>/join-requests/<requestId>/reject', () async {
      final code = await enableJoining(bob.token, projectB);
      final dave = await signIn(daveEmail, deviceId: 'device-dave-2');
      final asked = await http.post(
        baseUri.replace(path: '/projects/join-requests'),
        headers: authHeaders(dave.token),
        body: jsonEncode({'code': code}),
      );
      expect(asked.statusCode, 200, reason: asked.body);
      final requestId = JoinRequestCreatedResponse.fromJson(
        jsonDecode(asked.body) as Map<String, Object?>,
      ).requestId;

      await sameAsFictional(
        'reject a join request',
        (projectId) => http.post(
          baseUri.replace(
            path: '/projects/$projectId/join-requests/$requestId/reject',
          ),
          headers: authHeaders(alice.token),
        ),
      );
      final decided = await connection.execute(
        'SELECT decided_at FROM project_join_requests WHERE request_id = \$1',
        parameters: [requestId],
      );
      expect(decided.first.first, isNull);
    });

    test('POST /projects/<id>/members/readmit', () async {
      await sameAsFictional(
        'readmit a member',
        (projectId) => http.post(
          baseUri.replace(path: '/projects/$projectId/members/readmit'),
          headers: authHeaders(alice.token),
          body: jsonEncode({'user_id': bob.userId, 'role': 'owner'}),
        ),
      );
      final granted = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
        'WHERE project_id = \$1 AND user_id = \$2 AND end_date IS NULL',
        parameters: [projectB, bob.userId],
      );
      expect(
        granted.first.first,
        1,
        reason: "Alice's call added or duplicated a membership in Bob project",
      );
    });

    test('GET /projects/mine lists only what the session reaches', () async {
      final response = await http.get(
        baseUri.replace(path: '/projects/mine'),
        headers: authHeaders(alice.token),
      );
      expect(response.statusCode, 200, reason: response.body);
      final listed = ProjectDirectoryResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      ).projects.map((p) => p.projectId).toList();
      expect(listed, [projectA]);
    });

    test(
      'GET /projects/mine ignores a caller-supplied user_id, in the query '
      'and in the body (task 11.64, finding P-1)',
      () async {
        // The gap task 11.49 recorded and did not attack: `/auth/sessions`
        // has had this exact test since task 11.35 and this route had none,
        // so "the user_id comes from the session" was a true sentence in a
        // comment with nothing measuring it. Bob is a real other person with
        // a real other project, so a route that honoured either input would
        // return projectB here rather than nothing at all — which is what
        // makes this an attack and not a shape check.
        final viaQuery = await http.get(
          baseUri.replace(
            path: '/projects/mine',
            query: 'user_id=${bob.userId}&device_id=bobs-phone',
          ),
          headers: authHeaders(alice.token),
        );
        expect(viaQuery.statusCode, 200, reason: viaQuery.body);
        expect(
          ProjectDirectoryResponse.fromJson(
            jsonDecode(viaQuery.body) as Map<String, Object?>,
          ).projects.map((p) => p.projectId).toList(),
          [projectA],
          reason: 'a query-supplied user_id must be ignored entirely',
        );

        // A GET with a body is unusual, not impossible.
        final request = http.Request(
          'GET',
          baseUri.replace(path: '/projects/mine'),
        )
          ..headers.addAll({
            ...authHeaders(alice.token),
            'content-type': 'application/json',
          })
          ..body = jsonEncode({'user_id': bob.userId});
        final viaBody = await http.Response.fromStream(
          await request.send(),
        );
        expect(viaBody.statusCode, 200, reason: viaBody.body);
        expect(
          ProjectDirectoryResponse.fromJson(
            jsonDecode(viaBody.body) as Map<String, Object?>,
          ).projects.map((p) => p.projectId).toList(),
          [projectA],
          reason: 'a body-supplied user_id must be ignored entirely',
        );
      },
    );

    test(
      'GET /projects/mine returns exactly the five fields §4.28 allows, and '
      'does not permit caching (task 11.64, finding P-1; task 11.290 added '
      'the fifth)',
      () async {
        final response = await http.get(
          baseUri.replace(path: '/projects/mine'),
          headers: authHeaders(alice.token),
        );
        expect(response.statusCode, 200, reason: response.body);
        expect(
          response.headers['cache-control'],
          'no-store',
          reason:
              'a list of somebody\'s projects must not be left in a shared '
              'cache; the sessions listing has sent this since task 11.35',
        );
        final rows =
            (jsonDecode(response.body) as Map<String, Object?>)['projects']
                as List<Object?>;
        expect(rows, isNotEmpty, reason: 'nothing is measured by an empty page');
        for (final row in rows) {
          expect(
            (row! as Map<String, Object?>).keys.toSet(),
            {
              'project_id',
              'project_name',
              'owner_user_id',
              'role',
              // Task 11.290: null here, because nothing is scheduled — the
              // key is always present so the field set is one set.
              'destroy_at',
            },
            reason:
                'Security Model §4.28 is the written statement of what a row '
                'here may carry. A field added to ProjectSummary without '
                'amending §4.28 is a disclosure decision nobody made.',
          );
        }
      },
    );

    test(
      'POST /projects/join-requests takes no project id, and a correct code '
      'grants nothing',
      () async {
        // This route deliberately has no project-scoped identifier — the code
        // names the project, so there is nothing for a caller to aim at. A
        // route that took one would let a caller ask "does this code work for
        // project X" and read the answer off the difference.
        //
        // **What has to hold instead changed with task 11.81, and this test
        // changed with it rather than being deleted.** It used to assert that
        // a code is bound to one address, so a stolen code is worthless. There
        // is no address binding any more — the code is shared on purpose. The
        // property that replaced it is stronger and is the one the whole
        // design rests on: **a correct code, used by somebody it was not meant
        // for, produces a request and no access whatsoever.**
        final code = await enableJoining(bob.token, projectB);

        final used = await http.post(
          baseUri.replace(path: '/projects/join-requests'),
          headers: authHeaders(alice.token),
          body: jsonEncode({'code': code}),
        );
        expect(
          used.statusCode,
          200,
          reason: 'a correct code does produce a request — that is the point',
        );

        // And Alice still reaches nothing. Not one row, not the name, not the
        // existence of anything she could not already see.
        expect((await pull(alice.token, projectId: projectB)).statusCode, 403);
        final memberships = await connection.execute(
          'SELECT count(*) FROM ${quoted(Tables.projectMemberships)} '
          'WHERE project_id = \$1 AND user_id = \$2',
          parameters: [projectB, alice.userId],
        );
        expect(
          memberships.first.first,
          0,
          reason: 'holding the code granted membership, which is the failure '
              'this whole design exists to prevent',
        );
        final mine = await http.get(
          baseUri.replace(path: '/projects/mine'),
          headers: authHeaders(alice.token),
        );
        expect(
          ProjectDirectoryResponse.fromJson(
            jsonDecode(mine.body) as Map<String, Object?>,
          ).projects.map((p) => p.projectId),
          [projectA],
          reason: 'a pending request must not put the project in her list — '
              'the reason a request is not a membership row',
        );
      },
    );

    test('a wrong code and a switched-off code answer identically', () async {
      // §4.13's existence oracle, on the one route an authenticated stranger
      // can reach. Compared to each other rather than to a constant, which is
      // the technique this file uses everywhere else.
      final code = await enableJoining(bob.token, projectB);
      final offAgain = await http.post(
        baseUri.replace(path: '/projects/$projectB/join-settings'),
        headers: authHeaders(bob.token),
        body: jsonEncode({'joining_enabled': false}),
      );
      expect(offAgain.statusCode, 200, reason: offAgain.body);

      final real = await http.post(
        baseUri.replace(path: '/projects/join-requests'),
        headers: authHeaders(alice.token),
        body: jsonEncode({'code': code}),
      );
      final nonsense = await http.post(
        baseUri.replace(path: '/projects/join-requests'),
        headers: authHeaders(alice.token),
        body: jsonEncode({'code': 'ZZZZZZZZ'}),
      );
      expect(real.statusCode, nonsense.statusCode);
      expect(_errorCode(real), _errorCode(nonsense));
      expect(real.statusCode, 403);
    });

    test('the retired redeem route is gone, not answering', () async {
      // Task 11.84 deleted it while deleting it was still free: nothing has
      // shipped, so there is no fleet on the previous build to answer. A stale
      // client now gets a plain 404, which is the truth.
      final response = await http.post(
        baseUri.replace(path: '/projects/invites/redeem'),
        headers: authHeaders(alice.token),
        body: jsonEncode({'code': 'ZZZZZZZZ'}),
      );
      expect(response.statusCode, 404);
    });

    test(
      'and a member of one project reads nothing of the other by pulling '
      'their own',
      () async {
        // The isolation that has nothing to do with a project id in a request:
        // a pull for A must not carry a row of B through the *global* tables,
        // which are filtered by reachability rather than by scope.
        final response = await pull(alice.token, projectId: projectA);
        final page = SyncPullResponse.fromJson(
          jsonDecode(response.body) as Map<String, Object?>,
        );
        final delivered = page.rows.values.expand((rows) => rows).toList();
        expect(
          delivered.any((row) => row['project_id'] == projectB),
          isFalse,
        );
        expect(
          delivered.any((row) => row['user_id'] == bob.userId),
          isFalse,
          reason: 'Bob\'s identity is not Alice\'s to receive',
        );
      },
    );
  });

  // ---- tags: §5.9(a) re-derived, and the re-delivery gap -----------------

  /// **Task 11.7, over the wire.** The app refuses a contributor's exclusion
  /// at the point of the tap, but that is advice — nothing in the app stops a
  /// device pushing the row straight to the server. This group is the boundary
  /// half: the same two rules, decided by the server, with no screen involved.
  ///
  /// The pair of tests matters more than either one. Refusing everything would
  /// pass the "contributor cannot exclude" test and destroy the feature, since
  /// superseding a colleague's bearing is the only correction mechanism a
  /// contributor has once editing is author-only.
  group('supersede and exclude (task 11.7)', skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;
    late ({String token, String userId}) contributor;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
      contributor = await joinAs(
        alice,
        carolEmail,
        projectId: projectA,
        role: 'contributor',
        deviceId: 'device-C',
      );
      // Two of the owner's observations for the marks to point at.
      final seeded = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observationRow(
              'obs-bad',
              projectId: projectA,
              userId: alice.userId,
              modifiedBy: alice.userId,
            ),
            observationRow(
              'obs-good',
              projectId: projectA,
              userId: alice.userId,
              modifiedBy: alice.userId,
            ),
          ],
        },
      );
      expect(seeded.statusCode, 200, reason: seeded.body);
    });

    test("a contributor may supersede the owner's observation — editing is "
        'author-only, so this is the only correction they have', () async {
      final response = await push(
        contributor.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            exclusionRow(
              'mark-supersede',
              projectId: projectA,
              observationId: 'obs-bad',
              userId: contributor.userId,
              kind: 'superseded',
              supersededBy: 'obs-good',
            ),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.observationExclusions}/mark-supersede/$projectA'),
        SyncRowOutcome.inserted,
      );
      expect(await countRows(Tables.observationExclusions, projectA), 1);
    });

    test('a contributor may not exclude — that rung is the owner\'s', () async {
      final response = await push(
        contributor.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            exclusionRow(
              'mark-exclude',
              projectId: projectA,
              observationId: 'obs-bad',
              userId: contributor.userId,
              kind: 'excluded',
            ),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.observationExclusions}/mark-exclude/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(await countRows(Tables.observationExclusions, projectA), 0);
    });

    test('an owner may exclude', () async {
      final response = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            exclusionRow(
              'mark-exclude',
              projectId: projectA,
              observationId: 'obs-bad',
              userId: alice.userId,
              kind: 'excluded',
            ),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.observationExclusions}/mark-exclude/$projectA'),
        SyncRowOutcome.inserted,
      );
    });

    test('and neither mark rewrites the observation it names — the row the '
        'server stores is byte for byte what its author pushed', () async {
      final before = await connection.execute(
        'SELECT * FROM ${quoted(Tables.observations)} '
        "WHERE observation_id = 'obs-bad' AND project_id = '$projectA'",
      );
      await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            exclusionRow(
              'mark-exclude',
              projectId: projectA,
              observationId: 'obs-bad',
              userId: alice.userId,
              kind: 'excluded',
            ),
          ],
        },
      );
      final after = await connection.execute(
        'SELECT * FROM ${quoted(Tables.observations)} '
        "WHERE observation_id = 'obs-bad' AND project_id = '$projectA'",
      );
      expect(after.single.toColumnMap(), before.single.toColumnMap());
    });
  });

  /// **Task 11.15, over the wire — who may *withdraw* a mark.**
  ///
  /// Task 11.7 made a mark its author's own row, which left a contributor's
  /// mistake permanent the moment they left the project: no owner could undo
  /// it and neither could the observation's own author. `Observation_Exclusions`
  /// is now [MutationRule.authorOrOwner] in the shared rule table, and this
  /// group is the enforced half of that — the app's version is advice.
  ///
  /// A withdrawal on the wire is the mark row coming back tombstoned, so every
  /// test here pushes the *same* row with `deleted_at` set and its revision
  /// bumped. What differs is only who pushes it.
  group('withdrawing a mark (task 11.15)', skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;
    late ({String token, String userId}) carol;

    /// Carol's supersede of the owner's bearing — the wrongly-marked bearing
    /// the task is written about.
    Map<String, Object?> carolsMark({
      int revision = 1,
      String? deletedAt,
      String? modifiedBy,
    }) => exclusionRow(
      'mark-supersede',
      projectId: projectA,
      observationId: 'obs-bad',
      userId: carol.userId,
      kind: 'superseded',
      supersededBy: 'obs-good',
      revision: revision,
      deletedAt: deletedAt,
      modifiedBy: modifiedBy,
    );

    Future<SyncRowOutcome?> withdrawAs(
      ({String token, String userId}) actor, {
      required String deviceId,
    }) async {
      final response = await push(
        actor.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            carolsMark(
              revision: 2,
              deletedAt: at,
              modifiedBy: actor.userId,
            ),
          ],
        },
        deviceId: deviceId,
      );
      return outcome(
        response,
        '${Tables.observationExclusions}/mark-supersede/$projectA',
      );
    }

    Future<Object?> storedDeletedAt() async {
      final rows = await connection.execute(
        'SELECT deleted_at FROM ${quoted(Tables.observationExclusions)} '
        r'WHERE exclusion_id = $1 AND project_id = $2',
        parameters: ['mark-supersede', projectA],
      );
      return rows.single.first;
    }

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
      carol = await joinAs(
        alice,
        carolEmail,
        projectId: projectA,
        role: 'contributor',
        deviceId: 'device-C',
      );
      final seeded = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.observations: [
            observationRow('obs-bad', projectId: projectA,
                userId: alice.userId, modifiedBy: alice.userId),
            observationRow('obs-good', projectId: projectA,
                userId: alice.userId, modifiedBy: alice.userId),
          ],
        },
      );
      expect(seeded.statusCode, 200, reason: seeded.body);
      final marked = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [carolsMark()],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(marked,
            '${Tables.observationExclusions}/mark-supersede/$projectA'),
        SyncRowOutcome.inserted,
      );
    });

    test("an owner may withdraw a contributor's supersede", () async {
      expect(
        await withdrawAs(alice, deviceId: 'device-A'),
        SyncRowOutcome.updated,
      );
      expect(await storedDeletedAt(), isNotNull);
    });

    test('the mark\'s own author may still withdraw it', () async {
      // The arm task 11.7 already had. Widening the rule must not cost it.
      expect(
        await withdrawAs(carol, deviceId: 'device-C'),
        SyncRowOutcome.updated,
      );
      expect(await storedDeletedAt(), isNotNull);
    });

    test('an unrelated contributor may not', () async {
      final dave = await joinAs(alice, daveEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-D');
      expect(
        await withdrawAs(dave, deviceId: 'device-D'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedDeletedAt(),
        isNull,
        reason: 'the mark must still be in force',
      );
    });

    test('the case that motivates the task: the author has left the project '
        'and an owner can still withdraw', () async {
      // Carol's membership is closed, exactly as removing her from the owner
      // dashboard closes it. The mark row is untouched and still names her —
      // which is precisely why the author-only rule stranded it, with nobody
      // left on the project able to put the bearing back into analysis.
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1 WHERE project_id = $2 AND user_id = $3',
        parameters: [at, projectA, carol.userId],
      );

      expect(
        await withdrawAs(alice, deviceId: 'device-A'),
        SyncRowOutcome.updated,
      );
      expect(await storedDeletedAt(), isNotNull);
    });

    test('a departed author cannot withdraw their own mark either — the '
        'project decides, not the row', () async {
      // The other half of the same state change, and the one that shows the
      // widening did not turn the mark into a permanent private key. Once
      // carol is off the project she has no access to it at all; it is the
      // *owner* arm that rescues the mark, not a lingering author arm.
      await connection.execute(
        'UPDATE ${quoted(Tables.projectMemberships)} '
        r'SET end_date = $1 WHERE project_id = $2 AND user_id = $3',
        parameters: [at, projectA, carol.userId],
      );

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.observationExclusions: [
            carolsMark(revision: 2, deletedAt: at, modifiedBy: carol.userId),
          ],
        },
        deviceId: 'device-C',
      );
      expect(response.statusCode, isNot(200), reason: response.body);
      expect(await storedDeletedAt(), isNull);
    });
  });

  group('tags', skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
    });

    test('a viewer cannot rename a tag their project uses', () async {
      await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA,
                modifiedBy: alice.userId),
          ],
        },
      );
      final bob = await joinAs(alice, bobEmail, projectId: projectA,
          role: 'viewer', deviceId: 'device-B');

      final response = await push(
        bob.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA, modifiedBy: bob.userId,
                name: 'Renamed', revision: 9),
          ],
        },
        deviceId: 'device-B',
      );
      expect(
        outcome(response, '${Tables.tags}/tag-elk/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedTagName('tag-elk', projectId: projectA), 'Tag');
    });

    test('a viewer cannot create one either', () async {
      // Task 11.11 states the rule and owns the product side (the near-
      // duplicate warning, and narrowing *editing* to owners). The enforcement
      // is here because §4.21 claims a viewer writes nothing, and a claimed
      // control that does not quite fire is worse than one that is not claimed.
      final bob = await joinAs(alice, bobEmail, projectId: projectA,
          role: 'viewer', deviceId: 'device-B');
      final response = await push(
        bob.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-new', projectId: projectA, modifiedBy: bob.userId),
          ],
        },
        deviceId: 'device-B',
      );
      expect(
        outcome(response, '${Tables.tags}/tag-new/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedTagName('tag-new', projectId: projectA), isNull);
    });

    test('a contributor can create one — and this is the rule task 11.11 '
        'exists to protect', () async {
      // Owner-only creation was proposed and rejected. It does not prevent
      // duplicates (two owners offline collide identically) and it does cost a
      // field tech with no signal the ability to record an observation at all,
      // which is permanent where a duplicate tag is not.
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');
      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-new', projectId: projectA, modifiedBy: carol.userId,
                name: 'Fresh'),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.tags}/tag-new/$projectA'),
        SyncRowOutcome.inserted,
      );
      expect(await storedTagName('tag-new', projectId: projectA), 'Fresh');
    });

    test('but a contributor cannot rename one their project uses (task 11.11)',
        () async {
      // **This inverts what this test asserted before task 11.11**, and the
      // asymmetry is the decision rather than an inconsistency. Creating a tag
      // is additive and recoverable. Renaming one rewrites what every
      // observation already recorded against it means, and those bearings
      // cannot be taken again.
      await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA,
                modifiedBy: alice.userId),
          ],
        },
      );
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA, modifiedBy: carol.userId,
                name: 'Renamed', revision: 9),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.tags}/tag-elk/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(await storedTagName('tag-elk', projectId: projectA), 'Tag');
    });

    test('nor retire one — retiring is a status change and gets no exemption',
        () async {
      await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA,
                modifiedBy: alice.userId),
          ],
        },
      );
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            {
              ...tagRow('tag-elk', projectId: projectA,
                  modifiedBy: carol.userId, revision: 9),
              'status': 'recovered',
            },
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.tags}/tag-elk/$projectA'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an owner can rename one', () async {
      await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA,
                modifiedBy: alice.userId),
          ],
        },
      );
      final response = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tags: [
            tagRow('tag-elk', projectId: projectA, modifiedBy: alice.userId,
                name: 'Renamed', revision: 9),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.tags}/tag-elk/$projectA'),
        SyncRowOutcome.updated,
      );
      expect(await storedTagName('tag-elk', projectId: projectA), 'Renamed');
    });

    // **Two tests are gone from here, and this note is what replaces them
    // (task 11.220, translating task 11.219's schema change).**
    //
    // *"an unlinked tag still syncs between its own author's devices"* proved
    // that a tag belonging to no project — `"None (unlinked)"` was an offered
    // choice in the old tag dialog — kept replicating between one person's own
    // devices, and that Security Model §5.9(a) was derived around that state
    // rather than against it. **There is no such state on the wire any more.**
    // `Tags.project_id` is `NOT NULL`, and `RowAuthorizer._decide`'s scope
    // check refuses any row whose `project_id` is not the project the request
    // names, so a tag in no project cannot be pushed, stored or pulled. Its
    // successor is this device's own tag library, and that is deliberately
    // **not a synced table** — `kTagLibraryTable` in `lib/data/db/schema.dart`
    // says so in its own doc comment and is absent from both `syncTables` and
    // `tableSpecs` — so there is nothing on this boundary left to assert.
    //
    // *"linking a tag re-delivers it to a member whose cursor is already past
    // it"* proved that a `Project_Tags` insert re-stamped the tag's
    // `server_seq`, so a teammate who had already read past it still received
    // it. **The operation it was about no longer exists**: a tag is created
    // *inside* a project, so it is reachable from the moment it has a
    // `server_seq` and can never have been below a reader's cursor while
    // unreachable. Nothing widens a project's reach for a tag any more, so
    // there is no moment to re-stamp at. (The equivalent for *people* — a
    // colleague's `Users` row re-stamped when somebody joins — is untouched
    // and still covered; see `JoinService`'s two `refreshServerSeqFor` calls.)
    // The `_redeliverNewlyLinked` machinery that those tests covered sat in
    // `sync_service.dart` unreachable for a day after 11.219 — its branch was
    // keyed on `Project_Tags`, which the push loop no longer iterates — and
    // **task 11.221 deleted it (2026-09-10; `git log --grep=11.221` finds the
    // commit).** Nothing replaces it, for the reason above: there is no
    // moment at which a tag becomes reachable to somebody whose cursor has
    // already passed it. `refreshServerSeqFor` itself stays, for people.

    test(
      'a stranger claiming the same tag id gets a row of their own and cannot '
      'touch the original — §5.9(a) closed by construction',
      () async {
        // **This replaces "a stranger who knows its id cannot rewrite it".**
        // That test pushed a stranger's copy of a *global* tag and expected
        // `unauthorized`, because one `Tags` row was the only row for that id
        // and rewriting it was the attack. Under copy-on-add there is no one
        // row: `Tags` is keyed `(tag_id, project_id)`, so the stranger's push
        // names a different row in their own project and is an ordinary,
        // legitimate insert. **The refusal did not weaken — the thing it was
        // refusing stopped being expressible.**
        //
        // Two lines of code make that true and both are named rather than
        // assumed. `SyncService._findRow` builds its predicate from
        // `SyncTable.primaryKey`, which now includes `project_id`, so a lookup
        // can only ever return a row from the project the request names; and
        // `RowAuthorizer._decide`'s scope check refuses any row whose
        // `project_id` is not that project. Neither is about tags.
        //
        // **What is asserted is the outcome, not the mechanism**: the
        // stranger's row lands as *theirs*, and the original's name is
        // unchanged when read back with its own project named.
        await push(
          alice.token,
          projectId: projectA,
          rows: {
            Tables.tags: [
              tagRow('tag-shared', projectId: projectA,
                  modifiedBy: alice.userId),
            ],
          },
        );
        final dave = await signIn(daveEmail, deviceId: 'device-D');
        await publish(dave, daveEmail, projectB);

        final response = await push(
          dave.token,
          projectId: projectB,
          rows: {
            Tables.tags: [
              tagRow('tag-shared', projectId: projectB,
                  modifiedBy: dave.userId, name: 'Stolen', revision: 9),
            ],
          },
          deviceId: 'device-D',
        );
        expect(
          outcome(response, '${Tables.tags}/tag-shared/$projectB'),
          SyncRowOutcome.inserted,
          reason: 'a different row in a different project — accepting it is '
              'correct, and a refusal here would mean two people can never '
              'use the same tag id',
        );
        expect(
          await storedTagName('tag-shared', projectId: projectA),
          'Tag',
          reason: 'the original is what this test is protecting',
        );
        expect(
          await storedTagName('tag-shared', projectId: projectB),
          'Stolen',
          reason: 'positive control: if the stranger\'s push had not landed at '
              'all, the assertion above would pass for the wrong reason',
        );
      },
    );

    test(
      'a stranger cannot reach another project\'s tag by claiming its id, '
      'however many rows they send',
      () async {
        // **This replaces "a no-op row cannot vouch for a tag the caller may
        // not touch".** What that test proved: Security Gate B found that a
        // push is authorized row by row against one pre-push snapshot, and a
        // row that changes nothing needs no write permission — so a
        // deliberately stale copy of somebody else's tag sailed through as a
        // no-op, was recorded as "established by this push", and a second row
        // for the same id later in the same batch short-circuited every check
        // behind it.
        //
        // **The vouching mechanism is deleted** — `RowAuthorizer`'s
        // `_establishedThisPush` set and `_noteEstablishedTag` are gone, and
        // its class comment says why: a tag and the rows referencing it now
        // claim the same project, so the scope check answers both and there is
        // nothing to vouch for. **The attack is what is restated here**, not
        // the mechanism, because the harm it aimed at is what a person cares
        // about: a stranger rewriting a project's transmitter record, or being
        // handed its frequency on their next pull.
        //
        // The `Project_Tags` row the original push carried is not sent: that
        // table is not in `syncTables`, and a client claiming a schema major
        // the server does not support is refused at the envelope before any
        // row is read, so no real client can send one.
        // **Alice's tag carries a name only alice's row could have.** The
        // default 'Tag' would have made the last assertion in this test
        // unfalsifiable: dave's own rows are named 'Tag' too, so a check for
        // the absence of that string cannot tell "no data crossed over" from
        // "dave is reading his own copy". Watched failing that way before this
        // name was given.
        await push(
          alice.token,
          projectId: projectA,
          rows: {
            Tables.tags: [
              tagRow('tag-elk', projectId: projectA,
                  modifiedBy: alice.userId, name: "Alice's elk collar"),
            ],
          },
        );
        final dave = await signIn(daveEmail, deviceId: 'device-D');
        await publish(dave, daveEmail, projectB);

        // Two rows, one tag id, the original poison shape: the first loses
        // last-write-wins so it changes nothing, the second carries a winning
        // revision and the payload.
        //
        // **What this push does since task 11.221:** both rows claim *dave's*
        // project, so they are two rows for one primary key inside his own
        // data, and the server refuses every row sharing a key before
        // applying any — `applied: 0`, one outcome, `invalid`. (Measured on
        // 2026-09-10 before that change: the first row inserted, Postgres
        // refused the second on the key, and the response read `applied: 1`
        // beside a lone `invalid` — a response that disagreed with itself.
        // The payload never landed anywhere either way.) Asserted here
        // because the positive control below used to lean on the first row
        // landing, and now cannot.
        final poison = SyncPushResponse.fromJson(
          jsonDecode((await push(
            dave.token,
            projectId: projectB,
            rows: {
              Tables.tags: [
                tagRow('tag-elk', projectId: projectB, modifiedBy: dave.userId,
                    revision: 0),
                tagRow('tag-elk', projectId: projectB, modifiedBy: dave.userId,
                    name: 'Pwned', revision: 99),
              ],
            },
            deviceId: 'device-D',
          )).body) as Map<String, Object?>,
        );
        expect(poison.applied, 0);
        expect(
          poison.outcomes,
          {'${Tables.tags}/tag-elk/$projectB': SyncRowOutcome.invalid},
        );
        expect(
          await storedTagName('tag-elk', projectId: projectA),
          "Alice's elk collar",
          reason: 'a stranger rewrote another project\'s transmitter record',
        );

        // The legitimate shape, one row, so that dave *has* a copy of his own
        // and the positive control on the pull below can mean something.
        await push(
          dave.token,
          projectId: projectB,
          rows: {
            Tables.tags: [
              tagRow('tag-elk', projectId: projectB, modifiedBy: dave.userId),
            ],
          },
          deviceId: 'device-D',
        );
        expect(
          await storedTagName('tag-elk', projectId: projectA),
          "Alice's elk collar",
          reason: 'one row, same id, other project — still not a rewrite',
        );

        // And the read half, which is the one the original link row was for.
        final delivered = SyncPullResponse.fromJson(
          jsonDecode((await pull(dave.token, projectId: projectB,
              deviceId: 'device-D')).body) as Map<String, Object?>,
        );
        final tags = delivered.rows[Tables.tags] ?? const [];
        expect(
          tags.map((r) => r['tag_id']),
          contains('tag-elk'),
          reason: 'positive control: the stranger does receive their OWN copy, '
              'so an assertion that simply looked for the absence of this id '
              'would pass whether or not the boundary held',
        );
        expect(
          tags.map((r) => r['project_id']),
          everyElement(projectB),
          reason: 'the stranger is handed rows of their own project and no '
              'others — which is what the old link row would have bought them',
        );
        expect(
          tags.map((r) => r['tag_name']),
          isNot(contains("Alice's elk collar")),
          reason: 'nothing carrying the original\'s field data crossed over',
        );
      },
    );
  });
  /// **Task 11.32, the server's half.** The client refuses a contributor's
  /// rewrite of a tag version at the tap; this is the boundary agreeing, so
  /// that a device editing its own SQLite file directly — which §4.23 says is
  /// always possible — cannot rewrite what a colleague's bearings say they
  /// were recorded against.
  group('what a bearing was recorded against (task 11.32)',
      skip: databaseSkipReason, () {
    late ({String token, String userId}) alice;

    setUp(() async {
      if (testDatabaseConfig == null) return;
      alice = await signIn(aliceEmail, deviceId: 'device-A');
      await publish(alice, aliceEmail, projectA);
    });

    Future<http.Response> giveProjectATag() => push(
      alice.token,
      projectId: projectA,
      rows: {
        // Two rows since task 11.219, not three: the `Project_Tags` link that
        // used to make the tag reachable inside the project is gone, because
        // the tag's own `project_id` is what makes it reachable now.
        Tables.tags: [
          tagRow('tag-elk', projectId: projectA, modifiedBy: alice.userId),
        ],
        Tables.tagVersions: [
          tagVersionRow('ver-1', tagId: 'tag-elk', projectId: projectA,
              modifiedBy: alice.userId),
        ],
      },
    );

    /// `projectId` is required for the same reason [storedTagName]'s is: a
    /// version is keyed `(tag_version_id, project_id)` since task 11.219, so a
    /// query on the id alone could answer about another project's row.
    Future<double?> storedVersionFrequency(
      String id, {
      required String projectId,
    }) async {
      final rows = await connection.execute(
        'SELECT frequency_mhz FROM "${Tables.tagVersions}" '
        r'WHERE tag_version_id = $1 AND project_id = $2',
        parameters: [id, projectId],
      );
      return rows.isEmpty ? null : rows.first.first as double?;
    }

    test('a tag and its first version land together in one push', () async {
      final response = await giveProjectATag();
      expect(
        outcome(response, '${Tables.tagVersions}/ver-1/$projectA'),
        SyncRowOutcome.inserted,
        // **The reason here changed with task 11.219, and the old one named a
        // mechanism that no longer exists.** It used to read: *"the tag is
        // established earlier in the same push, so its first version must be
        // authorized against it — this is what the syncTables ordering buys."*
        // That was about `RowAuthorizer._establishedThisPush`, which recorded
        // tag ids a push had been allowed to create so a reference later in the
        // same batch was not judged against a pre-push snapshot in which the
        // tag did not exist. That set is deleted. Both rows now claim
        // `projectA` and the scope check answers each on its own.
        //
        // **The `syncTables` order is still load-bearing, for a different
        // reason**: `Tag_Versions` sits after `Tags` so the foreign key
        // `(tag_id, project_id)` is satisfied when the version is inserted.
        // That is a database constraint, not an authorization one.
        reason: 'a version and its tag are in the same project, so one scope '
            'check answers both — and Tags is inserted first, so the foreign '
            'key holds',
      );
    });

    test('a contributor may append a version — additive and forward-only',
        () async {
      await giveProjectATag();
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.tagVersions: [
            tagVersionRow('ver-2', tagId: 'tag-elk', projectId: projectA,
                modifiedBy: carol.userId, frequencyMhz: 150.51),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.tagVersions}/ver-2/$projectA'),
        SyncRowOutcome.inserted,
        reason: 'requiring an owner here would refuse a contributor\'s own '
            'new tag\'s first version, intermittently, whenever a batch limit '
            'split the two rows across pushes',
      );
    });

    test('but a contributor may NOT rewrite one — that is the correction '
        'path, and it changes what bearings already taken say', () async {
      await giveProjectATag();
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');

      final response = await push(
        carol.token,
        projectId: projectA,
        rows: {
          Tables.tagVersions: [
            tagVersionRow('ver-1', tagId: 'tag-elk', projectId: projectA,
                modifiedBy: carol.userId, frequencyMhz: 999.0, revision: 9),
          ],
        },
        deviceId: 'device-C',
      );
      expect(
        outcome(response, '${Tables.tagVersions}/ver-1/$projectA'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedVersionFrequency('ver-1', projectId: projectA),
        150.1,
        reason: 'a refused rewrite must leave the stored version untouched',
      );
    });

    test('a viewer may not even append one', () async {
      await giveProjectATag();
      final bob = await joinAs(alice, bobEmail, projectId: projectA,
          role: 'viewer', deviceId: 'device-B');

      final response = await push(
        bob.token,
        projectId: projectA,
        rows: {
          Tables.tagVersions: [
            tagVersionRow('ver-2', tagId: 'tag-elk', projectId: projectA,
                modifiedBy: bob.userId),
          ],
        },
        deviceId: 'device-B',
      );
      expect(
        outcome(response, '${Tables.tagVersions}/ver-2/$projectA'),
        SyncRowOutcome.unauthorized,
      );
    });

    test('an owner may rewrite one — the correction path itself', () async {
      await giveProjectATag();
      final response = await push(
        alice.token,
        projectId: projectA,
        rows: {
          Tables.tagVersions: [
            tagVersionRow('ver-1', tagId: 'tag-elk', projectId: projectA,
                modifiedBy: alice.userId, frequencyMhz: 150.11, revision: 9),
          ],
        },
      );
      expect(
        outcome(response, '${Tables.tagVersions}/ver-1/$projectA'),
        SyncRowOutcome.updated,
      );
      expect(
        await storedVersionFrequency('ver-1', projectId: projectA),
        150.11,
      );
    });

    test('a version naming a tag this project does not hold is refused',
        () async {
      // **Restated for task 11.219, and the refusal moved rather than
      // weakened.** This used to be *"a version of a tag this project cannot
      // reach is refused"*, and its mechanism was
      // `RowAuthorizer._authorizeTagReferences` — the rule that a reference to
      // a *global* tag is also a *read* of it, which `Tag_Versions` inherited
      // by declaring `tagColumns`. That method is deleted; nothing computes
      // reachability from `tagColumns` any more.
      //
      // What refuses it now is that a version names `(tag_id, project_id)` and
      // projectB holds no `tag-elk`, so the row points at nothing this server
      // holds — `RowAuthorizer._authorizeReferences`, the ordinary dangling-
      // reference rule that governs a bearing naming a session that was never
      // uploaded. **The class of harm the old rule guarded is closed one layer
      // earlier**: bob's row carries `project_id: projectB`, so even a version
      // that *did* resolve would be a version of bob's own tag and would
      // disclose nothing of alice's.
      //
      // The outcome asserted below was measured, not predicted from that
      // paragraph.
      await giveProjectATag();
      final bobsProject = await signIn(bobEmail, deviceId: 'device-B');
      await publish(bobsProject, bobEmail, projectB);

      final response = await push(
        bobsProject.token,
        projectId: projectB,
        rows: {
          Tables.tagVersions: [
            tagVersionRow('ver-intruder', tagId: 'tag-elk',
                projectId: projectB, modifiedBy: bobsProject.userId),
          ],
        },
        deviceId: 'device-B',
      );
      expect(
        outcome(response, '${Tables.tagVersions}/ver-intruder/$projectB'),
        SyncRowOutcome.unauthorized,
      );
      expect(
        await storedVersionFrequency('ver-intruder', projectId: projectB),
        isNull,
        reason: 'a refused row must not have been written',
      );
      expect(
        await storedVersionFrequency('ver-1', projectId: projectA),
        150.1,
        reason: 'and the version it tried to sit beside is untouched',
      );
    });

    test('a teammate pulls the tag AND its history — otherwise the two '
        'devices disagree about what a bearing means', () async {
      await giveProjectATag();
      final carol = await joinAs(alice, carolEmail, projectId: projectA,
          role: 'contributor', deviceId: 'device-C');

      final page = SyncPullResponse.fromJson(
        jsonDecode((await pull(carol.token, projectId: projectA,
                deviceId: 'device-C')).body) as Map<String, Object?>,
      );
      expect(
        (page.rows[Tables.tagVersions] ?? const [])
            .map((r) => r['tag_version_id']),
        contains('ver-1'),
        // **The reason changed with task 11.219 and the old one is worth
        // recording, because it named the failure this test was built to
        // catch.** It read: *"a global table with no declared GlobalScope is
        // never delivered by pull at all — silently."* `Tag_Versions` was
        // global then, and a global table reached a project's pull only through
        // `GlobalScope`/`ProjectReachability`; forgetting to declare one made
        // the table invisible with nothing failing. It is project-scoped now,
        // so it arrives in the project's own delta stream like every other
        // scoped table, and that particular silent hole is closed by
        // construction. **The test still earns its place**: what it asserts is
        // that a teammate receives the tag's history at all, and a device that
        // receives a bearing without it reads "not recorded" where the recorder
        // reads a frequency — two devices disagreeing about what a bearing
        // means, which is what `Tag_Versions` exists to prevent.
        reason: 'a teammate who receives the tag but not its versions sees '
            '"not recorded" on every bearing the recorder took',
      );
    });
  });
}

/// The `error` field of a refusal, ignoring the per-request `trace_id`.
String? _errorCode(http.Response response) =>
    (jsonDecode(response.body) as Map<String, Object?>)['error'] as String?;

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
