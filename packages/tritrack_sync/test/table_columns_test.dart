import 'package:test/test.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

void main() {
  group('tableSpecs', () {
    test('covers exactly the tables in Tables.all, in the same order', () {
      expect(tableSpecs.map((s) => s.name).toList(), Tables.all);
    });

    test('tableSpecsByName covers every table with no duplicates', () {
      expect(tableSpecsByName.keys.toSet(), Tables.all.toSet());
      expect(tableSpecsByName, hasLength(Tables.all.length));
    });

    test('every table declares at least one primary key column', () {
      for (final spec in tableSpecs) {
        expect(spec.primaryKeyColumns, isNotEmpty, reason: spec.name);
      }
    });

    test('the column specs agree with syncTables about every primary key', () {
      // Two independent declarations of one fact — `tableSpecs` drives the DDL
      // both schemas are generated from, `syncTables` drives every WHERE clause
      // the sync engine builds. Task 10.35 had to change both, and a schema
      // whose keys disagree with the engine's idea of them would produce
      // wrong-row writes rather than an error, so they are pinned together
      // rather than each pinned to a hardcoded list.
      for (final spec in tableSpecs) {
        expect(
          spec.primaryKeyColumns.map((c) => c.name).toList(),
          syncTablesByName[spec.name]!.primaryKey,
          reason: spec.name,
        );
      }
    });

    test('a primary key column is never nullable', () {
      // `project_id` joined six primary keys in task 10.35. It was already
      // `NOT NULL` on all of them — which is what made the migration a pure
      // re-key with no data to backfill — but a key column that could be null
      // would make the key meaningless, so it is asserted rather than assumed.
      for (final spec in tableSpecs) {
        for (final column in spec.primaryKeyColumns) {
          expect(
            spec.isNotNull(column),
            isTrue,
            reason: '${spec.name}.${column.name}',
          );
        }
      }
    });

    test('no table declares a duplicate column name', () {
      for (final spec in tableSpecs) {
        expect(
          spec.columnNames.toSet(),
          hasLength(spec.columns.length),
          reason: '${spec.name} has a duplicate column',
        );
      }
    });

    test('every table carries all six sync columns', () {
      for (final spec in tableSpecs) {
        for (final syncColumn in syncColumns) {
          expect(
            spec.columnNames,
            contains(syncColumn.name),
            reason: '${spec.name} is missing ${syncColumn.name}',
          );
        }
      }
    });

    test('the sync column set is exactly the documented six', () {
      expect(syncColumns.map((c) => c.name).toList(), [
        'created_at',
        'updated_at',
        'deleted_at',
        'revision',
        'last_modified_by',
        'origin_device_id',
      ]);
    });

    test('primary keys are NOT NULL even where declared nullable', () {
      // SQLite lets a bare `TEXT PRIMARY KEY` hold NULL; Postgres does not.
      // The spec takes the stricter reading, so isNotNull must not depend on
      // the `nullable` flag for a primary key.
      for (final spec in tableSpecs) {
        for (final pk in spec.primaryKeyColumns) {
          expect(spec.isNotNull(pk), isTrue, reason: '${spec.name}.${pk.name}');
        }
      }
    });

    test('no server-only column appears in the shared spec', () {
      // Phase 10 invariant 3: a device that has never synced must still write
      // rows fine, so no client-visible declaration may mention these.
      for (final spec in tableSpecs) {
        expect(spec.columnNames, isNot(contains('server_seq')));
        expect(spec.columnNames, isNot(contains('received_at')));
        expect(spec.columnNames, isNot(contains('clock_skew_flag')));
      }
    });

    test('every syncTables descriptor has a matching column spec', () {
      // The two declarations describe the same tables from different angles
      // (merge metadata vs. column shape); a table in one and not the other
      // means the engine would handle a table the schema doesn't define, or
      // vice versa.
      for (final table in syncTables) {
        final spec = tableSpecsByName[table.name];
        expect(spec, isNotNull, reason: 'no column spec for ${table.name}');
        for (final pk in table.primaryKey) {
          expect(
            spec!.columnNames,
            contains(pk),
            reason: '${table.name} primary key $pk not in column spec',
          );
        }
        for (final userColumn in table.userColumns) {
          expect(
            spec!.columnNames,
            contains(userColumn),
            reason: '${table.name} user column $userColumn not in column spec',
          );
        }
        for (final tagColumn in table.tagColumns) {
          expect(
            spec!.columnNames,
            contains(tagColumn),
            reason: '${table.name} tag column $tagColumn not in column spec',
          );
        }
        final scope = table.projectScopeColumn;
        if (scope != null) {
          expect(
            spec!.columnNames,
            contains(scope),
            reason: '${table.name} scope column $scope not in column spec',
          );
        }
      }
    });

    test('syncTables and tableSpecs agree on primary keys', () {
      for (final table in syncTables) {
        final spec = tableSpecsByName[table.name]!;
        expect(
          spec.primaryKeyColumns.map((c) => c.name).toList(),
          table.primaryKey,
          reason: table.name,
        );
      }
    });
  });
}
