import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/models/observation.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The on-device upgrade to schema v13 (task 11.193): the flag saying the
/// signal itself sounded wrong.**
///
/// One nullable column, so the migration has almost nothing to get wrong — and
/// the one thing it could get wrong is the thing this file is for. **A bearing
/// recorded before this column existed must come out of the migration saying
/// nothing**, not saying `0`. A `0` would mean *somebody listened and heard
/// nothing wrong*, which is a claim nobody made, and the whole use of this flag
/// is to find collars that are failing — so a season of invented "sounded fine"
/// rows is exactly what would hide one.
///
/// The `1 = flagged, 0 = not flagged, NULL = nobody was asked` reading has to
/// survive the round trip through [Observation] as well, because that is where
/// every screen and every export gets it from.
void main() {
  const t = '2026-09-07T00:00:00.000Z';

  /// A v12 database built by running the real migrations, so this is the shape
  /// a device in the field actually has rather than a hand-written
  /// approximation of one.
  Future<Database> openV12() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 12, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 12);
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
    await db.insert(Tables.projects, {
      'project_id': 'project-1',
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
      'frequency_mhz': 150.325,
      'pulse_rate': 52.0,
      'tag_name': 'Coco',
      'date_put_on': t,
      'status': 'active',
      'color_hex': '#4C9F70',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.observations, {
      'observation_id': 'obs-1',
      'project_id': 'project-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-09-06T09:00:00.000',
      'timestamp_utc': '2026-09-06T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2,
      'longitude': -111.6,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'magnetic_bearing': 47.5,
      'true_north_bearing': 58.5,
      'bearing_uncertainty': 5.0,
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'notes': 'ridge above the creek',
      'pulse_mode': 1,
      'created_at': t,
      'updated_at': t,
      'revision': 3,
    });
  }

  test('a bearing recorded before the flag existed says nothing, not "no"',
      () async {
    final db = await openV12();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 12, to: 13);

    final row = (await db.query(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-1'],
    )).single;

    expect(
      row['signal_irregular'],
      isNull,
      reason: 'The observer who took this bearing was never shown the control, '
          'so the database cannot know whether the pulses sounded even. '
          'Writing 0 here would say they listened and heard nothing wrong — a '
          'claim nobody made, in the one column whose whole purpose is finding '
          'the collars that are failing.',
    );
    expect(
      Observation.fromRow(row).signalIrregular,
      isNull,
      reason: 'And it must read back as "not recorded" rather than as false: '
          'every screen and the CSV export get their answer from here.',
    );
  });

  test('nothing else on the row moved', () async {
    final db = await openV12();
    addTearDown(db.close);
    await seed(db);

    final before = (await db.query(Tables.observations)).single;
    await runMigrations(db, from: 12, to: 13);
    final after = (await db.query(Tables.observations)).single;

    // The new column is the only difference. Compared as whole maps rather
    // than field by field, so a value this migration was never supposed to
    // touch cannot go quietly missing from the comparison.
    expect(
      Map<String, Object?>.from(after)..remove('signal_irregular'),
      before,
    );
  });

  test('all three answers survive the round trip through Observation',
      () async {
    final db = await openV12();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 12, to: 13);

    final base = Observation.fromRow(
      (await db.query(Tables.observations)).single,
    );

    for (final (id, flag, stored) in <(String, bool?, Object?)>[
      ('obs-flagged', true, 1),
      ('obs-clear', false, 0),
      ('obs-unasked', null, null),
    ]) {
      await db.insert(
        Tables.observations,
        base.copyWith(observationId: id, signalIrregular: flag).toColumns(),
      );
      final row = (await db.query(
        Tables.observations,
        where: 'observation_id = ?',
        whereArgs: [id],
      )).single;
      expect(row['signal_irregular'], stored,
          reason: 'SQLite has no boolean; 1 and 0 are the stored form, and '
              'NULL is a third answer rather than a missing one.');
      expect(Observation.fromRow(row).signalIrregular, flag);
    }
  });
}
