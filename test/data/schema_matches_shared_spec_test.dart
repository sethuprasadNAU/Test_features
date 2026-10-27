import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// The drift guard between the app's SQLite schema and the canonical column
/// set in `package:tritrack_sync` (task 10.5).
///
/// The app's DDL strings stay SQLite-specific and are never edited once
/// shipped, and the server writes Postgres — so the two schemas are
/// necessarily *separate code*. `tableSpecs` is the one declaration both are
/// checked against, which is what stops them diverging silently. Without this
/// test the shared spec would be documentation rather than a guarantee.
///
/// If this fails after you add a column: append it to `tableSpecs`, add the
/// migration on *both* sides (app `migrations.dart`, server
/// `postgres_migrations.dart`), and bump `latestSchemaVersion`.
void main() {
  late Database db;

  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(
        version: latestSchemaVersion,
        singleInstance: false,
      ),
    );
    await runMigrations(db, from: 0, to: latestSchemaVersion);
  });

  tearDown(() => db.close());

  /// `PRAGMA table_info` maps SQLite's declared type back onto the shared
  /// spec's three-way [ColumnType].
  ColumnType typeFromSqlite(String declared) =>
      switch (declared.toUpperCase()) {
        'TEXT' => ColumnType.text,
        'REAL' => ColumnType.real,
        'INTEGER' => ColumnType.integer,
        _ => throw StateError('unmapped SQLite type "$declared"'),
      };

  test('every table in the shared spec exists in the SQLite schema', () async {
    final rows = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'",
    );
    final actual = rows.map((r) => r['name'] as String).toSet();
    expect(actual, containsAll(tableSpecs.map((s) => s.name)));
  });

  test('the shared spec covers exactly the tables the app creates', () {
    expect(tableSpecs.map((s) => s.name).toList(), Tables.all);
  });

  for (final spec in tableSpecs) {
    group(spec.name, () {
      test('column names and order match the shared spec', () async {
        final info = await db.rawQuery('PRAGMA table_info(${spec.name})');
        final actual = info.map((c) => c['name'] as String).toList();
        expect(actual, spec.columnNames.toList());
      });

      test('column types match the shared spec', () async {
        final info = await db.rawQuery('PRAGMA table_info(${spec.name})');
        for (final col in info) {
          final name = col['name'] as String;
          final declared = typeFromSqlite(col['type'] as String);
          final expected = spec.columns.firstWhere((c) => c.name == name);
          expect(declared, expected.type, reason: '${spec.name}.$name type');
        }
      });

      test('nullability matches the shared spec', () async {
        final info = await db.rawQuery('PRAGMA table_info(${spec.name})');
        for (final col in info) {
          final name = col['name'] as String;
          final expected = spec.columns.firstWhere((c) => c.name == name);
          // SQLite quirk: a bare `TEXT PRIMARY KEY` reports notnull=0 and
          // genuinely does accept NULL (only INTEGER PRIMARY KEY, the rowid
          // alias, is implicitly NOT NULL). The shared spec takes Postgres's
          // stricter reading, so primary keys are exempted from this
          // comparison rather than the spec being loosened to match SQLite's
          // leniency — see TableSpec.isNotNull.
          if (expected.primaryKey) continue;
          final actualNotNull = (col['notnull'] as int) == 1;
          expect(
            actualNotNull,
            spec.isNotNull(expected),
            reason: '${spec.name}.$name nullability',
          );
        }
      });

      test('primary key columns match the shared spec', () async {
        final info = await db.rawQuery('PRAGMA table_info(${spec.name})');
        final actualPk = info.where((c) => (c['pk'] as int) > 0).toList()
          ..sort((a, b) => (a['pk'] as int).compareTo(b['pk'] as int));
        expect(
          actualPk.map((c) => c['name'] as String).toList(),
          spec.primaryKeyColumns.map((c) => c.name).toList(),
        );
      });
    });
  }

  test(
    'no server-only column leaks into the shared spec (Phase 10 invariant 3)',
    () {
      // `server_seq` and `received_at` are server bookkeeping. If either ever
      // appears here, a client could come to depend on it and a never-synced
      // device would stop being able to write rows.
      for (final spec in tableSpecs) {
        expect(spec.columnNames, isNot(contains('server_seq')));
        expect(spec.columnNames, isNot(contains('received_at')));
      }
    },
  );
}
