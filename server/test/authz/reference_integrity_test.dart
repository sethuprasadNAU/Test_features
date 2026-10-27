@Tags(['postgres'])
library;

import 'package:postgres/postgres.dart';
import 'package:test/test.dart';
import 'package:tritrack_server/tritrack_server.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import '../support/database_test_config.dart';

/// **Task 11.46.** Guards the two assumptions
/// `RowAuthorizer._authorizeReferences` rests on.
///
/// That check refuses a row whose foreign key would dangle, so that a
/// reference to a refused row costs one row instead of the whole request. It
/// is derived from [foreignKeys] and it relies on `syncTables` being in
/// foreign-key-safe order. Neither of those is a thing a person has to
/// remember here — both are asserted below, against the database that is
/// actually built and against the table list that is actually iterated.
///
/// **Why a guard and not a comment.** The per-key argument for why this check
/// cannot become an existence oracle (see its doc) is written one foreign key
/// at a time. A foreign key added later inherits the *check* automatically and
/// the *argument* not at all — so the first test here fails when the schema
/// gains one that [foreignKeys] does not declare, which is the moment somebody
/// has to extend the argument. This is the same shape as task 11.45's rule
/// that a guard must derive what it measures rather than count artifacts.
void main() {
  late Connection connection;
  const testSchema = 'tritrack_reference_integrity_test';

  setUpAll(() async {
    if (testDatabaseConfig == null) return;
    connection = await Connection.open(
      testDatabaseConfig!.endpoint,
      settings: const ConnectionSettings(sslMode: SslMode.disable),
    );
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.execute('CREATE SCHEMA $testSchema');
    await connection.execute('SET search_path TO $testSchema');
    await PostgresMigrations.run(connection);
  });

  tearDownAll(() async {
    if (testDatabaseConfig == null) return;
    await connection.execute('DROP SCHEMA IF EXISTS $testSchema CASCADE');
    await connection.close();
  });

  group('reference integrity', skip: databaseSkipReason, () {
    test(
      'every foreign key the database actually has is declared in '
      'foreignKeys — so none can reach the reference check unreasoned',
      () async {
        // Read back from the migrated database rather than from the DDL
        // strings: what the check has to cover is what Postgres will enforce
        // at COMMIT, and a constraint added by a migration rather than by
        // `schemaStatements()` counts exactly the same.
        final result = await connection.execute("""
          SELECT
            child.relname AS from_table,
            parent.relname AS to_table,
            (SELECT string_agg(att.attname, ',' ORDER BY k.ord)
               FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_attribute att
                 ON att.attrelid = con.conrelid AND att.attnum = k.attnum)
              AS from_columns,
            (SELECT string_agg(att.attname, ',' ORDER BY k.ord)
               FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
               JOIN pg_attribute att
                 ON att.attrelid = con.confrelid AND att.attnum = k.attnum)
              AS to_columns
          FROM pg_constraint con
          JOIN pg_class child ON child.oid = con.conrelid
          JOIN pg_class parent ON parent.oid = con.confrelid
          JOIN pg_namespace ns ON ns.oid = child.relnamespace
          WHERE con.contype = 'f' AND ns.nspname = '$testSchema'
        """);

        // Only constraints on **synced** tables are this check's business:
        // `_authorizeReferences` runs on a pushed row, and the server's own
        // auth tables (`auth_accounts`, `auth_sessions`) are never pushed —
        // no request writes them and no foreign key crosses between the two
        // sets. Derived from `syncTables` rather than named, so a table that
        // becomes synced is covered without an edit here. This narrowing is
        // load-bearing and was found by running the guard: it reported
        // `auth_sessions(user_id) -> auth_accounts(user_id)` on its first run.
        final syncedTableNames = {for (final t in syncTables) t.name};
        final inDatabase = <String>{};
        for (final row in result) {
          final map = row.toColumnMap();
          if (!syncedTableNames.contains(map['from_table'])) continue;
          inDatabase.add(
            '${map['from_table']}(${map['from_columns']}) -> '
            '${map['to_table']}(${map['to_columns']})',
          );
        }

        final declared = {
          for (final fk in foreignKeys)
            '${fk.$1}(${fk.$2.join(',')}) -> ${fk.$3}(${fk.$4.join(',')})',
        };

        expect(
          inDatabase.difference(declared),
          isEmpty,
          reason:
              'The database enforces a foreign key that `foreignKeys` does '
              'not declare, so `RowAuthorizer._authorizeReferences` will not '
              'check it — and a row that dangles it will take the whole push '
              'down at COMMIT with an unexplained error, which is exactly the '
              'failure task 11.46 closed. Declare it, and extend that '
              "method's per-key argument for why checking it discloses "
              'nothing.',
        );
        expect(
          declared.difference(inDatabase),
          isEmpty,
          reason:
              '`foreignKeys` declares a constraint the database does not '
              'have. The reference check would then refuse rows Postgres '
              'would have accepted.',
        );
        // Fails loudly rather than passing vacuously if the query above ever
        // stops returning anything.
        expect(inDatabase, isNotEmpty);
      },
    );

    test(
      'syncTables is in foreign-key-safe order, which is what lets a '
      'referent be decided before the rows pointing at it',
      () {
        final position = {
          for (var i = 0; i < syncTables.length; i++) syncTables[i].name: i,
        };
        for (final fk in foreignKeys) {
          final from = position[fk.$1];
          final to = position[fk.$3];
          // A foreign key onto a table sync does not carry at all is not this
          // guard's business; there are none today, and one would be caught by
          // the test above.
          if (from == null || to == null) continue;
          // Self-references are vacuously ordered.
          if (fk.$1 == fk.$3) continue;
          expect(
            to,
            lessThan(from),
            reason:
                '${fk.$1} references ${fk.$3}, but syncTables lists '
                '${fk.$3} after it. `RowAuthorizer` judges rows in that '
                'order and records what it has allowed as it goes, so a '
                'referent listed later has not been decided yet — every row '
                'of ${fk.$1} would be refused as a dangling reference on a '
                'push that carries both.',
          );
        }
      },
    );
  });
}
