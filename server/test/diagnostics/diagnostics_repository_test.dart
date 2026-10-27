@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// [DiagnosticsRepository] is every read the console (task 10.13) can make.
/// The two things worth proving beyond "the query returns rows": it never
/// selects a token column, and it never accepts an arbitrary table name.
/// See `test/integration/postgres_sync_test.dart`'s header for how to run
/// these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_diagnostics_repo_test';
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
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
  });

  Future<void> seedProject() => connection.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, '
      'revision, server_seq) '
      r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0, 1)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes, server_seq) '
      r"VALUES ('proj-1', 'Elk', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15, 2)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projectMemberships)} '
      '(membership_id, project_id, user_id, join_date, role, created_at, '
      'updated_at, revision, server_seq) '
      r"VALUES ('mem-1', 'proj-1', 'user-1', $1, 'owner', $1, $1, 0, 3)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.observations)} '
      '(observation_id, project_id, user_id, timestamp_local, timestamp_utc, '
      'timezone_offset, latitude, longitude, position_source, elevation, '
      'altitude_agl, observation_type, signal_type, signal_strength, '
      'created_at, updated_at, revision, last_modified_by, server_seq) '
      r"VALUES ('obs-1', 'proj-1', 'user-1', $1, $1, '+00:00', 35.0, -111.0, "
      r"'gps_fix', 2100.0, 0, 'directional', 'regular_pulse', 'strong', "
      r"$1, $1, 1, 'user-1', 4)",
      parameters: [at],
    );
  });

  group('projects and rows', skip: databaseSkipReason, () {
    test('projects lists what was seeded', () async {
      await seedProject();
      final repo = DiagnosticsRepository(connection);
      final projects = await repo.projects();
      expect(projects.single['project_id'], 'proj-1');
      expect(projects.single['project_name'], 'Elk');
    });

    test('rowCounts reports per-table counts scoped to the project', () async {
      await seedProject();
      final repo = DiagnosticsRepository(connection);
      final counts = await repo.rowCounts('proj-1');
      expect(counts[Tables.observations], 1);
      expect(counts[Tables.projectMemberships], 1);
      // A global table (no project scope) is reported server-wide.
      expect(counts[Tables.users], 1);
    });

    test(
      'recentRows returns the sync columns the merge argument needs',
      () async {
        await seedProject();
        final repo = DiagnosticsRepository(connection);
        final rows = await repo.recentRows(
          Tables.observations,
          projectId: 'proj-1',
        );
        final row = rows!.single;
        expect(row['revision'], 1);
        expect(row['last_modified_by'], isNotNull);
        expect(row['origin_device_id'], isNull);
        expect(row['server_seq'], 4);
      },
    );

    test(
      'recentRows refuses a table name the sync protocol does not know',
      () async {
        final repo = DiagnosticsRepository(connection);
        // Not a real accessible route in practice — `table` comes from a URL
        // path segment — but the repository itself must refuse it, not just
        // the route, in case a future caller reaches this class directly.
        final rows = await repo.recentRows('auth_sessions');
        expect(rows, isNull);
      },
    );

    test('recentRows respects the limit', () async {
      await seedProject();
      final repo = DiagnosticsRepository(connection);
      final rows = await repo.recentRows(
        Tables.observations,
        projectId: 'proj-1',
        limit: 0 + 1,
      );
      expect(rows, hasLength(1));
    });
  });

  group('memberships', skip: databaseSkipReason, () {
    test('lists the owner membership for a project', () async {
      await seedProject();
      final repo = DiagnosticsRepository(connection);
      final memberships = await repo.membershipsFor('proj-1');
      expect(memberships.single['user_id'], 'user-1');
      expect(memberships.single['role'], 'owner');
      expect(memberships.single['end_date'], isNull);
    });
  });

  group('identities', skip: databaseSkipReason, () {
    test('joins the auth anchor to the synced display name', () async {
      await seedProject();
      await connection.execute(
        "INSERT INTO auth_accounts (user_id, email) VALUES ('user-1', 'sam@example.com')",
      );
      final repo = DiagnosticsRepository(connection);
      final identities = await repo.identities();
      final identity = identities.single;
      expect(identity['user_id'], 'user-1');
      expect(identity['first_name'], 'Sam');
      expect(identity['prior_emails'], isEmpty);
      // No column named anything like a secret ever appears.
      expect(identity.keys, isNot(contains('token_hash')));
    });

    test('surfaces every recorded prior email for the dedup trail', () async {
      await seedProject();
      await connection.execute(
        "INSERT INTO auth_accounts (user_id, email) VALUES ('user-1', 'sam@example.com')",
      );
      await connection.execute(
        'INSERT INTO ${quoted(Tables.userEmails)} '
        '(user_email_id, user_id, email, recorded_at, created_at, '
        'updated_at, revision, server_seq) '
        r"VALUES ('ue-1', 'user-1', 'old@example.com', $1, $1, $1, 0, 5)",
        parameters: [at],
      );
      final repo = DiagnosticsRepository(connection);
      final identity = (await repo.identities()).single;
      final priorEmails = identity['prior_emails'] as List;
      expect(priorEmails.single['email'], 'old@example.com');
    });
  });

  group('devices', skip: databaseSkipReason, () {
    test('joins cursor position with session liveness, never a token', () async {
      await seedProject();
      await connection.execute(
        "INSERT INTO auth_accounts (user_id, email) VALUES ('user-1', 'sam@example.com')",
      );
      await CursorStore(connection).acknowledge(
        const SyncCursorKey(
          userId: 'user-1',
          deviceId: 'device-A',
          projectId: 'proj-1',
        ),
        cursor: 4,
        at: DateTime.parse(at),
      );
      await connection.execute(
        'INSERT INTO auth_sessions '
        '(session_id, token_hash, user_id, device_id, created_at, '
        'last_seen_at, expires_at) '
        r"VALUES ('sess-1', 'deadbeef', 'user-1', 'device-A', $1, $1, $2)",
        parameters: [
          DateTime.parse(at),
          DateTime.parse(at).add(const Duration(days: 30)),
        ],
      );

      final repo = DiagnosticsRepository(connection);
      final devices = await repo.devices(userId: 'user-1');
      final device = devices.single;
      expect(device['device_id'], 'device-A');
      expect(device['acknowledged_seq'], 4);
      expect(device['session_last_seen_at'], isNotNull);
      expect(device['session_expires_at'], isNotNull);
      expect(device['session_revoked_at'], isNull);
      // The one thing this must never do.
      expect(device.keys, isNot(contains('token_hash')));
      expect(device.values, isNot(contains('deadbeef')));
    });

    test(
      'with no user filter, every device on the server is included',
      () async {
        await seedProject();
        await CursorStore(connection).acknowledge(
          const SyncCursorKey(
            userId: 'user-1',
            deviceId: 'device-A',
            projectId: 'proj-1',
          ),
          cursor: 1,
          at: DateTime.parse(at),
        );
        final repo = DiagnosticsRepository(connection);
        final devices = await repo.devices();
        expect(devices, isNotEmpty);
      },
    );
  });
}
