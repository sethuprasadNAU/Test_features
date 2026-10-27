@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// [SyncTrafficLogStore] is the durable half of task 10.13's headline
/// feature — "rows that lost last-write-wins" has to survive past the one
/// HTTP response it was computed for. See
/// `test/integration/postgres_sync_test.dart`'s header for how to run these.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_traffic_log_test';

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

  group('SyncTrafficLogStore', skip: databaseSkipReason, () {
    test('records and reads back a push entry', () async {
      final store = SyncTrafficLogStore(connection);
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-A',
        projectId: 'proj-1',
        cursorOut: 42,
        rowsPushed: 3,
        rowsApplied: 2,
        rowsRejected: 1,
        clientSchemaMajor: 1,
        clientSchemaVersion: 5,
        statusCode: 200,
      );

      final entries = await store.recent();
      expect(entries, hasLength(1));
      final entry = entries.single;
      expect(entry.kind, 'push');
      expect(entry.userId, 'user-1');
      expect(entry.deviceId, 'device-A');
      expect(entry.projectId, 'proj-1');
      expect(entry.cursorOut, 42);
      expect(entry.rowsPushed, 3);
      expect(entry.rowsApplied, 2);
      expect(entry.rowsRejected, 1);
      expect(entry.rowsLost, 0);
      expect(entry.lostDetail, isEmpty);
      expect(entry.clientSchemaMajor, 1);
      expect(entry.clientSchemaVersion, 5);
      expect(entry.statusCode, 200);
      expect(entry.errorCode, isNull);
    });

    test('recentLost returns only requests that actually lost a row, with '
        'enough detail to find it', () async {
      final store = SyncTrafficLogStore(connection);
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-A',
        projectId: 'proj-1',
        rowsPushed: 1,
        rowsApplied: 1,
        statusCode: 200,
      );
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-B',
        projectId: 'proj-1',
        rowsPushed: 1,
        lost: const [LoggedLostRow(table: 'Observations', primaryKey: 'obs-1')],
        statusCode: 200,
      );

      final lost = await store.recentLost();
      expect(lost, hasLength(1));
      expect(lost.single.deviceId, 'device-B');
      expect(lost.single.rowsLost, 1);
      expect(lost.single.lostDetail.single.table, 'Observations');
      expect(lost.single.lostDetail.single.primaryKey, 'obs-1');
    });

    test('recent orders newest first', () async {
      final store = SyncTrafficLogStore(connection);
      for (final deviceId in ['first', 'second', 'third']) {
        await store.record(
          kind: 'ack',
          userId: 'user-1',
          deviceId: deviceId,
          projectId: 'proj-1',
          statusCode: 200,
        );
      }
      final entries = await store.recent();
      expect(entries.map((e) => e.deviceId), ['third', 'second', 'first']);
    });

    test('latestPerDevice returns one row per (user, device)', () async {
      final store = SyncTrafficLogStore(connection);
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-A',
        clientSchemaMajor: 1,
        clientSchemaVersion: 3,
        statusCode: 200,
      );
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-A',
        clientSchemaMajor: 1,
        clientSchemaVersion: 5,
        statusCode: 200,
      );
      await store.record(
        kind: 'push',
        userId: 'user-1',
        deviceId: 'device-B',
        clientSchemaMajor: 1,
        clientSchemaVersion: 4,
        statusCode: 200,
      );

      final latest = await store.latestPerDevice();
      final byDevice = {for (final e in latest) e.deviceId: e};
      expect(byDevice.keys, {'device-A', 'device-B'});
      expect(byDevice['device-A']!.clientSchemaVersion, 5);
      expect(byDevice['device-B']!.clientSchemaVersion, 4);
    });

    test(
      'a refusal is logged with its status and error code, no row counts',
      () async {
        final store = SyncTrafficLogStore(connection);
        await store.record(
          kind: 'push',
          userId: 'user-1',
          deviceId: 'device-A',
          projectId: 'proj-1',
          statusCode: 409,
          errorCode: 'schema_version_mismatch',
        );

        final entry = (await store.recent()).single;
        expect(entry.statusCode, 409);
        expect(entry.errorCode, 'schema_version_mismatch');
        expect(entry.rowsApplied, 0);
      },
    );
  });
}
