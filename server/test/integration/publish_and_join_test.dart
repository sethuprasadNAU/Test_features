@Tags(['postgres'])
library;

import 'dart:convert';
import 'dart:io';

import '../support/database_test_config.dart';

import 'package:http/http.dart' as http;
import 'package:postgres/postgres.dart';
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// End-to-end over a **real bound HTTP socket**, using the same
/// `createHandler` wiring `bin/server.dart` does — the only difference from a
/// deployed server is which Postgres schema it points at. This is what proves
/// task 10.9's acceptance criteria rather than merely the unit-level pieces:
/// publish uploads a project completely and idempotently, a second device
/// joins and converges, and two same-named projects never cross.
///
/// See `test/integration/postgres_sync_test.dart`'s header for how to run
/// these against a real database.
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_publish_join_test';

  final captured = <String, String>{};

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

    final handler = createHandler(
      withAuthService: <T>(action) => connection.runTx(
        (tx) => action(
          AuthService(
            session: tx,
            emailSender: _CapturingSender(captured),
            linkBaseUrl: 'http://test',
          ),
        ),
      ),
      withSyncContext: (request, action) async {
        final token = bearerToken(request);
        if (token == null) return _unauthorizedResponse();
        return connection.runTx((tx) async {
          final auth = AuthService(
            session: tx,
            emailSender: _CapturingSender(captured),
            linkBaseUrl: 'http://test',
          );
          final activeSession = await auth.validateSession(token);
          if (activeSession == null) return _unauthorizedResponse();
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

  /// Signs in a fresh session for [email] over real HTTP, returning the
  /// bearer token and the server's authoritative `user_id`.
  Future<({String token, String userId})> signIn(String email) async {
    final requestId =
        jsonDecode(
              (await http.post(
                baseUri.replace(path: '/auth/magic-link'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'email': email}),
              )).body,
            )['request_id']
            as String;
    // requestId not otherwise used here; the token is read from the captured
    // link, matching the dev flow.
    // ignore: unused_local_variable
    final _ = requestId;

    final linkUrl = captured[email]!;
    final token = Uri.parse(linkUrl).queryParameters['token']!;

    final redeemed =
        jsonDecode(
              (await http.post(
                baseUri.replace(path: '/auth/redeem'),
                headers: {'content-type': 'application/json'},
                body: jsonEncode({'token': token, 'device_id': 'device-A'}),
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

  Map<String, Object?> observation(
    String id, {
    required String projectId,
    required String userId,
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
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  /// The owner's own `Users` row. Every push that carries a `Projects` row
  /// needs it: `Projects.owner_user_id` is a foreign key, and the real client
  /// always sends it because `ProjectExporter.collect` gathers the users a
  /// project references.
  ///
  /// [email] must be the address the caller *signed in with*: since task 10.55
  /// the server refuses a `Users.email` it never authenticated for that id. The
  /// default matches the address almost every test here signs in as; the two
  /// that sign in as somebody else pass their own.
  Map<String, Object?> user(
    String userId, {
    String email = 'sam@example.com',
  }) => {
    'user_id': userId,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': email,
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'revision': 1,
    'last_modified_by': userId,
    'origin_device_id': 'device-A',
  };

  Map<String, Object?> project(String id, {required String ownerId}) => {
    'project_id': id,
    'project_name': 'Elk Study',
    'owner_user_id': ownerId,
    'creation_date': '2026-08-01T12:00:00.000Z',
    'datum': 'WGS84',
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
    'coordinate_format': 'dd',
    'triangulation_window_minutes': 15,
  };

  Map<String, Object?> ownerMembership(
    String id, {
    required String projectId,
    required String ownerId,
  }) => {
    'membership_id': id,
    'project_id': projectId,
    'user_id': ownerId,
    'join_date': '2026-08-01T12:00:00.000Z',
    'role': 'owner',
    'created_at': '2026-08-01T12:00:00.000Z',
    'updated_at': '2026-08-01T12:00:00.000Z',
    'revision': 0,
    'last_modified_by': ownerId,
    'origin_device_id': 'device-A',
  };

  group('unauthenticated', skip: databaseSkipReason, () {
    test(
      'sync and directory routes refuse a request with no bearer token',
      () async {
        final push = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: {'content-type': 'application/json'},
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'p',
              deviceId: 'd',
              rows: const {},
            ).toJson(),
          ),
        );
        expect(push.statusCode, 401);

        final mine = await http.get(baseUri.replace(path: '/projects/mine'));
        expect(mine.statusCode, 401);
      },
    );
  });

  group('publish', skip: databaseSkipReason, () {
    test('uploads a project completely', () async {
      final owner = await signIn('sam@example.com');

      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId)],
              Tables.projects: [project('proj-1', ownerId: owner.userId)],
              Tables.projectMemberships: [
                ownerMembership(
                  'mem-1',
                  projectId: 'proj-1',
                  ownerId: owner.userId,
                ),
              ],
              Tables.observations: [
                observation('obs-1', projectId: 'proj-1', userId: owner.userId),
                observation('obs-2', projectId: 'proj-1', userId: owner.userId),
              ],
            },
          ).toJson(),
        ),
      );
      expect(response.statusCode, 200);
      final body = SyncPushResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      );
      // Users + Projects + membership + two observations.
      expect(body.applied, 5);
      expect(body.outcomes.values, everyElement(SyncRowOutcome.inserted));

      final directly = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.observations)} '
        r'WHERE project_id = $1',
        parameters: ['proj-1'],
      );
      expect(directly.first.first, 2);
    });

    test('is idempotent — publishing twice creates no duplicate', () async {
      final owner = await signIn('sam@example.com');
      final rows = {
        Tables.users: [user(owner.userId)],
        Tables.projects: [project('proj-1', ownerId: owner.userId)],
        Tables.projectMemberships: [
          ownerMembership('mem-1', projectId: 'proj-1', ownerId: owner.userId),
        ],
      };

      for (var i = 0; i < 2; i++) {
        final response = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: rows,
            ).toJson(),
          ),
        );
        expect(response.statusCode, 200);
      }

      final count = await connection.execute(
        'SELECT count(*) FROM ${quoted(Tables.projects)} WHERE project_id = \$1',
        parameters: ['proj-1'],
      );
      expect(count.first.first, 1);
    });

    test(
      'an interrupted-then-retried publish still produces no duplicate',
      () async {
        // "Interrupted" here means: a batch fails to reach the server (an
        // exception before the request completes) and the client retries from
        // scratch. Since every row upserts by its stable primary key, the retry
        // is naturally idempotent — modelled by simply calling push twice more,
        // once with only part of the payload (the "interrupted" attempt) and
        // once with all of it (the retry).
        final owner = await signIn('sam@example.com');

        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [project('proj-1', ownerId: owner.userId)],
              },
            ).toJson(),
          ),
        );
        // The retry re-sends everything, including what already landed.
        final retry = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [project('proj-1', ownerId: owner.userId)],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-1',
                    projectId: 'proj-1',
                    ownerId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );
        expect(retry.statusCode, 200);

        final projectCount = await connection.execute(
          'SELECT count(*) FROM ${quoted(Tables.projects)} WHERE project_id = \$1',
          parameters: ['proj-1'],
        );
        expect(projectCount.first.first, 1);
      },
    );
  });

  group('join — a second device converges', skip: databaseSkipReason, () {
    test('pulling from a fresh cursor brings down the whole project', () async {
      final owner = await signIn('sam@example.com');
      final pushResponse = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId)],
              Tables.projects: [project('proj-1', ownerId: owner.userId)],
              Tables.projectMemberships: [
                ownerMembership(
                  'mem-1',
                  projectId: 'proj-1',
                  ownerId: owner.userId,
                ),
              ],
              Tables.observations: [
                observation('obs-1', projectId: 'proj-1', userId: owner.userId),
              ],
            },
          ).toJson(),
        ),
      );

      // A second device, same person, same session-issuing identity (a fresh
      // sign-in — Phase 10's "same user, many devices").
      final second = await signIn('sam@example.com');
      expect(second.userId, owner.userId);

      final pullResponse = await http.post(
        baseUri.replace(path: '/sync/pull'),
        headers: authHeaders(second.token),
        body: jsonEncode(
          SyncPullRequest(
            projectId: 'proj-1',
            deviceId: 'device-B',
            cursor: 0,
          ).toJson(),
        ),
      );
      expect(pullResponse.statusCode, 200);
      final page = SyncPullResponse.fromJson(
        jsonDecode(pullResponse.body) as Map<String, Object?>,
      );
      expect(page.rows[Tables.observations]!.single['observation_id'], 'obs-1');
      expect(page.rows[Tables.projects]!.single['project_id'], 'proj-1');

      // Task 11.58: both routes name the database that answered, and it is
      // the one this database minted — so a device can tell this database
      // from a restored or rebuilt one. Read from the table rather than
      // compared only between the two responses, because two responses
      // agreeing about a value nobody stored would prove nothing.
      final pushed = SyncPushResponse.fromJson(
        jsonDecode(pushResponse.body) as Map<String, Object?>,
      );
      final stored = await connection.execute(
        'SELECT database_id FROM $databaseIdentityTable',
      );
      expect(stored, hasLength(1));
      expect(page.databaseId, stored.first.first);
      expect(pushed.databaseId, stored.first.first);
    });

    test(
      'the joined project appears in the directory for the same user only',
      () async {
        final owner = await signIn('sam@example.com');
        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [project('proj-1', ownerId: owner.userId)],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-1',
                    projectId: 'proj-1',
                    ownerId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );

        final mine = await http.get(
          baseUri.replace(path: '/projects/mine'),
          headers: authHeaders(owner.token),
        );
        final directory = ProjectDirectoryResponse.fromJson(
          jsonDecode(mine.body) as Map<String, Object?>,
        );
        expect(directory.projects.map((p) => p.projectId), ['proj-1']);
        expect(directory.projects.single.role, 'owner');

        final stranger = await signIn('kim@example.com');
        final strangerMine = await http.get(
          baseUri.replace(path: '/projects/mine'),
          headers: authHeaders(stranger.token),
        );
        final strangerDirectory = ProjectDirectoryResponse.fromJson(
          jsonDecode(strangerMine.body) as Map<String, Object?>,
        );
        expect(strangerDirectory.projects, isEmpty);
      },
    );

    test(
      'a stranger cannot push or pull a project they do not belong to',
      () async {
        final owner = await signIn('sam@example.com');
        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [project('proj-1', ownerId: owner.userId)],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-1',
                    projectId: 'proj-1',
                    ownerId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );

        final stranger = await signIn('kim@example.com');
        final pull = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(stranger.token),
          body: jsonEncode(
            SyncPullRequest(
              projectId: 'proj-1',
              deviceId: 'device-C',
              cursor: 0,
            ).toJson(),
          ),
        );
        expect(pull.statusCode, 403);

        final push = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(stranger.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-C',
              rows: {
                Tables.observations: [
                  observation(
                    'obs-hostile',
                    projectId: 'proj-1',
                    userId: stranger.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );
        expect(push.statusCode, 403);
      },
    );
  });

  group('deleting a published project (task 11.289)', skip: databaseSkipReason,
      () {
    /// **The half of Michael's 2026-09-20 measurement that never ran.** He
    /// deleted a published project on the phone and the server's `deleted_at`
    /// stayed empty — because the device never made the push (the client
    /// round is scoped to the open project, and deleting it cleared that). So
    /// nothing had ever shown what the server does with an owner's `Projects`
    /// tombstone when it *does* arrive. This does: the same row the phone
    /// would send — `deleted_at` set, `revision` bumped, `updated_at` moved on
    /// — pushed by the owner, weeks after the fact.
    Future<({String token, String userId})> publishedByOwner() async {
      final owner = await signIn('sam@example.com');
      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId)],
              Tables.projects: [project('proj-1', ownerId: owner.userId)],
              Tables.projectMemberships: [
                ownerMembership(
                  'mem-1',
                  projectId: 'proj-1',
                  ownerId: owner.userId,
                ),
              ],
            },
          ).toJson(),
        ),
      );
      expect(response.statusCode, 200);
      return owner;
    }

    Map<String, Object?> tombstone(String ownerId) => {
      ...project('proj-1', ownerId: ownerId),
      // A month later, on the phone, out of signal: the client stamps the
      // deletion with its own clock and the row arrives when it arrives.
      'updated_at': '2026-09-20T09:00:00.000Z',
      'deleted_at': '2026-09-20T09:00:00.000Z',
      'revision': 1,
    };

    test('the owner\'s tombstone is stored, and the project leaves the '
        'directory', () async {
      final owner = await publishedByOwner();

      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-A',
            rows: {
              Tables.projects: [tombstone(owner.userId)],
            },
          ).toJson(),
        ),
      );
      expect(response.statusCode, 200);
      final body = SyncPushResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      );
      expect(
        body.outcomes['${Tables.projects}/proj-1'],
        SyncRowOutcome.updated,
        reason: 'a tombstone is an ordinary update to deleted_at, and the '
            'owner is entitled to it',
      );

      final stored = await connection.execute(
        'SELECT deleted_at FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: ['proj-1'],
      );
      expect(stored.first.first, isNotNull,
          reason: 'this is the column Michael queried and found empty');

      // The directory is what a new device reads to decide what to offer
      // the person; a deleted project must not be in it, or it comes back on
      // every phone they sign in on.
      final mine = await http.get(
        baseUri.replace(path: '/projects/mine'),
        headers: authHeaders(owner.token),
      );
      final directory = ProjectDirectoryResponse.fromJson(
        jsonDecode(mine.body) as Map<String, Object?>,
      );
      expect(directory.projects, isEmpty);
    });

    test('a contributor\'s tombstone for the owner\'s project is refused',
        () async {
      // The client never offers this row (`offer_rules.dart` withholds a
      // `Projects` row whose owner is somebody else), so this is the server
      // holding its own line rather than a path the app takes: the rule the
      // matrix states for `Projects` (owner-only), checked on the tombstone.
      final owner = await publishedByOwner();
      final member = await signIn('kim@example.com');
      // Their identity row, as their own device's first push would have
      // written it — the membership below is a foreign key to it.
      await connection.execute(
        'INSERT INTO ${quoted(Tables.users)} '
        '(user_id, first_name, last_name, email, created_at, updated_at, '
        'revision, last_modified_by, origin_device_id) VALUES '
        r'($1, $2, $3, $4, $5, $5, 0, $1, $6)',
        parameters: [
          member.userId,
          'Kim',
          'Ranger',
          'kim@example.com',
          '2026-08-01T12:00:00.000Z',
          'device-C',
        ],
      );
      // Admit them as the server itself would on a redeemed invitation.
      await connection.execute(
        'INSERT INTO ${quoted(Tables.projectMemberships)} '
        '(membership_id, project_id, user_id, join_date, role, created_at, '
        'updated_at, revision, last_modified_by, origin_device_id) VALUES '
        r'($1, $2, $3, $4, $5, $4, $4, 0, $3, $6)',
        parameters: [
          'mem-2',
          'proj-1',
          member.userId,
          '2026-08-01T12:00:00.000Z',
          'contributor',
          'device-C',
        ],
      );

      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(member.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-C',
            rows: {
              Tables.projects: [
                {...tombstone(owner.userId), 'last_modified_by': member.userId},
              ],
            },
          ).toJson(),
        ),
      );
      expect(response.statusCode, 200);
      final body = SyncPushResponse.fromJson(
        jsonDecode(response.body) as Map<String, Object?>,
      );
      expect(
        body.outcomes['${Tables.projects}/proj-1'],
        SyncRowOutcome.unauthorized,
      );
      final stored = await connection.execute(
        'SELECT deleted_at FROM ${quoted(Tables.projects)} '
        r'WHERE project_id = $1',
        parameters: ['proj-1'],
      );
      expect(stored.first.first, isNull);
    });
  });

  group('two same-named projects never cross', skip: databaseSkipReason, () {
    test(
      'two distinct project_ids with the same name stay fully separate',
      () async {
        final owner = await signIn('sam@example.com');

        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-a',
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [
                  {
                    ...project('proj-a', ownerId: owner.userId),
                    'project_name': 'Elk Study',
                  },
                ],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-a',
                    projectId: 'proj-a',
                    ownerId: owner.userId,
                  ),
                ],
                Tables.observations: [
                  observation(
                    'obs-a',
                    projectId: 'proj-a',
                    userId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );
        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-b',
              deviceId: 'device-B',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [
                  {
                    ...project('proj-b', ownerId: owner.userId),
                    'project_name': 'Elk Study',
                  },
                ],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-b',
                    projectId: 'proj-b',
                    ownerId: owner.userId,
                  ),
                ],
                Tables.observations: [
                  observation(
                    'obs-b',
                    projectId: 'proj-b',
                    userId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        );

        final pullA = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPullRequest(
              projectId: 'proj-a',
              deviceId: 'device-C',
              cursor: 0,
            ).toJson(),
          ),
        );
        final pageA = SyncPullResponse.fromJson(
          jsonDecode(pullA.body) as Map<String, Object?>,
        );
        final observationIdsA = (pageA.rows[Tables.observations] ?? const [])
            .map((r) => r['observation_id']);
        expect(observationIdsA, contains('obs-a'));
        expect(observationIdsA, isNot(contains('obs-b')));

        final directory = ProjectDirectoryResponse.fromJson(
          jsonDecode(
                (await http.get(
                  baseUri.replace(path: '/projects/mine'),
                  headers: authHeaders(owner.token),
                )).body,
              )
              as Map<String, Object?>,
        );
        expect(
          directory.projects.map((p) => p.projectId),
          unorderedEquals(['proj-a', 'proj-b']),
        );
      },
    );
  });

  // Security Gate C, finding C-2 (`TriTrack_Security_Model.md` §7.3 B2), the
  // §4.13 requirement stated in its own words: "Wrong project, wrong user, and
  // nonexistent are indistinguishable from outside."
  //
  // Every test here compares a **real project the caller may not touch**
  // against a **project id that has never existed**, and asserts the two
  // answers are the same one. Comparing the responses to each other rather
  // than to an expected literal is deliberate: the requirement is that they
  // match, not that they match some particular text, so this keeps holding if
  // the refusal is later reworded.
  group('the project existence oracle (C-2)', skip: databaseSkipReason, () {
    const fabricated = 'proj-never-existed';

    /// Publishes `proj-owned` as Sam, then signs in an unrelated second user
    /// who has no relationship to it.
    Future<({String token, String userId})>
    setUpForeignProjectAndStranger() async {
      final owner = await signIn('sam@example.com');
      final published = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-owned',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId)],
              Tables.projects: [project('proj-owned', ownerId: owner.userId)],
              Tables.observations: [
                observation(
                  'obs-owned',
                  projectId: 'proj-owned',
                  userId: owner.userId,
                ),
              ],
            },
          ).toJson(),
        ),
      );
      expect(published.statusCode, 200);
      return signIn('stranger@example.com');
    }

    /// The response to [path] for [projectId], as the pair a prober can see.
    Future<({int status, String body})> probe(
      String token,
      String path,
      Map<String, Object?> Function(String projectId) request,
      String projectId,
    ) async {
      final response = await http.post(
        baseUri.replace(path: path),
        headers: authHeaders(token),
        body: jsonEncode(request(projectId)),
      );
      return (status: response.statusCode, body: response.body);
    }

    test('pull cannot tell a real foreign project from a fabricated '
        'one', () async {
      final stranger = await setUpForeignProjectAndStranger();
      Map<String, Object?> body(String projectId) => SyncPullRequest(
        projectId: projectId,
        deviceId: 'device-B',
        cursor: 0,
      ).toJson();

      final real = await probe(
        stranger.token,
        '/sync/pull',
        body,
        'proj-owned',
      );
      final fake = await probe(stranger.token, '/sync/pull', body, fabricated);

      expect(real.status, fake.status);
      expect(real.body, fake.body);
      expect(
        real.status,
        403,
        reason: 'and the shared answer must be the refusal, not the disclosure',
      );
    });

    test('push cannot tell a real foreign project from a fabricated '
        'one', () async {
      final stranger = await setUpForeignProjectAndStranger();
      Map<String, Object?> body(String projectId) => SyncPushRequest(
        projectId: projectId,
        deviceId: 'device-B',
        rows: {
          Tables.observations: [
            observation(
              'obs-probe',
              projectId: projectId,
              userId: stranger.userId,
            ),
          ],
        },
      ).toJson();

      final real = await probe(
        stranger.token,
        '/sync/push',
        body,
        'proj-owned',
      );
      final fake = await probe(stranger.token, '/sync/push', body, fabricated);

      expect(real.status, fake.status);
      expect(real.body, fake.body);
      expect(real.status, 403);
    });

    test('ack cannot tell a real foreign project from a fabricated '
        'one', () async {
      final stranger = await setUpForeignProjectAndStranger();
      Map<String, Object?> body(String projectId) => SyncAckRequest(
        projectId: projectId,
        deviceId: 'device-B',
        cursor: 0,
      ).toJson();

      final real = await probe(stranger.token, '/sync/ack', body, 'proj-owned');
      final fake = await probe(stranger.token, '/sync/ack', body, fabricated);

      expect(real.status, fake.status);
      expect(real.body, fake.body);
      expect(real.status, 403);
    });

    test('a push carrying no rows of that project tells nothing '
        'either', () async {
      // The publisher's first request is `{Users: [...]}` — global rows, sent
      // before the `Projects` row exists. It has to keep working against a
      // project id the server has never seen, so it must also keep working,
      // identically, against one it has.
      final stranger = await setUpForeignProjectAndStranger();

      // A *different* colleague per probe, so neither push is a no-op that the
      // other one already applied — the two would then differ for a reason
      // that has nothing to do with the project. Which means the bodies carry
      // different primary keys, so this compares what a prober can actually
      // use: the status, and what the server says it did.
      Map<String, Object?> body(String projectId) => SyncPushRequest(
        projectId: projectId,
        deviceId: 'device-B',
        rows: {
          Tables.users: [
            {
              ...user('colleague-for-$projectId'),
              'email': 'colleague-$projectId@example.com',
            },
          ],
        },
      ).toJson();

      ({int applied, List<Object?> outcomes}) verdict(String raw) {
        final decoded = jsonDecode(raw) as Map<String, Object?>;
        return (
          applied: decoded['applied']! as int,
          outcomes: (decoded['outcomes']! as Map<String, Object?>).values
              .toList(),
        );
      }

      final real = await probe(
        stranger.token,
        '/sync/push',
        body,
        'proj-owned',
      );
      final fake = await probe(stranger.token, '/sync/push', body, fabricated);

      expect(real.status, fake.status);
      expect(verdict(real.body).applied, verdict(fake.body).applied);
      expect(verdict(real.body).outcomes, equals(verdict(fake.body).outcomes));
      expect(
        real.status,
        200,
        reason: 'naming a project you send none of is not a request about it',
      );
    });

    test('nor does a tag push, which the named project must not vouch '
        'for', () async {
      // **The claim is unchanged; where the refusal happens moved (task
      // 11.219, retranslated by task 11.220), and the old comment named the
      // old place.** It used to read: *"`Tags` is global too, so a tag-only
      // push is permitted against any id — and the tag rule asks 'does *this*
      // project reference it'."* Both halves are now false. `Tags` carries a
      // `project_id`, so `_touchesProject` in `sync_routes.dart` says a
      // tag-only push **is** a request about the project it names, and the
      // route refuses it outright when the caller has no relationship to that
      // project; and `_authorizeTagReferences`, the rule that asked whether the
      // project referenced the tag, is deleted.
      //
      // **What C-2 requires is unchanged and is what is asserted below**: the
      // stranger's push against a project that really exists and against one
      // that does not must be indistinguishable, byte for byte, or the answer
      // itself tells them which project ids are real. Measured on 2026-09-10:
      // both are `403 {"error":"forbidden"}`, with no detail either way, which
      // is `_forbidden()`'s whole purpose.
      final owner = await signIn('sam@example.com');
      await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-owned',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId)],
              Tables.projects: [project('proj-owned', ownerId: owner.userId)],
            },
          ).toJson(),
        ),
      );
      await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-owned',
            deviceId: 'device-A',
            rows: {
              Tables.tags: [
                {
                  'tag_id': 'tag-owned',
                  'project_id': 'proj-owned',
                  'lineage_id': 'tag-owned',
                  'frequency_mhz': 150.1,
                  'tag_name': 'Elk 12',
                  'status': 'active',
                  'color_hex': '#FF0000',
                  'created_at': '2026-08-01T12:00:00.000Z',
                  'updated_at': '2026-08-01T12:00:00.000Z',
                  'revision': 1,
                  'last_modified_by': owner.userId,
                  'origin_device_id': 'device-A',
                },
              ],
            },
          ).toJson(),
        ),
      );

      final stranger = await signIn('stranger@example.com');
      Map<String, Object?> body(String projectId) => SyncPushRequest(
        projectId: projectId,
        deviceId: 'device-B',
        rows: {
          Tables.tags: [
            {
              'tag_id': 'tag-owned',
              'project_id': projectId,
              'lineage_id': 'tag-owned',
              'frequency_mhz': 151.1,
              'tag_name': 'DESTROYED',
              'status': 'active',
              'color_hex': '#00FF00',
              'created_at': '2026-08-01T12:00:00.000Z',
              'updated_at': '2026-08-02T12:00:00.000Z',
              'revision': 999,
              'last_modified_by': stranger.userId,
              'origin_device_id': 'device-B',
            },
          ],
        },
      ).toJson();

      final real = await probe(
        stranger.token,
        '/sync/push',
        body,
        'proj-owned',
      );
      final fake = await probe(stranger.token, '/sync/push', body, fabricated);

      expect(real.status, fake.status);
      expect(real.body, fake.body);
      expect(
        real.status,
        403,
        reason: 'a stranger\'s tag push into a project they have no '
            'relationship to is refused — and a refusal that carried a reason '
            'would be the oracle this test exists for',
      );
      expect(
        jsonDecode(real.body),
        {'error': 'forbidden'},
        reason: 'no detail: not which project, not whether it exists, not '
            'which row. Asserted as the whole body rather than as a subset, so '
            'a field added later cannot slip in unnoticed',
      );
    });

    test('a first publish onto a fabricated id still works', () async {
      // The one thing the fix must not cost. `ProjectAccess.absent` no longer
      // permits sync by itself; a push that *establishes* the project is what
      // permits it now.
      final owner = await signIn('newbie@example.com');
      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-brand-new',
            deviceId: 'device-A',
            rows: {
              Tables.users: [user(owner.userId, email: 'newbie@example.com')],
              Tables.projects: [
                project('proj-brand-new', ownerId: owner.userId),
              ],
              Tables.observations: [
                observation(
                  'obs-new',
                  projectId: 'proj-brand-new',
                  userId: owner.userId,
                ),
              ],
            },
          ).toJson(),
        ),
      );

      expect(response.statusCode, 200);
      final outcomes =
          (jsonDecode(response.body) as Map<String, Object?>)['outcomes']!
              as Map<String, Object?>;
      expect(outcomes['${Tables.projects}/proj-brand-new'], 'inserted');
      expect(
        outcomes['${Tables.observations}/obs-new/proj-brand-new'],
        'inserted',
      );
    });

    test('a first publish that cannot land is a refusal, not a 500', () async {
      // The subtlest half of the seam. This `Projects` row is well-formed and
      // names the caller — it passes every check the router can make — but its
      // `owner_user_id` foreign key points at a `Users` row that was never
      // pushed. Foreign keys are DEFERRABLE INITIALLY DEFERRED (task 10.5), so
      // that failure does not raise until COMMIT, which is far too late to be
      // anything but a `500`. And a `500` here against a `403` for a real
      // project is the oracle again, reachable with a request that creates
      // nothing at all — cheaper than the collision probe §4.13 accepts.
      final newcomer = await signIn('newcomer@example.com');

      final onFabricated = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(newcomer.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-no-owner-row',
            deviceId: 'device-C',
            rows: {
              Tables.projects: [
                project('proj-no-owner-row', ownerId: newcomer.userId),
              ],
            },
          ).toJson(),
        ),
      );

      expect(onFabricated.statusCode, 403);
      expect(jsonDecode(onFabricated.body), {'error': 'forbidden'});

      // And the transaction it rolled back left nothing behind: the same
      // publish works once the `Users` row its foreign key needs is there.
      await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(newcomer.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-no-owner-row',
            deviceId: 'device-C',
            rows: {
              Tables.users: [
                user(newcomer.userId, email: 'newcomer@example.com'),
              ],
            },
          ).toJson(),
        ),
      );
      final retried = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(newcomer.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-no-owner-row',
            deviceId: 'device-C',
            rows: {
              Tables.projects: [
                project('proj-no-owner-row', ownerId: newcomer.userId),
              ],
            },
          ).toJson(),
        ),
      );
      expect(retried.statusCode, 200);
      expect(
        jsonDecode(retried.body),
        containsPair('outcomes', {
          '${Tables.projects}/proj-no-owner-row': 'inserted',
        }),
      );
    });

    test('but a Projects row naming someone else does not open the '
        'door', () async {
      // The establishing exemption is what makes publish work, so it is the
      // one thing worth probing: it must not be a way to push arbitrary rows
      // into a project you are inventing on someone else's behalf.
      final owner = await signIn('sam@example.com');
      final stranger = await signIn('stranger@example.com');

      final response = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(stranger.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-for-victim',
            deviceId: 'device-B',
            rows: {
              Tables.projects: [
                project('proj-for-victim', ownerId: owner.userId),
              ],
              Tables.observations: [
                observation(
                  'obs-planted',
                  projectId: 'proj-for-victim',
                  userId: stranger.userId,
                ),
              ],
            },
          ).toJson(),
        ),
      );

      expect(response.statusCode, 403);
    });
  });

  /// **Task 11.46.** A project built from a colleague's archive carries rows
  /// that colleague last touched. Those rows are refused — correctly, and by
  /// design — and the question this group answers is what happens to the
  /// caller's *own* rows that point at them.
  ///
  /// Before this task, one of the two answers below was an unexplained `500`:
  /// the schema's foreign keys are deferred to COMMIT, so a reference to a
  /// refused row did not fail at its INSERT, it failed after every per-row
  /// outcome had already been decided, and took the whole request with it.
  group(
    "a project built from a colleague's data (task 11.46)",
    skip: databaseSkipReason,
    () {
      /// The colleague-edited tag. `projectId` is a parameter since task
      /// 11.219: a tag belongs to one project, so "the tag this project holds"
      /// and "the tag" are the same row, and the `Project_Tags` link that used
      /// to carry the project has gone with the table.
      Map<String, Object?> tag(String by, {required String projectId}) => {
        'tag_id': 'tag-shared',
        'project_id': projectId,
        'lineage_id': 'tag-shared',
        'frequency_mhz': 148.520,
        'tag_name': 'Collar 12',
        'status': 'active',
        'color_hex': '#FF0000',
        'created_at': '2026-06-01T12:00:00.000Z',
        'updated_at': '2026-07-01T12:00:00.000Z',
        'revision': 3,
        'last_modified_by': by,
        'origin_device_id': 'device-B',
      };

      Map<String, Object?> session(String projectId, String by) => {
        'session_id': 'sess-1',
        'project_id': projectId,
        'tag_id': 'tag-shared',
        'label': 'Morning sweep',
        'started_at_local': '2026-08-01T12:00:00.000Z',
        'started_at_utc': '2026-08-01T12:00:00.000Z',
        'started_at_offset': '+00:00',
        'created_at': '2026-08-01T12:00:00.000Z',
        'updated_at': '2026-08-01T12:00:00.000Z',
        'revision': 2,
        'last_modified_by': by,
        'origin_device_id': 'device-B',
      };

      Future<Map<String, Object?>> establish(
        ({String token, String userId}) owner,
        String projectId, {
        required String tagAuthor,
      }) async {
        final response = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: projectId,
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId)],
                Tables.projects: [project(projectId, ownerId: owner.userId)],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-1',
                    projectId: projectId,
                    ownerId: owner.userId,
                  ),
                ],
                Tables.tags: [tag(tagAuthor, projectId: projectId)],
                Tables.observations: [
                  {
                    ...observation(
                      'obs-1',
                      projectId: projectId,
                      userId: owner.userId,
                    ),
                    'tag_id': 'tag-shared',
                  },
                ],
              },
            ).toJson(),
          ),
        );
        expect(response.statusCode, 200);
        return jsonDecode(response.body) as Map<String, Object?>;
      }

      test(
        'a first publish whose tag a colleague last edited now lands whole — '
        'the editor is not a member and never will be (task 11.47)',
        () async {
          // **This test's expectations were inverted by task 11.47, and the
          // inversion is the point rather than a repair.** It used to assert
          // that all three rows came back `unauthorized`, and that *was* the
          // behaviour — task 11.46 wrote it to prove the publish no longer
          // died. But refusing them was itself the defect one level up:
          // `Tags` has no author column at all, so the only thing refusing it
          // was a note about who last renamed it, and the cost of that note
          // was the owner's own bearing.
          //
          // `colleague-user-id` is seeded nowhere: no `Users` row, no
          // membership, and a brand-new project that reaches nobody. So this
          // is precisely the acceptance case — *the editor is not, and never
          // will be, a member* — and under the old rule clause 2 could never
          // come true, which is why these rows were held forever rather than
          // held pending anything.
          final owner = await signIn('sam@example.com');
          final body = await establish(
            owner,
            'proj-colleague-tag',
            tagAuthor: 'colleague-user-id',
          );

          final outcomes = body['outcomes']! as Map<String, Object?>;
          expect(outcomes['${Tables.projects}/proj-colleague-tag'], 'inserted');

          // The tag itself: an audit name the project cannot reach, on a
          // table with no identity column, is no longer a reason to refuse.
          //
          // **One assertion where there were two (task 11.219).** The second
          // checked the `Project_Tags` link that put this tag in the project;
          // the tag's own `project_id` is that now, so the row asserted below
          // *is* both claims.
          expect(
            outcomes['${Tables.tags}/tag-shared/proj-colleague-tag'],
            'inserted',
          );
          // **And the row this was really costing.** The bearing is the
          // owner's own field data; it was refused only because the tag it
          // names was, and that cascade is what made a weak claim expensive.
          expect(
            outcomes['${Tables.observations}/obs-1/proj-colleague-tag'],
            'inserted',
          );
        },
      );

      test(
        'but a bearing the colleague authored is still refused in that same '
        'push — the boundary task 11.47 must not cross',
        () async {
          // The other side of the line, in one request, so the two cannot
          // drift apart. Michael decided on 2026-08-28 that a record restored
          // from a colleague's archive keeps their name: `Observations` is
          // author-governed, so a bearing naming the colleague as its author
          // stays refused even while the *tag* they last edited is accepted.
          //
          // Without this assertion the test above would pass just as well
          // against a build that had relaxed identity columns too, which is
          // the whole thing that must not happen.
          final owner = await signIn('sam@example.com');
          await establish(owner, 'proj-boundary', tagAuthor: 'colleague-user-id');

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode(
              SyncPushRequest(
                projectId: 'proj-boundary',
                deviceId: 'device-A',
                rows: {
                  // Shared vocabulary the colleague last edited: accepted.
                  Tables.triangulationSessions: [
                    session('proj-boundary', 'colleague-user-id'),
                  ],
                  // Field data the colleague *authored*: refused, permanently
                  // and by design.
                  Tables.observations: [
                    {
                      ...observation(
                        'obs-theirs',
                        projectId: 'proj-boundary',
                        userId: 'colleague-user-id',
                      ),
                      'tag_id': 'tag-shared',
                    },
                  ],
                },
              ).toJson(),
            ),
          );

          expect(response.statusCode, 200);
          final outcomes =
              (jsonDecode(response.body)
                  as Map<String, Object?>)['outcomes']!
              as Map<String, Object?>;
          expect(
            outcomes['${Tables.triangulationSessions}/sess-1/proj-boundary'],
            'inserted',
            reason: 'an edited-by name on shared vocabulary replicates',
          );
          expect(
            outcomes['${Tables.observations}/obs-theirs/proj-boundary'],
            'unauthorized',
            reason:
                'an authored-by name does not — this is the accepted cost of '
                "keeping a restored record's provenance, not a defect",
          );
        },
      );

      test(
        'a bearing naming a session the server would not take is still '
        'refused cleanly, not with a crash (task 11.46)',
        () async {
          // **Task 11.46's regression test, re-expressed by task 11.47 rather
          // than deleted, and the re-expression is deliberate.**
          //
          // The property under test has not changed: a bearing whose
          // referent the server refuses must come back as one more per-row
          // `unauthorized`, because `Observations.(session_id, project_id)`
          // is a real deferred foreign key and before 11.46 the whole push
          // died at COMMIT with `500 internal_error` — no per-row outcome,
          // everything rolled back, and a person left with "Could not
          // publish" and nothing to act on.
          //
          // What changed is only the *way a session gets refused*. This test
          // used to manufacture one with an audit name the project could not
          // reach, and task 11.47 made that case legal — so, left alone, this
          // test would have gone green while measuring nothing at all, which
          // is the exact failure mode this project keeps naming. It now uses
          // a cause 11.47 does not touch: the session references a **tag the
          // project cannot reach**, refused by `_authorizeTagReferences`.
          final owner = await signIn('sam@example.com');
          // The project's own tag is the owner's, so it lands and is
          // reachable — which isolates the session reference as the only
          // thing at issue, exactly as before.
          await establish(owner, 'proj-2', tagAuthor: owner.userId);

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode(
              SyncPushRequest(
                projectId: 'proj-2',
                deviceId: 'device-A',
                rows: {
                  // A session pointing at a tag this project has never had.
                  // Its audit name is the owner's own, so nothing about *who
                  // touched it* is at issue — only the foreign tag.
                  Tables.triangulationSessions: [
                    {
                      ...session('proj-2', owner.userId),
                      'tag_id': 'tag-not-in-this-project',
                    },
                  ],
                  // And the owner's OWN bearing, naming that session.
                  // Nothing about this row is refusable on its own — it is
                  // the reference that is the problem.
                  Tables.observations: [
                    {
                      ...observation(
                        'obs-9',
                        projectId: 'proj-2',
                        userId: owner.userId,
                      ),
                      'tag_id': 'tag-shared',
                      'session_id': 'sess-1',
                    },
                  ],
                },
              ).toJson(),
            ),
          );

          expect(
            response.statusCode,
            200,
            reason: 'a refused referent must not take the request down',
          );
          final outcomes =
              (jsonDecode(response.body)
                  as Map<String, Object?>)['outcomes']!
              as Map<String, Object?>;
          expect(
            outcomes['${Tables.triangulationSessions}/sess-1/proj-2'],
            'unauthorized',
            reason:
                'if this ever reads "inserted", the cause this test relies on '
                'has gone the way the audit-name one did, and the dangling-'
                'reference property below is no longer being measured',
          );
          expect(outcomes['${Tables.observations}/obs-9/proj-2'], 'unauthorized');
        },
      );

      test(
        'and an ordinary bearing on a session of the caller\'s own, pushed in '
        'the same batch as that session, is still accepted',
        () async {
          // The other half of the property: refusing a dangling reference must
          // not refuse a *satisfied* one. The session and the bearing naming
          // it arrive together, so at the moment the bearing is judged the
          // session has been allowed but not yet written — which is exactly
          // the case `_writtenThisPush` exists for.
          final owner = await signIn('sam@example.com');
          await establish(owner, 'proj-3', tagAuthor: owner.userId);

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode(
              SyncPushRequest(
                projectId: 'proj-3',
                deviceId: 'device-A',
                rows: {
                  Tables.triangulationSessions: [
                    session('proj-3', owner.userId),
                  ],
                  Tables.observations: [
                    {
                      ...observation(
                        'obs-10',
                        projectId: 'proj-3',
                        userId: owner.userId,
                      ),
                      'tag_id': 'tag-shared',
                      'session_id': 'sess-1',
                    },
                  ],
                },
              ).toJson(),
            ),
          );

          expect(response.statusCode, 200);
          final outcomes =
              (jsonDecode(response.body)
                  as Map<String, Object?>)['outcomes']!
              as Map<String, Object?>;
          expect(
            outcomes['${Tables.triangulationSessions}/sess-1/proj-3'],
            'inserted',
          );
          expect(outcomes['${Tables.observations}/obs-10/proj-3'], 'inserted');
        },
      );
    },
  );
}

Response _unauthorizedResponse() => Response(
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
