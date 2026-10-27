import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'migration_support.dart';

/// Exercises the on-device upgrade path for schema v3: relaxing the `NOT
/// NULL` on `Observations.tag_id` so a tag-less field note can be recorded.
///
/// SQLite cannot relax a column constraint in place, so this is a
/// create-copy-drop-rename table rebuild — the same risk class as schema
/// v6's rekey (`schema_v6_migration_test.dart`), and the first one this
/// project ever shipped. Task 11.16 exists because a rebuild is exactly the
/// shape that can complete without error while silently losing or shifting a
/// column's values, and until now nothing tested this one against an
/// existing observation at all.
void main() {
  const t = '2026-07-16T18:30:00.000Z';

  Future<Database> openV2() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 2, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 2);
    return db;
  }

  Future<void> seedV2Data(Database db) async {
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.projects, {
      'project_id': 'proj-1',
      'project_name': 'Peaks',
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.tags, {
      'tag_id': 'tag-1',
      'frequency_mhz': 150.125,
      'tag_name': 'Goshawk 12',
      'date_put_on': t,
      'status': 'active',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    // Every column schema v3's rebuild carries forward, populated with a
    // distinct, non-default value each so a column shifted into the wrong
    // slot by a rebuild bug cannot hide behind a shared default.
    await db.insert(Tables.observations, {
      'observation_id': 'obs-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-07-16T11:30:00.000',
      'timestamp_utc': t,
      'timezone_offset': '-07:00',
      'latitude': 35.19,
      'longitude': -111.62,
      'position_accuracy_m': 4.2,
      'position_source': 'gps_fix',
      'elevation': 2103.0,
      'altitude_agl': 1.5,
      'observation_type': 'directional',
      'magnetic_bearing': 145.0,
      'true_north_bearing': 152.3,
      'bearing_uncertainty': 3.0,
      'bearing_capture_method': 'manual',
      'bearing_method': 'point',
      'signal_type': 'pulse',
      'signal_strength': 'strong',
      'bearing_quality': 'good',
      'notes': 'strong steady pulse',
      'created_at': t,
      'updated_at': t,
      'revision': 3,
    });
  }

  test('an existing observation survives the rebuild with every value intact',
      () async {
    final db = await openV2();
    await seedV2Data(db);

    final before = (await db.query(Tables.observations)).single;

    await runMigrations(db, from: 2, to: lastVersionBeforeTheWipe);

    final after = await db.query(Tables.observations);
    expect(after, hasLength(1));
    // Column-for-column against the pre-migration row, not a hand-picked
    // subset — a rebuild that shifted values between columns would still
    // pass a check that only re-read a few fields.
    for (final column in before.keys) {
      expect(
        after.single[column],
        before[column],
        reason: 'observations.$column changed during the v3 rebuild',
      );
    }

    await db.close();
  });

  test(
    'the point of the migration actually took effect: a tag-less observation '
    'can now be recorded',
    () async {
      final db = await openV2();
      await seedV2Data(db);
      await runMigrations(db, from: 2, to: lastVersionBeforeTheWipe);
      await db.execute('PRAGMA foreign_keys = ON');

      // Before v3 this insert would violate `tag_id NOT NULL`. Surviving
      // rows are necessary but not sufficient — the schema change itself has
      // to have landed, which "the old row is untouched" alone cannot prove.
      await db.insert(Tables.observations, {
        'observation_id': 'obs-2',
        'project_id': 'proj-1',
        'user_id': 'user-1',
        'tag_id': null,
        'timestamp_local': '2026-07-16T12:00:00.000',
        'timestamp_utc': t,
        'timezone_offset': '-07:00',
        'latitude': 35.20,
        'longitude': -111.63,
        'position_source': 'gps_fix',
        'elevation': 2100.0,
        'altitude_agl': 0.0,
        'observation_type': 'note',
        'signal_type': 'none',
        'signal_strength': 'none',
        'notes': 'fresh tracks, no collar heard',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });

      final noteRow = (await db.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: ['obs-2'],
      )).single;
      expect(noteRow['tag_id'], isNull);

      await db.close();
    },
  );

  test('the four indexes dropped with the old table are recreated', () async {
    final db = await openV2();
    await seedV2Data(db);
    await runMigrations(db, from: 2, to: lastVersionBeforeTheWipe);

    final indexes = (await db.rawQuery(
      "SELECT name FROM sqlite_master WHERE type = 'index' "
      "AND tbl_name = '${Tables.observations}'",
    )).map((r) => r['name']).toSet();
    expect(
      indexes,
      containsAll({
        'idx_observations_project',
        'idx_observations_tag',
        'idx_observations_ts',
        'idx_observations_session',
      }),
    );

    await db.close();
  });
}
