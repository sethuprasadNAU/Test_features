import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/models/project.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Schema v18 (task 11.56): `Projects` gains the provenance pair.
///
/// **Run against a populated database**, for task 11.243's reason: a
/// migration test on an empty one is a syntax check wearing a test's
/// clothes. The one thing this migration *does* to existing rows — write
/// each project's lineage as its own id — is invisible with no rows.
void main() {
  const t = '2026-09-01T00:00:00.000Z';

  Future<Database> openV17() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 17, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 17);
    return db;
  }

  Future<void> seed(Database db) async {
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    for (final id in ['ponui-2024', 'ponui-2025']) {
      await db.insert(Tables.projects, {
        'project_id': id,
        'project_name': id,
        'owner_user_id': 'user-1',
        'creation_date': t,
        'datum': 'WGS84',
        'coordinate_format': 'dd',
        'triangulation_window_minutes': 15,
        'created_at': t,
        'updated_at': t,
        'revision': 3,
      });
    }
  }

  test(
    'a v17 database has no lineage column, and the migration adds both',
    () async {
      final db = await openV17();
      await seed(db);
      final before = await db.rawQuery('PRAGMA table_info(${Tables.projects})');
      expect(before.map((c) => c['name']), isNot(contains('lineage_id')));

      await runMigrations(db, from: 17, to: 18);

      final after = await db.rawQuery('PRAGMA table_info(${Tables.projects})');
      final names = after.map((c) => c['name']).toList();
      expect(names, containsAll(['lineage_id', 'copied_at']));
      // Appended, which is where the shared spec declares them — the schema
      // test compares declaration order, and this is the reason it can.
      expect(names.sublist(names.length - 2), ['lineage_id', 'copied_at']);
      for (final column in after.where(
        (c) => c['name'] == 'lineage_id' || c['name'] == 'copied_at',
      )) {
        expect(column['notnull'], 0, reason: 'a minor may not add NOT NULL');
      }
      await db.close();
    },
  );

  test('every existing project becomes the first of its own line, and is '
      'not marked as copied', () async {
    final db = await openV17();
    await seed(db);
    await runMigrations(db, from: 17, to: 18);
    final rows = await db.query(Tables.projects, orderBy: 'project_id');
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row['lineage_id'], row['project_id']);
      expect(row['copied_at'], isNull);
      // Nothing else on the row moved: not a write anybody made.
      expect(row['revision'], 3);
      expect(row['updated_at'], t);
      final project = Project.fromRow(row);
      expect(project.effectiveLineageId, project.projectId);
    }
    await db.close();
  });

  test('a row that arrives with a null lineage — an older peer\'s — reads as '
      'its own line', () async {
    final db = await openV17();
    await runMigrations(db, from: 17, to: 18);
    await db.insert(Tables.projects, {
      'project_id': 'from-a-v17-phone',
      'project_name': 'x',
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    final project = Project.fromRow((await db.query(Tables.projects)).single);
    expect(project.lineageId, isNull);
    expect(project.effectiveLineageId, 'from-a-v17-phone');
    await db.close();
  });

  test('the model round-trips the pair', () async {
    final db = await openV17();
    await runMigrations(db, from: 17, to: 18);
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    final copied = DateTime.utc(2026, 9, 15, 10);
    final row = Project.fromRow({
      'project_id': 'ponui-2026',
      'project_name': 'Ponui 2026',
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'lineage_id': 'ponui-2025',
      'copied_at': copied.toIso8601String(),
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    // The model is v20's; this database is v18's, which has no zone column
    // yet (task 11.331), so the row is written in the shape v18 had.
    await db.insert(Tables.projects, row.toColumns()..remove('time_zone'));
    final back = Project.fromRow((await db.query(Tables.projects)).single);
    expect(back.lineageId, 'ponui-2025');
    expect(back.effectiveLineageId, 'ponui-2025');
    expect(back.copiedAt, copied);
    await db.close();
  });
}
