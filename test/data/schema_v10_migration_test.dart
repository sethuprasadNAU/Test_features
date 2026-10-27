import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the on-device upgrade path for schema v10 (task 11.33): the two
/// columns a ground-truth point gains — **what was found**, and **what the tag
/// read at the time**.
///
/// The point of interest is what happens to a point that was already on the
/// device. Nothing backfills either column: a truth point recorded before this
/// migration genuinely does not know whether the animal was there or only the
/// collar, and writing today's tag reading into it would be the same falsehood
/// task 11.32 removed from bearings. So both must come out NULL, and the rest
/// of the row must come out untouched.
void main() {
  const t = '2026-08-31T00:00:00.000Z';

  /// A v9 database, built by running the real migrations rather than by hand,
  /// so this is the shape a device in the field actually has.
  Future<Database> openV9() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 9, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 9);
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
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
  }

  test('a truth point recorded before v10 keeps every value it had, and '
      'records "not recorded" for both new columns', () async {
    final db = await openV9();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 9, to: 10);

    final row = (await db.query(
      Tables.actualTagLocations,
      where: 'location_id = ?',
      whereArgs: ['loc-old'],
    )).single;

    expect(row['found_kind'], isNull);
    expect(row['tag_version_id'], isNull);
    // Nothing else moved.
    expect(row['uncertainty_radius'], 15.0);
    expect(row['latitude'], 35.2);
    expect(row['notes'], 'found collar');
    expect(row['revision'], 0);
    expect(row['updated_at'], t);
  });

  test('a truth point written after v10 can carry both', () async {
    final db = await openV9();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 9, to: 10);

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
      'tag_version_id': 'tag-version-1',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final row = (await db.query(
      Tables.actualTagLocations,
      where: 'location_id = ?',
      whereArgs: ['loc-new'],
    )).single;
    expect(row['found_kind'], 'animal_and_collar');
    // Deliberately no foreign key: sync can deliver the point before the
    // `Tag_Versions` row it names, and an unresolvable reference must be inert
    // rather than a row this device refuses. Nothing here creates that version.
    expect(row['tag_version_id'], 'tag-version-1');
  });
}
