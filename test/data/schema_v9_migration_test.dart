import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the on-device upgrade path for schema v9 (task 11.32): the
/// `Tag_Versions` table, its `tag_id` index, and the `tag_version_id` column a
/// bearing gains so that editing a tag stops rewriting history.
///
/// **Written by task 11.124 because it did not exist.** Every other shipped
/// schema version had a populated-database upgrade test and v9 had none, which
/// meant the one migration that adds *both* a table and a column to a
/// high-volume table was covered only by the fresh-build path — and a fresh
/// build never exercises an upgrade at all.
///
/// The point of interest is the bearing that was already on the device.
/// **Nothing backfills `tag_version_id`**: a bearing recorded before this
/// migration genuinely does not know what the tag read at the time, and
/// writing today's answer into it is the exact falsehood task 11.32 exists to
/// remove. So it must come out NULL, and every other value on the row must
/// come out untouched.
void main() {
  const t = '2026-08-25T00:00:00.000Z';

  /// A v8 database, built by running the real migrations rather than by hand,
  /// so this is the shape a device in the field actually has.
  Future<Database> openV8() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 8, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 8);
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
    await db.insert(Tables.observations, {
      'observation_id': 'obs-old',
      'project_id': 'project-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-24T09:00:00.000',
      'timestamp_utc': '2026-08-24T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2,
      'longitude': -111.6,
      'position_source': 'gps',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'bearing',
      'magnetic_bearing': 47.5,
      'true_north_bearing': 58.5,
      'bearing_uncertainty': 5.0,
      'magnetic_declination': 11.0,
      'signal_type': 'continuous',
      'signal_strength': 'strong',
      'notes': 'ridge above the creek',
      'created_at': t,
      'updated_at': t,
      'revision': 3,
    });
  }

  test('a bearing recorded before v9 keeps every value it had, and records '
      '"no version known" rather than being given today\'s', () async {
    final db = await openV8();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 8, to: 9);

    final row = (await db.query(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-old'],
    )).single;

    expect(row['tag_version_id'], isNull);
    // Nothing else moved. The bearing itself is the irreplaceable field
    // record, so this is the assertion the migration exists to survive.
    expect(row['magnetic_bearing'], 47.5);
    expect(row['true_north_bearing'], 58.5);
    expect(row['bearing_uncertainty'], 5.0);
    expect(row['latitude'], 35.2);
    expect(row['longitude'], -111.6);
    expect(row['elevation'], 2100.0);
    expect(row['notes'], 'ridge above the creek');
    expect(row['revision'], 3);
    expect(row['updated_at'], t);
  });

  test('the upgrade brings an empty, usable Tag_Versions table', () async {
    final db = await openV8();
    addTearDown(db.close);
    await seed(db);

    // The table genuinely does not exist beforehand — otherwise this test
    // would pass on a database that had never been upgraded at all.
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='table' AND name=?",
        [Tables.tagVersions],
      ),
      isEmpty,
    );

    await runMigrations(db, from: 8, to: 9);

    expect(await db.query(Tables.tagVersions), isEmpty);

    await db.insert(Tables.tagVersions, {
      'tag_version_id': 'tv-1',
      'tag_id': 'tag-1',
      'effective_from': t,
      'frequency_mhz': 150.325,
      'pulse_rate': 40.0,
      'pulse_pattern': 'steady',
      'tag_name': 'Coco',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final stored = (await db.query(Tables.tagVersions)).single;
    expect(stored['tag_version_id'], 'tv-1');
    expect(stored['tag_name'], 'Coco');
    expect(stored['frequency_mhz'], 150.325);
  });

  test('the index the "what was this bearing recorded against?" read uses '
      'exists after the upgrade', () async {
    final db = await openV8();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 8, to: 9);

    // Named rather than counted: a count passes on the wrong index, which is
    // task 11.45's finding about guards that count artifacts.
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
        ['idx_tag_versions_tag'],
      ),
      hasLength(1),
    );
  });

  test('a bearing written after v9 can name the version it was taken '
      'against', () async {
    final db = await openV8();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 8, to: 9);

    await db.insert(Tables.tagVersions, {
      'tag_version_id': 'tv-1',
      'tag_id': 'tag-1',
      'effective_from': t,
      'frequency_mhz': 150.325,
      'tag_name': 'Coco',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.observations, {
      'observation_id': 'obs-new',
      'project_id': 'project-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-25T09:00:00.000',
      'timestamp_utc': '2026-08-25T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2004,
      'longitude': -111.6008,
      'position_source': 'gps',
      'elevation': 2105.0,
      'altitude_agl': 0.0,
      'observation_type': 'bearing',
      'magnetic_bearing': 51.0,
      'true_north_bearing': 62.0,
      'signal_type': 'continuous',
      'signal_strength': 'weak',
      'tag_version_id': 'tv-1',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final row = (await db.query(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-new'],
    )).single;
    expect(row['tag_version_id'], 'tv-1');
  });
}
