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

/// Task 10.46 (`TriTrack_Security_Model.md` §10.7, closing F10 §7.6, G-5
/// §9.5.1, H-4 and H-5): every malformed-envelope shape must answer a typed
/// `4xx`, never `500`, and a single bad row or an unrecognized table must not
/// take the rest of a push down with it.
///
/// Runs over a **real bound HTTP socket** with the same `createHandler`
/// wiring `bin/server.dart` uses — mirroring `publish_and_join_test.dart` —
/// because F10/H-4 are bugs in that exact wiring (an unchecked cast that ran
/// *before* `withSyncContext`'s authentication check). A unit test calling
/// `SyncPushRequest.fromJson` directly would never see them: the crash was in
/// `sync_routes.dart`'s `handle()`, one layer above the parsing it wraps.
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_envelope_typing_test';

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

  Future<({String token, String userId, String email})> signIn(
    String email,
  ) async {
    await http.post(
      baseUri.replace(path: '/auth/magic-link'),
      headers: {'content-type': 'application/json'},
      body: jsonEncode({'email': email}),
    );
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
      // Carried back because a `Users` row must now claim the address its
      // account authenticated with (task 10.55) — a fixture that hardcoded one
      // was testing a push the real client never sends.
      email: email,
    );
  }

  Map<String, String> authHeaders(String token) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $token',
  };

  Map<String, Object?> user(String userId, String email) => {
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

  /// Publishes a minimal, valid project so the push tests below have
  /// somewhere authorized to write.
  Future<void> publishProject(
    ({String token, String userId, String email}) owner,
    String projectId,
  ) {
    return http
        .post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: projectId,
              deviceId: 'device-A',
              rows: {
                Tables.users: [user(owner.userId, owner.email)],
                Tables.projects: [project(projectId, ownerId: owner.userId)],
                Tables.projectMemberships: [
                  ownerMembership(
                    'mem-1',
                    projectId: projectId,
                    ownerId: owner.userId,
                  ),
                ],
              },
            ).toJson(),
          ),
        )
        .then((r) => expect(r.statusCode, 200, reason: r.body));
  }

  group(
    'F10 / H-4 — envelope typing must never draw a 500',
    skip: databaseSkipReason,
    () {
      test(
        'an unauthenticated, wrongly-typed body draws 401, not 500',
        () async {
          // F10, reproduced verbatim: `project_id` is a number, not a
          // string, and there is no Authorization header at all. Before the
          // fix, the logging-only cast in `handle()` threw first.
          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'project_id': 42}),
          );
          expect(response.statusCode, 401);
        },
      );

      test(
        'schema_major as a string draws 400 malformed_envelope, not 500',
        () async {
          // H-4, reproduced verbatim, now authenticated: the right value,
          // wrong JSON type.
          final owner = await signIn('h4-string@example.invalid');
          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              'envelope': kSyncEnvelopeId,
              'protocol_version': syncProtocolVersion,
              'schema_version': latestSchemaVersion,
              'schema_major': '$schemaMajorVersion',
              'project_id': 'proj-1',
              'device_id': 'device-A',
              'rows': <String, Object?>{},
            }),
          );
          expect(response.statusCode, 400);
          expect(
            (jsonDecode(response.body) as Map)['error'],
            'malformed_envelope',
          );
        },
      );

      test(
        'project_id as a number draws 400, not 500, once authenticated',
        () async {
          final owner = await signIn('f10-authed@example.invalid');
          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              ...const SyncEnvelope().toJson(),
              'project_id': 42,
              'device_id': 'device-A',
              'rows': <String, Object?>{},
            }),
          );
          expect(response.statusCode, 400);
        },
      );

      test('the same shapes on /sync/pull and /sync/ack', () async {
        final owner = await signIn('f10-pullack@example.invalid');
        final pull = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 42,
            'device_id': 'device-A',
            'cursor': 0,
          }),
        );
        expect(pull.statusCode, 400);

        final ack = await http.post(
          baseUri.replace(path: '/sync/ack'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 42,
            'device_id': 'device-A',
            'cursor': 0,
          }),
        );
        expect(ack.statusCode, 400);
      });
    },
  );

  group(
    'H-5 — an unrecognized table produces a per-table outcome, not silence',
    skip: databaseSkipReason,
    () {
      test(
        'a push with one unknown table and one good row reports both',
        () async {
          final owner = await signIn('h5@example.invalid');
          await publishProject(owner, 'proj-1');

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              ...const SyncEnvelope().toJson(),
              'project_id': 'proj-1',
              'device_id': 'device-A',
              'rows': {
                'NotATable': [
                  {'whatever': 'x'},
                ],
                Tables.observations: [
                  observation(
                    'obs-1',
                    projectId: 'proj-1',
                    userId: owner.userId,
                  ),
                ],
              },
            }),
          );

          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final outcomes = body['outcomes'] as Map<String, Object?>;
          expect(outcomes['NotATable/?'], 'invalid');
          expect(outcomes['${Tables.observations}/obs-1/proj-1'], 'inserted');
          expect(body['applied'], 1);
        },
      );

      test(
        'a push of nothing but an unknown table still answers 200',
        () async {
          final owner = await signIn('h5-onlyunknown@example.invalid');
          await publishProject(owner, 'proj-1');

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              ...const SyncEnvelope().toJson(),
              'project_id': 'proj-1',
              'device_id': 'device-A',
              'rows': {
                'NotATable': [
                  {'whatever': 'x'},
                ],
              },
            }),
          );

          expect(response.statusCode, 200);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          expect(
            (body['outcomes'] as Map<String, Object?>)['NotATable/?'],
            'invalid',
          );
          expect(body['applied'], 0);
        },
      );
    },
  );

  group(
    'G-5 — one malformed row must not fail the whole push',
    skip: databaseSkipReason,
    () {
      test('a row missing a NOT NULL column is invalid; the rest of the batch '
          'still lands', () async {
        final owner = await signIn('g5-missing@example.invalid');
        await publishProject(owner, 'proj-1');

        final bad = observation(
          'obs-bad',
          projectId: 'proj-1',
          userId: owner.userId,
        )..remove('timestamp_local');
        final good = observation(
          'obs-good',
          projectId: 'proj-1',
          userId: owner.userId,
        );

        final response = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device-A',
            'rows': {
              Tables.observations: [bad, good],
            },
          }),
        );

        expect(response.statusCode, 200, reason: response.body);
        final body = jsonDecode(response.body) as Map<String, Object?>;
        final outcomes = body['outcomes'] as Map<String, Object?>;
        expect(outcomes['${Tables.observations}/obs-bad/proj-1'], 'invalid');
        expect(outcomes['${Tables.observations}/obs-good/proj-1'], 'inserted');
        expect(body['applied'], 1);
      });

      test('a wrongly-typed field RowValidator does not catch is invalid, not '
          'a 500', () async {
        final owner = await signIn('g5-wrongtype@example.invalid');
        await publishProject(owner, 'proj-1');

        // `RowValidator._num` returns null for a non-numeric string, so
        // this is silently treated as "absent" by the range check and
        // reaches Postgres, which rejects binding a String to a `double
        // precision` column.
        final bad = observation(
          'obs-badtype',
          projectId: 'proj-1',
          userId: owner.userId,
        )..['latitude'] = 'not-a-number';
        final good = observation(
          'obs-good2',
          projectId: 'proj-1',
          userId: owner.userId,
        );

        final response = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device-A',
            'rows': {
              Tables.observations: [bad, good],
            },
          }),
        );

        expect(response.statusCode, 200, reason: response.body);
        final body = jsonDecode(response.body) as Map<String, Object?>;
        final outcomes = body['outcomes'] as Map<String, Object?>;
        expect(
          outcomes['${Tables.observations}/obs-badtype/proj-1'],
          'invalid',
        );
        expect(outcomes['${Tables.observations}/obs-good2/proj-1'], 'inserted');
        expect(body['applied'], 1);
      });
    },
  );

  group(
    'J-4 (task 10.64) — /sync/pull cursor and batch_size never draw a 500',
    skip: databaseSkipReason,
    () {
      // §12.6's evidence, reproduced verbatim on every wrong JSON type each
      // field can carry — this is "derive every field... and test the cross
      // product: absent, wrong type," not just the one repro each field
      // happened to be shown with. `SyncPullRequest.fromJson`'s
      // `json['cursor'] as int?` / `json['batch_size'] as int?` threw on any
      // of these before task 10.64; a string is the exact case §12.6 quoted.
      Future<void> expectMalformedPull(
        String label,
        Object? cursor,
        Object? batchSize,
      ) async {
        final owner = await signIn('j4-$label@example.invalid');
        final response = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device-A',
            if (cursor != null) 'cursor': cursor,
            if (batchSize != null) 'batch_size': batchSize,
          }),
        );
        expect(response.statusCode, 400, reason: response.body);
        expect(
          (jsonDecode(response.body) as Map)['error'],
          'malformed_envelope',
        );
      }

      test(
        'cursor as a string',
        () => expectMalformedPull('cursor-string', 'abc', null),
      );
      test(
        'cursor as a float',
        () => expectMalformedPull('cursor-float', 1.5, null),
      );
      test(
        'cursor as an object',
        () => expectMalformedPull('cursor-object', {'a': 1}, null),
      );
      test(
        'cursor as a bool',
        () => expectMalformedPull('cursor-bool', true, null),
      );
      test(
        'batch_size as a string',
        () => expectMalformedPull('batchsize-string', null, 'x'),
      );
      test(
        'batch_size as an object',
        () => expectMalformedPull('batchsize-object', null, {}),
      );

      test('the same shape on /sync/ack', () async {
        final owner = await signIn('j4-ack@example.invalid');
        final response = await http.post(
          baseUri.replace(path: '/sync/ack'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device-A',
            'cursor': 'abc',
          }),
        );
        expect(response.statusCode, 400);
        expect(
          (jsonDecode(response.body) as Map)['error'],
          'malformed_envelope',
        );
      });

      test('a missing cursor still defaults rather than refusing', () async {
        // The absent case must keep working — this is what distinguishes
        // "the caller said nothing" (default) from "the caller said
        // something unusable" (refuse), the whole point of the fix.
        final owner = await signIn('j4-absent@example.invalid');
        await publishProject(owner, 'proj-1');
        final response = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device-A',
          }),
        );
        expect(response.statusCode, 200, reason: response.body);
      });
    },
  );

  group(
    'J-4 (task 10.64) — a NUL byte in project_id/device_id never draws a 500',
    skip: databaseSkipReason,
    () {
      test('device_id with a NUL byte on /sync/push', () async {
        final owner = await signIn('j4-nul-push@example.invalid');
        final response = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj-1',
            'device_id': 'device\u0000A',
            'rows': <String, Object?>{},
          }),
        );
        expect(response.statusCode, 400, reason: response.body);
        expect(
          (jsonDecode(response.body) as Map)['error'],
          'malformed_envelope',
        );
      });

      test('project_id with a NUL byte on /sync/pull', () async {
        final owner = await signIn('j4-nul-pull@example.invalid');
        final response = await http.post(
          baseUri.replace(path: '/sync/pull'),
          headers: authHeaders(owner.token),
          body: jsonEncode({
            ...const SyncEnvelope().toJson(),
            'project_id': 'proj\u00001',
            'device_id': 'device-A',
            'cursor': 0,
          }),
        );
        expect(response.statusCode, 400, reason: response.body);
        expect(
          (jsonDecode(response.body) as Map)['error'],
          'malformed_envelope',
        );
      });
    },
  );

  group(
    'J-5 (task 10.64) — a non-Map row entry in a known table is invalid, '
    'not silence',
    skip: databaseSkipReason,
    () {
      test(
        '§12.6\'s exact reproduction: three non-Map entries answer one '
        'invalid outcome, applied 0',
        () async {
          final owner = await signIn('j5@example.invalid');
          await publishProject(owner, 'proj-1');

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              ...const SyncEnvelope().toJson(),
              'project_id': 'proj-1',
              'device_id': 'device-A',
              'rows': {
                Tables.observations: ['hello', 1, null],
              },
            }),
          );

          expect(response.statusCode, 200, reason: response.body);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final outcomes = body['outcomes'] as Map<String, Object?>;
          expect(outcomes['${Tables.observations}/?'], 'invalid');
          expect(body['applied'], 0);
        },
      );

      test(
        'a mix of one malformed entry and one good row reports both',
        () async {
          final owner = await signIn('j5-mixed@example.invalid');
          await publishProject(owner, 'proj-1');

          final response = await http.post(
            baseUri.replace(path: '/sync/push'),
            headers: authHeaders(owner.token),
            body: jsonEncode({
              ...const SyncEnvelope().toJson(),
              'project_id': 'proj-1',
              'device_id': 'device-A',
              'rows': {
                Tables.observations: [
                  'not-a-row',
                  observation(
                    'obs-good3',
                    projectId: 'proj-1',
                    userId: owner.userId,
                  ),
                ],
              },
            }),
          );

          expect(response.statusCode, 200, reason: response.body);
          final body = jsonDecode(response.body) as Map<String, Object?>;
          final outcomes = body['outcomes'] as Map<String, Object?>;
          expect(outcomes['${Tables.observations}/?'], 'invalid');
          expect(
            outcomes['${Tables.observations}/obs-good3/proj-1'],
            'inserted',
          );
          expect(body['applied'], 1);
        },
      );
    },
  );

  group(
    'K-6 (task 10.78) — a malformed rows container is invalid, not silence',
    skip: databaseSkipReason,
    () {
      test(
        'a rows container that is not a JSON object draws one invalid '
        'outcome, applied 0',
        () async {
          final owner = await signIn('k6-container@example.invalid');
          await publishProject(owner, 'proj-1');

          for (final malformedRows in <Object?>['x', 1.5, [1], null]) {
            final response = await http.post(
              baseUri.replace(path: '/sync/push'),
              headers: authHeaders(owner.token),
              body: jsonEncode({
                ...const SyncEnvelope().toJson(),
                'project_id': 'proj-1',
                'device_id': 'device-A',
                'rows': malformedRows,
              }),
            );

            expect(
              response.statusCode,
              200,
              reason: 'rows=$malformedRows: ${response.body}',
            );
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final outcomes = body['outcomes'] as Map<String, Object?>;
            expect(
              outcomes['rows/?'],
              'invalid',
              reason: 'rows=$malformedRows',
            );
            expect(body['applied'], 0, reason: 'rows=$malformedRows');
          }
        },
      );

      test(
        'a known table whose value is not a list draws one invalid outcome '
        'for that table, applied 0',
        () async {
          final owner = await signIn('k6-table@example.invalid');
          await publishProject(owner, 'proj-1');

          for (final malformedValue in <Object?>[
            'x',
            5,
            null,
            {'not': 'a list'},
          ]) {
            final response = await http.post(
              baseUri.replace(path: '/sync/push'),
              headers: authHeaders(owner.token),
              body: jsonEncode({
                ...const SyncEnvelope().toJson(),
                'project_id': 'proj-1',
                'device_id': 'device-A',
                'rows': {Tables.observations: malformedValue},
              }),
            );

            expect(
              response.statusCode,
              200,
              reason: 'value=$malformedValue: ${response.body}',
            );
            final body = jsonDecode(response.body) as Map<String, Object?>;
            final outcomes = body['outcomes'] as Map<String, Object?>;
            expect(
              outcomes['${Tables.observations}/?'],
              'invalid',
              reason: 'value=$malformedValue',
            );
            expect(body['applied'], 0, reason: 'value=$malformedValue');
          }
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
