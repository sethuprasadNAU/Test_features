import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the on-device upgrade path for schema v11 (task 11.93): the two
/// columns a ground-truth point gains — **who walked in and found it**, and
/// **how its coordinate was got**.
///
/// The point of interest is the row that was already on the device. **Nothing
/// backfills either column**, and the temptation to is specific and named: the
/// row carries `last_modified_by`, and using it would produce an author that
/// looks like a fact and is a guess. A point recorded before this migration
/// genuinely does not know who found it or whether its coordinate came from a
/// fix, so both come out NULL and every screen reads NULL as "not recorded".
void main() {
  const t = '2026-08-31T00:00:00.000Z';

  /// A v10 database, built by running the real migrations rather than by hand,
  /// so this is the shape a device in the field actually has.
  Future<Database> openV10() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 10, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 10);
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
      'tag_name': 'Coco',
      'date_put_on': t,
      'status': 'active',
      'color_hex': '#4C9F70',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.actualTagLocations, {
      'location_id': 'loc-old',
      'project_id': 'project-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-30T09:00:00.000',
      'timestamp_utc': '2026-08-30T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2,
      'longitude': -111.6,
      'uncertainty_radius': 15.0,
      'notes': 'found collar',
      'found_kind': 'animal_and_collar',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
      // The value a backfill would have reached for. It names whoever last
      // *touched* the row, which is not who found the collar.
      'last_modified_by': 'user-1',
    });
  }

  test('a truth point recorded before v11 keeps every value it had, and '
      'records "not recorded" for both new columns', () async {
    final db = await openV10();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 10, to: 11);

    final row = (await db.query(
      Tables.actualTagLocations,
      where: 'location_id = ?',
      whereArgs: ['loc-old'],
    )).single;

    expect(
      row['user_id'],
      isNull,
      reason: 'the row knows who last touched it and that is not who found '
          'the collar — an author backfilled from it would be a guess wearing '
          "a fact's clothing",
    );
    expect(row['user_id'], isNot('user-1'));
    expect(
      row['position_source'],
      isNull,
      reason: 'nobody recorded whether this coordinate was measured at the '
          'collar or eyeballed across 200 m of savannah, and "gps_fix" would '
          'claim they had',
    );
    // Nothing else moved.
    expect(row['found_kind'], 'animal_and_collar');
    expect(row['uncertainty_radius'], 15.0);
    expect(row['latitude'], 35.2);
    expect(row['notes'], 'found collar');
    expect(row['revision'], 0);
    expect(row['updated_at'], t);
    expect(row['last_modified_by'], 'user-1');
  });

  test('a truth point written after v11 can carry both, including a fix that '
      'was later moved by hand', () async {
    final db = await openV10();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 10, to: 11);

    await db.insert(Tables.actualTagLocations, {
      'location_id': 'loc-new',
      'project_id': 'project-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-31T09:00:00.000',
      'timestamp_utc': '2026-08-31T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2004,
      'longitude': -111.6008,
      'uncertainty_radius': 4.0,
      'found_kind': 'animal_and_collar',
      'user_id': 'user-1',
      'position_source': 'gps_fix_adjusted',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final row = (await db.query(
      Tables.actualTagLocations,
      where: 'location_id = ?',
      whereArgs: ['loc-new'],
    )).single;
    expect(row['user_id'], 'user-1');
    expect(row['position_source'], 'gps_fix_adjusted');
  });

  test('a truth point may name a finder this device does not hold', () async {
    final db = await openV10();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 10, to: 11);

    // **Deliberately no foreign key on `user_id`**, unlike
    // `Observations.user_id`. SQLite cannot add one with `ALTER TABLE` — it
    // needs the whole-table rebuild schema v6 did, on every device in the
    // field — and the server's naming invariant already refuses any finder but
    // the authenticated caller. This asserts the absence rather than leaving it
    // to be rediscovered as a gap.
    await db.insert(Tables.actualTagLocations, {
      'location_id': 'loc-foreign',
      'project_id': 'project-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-31T09:00:00.000',
      'timestamp_utc': '2026-08-31T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2004,
      'longitude': -111.6008,
      'uncertainty_radius': 4.0,
      'user_id': 'user-not-here',
      'position_source': 'manual_pin',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final row = (await db.query(
      Tables.actualTagLocations,
      where: 'location_id = ?',
      whereArgs: ['loc-foreign'],
    )).single;
    expect(row['user_id'], 'user-not-here');
  });
}
