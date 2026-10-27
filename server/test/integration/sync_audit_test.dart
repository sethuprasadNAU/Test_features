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

/// Task 10.23 — C-5: a denied sync request must leave an
/// `authorization_denied` row in `auth_audit_log`, proven against a real
/// Postgres over a real bound HTTP socket.
///
/// Wired with **two connections**, exactly as `bin/server.dart` is: one the
/// sync handler's `runTx` owns, one dedicated to the audit log. That
/// dedicated connection is the fix. Security Model §7.3 B5 found the audit
/// write sharing the sync connection instead — `postgres` refuses a second
/// statement on a connection while that connection's own transaction is
/// open, so the write was refused every time, silently, and
/// `grep authorizationDenied server/test` found nothing that would have
/// caught it. Reverting `withAuditLog` below to reuse `connection` instead of
/// `auditConnection` reproduces that failure and fails this test.
///
/// See `test/integration/postgres_sync_test.dart`'s header for how to run
/// these against a real database.
void main() {
  late Connection connection;
  late Connection auditConnection;
  late HttpServer server;
  late Uri baseUri;
  const testSchema = 'tritrack_sync_audit_test';

  final captured = <String, String>{};

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
    await connection.close();
    await auditConnection.close();
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
      // The fix under test: a connection with no transaction of its own,
      // so writing here never collides with the `runTx` above.
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

  Future<({String token, String userId})> signIn(String email) async {
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
    );
  }

  Map<String, String> authHeaders(String token) => {
    'content-type': 'application/json',
    'authorization': 'Bearer $token',
  };

  Map<String, Object?> user(String userId) => {
    'user_id': userId,
    'first_name': 'Sam',
    'last_name': 'Ranger',
    'email': 'sam@example.com',
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

  Future<List<Map<String, Object?>>> authorizationDenials() async {
    final result = await connection.execute(
      'SELECT user_id, outcome, reason FROM auth_audit_log '
      r"WHERE event = 'authorization_denied'",
    );
    return [for (final row in result) row.toColumnMap()];
  }

  group('authorization denials are audited', skip: databaseSkipReason, () {
    test('a stranger pushing to a project they do not belong to leaves an '
        'authorization_denied row naming the caller and the project', () async {
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
      final push = await http.post(
        baseUri.replace(path: '/sync/push'),
        headers: authHeaders(stranger.token),
        body: jsonEncode(
          SyncPushRequest(
            projectId: 'proj-1',
            deviceId: 'device-C',
            rows: {
              Tables.observations: [
                {
                  'observation_id': 'obs-hostile',
                  'project_id': 'proj-1',
                  'user_id': stranger.userId,
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
                  'last_modified_by': stranger.userId,
                  'origin_device_id': 'device-C',
                },
              ],
            },
          ).toJson(),
        ),
      );
      expect(push.statusCode, 403);

      final denials = await authorizationDenials();
      expect(
        denials,
        hasLength(1),
        reason:
            'this is the row Security Model §7.3 B5 found was never '
            'written',
      );
      expect(denials.single['user_id'], stranger.userId);
      expect(denials.single['outcome'], 'proj-1');
      expect(denials.single['reason'], 'push');
    });
  });
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
