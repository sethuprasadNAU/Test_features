import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'fixtures.dart';

/// Schema v19 (task 11.323, major 6): an estimate may have **no ellipse**.
///
/// **Run against a populated database**, for task 11.243's reason: the one
/// thing this migration does to existing rows — turn a 0 × 0 ellipse into
/// none — is invisible with no rows, and a rebuild that dropped a row or a
/// column would be too.
void main() {
  const t = '2026-09-01T00:00:00.000Z';

  Future<Database> openV18() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 18, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 18);
    return db;
  }

  Map<String, Object?> estimate(
    String id, {
    required double major,
    required double minor,
    required double rotation,
  }) => {
    'position_id': id,
    'project_id': 'project-1',
    'tag_id': 'tag-1',
    'timestamp_local': '2026-09-01T08:00:00.000',
    'timestamp_utc': t,
    'timezone_offset': '-07:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'semi_major_axis': major,
    'semi_minor_axis': minor,
    'rotation_angle': rotation,
    'method': 'lenth_mle',
    'observation_ids_used': '["a","b","c"]',
    'notes': 'kept',
    'created_at': t,
    'updated_at': t,
    'revision': 4,
    'last_modified_by': 'user-1',
    'origin_device_id': 'device-1',
  };

  Future<void> seed(Database db) async {
    await db.insert(Tables.users, sampleUser().toColumns());
    // The model is v20's; this database is v18's, which has no zone column
    // yet (task 11.331), so the row is written in the shape v18 had.
    await db.insert(
      Tables.projects,
      sampleProject().toColumns()..remove('time_zone'),
    );
    await db.insert(Tables.tags, sampleTag(id: 'tag-1').toColumns());
    await db.insert(
      Tables.estimatedPositions,
      estimate('real', major: 220.5, minor: 90.25, rotation: 37.0),
    );
    // What the app wrote for a two-bearing estimate before v19.
    await db.insert(
      Tables.estimatedPositions,
      estimate('two-bearings', major: 0, minor: 0, rotation: 0),
    );
  }

  test('the three ellipse columns become nullable, and nothing else moves',
      () async {
    final db = await openV18();
    await seed(db);
    final before = await db.rawQuery(
      'PRAGMA table_info(${Tables.estimatedPositions})',
    );
    await runMigrations(db, from: 18, to: 19);
    final after = await db.rawQuery(
      'PRAGMA table_info(${Tables.estimatedPositions})',
    );

    expect(
      after.map((c) => c['name']).toList(),
      before.map((c) => c['name']).toList(),
      reason: 'the rebuild keeps every column, in order',
    );
    const ellipse = {'semi_major_axis', 'semi_minor_axis', 'rotation_angle'};
    for (final column in after) {
      final was = before.firstWhere((c) => c['name'] == column['name']);
      expect(
        column['notnull'],
        ellipse.contains(column['name']) ? 0 : was['notnull'],
        reason: '${column['name']}',
      );
      expect(column['pk'], was['pk'], reason: '${column['name']} key');
    }
    final indexes = await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = '${Tables.estimatedPositions}' AND sql IS NOT NULL",
    );
    expect(indexes.map((r) => r['name']).toSet(), {
      'idx_estpositions_project',
      'idx_estpositions_tag',
      'idx_estpositions_ts',
    });
    final references = await db.rawQuery(
      'PRAGMA foreign_key_list(${Tables.estimatedPositions})',
    );
    expect(
      references.map((r) => '${r['table']}.${r['from']}').toSet(),
      {'${Tables.projects}.project_id', '${Tables.tags}.tag_id',
        '${Tables.tags}.project_id'},
    );
    await db.close();
  });

  test('a 0 × 0 ellipse becomes no ellipse, a real one is kept to the digit, '
      'and every other value survives', () async {
    final db = await openV18();
    await seed(db);
    await runMigrations(db, from: 18, to: 19);

    final rows = {
      for (final r in await db.query(Tables.estimatedPositions))
        r['position_id']: r,
    };
    expect(rows.keys.toSet(), {'real', 'two-bearings'});

    final real = rows['real']!;
    expect(real['semi_major_axis'], 220.5);
    expect(real['semi_minor_axis'], 90.25);
    expect(real['rotation_angle'], 37.0);

    final none = rows['two-bearings']!;
    expect(none['semi_major_axis'], isNull);
    expect(none['semi_minor_axis'], isNull);
    expect(none['rotation_angle'], isNull);
    expect(
      RowValidator.validate(Tables.estimatedPositions, none),
      isEmpty,
      reason: 'the rewritten row is one the sync rules now accept',
    );
    expect(
      RowValidator.validate(
        Tables.estimatedPositions,
        estimate('two-bearings', major: 0, minor: 0, rotation: 0),
      ),
      isNotEmpty,
      reason: 'and the row it replaced is one they refuse — the reason the '
          'estimate never synced',
    );

    for (final row in rows.values) {
      expect(row['latitude'], 35.1);
      expect(row['notes'], 'kept');
      expect(row['revision'], 4, reason: 'sync metadata is left alone');
      expect(row['updated_at'], t);
      expect(row['observation_ids_used'], '["a","b","c"]');
    }
    await db.close();
  });
}
