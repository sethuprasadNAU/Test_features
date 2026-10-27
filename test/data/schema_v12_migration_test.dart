import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

/// **The on-device upgrade to schema v12 (task 11.187): a tag's pulse modes.**
///
/// The dangerous part of this feature is not the picker or the toggle — it is
/// this migration, because it runs against a collar roster and a season of
/// bearings that already exist. Three things have to be true afterwards and
/// each is asserted here rather than described:
///
/// 1. **A tag that already had a `pulse_rate` still has it, on mode 1.** No
///    value moves and no arithmetic runs: the unit was beats per minute before
///    and is beats per minute after.
/// 2. **Every existing tag and tag version gets the two mode names the old
///    build offered, and no rate for the second one.** Naming them is
///    transcription; inventing a mortality rate would be a measurement nobody
///    took.
/// 3. **No bearing is touched.** `pulse_mode` is NULL on every row that
///    predates the migration, and is read through `signal_type` instead.
///
/// The fourth thing is structural: `Tag_Versions` is **rebuilt** so its column
/// order still matches the order derived from `Tags` through `tagColumnKinds`.
/// A rebuild is the migration in this set most able to lose a row, so the rows
/// are checked field by field on the far side.
void main() {
  const t = '2026-09-01T00:00:00.000Z';

  /// A v11 database built by running the real migrations, so this is the shape
  /// a device in the field actually has — not a hand-written approximation of
  /// one.
  Future<Database> openV11() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 11, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 11);
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
    // The tag whose rate somebody measured — the case the acceptance criteria
    // name explicitly.
    await db.insert(Tables.tags, {
      'tag_id': 'tag-rated',
      'frequency_mhz': 150.325,
      'pulse_rate': 52.0,
      'pulse_pattern': 'steady',
      'tag_name': 'Coco',
      'date_put_on': t,
      'status': 'active',
      'color_hex': '#4C9F70',
      'created_at': t,
      'updated_at': t,
      'revision': 4,
    });
    // And the tag nobody measured, because "optional" has meant optional since
    // the form was written.
    await db.insert(Tables.tags, {
      'tag_id': 'tag-unrated',
      'frequency_mhz': 151.100,
      'tag_name': 'Bandit',
      'date_put_on': t,
      'status': 'active',
      'color_hex': '#E69F00',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.tagVersions, {
      'tag_version_id': 'tv-1',
      'tag_id': 'tag-rated',
      'effective_from': t,
      'frequency_mhz': 150.325,
      'pulse_rate': 52.0,
      'pulse_pattern': 'steady',
      'tag_name': 'Coco',
      'created_at': t,
      'updated_at': t,
      'deleted_at': null,
      'revision': 2,
      'last_modified_by': 'user-1',
      'origin_device_id': 'device-a',
    });
    for (final (id, signalType) in [
      ('obs-regular', 'regular_pulse'),
      ('obs-mortality', 'mortality_signal'),
    ]) {
      await db.insert(Tables.observations, {
        'observation_id': id,
        'project_id': 'project-1',
        'user_id': 'user-1',
        'tag_id': 'tag-rated',
        'timestamp_local': '2026-08-31T09:00:00.000',
        'timestamp_utc': '2026-08-31T16:00:00.000Z',
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
        'signal_type': signalType,
        'signal_strength': 'strong',
        'notes': 'ridge above the creek',
        'tag_version_id': 'tv-1',
        'created_at': t,
        'updated_at': t,
        'revision': 3,
      });
    }
  }

  test('a tag that already had a pulse rate keeps it, as mode 1, with no '
      'arithmetic done to it', () async {
    final db = await openV11();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 11, to: 12);

    final row = (await db.query(
      Tables.tags,
      where: 'tag_id = ?',
      whereArgs: ['tag-rated'],
    )).single;

    // The value itself, unmoved and unconverted. 52 bpm before, 52 bpm after —
    // the seconds-per-pulse toggle is a display preference and this is the
    // assertion that says so.
    expect(row['pulse_rate'], 52.0);
    expect(row['pulse_mode_1_name'], 'Normal');
    // Named, because the old build offered this mode to every collar. Not
    // rated, because it had nowhere to record a rate for it.
    expect(row['pulse_mode_2_name'], 'Mortality');
    expect(row['pulse_mode_2_rate_bpm'], isNull);
    expect(row['pulse_mode_3_name'], isNull);
    expect(row['pulse_mode_3_rate_bpm'], isNull);
    // Nothing else moved.
    expect(row['frequency_mhz'], 150.325);
    expect(row['pulse_pattern'], 'steady');
    expect(row['tag_name'], 'Coco');
    expect(row['revision'], 4);
  });

  test('a tag whose rate nobody measured is not given one', () async {
    final db = await openV11();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 11, to: 12);

    final row = (await db.query(
      Tables.tags,
      where: 'tag_id = ?',
      whereArgs: ['tag-unrated'],
    )).single;

    expect(row['pulse_mode_1_name'], 'Normal');
    expect(row['pulse_rate'], isNull);
    expect(row['pulse_mode_2_name'], 'Mortality');
    expect(row['pulse_mode_2_rate_bpm'], isNull);
  });

  test('the Tag_Versions rebuild carries every row across intact, and the '
      'rebuilt table has the column order the shared spec derives', () async {
    // **Stops at v12 on purpose.** This test is about v12's rebuild, and
    // schema v14 rebuilds the same table again to give it a `project_id` —
    // running past v12 would mean asserting v14's column order under v12's
    // name, which is how a test comes to be about something other than what
    // it says. v14's own shape is covered by
    // `schema_matches_shared_spec_test.dart`.
    final db = await openV11();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 11, to: 12);

    final row = (await db.query(Tables.tagVersions)).single;
    expect(row['tag_version_id'], 'tv-1');
    expect(row['tag_id'], 'tag-rated');
    expect(row['effective_from'], t);
    expect(row['frequency_mhz'], 150.325);
    expect(row['pulse_rate'], 52.0);
    expect(row['pulse_pattern'], 'steady');
    expect(row['tag_name'], 'Coco');
    // What the tag's modes were called while this version was current. The
    // records pointing at it read these words, not today's.
    expect(row['pulse_mode_1_name'], 'Normal');
    expect(row['pulse_mode_2_name'], 'Mortality');
    expect(row['pulse_mode_2_rate_bpm'], isNull);
    // The sync columns a rebuild is most likely to drop on the floor.
    expect(row['created_at'], t);
    expect(row['updated_at'], t);
    expect(row['revision'], 2);
    expect(row['last_modified_by'], 'user-1');
    expect(row['origin_device_id'], 'device-a');

    // The reason the table is rebuilt rather than altered: the derived spec
    // puts the measurement columns before the sync columns, and appending
    // cannot do that.
    //
    // **Written out rather than read from `tableSpecs` since task 11.219.**
    // That spec describes the schema *after every migration*, and v14 adds a
    // `project_id` this table does not have at v12 — comparing against it
    // here would make this test drift into being about the current schema
    // rather than about the change v12 made. The v14 shape is what
    // `schema_matches_shared_spec_test.dart` checks.
    final info = await db.rawQuery('PRAGMA table_info(${Tables.tagVersions})');
    expect(info.map((c) => c['name'] as String).toList(), [
      'tag_version_id',
      'tag_id',
      'effective_from',
      'frequency_mhz',
      'pulse_rate',
      'pulse_pattern',
      'tag_name',
      'pulse_mode_1_name',
      'pulse_mode_2_name',
      'pulse_mode_2_rate_bpm',
      'pulse_mode_3_name',
      'pulse_mode_3_rate_bpm',
      'created_at',
      'updated_at',
      'deleted_at',
      'revision',
      'last_modified_by',
      'origin_device_id',
    ]);

    // The index the "what was this bearing recorded against?" read uses is
    // dropped with the old table. Named rather than counted.
    expect(
      await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type='index' AND name=?",
        ['idx_tag_versions_tag'],
      ),
      hasLength(1),
    );
    // And the foreign key it had. A rebuild that forgets this leaves the
    // version table able to name a collar that does not exist.
    final keys = await db.rawQuery(
      'PRAGMA foreign_key_list(${Tables.tagVersions})',
    );
    expect(keys.map((k) => k['table']), contains(Tables.tags));
  });

  test('no bearing is backfilled: pulse_mode stays NULL and is read through '
      'signal_type instead', () async {
    final db = await openV11();
    addTearDown(db.close);
    await seed(db);

    await runMigrations(db, from: 11, to: 12);

    final rows = await db.query(Tables.observations, orderBy: 'observation_id');
    expect(rows, hasLength(2));
    for (final row in rows) {
      expect(row['pulse_mode'], isNull);
      // The bearing itself is the irreplaceable field record.
      expect(row['magnetic_bearing'], 47.5);
      expect(row['bearing_uncertainty'], 5.0);
      expect(row['revision'], 3);
      expect(row['tag_version_id'], 'tv-1');
    }

    // Michael's answer 3, 2026-09-07: records already stored as
    // `regular_pulse` / `mortality_signal` adopt the new default names. That
    // happens on read, with no UPDATE behind it.
    final byId = {for (final r in rows) r['observation_id'] as String: r};
    expect(
      pulseModeSlotOf(
        storedSlot: byId['obs-regular']!['pulse_mode'] as int?,
        legacy: SignalType.fromDb(byId['obs-regular']!['signal_type'] as String),
      ),
      1,
    );
    expect(
      pulseModeSlotOf(
        storedSlot: byId['obs-mortality']!['pulse_mode'] as int?,
        legacy:
            SignalType.fromDb(byId['obs-mortality']!['signal_type'] as String),
      ),
      2,
    );
  });

  test('a bearing written after v12 records the mode it was heard on',
      () async {
    final db = await openV11();
    addTearDown(db.close);
    await seed(db);
    await runMigrations(db, from: 11, to: 12);

    await db.insert(Tables.observations, {
      'observation_id': 'obs-new',
      'project_id': 'project-1',
      'user_id': 'user-1',
      'tag_id': 'tag-rated',
      'timestamp_local': '2026-09-02T09:00:00.000',
      'timestamp_utc': '2026-09-02T16:00:00.000Z',
      'timezone_offset': '-07:00',
      'latitude': 35.2,
      'longitude': -111.6,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'observation_type': 'directional',
      'signal_type': 'regular_pulse',
      'signal_strength': 'strong',
      'pulse_mode': 3,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });

    final row = (await db.query(
      Tables.observations,
      where: 'observation_id = ?',
      whereArgs: ['obs-new'],
    )).single;
    expect(row['pulse_mode'], 3);
    // The stored slot wins over the two-valued legacy column, which is what
    // makes the projection safe to be lossy about a third mode.
    expect(
      pulseModeSlotOf(
        storedSlot: row['pulse_mode'] as int?,
        legacy: SignalType.fromDb(row['signal_type'] as String),
      ),
      3,
    );
  });
}
