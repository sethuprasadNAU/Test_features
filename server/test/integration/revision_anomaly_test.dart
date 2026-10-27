@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// Task 11.159, against the real storage layer.
///
/// **The shape being pinned down is "stored, and named".** A row pushed at an
/// absurd `revision` wins last-write-wins forever, and this server does not
/// refuse it — see `RevisionPlausibility` for the measurement that settled
/// refuse-versus-detect, and `test/data/sync/offline_revision_burst_test.dart`
/// in the app for the burst measurement that killed the bound-the-increment
/// candidate. So every test here asserts **both halves**: the row is on the
/// server afterwards, and the register says so. A test that only checked the
/// register would pass over a build that had quietly started refusing.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_revision_anomaly_test';
  const projectId = 'proj-1';
  const userId = 'user-1';
  const deviceId = 'device-A';

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
    await _seed(connection);
  });

  Map<String, Object?> observation(
    String id, {
    required int revision,
    String createdAt = '2026-08-01T12:00:00.000Z',
    String updatedAt = '2026-08-01T12:00:00.000Z',
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
    'created_at': createdAt,
    'updated_at': updatedAt,
    'revision': revision,
    'last_modified_by': userId,
    'origin_device_id': deviceId,
  };

  Future<PushResult> push(SyncRows rows) => connection.runTx(
    (tx) => SyncService(session: tx).applyPush(
      projectId: projectId,
      rows: rows,
      deviceId: deviceId,
      authorizer: RowAuthorizer(
        session: tx,
        projectId: projectId,
        userId: userId,
        access: ProjectAccess.owner,
      ),
    ),
  );

  Future<List<RevisionAnomalyEntry>> anomalies() =>
      connection.runTx((tx) => RevisionAnomalyLog(tx).recent());

  Future<int> storedRevision(String id) async {
    final result = await connection.execute(
      'SELECT revision FROM ${quoted(Tables.observations)} '
      r'WHERE observation_id = $1 AND project_id = $2',
      parameters: [id, projectId],
    );
    return result.first.first! as int;
  }

  group('a revision nobody can overtake', skip: databaseSkipReason, () {
    test(
      'a first push at 2^62 is STORED and named — nothing strands it, and the '
      'register says which row, whose device, and by how far',
      () async {
        const absurd = 4611686018427387904;
        final result = await push({
          Tables.observations: [
            observation(
              'obs-pinned',
              revision: absurd,
              updatedAt: '2026-08-01T13:00:00.000Z',
            ),
          ],
        });

        // Half one: the row went in. A refusal here would be the failure this
        // whole design exists to avoid.
        expect(result.applied, 1);
        expect(
          result.outcomes['${Tables.observations}/obs-pinned/$projectId'],
          SyncRowOutcome.inserted,
        );
        expect(await storedRevision('obs-pinned'), absurd);

        // Half two: somebody can find out.
        final recorded = await anomalies();
        expect(recorded, hasLength(1));
        final entry = recorded.single;
        expect(entry.tableName, Tables.observations);
        expect(entry.rowKey, 'obs-pinned/$projectId');
        expect(entry.observedAs, RevisionSighting.arriving.db);
        expect(entry.incomingRevision, absurd);
        expect(entry.storedRevision, isNull);
        expect(entry.reportingUserId, userId);
        expect(entry.reportingDeviceId, deviceId);
        // 3600 seconds of claimed life, one edit a second, plus the burst
        // allowance — the log line carries what it found, not just a name.
        expect(entry.allowedEdits, 4600);
        expect(entry.sightings, 1);
      },
    );

    test('an ordinary offline burst — the fifty corrections the app measured — '
        'is stored and recorded nowhere', () async {
      await push({
        Tables.observations: [observation('obs-1', revision: 1)],
      });
      await push({
        Tables.observations: [
          observation(
            'obs-1',
            revision: 51,
            updatedAt: '2026-08-01T13:00:00.000Z',
          ),
        ],
      });

      expect(await storedRevision('obs-1'), 51);
      expect(await anomalies(), isEmpty);
    });

    test('a teammate losing to a row already pinned is what makes a pin that '
        'predates this detection visible', () async {
      // Put the pin in place behind the detection's back, the way a row
      // pushed before this code shipped would already be sitting there.
      await connection.execute(
        'INSERT INTO ${quoted(Tables.observations)} '
        '(observation_id, project_id, user_id, timestamp_local, '
        'timestamp_utc, timezone_offset, latitude, longitude, '
        'position_source, elevation, altitude_agl, observation_type, '
        'signal_type, signal_strength, created_at, updated_at, revision, '
        'last_modified_by, origin_device_id) '
        r"VALUES ('obs-old', $1, $2, $3, $3, '+00:00', 35.19, -111.65, "
        r"'gps_fix', 2100.0, 0.0, 'directional', 'regular_pulse', "
        r"'strong', $3, $3, 4611686018427387904, $2, 'device-Z')",
        parameters: [projectId, userId, '2026-08-01T12:00:00.000Z'],
      );

      final result = await push({
        Tables.observations: [
          observation(
            'obs-old',
            revision: 8,
            updatedAt: '2026-08-02T12:00:00.000Z',
          ),
        ],
      });

      expect(
        result.outcomes['${Tables.observations}/obs-old/$projectId'],
        SyncRowOutcome.lostToServer,
      );

      final entry = (await anomalies()).single;
      expect(entry.observedAs, RevisionSighting.blocking.db);
      expect(entry.incomingRevision, 4611686018427387904);
      // The attribution on a `blocking` sighting is the person whose
      // correction was discarded, not whoever pinned the row — the register's
      // own documentation says so, and this is the assertion that keeps it
      // true.
      expect(entry.reportingUserId, userId);
    });

    test(
      'the register is one row per record, not one per push — the pin arriving '
      'and then blocking somebody is two sightings of one row, not two rows',
      () async {
        await push({
          Tables.observations: [
            observation(
              'obs-pinned',
              revision: 4611686018427387904,
              updatedAt: '2026-08-01T13:00:00.000Z',
            ),
          ],
        });
        expect(
          (await anomalies()).single.observedAs,
          RevisionSighting.arriving.db,
        );

        // The teammate's honest correction, which loses and always will.
        await push({
          Tables.observations: [
            observation(
              'obs-pinned',
              revision: 9,
              updatedAt: '2026-08-02T12:00:00.000Z',
            ),
          ],
        });

        final recorded = await anomalies();
        expect(recorded, hasLength(1));
        expect(recorded.single.sightings, 2);
        expect(recorded.single.observedAs, RevisionSighting.blocking.db);
      },
    );
  });
}

Future<void> _seed(Connection connection) async {
  const at = '2026-08-01T12:00:00.000Z';
  await connection.runTx((tx) async {
    await tx.execute(
      'INSERT INTO ${quoted(Tables.users)} '
      '(user_id, first_name, last_name, email, created_at, updated_at, revision) '
      r"VALUES ('user-1', 'Sam', 'Ranger', 'sam@example.com', $1, $1, 0)",
      parameters: [at],
    );
    await tx.execute(
      'INSERT INTO ${quoted(Tables.projects)} '
      '(project_id, project_name, owner_user_id, creation_date, datum, '
      'created_at, updated_at, revision, coordinate_format, '
      'triangulation_window_minutes) '
      r"VALUES ('proj-1', 'Elk', 'user-1', $1, 'WGS84', $1, $1, 0, 'dd', 15)",
      parameters: [at],
    );
  });
}
