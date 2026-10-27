import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

/// Exercises the on-device upgrade path for schema v7 (task 11.7):
/// `Observation_Exclusions`, a purely additive new table.
///
/// Purely additive is the lowest-risk migration shape, but it was still
/// untested as an upgrade before task 11.16 — this closes that for the same
/// reason the v2 and v5 tests do: "additive, so obviously safe" is a claim,
/// not a check.
void main() {
  const t = '2026-08-21T00:00:00.000Z';

  test('upgrading a v6 database preserves an existing observation and adds a '
      'usable Observation_Exclusions table', () async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 6, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 6);

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
      'color_hex': '#FF0000',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.observations, {
      'observation_id': 'obs-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-08-21T11:30:00.000',
      'timestamp_utc': t,
      'timezone_offset': '-07:00',
      'latitude': 35.19,
      'longitude': -111.62,
      'position_source': 'gps_fix',
      'elevation': 2103.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'magnetic_bearing': 145.0,
      'signal_type': 'pulse',
      'signal_strength': 'strong',
      'notes': 'strong steady pulse',
      'created_at': t,
      'updated_at': t,
      'revision': 3,
    });

    final before = (await db.query(Tables.observations)).single;

    await runMigrations(db, from: 6, to: 7);

    final after = await db.query(Tables.observations);
    expect(after, hasLength(1));
    // Every column that existed at v6, unchanged. Columns added by a later
    // migration are subtracted and checked below — this runs 6 → latest.
    final carried = Map<String, Object?>.of(after.single)
      ..removeWhere((column, _) => !before.containsKey(column));
    expect(
      carried,
      before,
      reason: 'the observation changed during the upgrade',
    );
    // Schema v9 (task 11.32): added, and deliberately not backfilled.
    expect(
      after.single['tag_version_id'],
      isNull,
      reason:
          'an observation older than Tag_Versions must read "not '
          'recorded", never the tag\'s present-day values',
    );

    // The point of the migration: the new table exists and actually works,
    // not merely that the old table survived.
    await db.insert(Tables.observationExclusions, {
      'exclusion_id': 'excl-1',
      'project_id': 'proj-1',
      'observation_id': 'obs-1',
      'user_id': 'user-1',
      'kind': 'exclude',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    final exclusions = await db.query(Tables.observationExclusions);
    expect(exclusions.single['kind'], 'exclude');

    await db.close();
  });
}
