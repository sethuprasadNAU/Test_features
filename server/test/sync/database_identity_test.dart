@Tags(['postgres'])
library;

import 'dart:io';

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';

import '../support/database_test_config.dart';

/// Task 11.58: the identifier that tells a device which database answered.
///
/// Two halves, and only the second needs Postgres:
///
/// - **the scripts** — a restore must not inherit the identifier, and the two
///   shell scripts that make sure of it cannot import
///   [databaseIdentityTable], so this reads them and fails if either stops
///   naming it. A renamed table with scripts still naming the old one would
///   make every restore look like the original to every device, silently.
/// - **the mint** — once, stable across restarts, and fresh when the row is
///   gone, which is the state a restore leaves behind.
void main() {
  group('the backup scripts keep a restore from inheriting it', () {
    // Run from `server/`, which is where `dart test` runs this suite.
    String read(String path) => File(path).readAsStringSync();

    test('backup.sh leaves the row out of every archive', () {
      expect(
        read('backup/backup.sh'),
        contains('--exclude-table-data=$databaseIdentityTable'),
      );
    });

    test('restore.sh empties it before promoting a restore', () {
      final script = read('backup/restore.sh');
      expect(script, contains('DELETE FROM $databaseIdentityTable'));
      // Before the swap, not after: once promoted, the restored database is
      // the live one, and a server started in between would hand the old
      // identifier to every device that asked.
      expect(
        script.indexOf('DELETE FROM $databaseIdentityTable'),
        lessThan(script.indexOf('# SWAP.')),
      );
    });
  });

  group('the mint', skip: databaseSkipReason, () {
    late Connection connection;
    const testSchema = 'tritrack_database_identity_test';

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
      await PostgresMigrations.run(connection, log: (_) {});
    });

    Future<List<String>> rows() async => [
      for (final row in await connection.execute(
        'SELECT database_id FROM $databaseIdentityTable',
      ))
        row.first! as String,
    ];

    test('a new database gets exactly one, when its schema is built', () async {
      final ids = await rows();
      expect(ids, hasLength(1));
      expect(ids.single, isNotEmpty);
      expect(await readDatabaseIdentity(connection), ids.single);
    });

    test('a restart does not change it', () async {
      final before = await readDatabaseIdentity(connection);
      // What every start does: `_ensureServerOnlyTables` runs again.
      await PostgresMigrations.run(connection, log: (_) {});
      await PostgresMigrations.run(connection, log: (_) {});
      expect(await rows(), [before]);
    });

    test('a database left without one — what a restore leaves — gets a new '
        'one on the next start', () async {
      final original = await readDatabaseIdentity(connection);
      // The state `backup.sh`'s archive restores to, and the state
      // `restore.sh` leaves an archive from anywhere else in.
      await connection.execute('DELETE FROM $databaseIdentityTable');
      await PostgresMigrations.run(connection, log: (_) {});
      final minted = await rows();
      expect(minted, hasLength(1));
      expect(minted.single, isNot(original));
    });

    test('and a request that finds none mints one rather than answering '
        'without it', () async {
      // Without a start in between. A null on the wire reads to a device as
      // "this server predates the field", which keeps its old bookmark — the
      // wrong answer for a database that has lost its identifier.
      final original = await readDatabaseIdentity(connection);
      await connection.execute('DELETE FROM $databaseIdentityTable');
      final minted = await readDatabaseIdentity(connection);
      expect(minted, isNot(original));
      expect(await readDatabaseIdentity(connection), minted);
      expect(await rows(), [minted]);
    });
  });
}
