import 'package:flutter_test/flutter_test.dart';
import 'package:tritrack/data/db/app_database.dart';
import 'package:tritrack/data/db/schema.dart';

void main() {
  late AppDatabase database;

  setUp(() async {
    database = await AppDatabase.openInMemory();
  });

  tearDown(() async {
    await database.close();
  });

  // The six global sync/merge columns that must exist on every table.
  const syncColumns = {
    'created_at',
    'updated_at',
    'deleted_at',
    'revision',
    'last_modified_by',
    'origin_device_id',
  };

  test('all specified tables are created', () async {
    final rows = await database.raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    );
    final names = rows.map((r) => r['name'] as String).toSet();
    for (final table in Tables.all) {
      expect(names, contains(table), reason: 'missing table $table');
    }
  });

  test('every table carries the six sync/merge columns', () async {
    for (final table in Tables.all) {
      final info = await database.raw.rawQuery('PRAGMA table_info($table)');
      final columns = info.map((r) => r['name'] as String).toSet();
      expect(
        columns.containsAll(syncColumns),
        isTrue,
        reason: 'table $table is missing sync columns: '
            '${syncColumns.difference(columns)}',
      );
    }
  });

  test('required indexes exist', () async {
    final rows = await database.raw.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'",
    );
    final indexes = rows.map((r) => r['name'] as String).toSet();
    // The spec-required high-volume indexes plus the email dedup index.
    const required = {
      'idx_users_email',
      'idx_observations_project',
      'idx_observations_tag',
      'idx_observations_ts',
      'idx_nondetections_project',
      'idx_nondetections_ts',
      'idx_estpositions_project',
      'idx_estpositions_tag',
      'idx_estpositions_ts',
    };
    expect(indexes.containsAll(required), isTrue,
        reason: 'missing indexes: ${required.difference(indexes)}');
  });

  test('foreign key enforcement is ON for the connection', () async {
    final result = await database.raw.rawQuery('PRAGMA foreign_keys');
    expect(result.first.values.first, 1);
  });

  test('user_version matches the schema version', () async {
    final result = await database.raw.rawQuery('PRAGMA user_version');
    expect(result.first.values.first, AppDatabase.schemaVersion);
    expect(AppDatabase.schemaVersion, greaterThanOrEqualTo(1));
  });
}
