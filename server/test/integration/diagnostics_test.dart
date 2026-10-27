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

/// End-to-end over a real bound HTTP socket, using the same `createHandler`
/// wiring `bin/server.dart` does — proving task 10.13's acceptance criteria
/// against the actual routes rather than the pieces in isolation: a lost row
/// really does show up in `/diagnostics/traffic`, and the console really is
/// unreachable when not explicitly enabled.
///
/// See `test/integration/postgres_sync_test.dart`'s header for how to run
/// these against a real database.
void main() {
  late Connection connection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_diagnostics_e2e_test';
  const diagnosticsToken = 'test-diagnostics-token';
  final captured = <String, String>{};
  var idCounter = 0;
  String nextId() => 'id-${idCounter++}';

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

  Future<HttpServer> startServer({required bool diagnosticsEnabled}) async {
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
        if (token == null) return Response(401);
        return connection.runTx((tx) async {
          final auth = AuthService(
            session: tx,
            emailSender: _CapturingSender(captured),
            linkBaseUrl: 'http://test',
          );
          final activeSession = await auth.validateSession(token);
          if (activeSession == null) return Response(401);
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
      diagnosticsConfig: diagnosticsEnabled
          ? const DiagnosticsConfig(
              enabled: true,
              allowRemote: false,
              token: diagnosticsToken,
            )
          : null,
      withDiagnostics: !diagnosticsEnabled
          ? null
          : (request, action) async => action(
              DiagnosticsContext(
                repo: DiagnosticsRepository(connection),
                trafficLog: SyncTrafficLogStore(connection),
                auditLog: AuthAuditLog(
                  connection,
                  onError: (type) =>
                      fail('audit log write failed and was swallowed: $type'),
                ),
              ),
            ),
    );
    return shelf_io.serve(
      handler,
      InternetAddress.loopbackIPv4,
      0,
      poweredByHeader: null,
    );
  }

  setUp(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
  });

  tearDown(() => server.close(force: true));

  /// Signs in via a direct `AuthService` call sharing the test's own
  /// connection — the same pattern `auth_flow_test.dart` uses — rather than
  /// the HTTP `/auth/*` routes, since only the token's *hash* is ever
  /// persisted and this test cares about exercising `/sync/*` and
  /// `/diagnostics/*` over real HTTP, not re-deriving the magic-link round
  /// trip those routes already have their own tests for.
  Future<({String token, String userId})> signIn(String email) async {
    return connection.runTx((tx) async {
      final auth = AuthService(
        session: tx,
        emailSender: _CapturingSender(captured),
        linkBaseUrl: 'http://test',
      );
      await auth.requestMagicLink(rawEmail: email, requestId: nextId());
      final url = captured[email]!;
      final token = Uri.parse(url).queryParameters['token']!;
      final issued = await auth.redeem(
        token: token,
        deviceId: 'device-A',
        sessionId: nextId(),
        newUserId: nextId(),
      );
      return (token: issued!.token, userId: issued.userId);
    });
  }

  Map<String, String> authHeaders(String token) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $token',
  };

  Map<String, Object?> observation(String id, {required String userId}) => {
    'observation_id': id,
    'project_id': 'proj-1',
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

  group('diagnostics disabled (the default)', skip: databaseSkipReason, () {
    test('the console routes do not exist', () async {
      server = await startServer(diagnosticsEnabled: false);
      baseUri = Uri.parse('http://${server.address.address}:${server.port}');

      final response = await http.get(
        baseUri.replace(path: '/diagnostics/health'),
      );
      expect(response.statusCode, isNot(200));
    });
  });

  group('diagnostics enabled', skip: databaseSkipReason, () {
    test('requires the token even against the full stack', () async {
      server = await startServer(diagnosticsEnabled: true);
      baseUri = Uri.parse('http://${server.address.address}:${server.port}');

      final response = await http.get(
        baseUri.replace(path: '/diagnostics/health'),
      );
      expect(response.statusCode, 401);
    });

    test(
      'a row that loses last-write-wins appears in the traffic log',
      () async {
        server = await startServer(diagnosticsEnabled: true);
        baseUri = Uri.parse('http://${server.address.address}:${server.port}');
        final owner = await signIn('sam@example.com');

        await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-A',
              rows: {
                Tables.users: [
                  {
                    'user_id': owner.userId,
                    'first_name': 'Sam',
                    'last_name': 'Ranger',
                    'email': 'sam@example.com',
                    'created_at': '2026-08-01T12:00:00.000Z',
                    'updated_at': '2026-08-01T12:00:00.000Z',
                    'revision': 0,
                    'last_modified_by': owner.userId,
                    'origin_device_id': 'device-A',
                  },
                ],
                Tables.projects: [
                  {
                    'project_id': 'proj-1',
                    'project_name': 'Elk',
                    'owner_user_id': owner.userId,
                    'creation_date': '2026-08-01T12:00:00.000Z',
                    'datum': 'WGS84',
                    'created_at': '2026-08-01T12:00:00.000Z',
                    'updated_at': '2026-08-01T12:00:00.000Z',
                    'revision': 0,
                    'last_modified_by': owner.userId,
                    'origin_device_id': 'device-A',
                    'coordinate_format': 'dd',
                    'triangulation_window_minutes': 15,
                  },
                ],
                Tables.projectMemberships: [
                  {
                    'membership_id': 'mem-1',
                    'project_id': 'proj-1',
                    'user_id': owner.userId,
                    'join_date': '2026-08-01T12:00:00.000Z',
                    'role': 'owner',
                    'created_at': '2026-08-01T12:00:00.000Z',
                    'updated_at': '2026-08-01T12:00:00.000Z',
                    'revision': 0,
                    'last_modified_by': owner.userId,
                    'origin_device_id': 'device-A',
                  },
                ],
                Tables.observations: [
                  observation('obs-1', userId: owner.userId),
                ],
              },
            ).toJson(),
          ),
        );

        // A second, older-revision push for the same row loses LWW.
        final losingPush = await http.post(
          baseUri.replace(path: '/sync/push'),
          headers: authHeaders(owner.token),
          body: jsonEncode(
            SyncPushRequest(
              projectId: 'proj-1',
              deviceId: 'device-B',
              rows: {
                Tables.observations: [
                  observation('obs-1', userId: owner.userId),
                ],
              },
            ).toJson(),
          ),
        );
        expect(losingPush.statusCode, 200);

        final traffic = await http.get(
          baseUri.replace(
            path: '/diagnostics/traffic',
            queryParameters: {'lost_only': 'true'},
          ),
          headers: {'authorization': 'Bearer $diagnosticsToken'},
        );
        expect(traffic.statusCode, 200);
        final body = jsonDecode(traffic.body) as Map<String, Object?>;
        final entries = body['entries'] as List;
        expect(entries, isNotEmpty);
        final entry = entries.first as Map<String, Object?>;
        expect(entry['device_id'], 'device-B');
        expect(entry['rows_lost'], greaterThan(0));
        final lostDetail = entry['lost_detail'] as List;
        // The protocol's row key, which since task 10.35 is
        // `(observation_id, project_id)` joined — so an operator reading the
        // traffic log is told which project's `obs-1` lost, not just that some
        // `obs-1` did. That distinction is the point of the re-key: two
        // projects may now legitimately hold the same id.
        expect((lostDetail.first as Map)['primary_key'], 'obs-1/proj-1');
      },
    );

    test('/diagnostics/projects lists a published project', () async {
      server = await startServer(diagnosticsEnabled: true);
      baseUri = Uri.parse('http://${server.address.address}:${server.port}');
      final owner = await signIn('sam@example.com');

      await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(owner.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-A',
            rows: {
              Tables.users: [
                {
                  'user_id': owner.userId,
                  'first_name': 'Sam',
                  'last_name': 'Ranger',
                  'email': 'sam@example.com',
                  'created_at': '2026-08-01T12:00:00.000Z',
                  'updated_at': '2026-08-01T12:00:00.000Z',
                  'revision': 0,
                  'last_modified_by': owner.userId,
                  'origin_device_id': 'device-A',
                },
              ],
              Tables.projects: [
                {
                  'project_id': 'proj-1',
                  'project_name': 'Elk',
                  'owner_user_id': owner.userId,
                  'creation_date': '2026-08-01T12:00:00.000Z',
                  'datum': 'WGS84',
                  'created_at': '2026-08-01T12:00:00.000Z',
                  'updated_at': '2026-08-01T12:00:00.000Z',
                  'revision': 0,
                  'last_modified_by': owner.userId,
                  'origin_device_id': 'device-A',
                  'coordinate_format': 'dd',
                  'triangulation_window_minutes': 15,
                },
              ],
            },
          ).toJson(),
        ),
      );

      final response = await http.get(
        baseUri.replace(path: '/diagnostics/projects'),
        headers: {'authorization': 'Bearer $diagnosticsToken'},
      );
      expect(response.statusCode, 200);
      final body = jsonDecode(response.body) as Map<String, Object?>;
      final projects = body['projects'] as List;
      expect(projects.map((p) => (p as Map)['project_id']), contains('proj-1'));
    });
  });
}

/// Captures the magic-link URL `AuthService` would otherwise email, so this
/// test can extract the plaintext token — only its hash is ever persisted.
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
