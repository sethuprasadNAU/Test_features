import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// Exercises the on-device upgrade path for schema v2 (Phase 4): two Project
/// Setup fields, `coordinate_format` and `triangulation_window_minutes`,
/// added by additive `ALTER TABLE ... DEFAULT`.
///
/// Additive `ALTER TABLE` is the lowest-risk migration shape in this set, but
/// task 11.16 exists precisely because "low risk" is not the same claim as
/// "tested" — nothing before this file ever ran it against a database that
/// already had a project in it.
void main() {
  const t = '2026-07-16T18:30:00.000Z';

  test(
    'upgrading a v1 database preserves an existing project and backfills '
    'the new columns with their defaults',
    () async {
      sqfliteFfiInit();
      final db = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(version: 1, singleInstance: false),
      );
      await runMigrations(db, from: 0, to: 1);

      await db.insert(Tables.users, {
        'user_id': 'user-1',
        'first_name': 'Sam',
        'last_name': 'Ranger',
        'email': 'sam@example.com',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });
      // Schema v1's Projects has no coordinate_format or
      // triangulation_window_minutes column yet — this is the row shape a
      // real pre-Phase-4 device would have on disk.
      await db.insert(Tables.projects, {
        'project_id': 'proj-1',
        'project_name': 'Peaks',
        'owner_user_id': 'user-1',
        'creation_date': t,
        'datum': 'WGS84',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });

      await runMigrations(db, from: 1, to: latestSchemaVersion);

      final rows = await db.query(Tables.projects);
      expect(rows, hasLength(1));
      final project = rows.single;
      // Every pre-existing value untouched.
      expect(project['project_id'], 'proj-1');
      expect(project['project_name'], 'Peaks');
      expect(project['owner_user_id'], 'user-1');
      expect(project['datum'], 'WGS84');
      // The two new columns backfilled with the migration's own defaults,
      // not left null or some other placeholder.
      expect(project['coordinate_format'], 'dd');
      expect(project['triangulation_window_minutes'], 15);

      await db.close();
    },
  );
}
