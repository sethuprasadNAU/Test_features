import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';

import 'migration_support.dart';

/// Exercises the on-device upgrade path for schema v6 (task 10.35, schema
/// **major 2**): the six project-scoped data tables are re-keyed
/// `(<id>, project_id)`.
///
/// This is the migration that carries real field data across the project's
/// first major bump, so it is tested for what a researcher would actually lose
/// if it went wrong — every row, every value, and referential integrity — not
/// just for "the DDL ran."
void main() {
  const t = '2026-07-16T18:30:00.000Z';

  /// A v5 database with one row in every table that v6 re-keys, plus the
  /// parents they reference. Deliberately built by running the real migrations
  /// 1..5 rather than by hand, so this is the shape a device in the field
  /// actually has.
  Future<Database> openV5() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 5, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 5);
    return db;
  }


  Future<void> seedProject(Database db, String projectId) async {
    await db.insert(Tables.projects, {
      'project_id': projectId,
      'project_name': 'Peaks $projectId',
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
  }

  /// A second project plus its own copy of the collar.
  ///
  /// **Task 11.219 is why the tag comes with it.** A tag belongs to one
  /// project now and `Observations.(tag_id, project_id)` references it, so a
  /// bearing landing in `proj-2` needs a tag *in* `proj-2` — which is
  /// copy-on-add working, not an obstacle to route around. The copy keeps
  /// the original's lineage, which is what says the two are one collar.
  Future<void> seedSecondProjectWithTagCopy(Database db, String tagId) async {
    await seedProject(db, 'proj-2');
    final original = (await db.query(
      Tables.tags,
      where: 'tag_id = ?',
      whereArgs: ['tag-1'],
    )).single;
    await db.insert(Tables.tags, {
      ...original,
      'tag_id': tagId,
      'project_id': 'proj-2',
      'copied_at': original['created_at'],
      // Task 11.240: the animal is project-scoped too, and the composite
      // foreign key refuses a copy that carries the *other* project's
      // individual — which is the key working, not an obstacle. A copy
      // arrives with nobody named; the receiving project names its own.
      'individual_id': null,
    });
  }


  Future<void> seedV5Data(Database db) async {
    await db.insert(Tables.users, {
      'user_id': 'user-1',
      'first_name': 'Sam',
      'last_name': 'Ranger',
      'email': 'sam@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await seedProject(db, 'proj-1');
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
    await db.insert(Tables.projectMemberships, {
      'membership_id': 'mem-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'join_date': t,
      'role': 'owner',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.triangulationSessions, {
      'session_id': 'sess-1',
      'project_id': 'proj-1',
      'tag_id': 'tag-1',
      'label': 'ridge sweep',
      'started_at_local': '2026-07-16T11:30:00.000',
      'started_at_utc': t,
      'started_at_offset': '-07:00',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.observations, {
      'observation_id': 'obs-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'tag_id': 'tag-1',
      'session_id': 'sess-1',
      'timestamp_local': '2026-07-16T11:30:00.000',
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
    await db.insert(Tables.nonDetections, {
      'non_detection_id': 'nd-1',
      'project_id': 'proj-1',
      'user_id': 'user-1',
      'timestamp_local': '2026-07-16T11:30:00.000',
      'timestamp_utc': t,
      'timezone_offset': '-07:00',
      'latitude': 35.20,
      'longitude': -111.63,
      'position_source': 'gps_fix',
      'elevation': 2100.0,
      'altitude_agl': 0.0,
      'tag_ids_listened_for': '["tag-1"]',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.estimatedPositions, {
      'position_id': 'pos-1',
      'project_id': 'proj-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-07-16T11:30:00.000',
      'timestamp_utc': t,
      'timezone_offset': '-07:00',
      'latitude': 35.21,
      'longitude': -111.64,
      'semi_major_axis': 120.0,
      'semi_minor_axis': 80.0,
      'rotation_angle': 42.0,
      'method': 'maximum_likelihood',
      'observation_ids_used': '["obs-1"]',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
    await db.insert(Tables.actualTagLocations, {
      'location_id': 'loc-1',
      'project_id': 'proj-1',
      'tag_id': 'tag-1',
      'timestamp_local': '2026-07-16T11:30:00.000',
      'timestamp_utc': t,
      'timezone_offset': '-07:00',
      'latitude': 35.22,
      'longitude': -111.65,
      'uncertainty_radius': 5.0,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    });
  }

  test('every re-keyed row survives the upgrade with all its values', () async {
    final db = await openV5();
    await seedV5Data(db);

    final before = <String, Map<String, Object?>>{
      for (final table in const [
        Tables.projectMemberships,
        Tables.triangulationSessions,
        Tables.observations,
        Tables.nonDetections,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
      ])
        table: (await db.query(table)).single,
    };

    await runMigrations(db, from: 5, to: lastVersionBeforeTheWipe);

    for (final entry in before.entries) {
      final after = await db.query(entry.key);
      expect(after, hasLength(1), reason: '${entry.key} lost its row');
      // Column-for-column, not just "a row is there". The rebuild copies with
      // `INSERT … SELECT *`, which is only correct while the new table declares
      // the same columns in the same order — a silent mismatch would shift
      // values between columns rather than fail.
      //
      // Columns *added* by a later migration are compared separately below,
      // because this test runs 5 → latest and every version above 6 is
      // entitled to add one. Subtracting them here rather than loosening the
      // comparison keeps the column-for-column property this test exists for.
      final carried = Map<String, Object?>.of(after.single)
        ..removeWhere((column, _) => !entry.value.containsKey(column));
      expect(carried, entry.value,
          reason: '${entry.key} changed a value during the rebuild');
    }

    // Schema v9 (task 11.32) adds `Observations.tag_version_id`, and the
    // acceptance criterion is that **it is not backfilled**: a bearing recorded
    // before there were versions genuinely does not know what the tag read at
    // the time, and writing today's answer into it is the falsehood the task
    // removes. Asserted here, on a real upgrade of a populated database, rather
    // than trusted to the migration containing no UPDATE.
    final upgraded = (await db.query(Tables.observations)).single;
    expect(upgraded.containsKey('tag_version_id'), isTrue);
    expect(
      upgraded['tag_version_id'],
      isNull,
      reason: 'an observation that predates Tag_Versions must stay "not '
          'recorded" — never backfilled from the tag row',
    );

    await db.close();
  });

  test('the upgrade leaves referential integrity intact', () async {
    final db = await openV5();
    await seedV5Data(db);
    await runMigrations(db, from: 5, to: lastVersionBeforeTheWipe);

    // `runMigrations` runs this itself and throws on a violation, so reaching
    // here already proves it — asserted explicitly anyway, because migrations
    // run with foreign keys *off* and this is the check that makes that safe.
    expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

    await db.close();
  });

  test('the same row id may now exist in two projects — the point of the bump',
      () async {
    final db = await openV5();
    await seedV5Data(db);
    await runMigrations(db, from: 5, to: lastVersionBeforeTheWipe);
    await db.execute('PRAGMA foreign_keys = ON');

    await seedSecondProjectWithTagCopy(db, 'tag-1-in-proj-2');

    // Exactly the shape of an imported replica (task 6.3): the sender's
    // `observation_id`, kept verbatim, landing in a different project than it
    // came from. Under schema major 1 this was a primary-key conflict, which
    // is what made the server refuse it forever.
    final original = (await db.query(Tables.observations,
            where: 'observation_id = ?', whereArgs: ['obs-1']))
        .single;
    await db.insert(Tables.observations, {
      ...original,
      'project_id': 'proj-2',
      'tag_id': 'tag-1-in-proj-2',
      'session_id': null,
    });

    final both = await db.query(Tables.observations,
        where: 'observation_id = ?', whereArgs: ['obs-1'], orderBy: 'project_id');
    expect(both, hasLength(2));
    expect(both.map((r) => r['project_id']), ['proj-1', 'proj-2']);
    // The original is untouched — a second project holding the same id is not
    // a merge.
    expect(both.first['notes'], 'strong steady pulse');
    expect(both.first['session_id'], 'sess-1');

    await db.close();
  });

  test('a duplicate id within one project is still a conflict', () async {
    final db = await openV5();
    await seedV5Data(db);
    await runMigrations(db, from: 5, to: lastVersionBeforeTheWipe);
    await db.execute('PRAGMA foreign_keys = ON');

    // The other half of the guarantee: widening the key must not have widened
    // it so far that a genuine duplicate slips through. Within one project the
    // id is still unique, which is what convergence relies on.
    final original = (await db.query(Tables.observations,
            where: 'observation_id = ?', whereArgs: ['obs-1']))
        .single;
    await expectLater(
      db.insert(Tables.observations, Map.of(original),
          conflictAlgorithm: ConflictAlgorithm.abort),
      throwsA(isA<DatabaseException>()),
    );

    await db.close();
  });

  test('an observation cannot reference a session in another project',
      () async {
    final db = await openV5();
    await seedV5Data(db);
    await runMigrations(db, from: 5, to: lastVersionBeforeTheWipe);
    await db.execute('PRAGMA foreign_keys = ON');
    await seedSecondProjectWithTagCopy(db, 'tag-1-in-proj-2');

    // The composite foreign key `(session_id, project_id)` earning its keep.
    // A single-column `REFERENCES Triangulation_Sessions(session_id)` would
    // have accepted this, letting one project's observation hang off another
    // project's session — a cross-project link created by an ordinary insert.
    final original = (await db.query(Tables.observations,
            where: 'observation_id = ?', whereArgs: ['obs-1']))
        .single;
    await expectLater(
      db.insert(Tables.observations, {
        ...original,
        'observation_id': 'obs-2',
        'project_id': 'proj-2',
        'tag_id': 'tag-1-in-proj-2',
        'session_id': 'sess-1', // lives in proj-1
      }),
      throwsA(isA<DatabaseException>()),
    );

    // But a session-less observation in the new project is fine: the composite
    // key is MATCH SIMPLE, so a NULL `session_id` leaves it unconstrained.
    await db.insert(Tables.observations, {
      ...original,
      'observation_id': 'obs-3',
      'project_id': 'proj-2',
      'tag_id': 'tag-1-in-proj-2',
      'session_id': null,
    });
    expect(
      await db.query(Tables.observations,
          where: 'observation_id = ?', whereArgs: ['obs-3']),
      hasLength(1),
    );

    await db.close();
  });
}
