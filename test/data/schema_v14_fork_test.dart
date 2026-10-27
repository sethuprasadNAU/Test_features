import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/db/tag_scope_migration.dart';

import 'migration_support.dart';

/// **Schema v14's fork (task 11.224): a tag two or more projects hold.**
///
/// Task 11.219 wrote this case as a refusal on the strength of one Mac
/// answering `1|5`. On 2026-09-10 Michael's iPhone answered `4|1, 2|2` — six
/// tags, two of them in two projects each — and the app would not open. The
/// fork is `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §3.3; this file runs it on
/// a database of exactly his shape before it runs on his.
///
/// **Every database here is built at v13 and migrated forward**, and every
/// number is asserted before and after. The property that matters is the
/// last group: a bearing that named collar X in project B now names project
/// B's copy **and still resolves to the same frequency, the same pulse rate
/// and a version with the same `effective_from`** — a fork that re-points a
/// bearing at a collar reading something different has changed the record.
void main() {
  Future<Database> openV13() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 13, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 13);
    return db;
  }

  const t = '2026-08-02T12:00:00.000Z';

  Map<String, Object?> sync(String at, {String? by = 'user-1'}) => {
    'created_at': at,
    'updated_at': at,
    'revision': 0,
    'last_modified_by': by,
  };

  Future<void> seedUser(Database db, [String id = 'user-1']) =>
      db.insert(Tables.users, {
        'user_id': id,
        'first_name': 'Sam',
        'last_name': 'Reyes',
        'email': '$id@example.com',
        ...sync(t),
      });

  Future<void> seedProject(Database db, String projectId) =>
      db.insert(Tables.projects, {
        'project_id': projectId,
        'project_name': projectId,
        'owner_user_id': 'user-1',
        'creation_date': t,
        'datum': 'WGS84',
        'coordinate_format': 'dd',
        'triangulation_window_minutes': 15,
        ...sync(t),
      });

  Future<void> seedTag(
    Database db,
    String tagId, {
    String name = 'Coco',
    double frequency = 150.325,
    double? pulseRate = 40,
  }) => db.insert(Tables.tags, {
    'tag_id': tagId,
    'frequency_mhz': frequency,
    'pulse_rate': pulseRate,
    'tag_name': name,
    'date_put_on': t,
    'status': 'active',
    'color_hex': '#E69F00',
    ...sync(t),
  });

  Future<void> link(
    Database db,
    String projectId,
    String tagId, {
    String createdAt = t,
    String? by = 'user-1',
    String? device,
  }) => db.insert(Tables.projectTags, {
    'project_id': projectId,
    'tag_id': tagId,
    'status': 'active',
    ...sync(createdAt, by: by),
    'origin_device_id': device,
  });

  Future<void> seedVersion(
    Database db,
    String id,
    String tagId, {
    required String effectiveFrom,
    required double frequency,
    double? pulseRate = 40,
  }) => db.insert(Tables.tagVersions, {
    'tag_version_id': id,
    'tag_id': tagId,
    'effective_from': effectiveFrom,
    'frequency_mhz': frequency,
    'pulse_rate': pulseRate,
    'tag_name': 'Coco',
    ...sync(effectiveFrom),
  });

  Future<void> seedSession(
    Database db, {
    required String id,
    required String projectId,
    required String tagId,
  }) => db.insert(Tables.triangulationSessions, {
    'session_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'started_at_local': t,
    'started_at_utc': t,
    'started_at_offset': '+00:00',
    ...sync(t),
  });

  Future<void> seedBearing(
    Database db, {
    required String id,
    required String projectId,
    required String tagId,
    String? versionId,
    String? sessionId,
    String createdAt = t,
  }) => db.insert(Tables.observations, {
    'observation_id': id,
    'project_id': projectId,
    'user_id': 'user-1',
    'tag_id': tagId,
    'tag_version_id': versionId,
    'session_id': sessionId,
    'timestamp_local': createdAt,
    'timestamp_utc': createdAt,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    ...sync(createdAt),
  });

  Future<void> seedEstimate(
    Database db, {
    required String id,
    required String projectId,
    required String tagId,
    required List<String> observationIds,
  }) => db.insert(Tables.estimatedPositions, {
    'position_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'timestamp_local': t,
    'timestamp_utc': t,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'semi_major_axis': 120.0,
    'semi_minor_axis': 80.0,
    'rotation_angle': 15.0,
    'method': 'mle',
    'observation_ids_used': '[${observationIds.map((o) => '"$o"').join(',')}]',
    ...sync(t),
  });

  Future<void> seedTruthPoint(
    Database db, {
    required String id,
    required String projectId,
    required String tagId,
    String? versionId,
  }) => db.insert(Tables.actualTagLocations, {
    'location_id': id,
    'project_id': projectId,
    'tag_id': tagId,
    'tag_version_id': versionId,
    'timestamp_local': t,
    'timestamp_utc': t,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'uncertainty_radius': 5.0,
    'user_id': 'user-1',
    ...sync(t),
  });

  Future<void> seedNonDetection(
    Database db, {
    required String id,
    required String projectId,
    required List<String> tagIds,
  }) => db.insert(Tables.nonDetections, {
    'non_detection_id': id,
    'project_id': projectId,
    'user_id': 'user-1',
    'timestamp_local': t,
    'timestamp_utc': t,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'tag_ids_listened_for': '[${tagIds.map((o) => '"$o"').join(',')}]',
    ...sync(t),
  });

  Future<int> count(Database db, String table, [String? where]) async =>
      (await db.rawQuery(
            'SELECT COUNT(*) AS c FROM $table${where == null ? '' : ' WHERE $where'}',
          )).first['c']!
          as int;

  Future<Map<String, Object?>> tagIn(
    Database db,
    String projectId, {
    required String lineage,
  }) async => (await db.query(
    Tables.tags,
    where: 'project_id = ? AND lineage_id = ?',
    whereArgs: [projectId, lineage],
  )).single;

  /// The shape Michael's iPhone reported on 2026-09-10: six tags, four in
  /// one project each, two held by two projects each. Both shared collars
  /// carry a two-version drift record and, **in each of their two
  /// projects**, three bearings (two against the first version, one against
  /// the second), a session those bearings belong to, an estimate built from
  /// them, a truth point against the second version, and a "no signal"
  /// entry that listened for the collar.
  ///
  /// The adoption dates are chosen so that the keeper is **not** the project
  /// inserted first for one of the two — `shared-2` was linked to `proj-a`
  /// first in insertion order, but `proj-c` adopted it a month earlier.
  Future<void> seedMichaelsShape(Database db) async {
    await seedUser(db);
    for (final p in ['proj-a', 'proj-b', 'proj-c']) {
      await seedProject(db, p);
    }
    // Four in exactly one project.
    await seedTag(db, 'single-1', name: 'Solo 1');
    await link(db, 'proj-a', 'single-1');
    await seedTag(db, 'single-2', name: 'Solo 2');
    await link(db, 'proj-b', 'single-2');
    await seedTag(db, 'single-3', name: 'Solo 3');
    await link(db, 'proj-c', 'single-3');
    await seedTag(db, 'single-4', name: 'Solo 4');
    await link(db, 'proj-a', 'single-4');
    await seedVersion(
      db,
      'single-1-v1',
      'single-1',
      effectiveFrom: '2026-01-01T00:00:00.000Z',
      frequency: 150.325,
    );
    await seedBearing(
      db,
      id: 'single-1-obs',
      projectId: 'proj-a',
      tagId: 'single-1',
      versionId: 'single-1-v1',
    );

    // Two shared. `shared-1`: proj-a adopted in June, proj-b in July.
    // `shared-2`: proj-a linked first in insertion order, but proj-c adopted
    // it in May and proj-a in June.
    const shared = <String, List<(String, String)>>{
      'shared-1': [
        ('proj-a', '2026-06-01T00:00:00.000Z'),
        ('proj-b', '2026-07-01T00:00:00.000Z'),
      ],
      'shared-2': [
        ('proj-a', '2026-06-15T00:00:00.000Z'),
        ('proj-c', '2026-05-01T00:00:00.000Z'),
      ],
    };
    for (final entry in shared.entries) {
      final tagId = entry.key;
      await seedTag(db, tagId, name: tagId, frequency: 151.110, pulseRate: 55);
      await seedVersion(
        db,
        '$tagId-v1',
        tagId,
        effectiveFrom: '2026-01-01T00:00:00.000Z',
        frequency: 151.105,
        pulseRate: 50,
      );
      await seedVersion(
        db,
        '$tagId-v2',
        tagId,
        effectiveFrom: '2026-03-01T00:00:00.000Z',
        frequency: 151.110,
        pulseRate: 55,
      );
      for (final (projectId, adoptedAt) in entry.value) {
        await link(
          db,
          projectId,
          tagId,
          createdAt: adoptedAt,
          by: 'linker-$projectId',
          device: 'device-$projectId',
        );
        final prefix = '$tagId-$projectId';
        await seedSession(
          db,
          id: '$prefix-session',
          projectId: projectId,
          tagId: tagId,
        );
        for (var i = 1; i <= 3; i++) {
          await seedBearing(
            db,
            id: '$prefix-obs-$i',
            projectId: projectId,
            tagId: tagId,
            versionId: i == 3 ? '$tagId-v2' : '$tagId-v1',
            sessionId: '$prefix-session',
          );
        }
        await seedEstimate(
          db,
          id: '$prefix-estimate',
          projectId: projectId,
          tagId: tagId,
          observationIds: ['$prefix-obs-1', '$prefix-obs-2', '$prefix-obs-3'],
        );
        await seedTruthPoint(
          db,
          id: '$prefix-truth',
          projectId: projectId,
          tagId: tagId,
          versionId: '$tagId-v2',
        );
        await seedNonDetection(
          db,
          id: '$prefix-nd',
          projectId: projectId,
          tagIds: [tagId],
        );
      }
    }
  }

  group('the census names the fork before anything moves', () {
    test('Michael\'s four numbers, and who keeps which id', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedMichaelsShape(db);

      final census = await TagScopeMigration.takeCensus(db);
      expect(census.total, 6);
      expect(census.linkedToExactlyOneProject, 4);
      expect(census.linkedToTwoOrMoreProjects, 2);
      expect(census.linkedToNoProject, 0);
      expect(census.forks, hasLength(2));

      final byTag = {for (final f in census.forks) f.tagId: f};
      expect(byTag['shared-1']!.keeper.projectId, 'proj-a');
      expect(byTag['shared-1']!.copies.map((c) => c.projectId), ['proj-b']);
      expect(
        byTag['shared-2']!.keeper.projectId,
        'proj-c',
        reason:
            'proj-a was linked first in insertion order, but proj-c '
            'adopted the collar a month earlier — §3.3 orders by the '
            'link\'s created_at, not by anything about row order',
      );
      expect(byTag['shared-2']!.copies.map((c) => c.projectId), ['proj-a']);
      expect(
        byTag['shared-2']!.copies.single.adoptedAt,
        '2026-06-15T00:00:00.000Z',
      );
      expect(
        census.scope['shared-2'],
        'proj-c',
        reason: 'the keeper is what the rebuild scopes the original row to',
      );
      expect(
        census.report().join('\n'),
        allOf(
          contains(
            '2 tag(s) are named by two or more projects; each is forked',
          ),
          contains('shared-2:'),
          contains(
            'keeps the original id in proj-c (adopted '
            '2026-05-01T00:00:00.000Z, by link)',
          ),
          contains(
            'copied into proj-a (adopted 2026-06-15T00:00:00.000Z, '
            'by link)',
          ),
        ),
        reason:
            'the device log is where Michael reads this, and it has to '
            'say which project kept the id and on the strength of what date',
      );
    });
  });

  group('the fork on Michael\'s shape — counts before and after', () {
    late Database db;
    late List<String> printed;

    setUp(() async {
      db = await openV13();
      await seedMichaelsShape(db);
      // Before.
      expect(await count(db, Tables.tags), 6);
      expect(await count(db, Tables.tagVersions), 5);
      expect(await count(db, Tables.observations), 13);
      expect(await count(db, Tables.triangulationSessions), 4);
      expect(await count(db, Tables.estimatedPositions), 4);
      expect(await count(db, Tables.actualTagLocations), 4);
      expect(await count(db, Tables.nonDetections), 4);
      expect(await count(db, Tables.projectTags), 8);

      printed = <String>[];
      // Through `runMigrations` rather than `apply` directly, so the
      // foreign-key check at the end of the migration runs as it does on a
      // device; the lines are captured off the migration's own channel.
      await runZoned(
        () => runMigrations(db, from: 13, to: lastVersionBeforeTheWipe),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      await db.execute('PRAGMA foreign_keys = ON');
    });

    tearDown(() => db.close());

    test(
      'six collars become eight rows, nothing else is lost or duplicated',
      () async {
        expect(await count(db, Tables.tags), 8);
        expect(
          await count(db, Tables.tagVersions),
          9,
          reason:
              'the five original version rows, plus each shared collar\'s '
              'two-row chain copied once into its second project',
        );
        // Every record table has exactly the rows it had.
        expect(await count(db, Tables.observations), 13);
        expect(await count(db, Tables.triangulationSessions), 4);
        expect(await count(db, Tables.estimatedPositions), 4);
        expect(await count(db, Tables.actualTagLocations), 4);
        expect(await count(db, Tables.nonDetections), 4);
        expect(
          await count(db, Tables.projectTags),
          8,
          reason: '§3.5: the links are the audit trail of what the fork did',
        );
        expect(
          await count(db, kTagLibraryTable),
          6,
          reason:
              'one library entry per physical collar; a copy shares its '
              'lineage and contributes no second entry',
        );
        // Every foreign key resolves — the migration has already checked this
        // with `PRAGMA foreign_key_check`; asserted here so a reader can see
        // what that check was protecting.
        expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);
      },
    );

    test('the four single-project tags are untouched', () async {
      for (final (tagId, projectId) in [
        ('single-1', 'proj-a'),
        ('single-2', 'proj-b'),
        ('single-3', 'proj-c'),
        ('single-4', 'proj-a'),
      ]) {
        final rows = await db.query(
          Tables.tags,
          where: 'tag_id = ?',
          whereArgs: [tagId],
        );
        expect(rows, hasLength(1), reason: '$tagId was not forked');
        expect(rows.single['project_id'], projectId);
        expect(rows.single['lineage_id'], tagId);
        expect(rows.single['copied_at'], isNull);
      }
      expect(
        (await db.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: ['single-1-obs'],
        )).single,
        containsPair('tag_version_id', 'single-1-v1'),
      );
    });

    test('the keeper keeps the original id; the copy carries the lineage, '
        'the adoption date and the linker', () async {
      final keeper = await tagIn(db, 'proj-c', lineage: 'shared-2');
      expect(keeper['tag_id'], 'shared-2');
      expect(keeper['copied_at'], isNull);

      final copy = await tagIn(db, 'proj-a', lineage: 'shared-2');
      expect(copy['tag_id'], isNot('shared-2'));
      expect(copy['lineage_id'], 'shared-2');
      expect(
        copy['copied_at'],
        '2026-06-15T00:00:00.000Z',
        reason:
            'the link\'s own created_at — the day proj-a actually '
            'adopted the collar, already recorded, not today',
      );
      expect(copy['created_at'], '2026-06-15T00:00:00.000Z');
      expect(copy['updated_at'], '2026-06-15T00:00:00.000Z');
      expect(copy['revision'], 0);
      expect(copy['last_modified_by'], 'linker-proj-a');
      expect(copy['origin_device_id'], 'device-proj-a');
      // The measurements are the original's.
      expect(copy['frequency_mhz'], 151.110);
      expect(copy['pulse_rate'], 55.0);
      expect(copy['tag_name'], 'shared-2');
    });

    test('a bearing in the copied project names the copy, and still reads '
        'the same frequency, pulse rate and effective version', () async {
      // **The property that matters.** proj-b's three bearings against
      // shared-1 named versions v1, v1, v2 before the fork. Afterwards each
      // must name a version row that belongs to proj-b's copy and has the
      // same effective_from and measurements as the one it named before.
      final copy = await tagIn(db, 'proj-b', lineage: 'shared-1');
      final copyId = copy['tag_id']! as String;

      const before = {
        'shared-1-proj-b-obs-1': ('2026-01-01T00:00:00.000Z', 151.105, 50.0),
        'shared-1-proj-b-obs-2': ('2026-01-01T00:00:00.000Z', 151.105, 50.0),
        'shared-1-proj-b-obs-3': ('2026-03-01T00:00:00.000Z', 151.110, 55.0),
      };
      for (final entry in before.entries) {
        final obs = (await db.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: [entry.key],
        )).single;
        expect(obs['project_id'], 'proj-b');
        expect(
          obs['tag_id'],
          copyId,
          reason: '${entry.key} follows its project',
        );
        expect(
          obs['tag_version_id'],
          isNot(anyOf('shared-1-v1', 'shared-1-v2')),
          reason: 'the version it names is the copied one, not proj-a\'s',
        );
        final version = (await db.query(
          Tables.tagVersions,
          where: 'tag_version_id = ? AND project_id = ?',
          whereArgs: [obs['tag_version_id'], 'proj-b'],
        )).single;
        expect(version['tag_id'], copyId);
        final (effectiveFrom, frequency, pulseRate) = entry.value;
        expect(version['effective_from'], effectiveFrom);
        expect(version['frequency_mhz'], frequency);
        expect(version['pulse_rate'], pulseRate);
        // And the collar the bearing resolves to reads what it read.
        final tag = (await db.query(
          Tables.tags,
          where: 'tag_id = ? AND project_id = ?',
          whereArgs: [obs['tag_id'], obs['project_id']],
        )).single;
        expect(tag['frequency_mhz'], 151.110);
        expect(tag['pulse_rate'], 55.0);
      }

      // The keeper's bearings did not move at all.
      for (var i = 1; i <= 3; i++) {
        final obs = (await db.query(
          Tables.observations,
          where: 'observation_id = ?',
          whereArgs: ['shared-1-proj-a-obs-$i'],
        )).single;
        expect(obs['tag_id'], 'shared-1');
        expect(obs['tag_version_id'], i == 3 ? 'shared-1-v2' : 'shared-1-v1');
      }
    });

    test(
      'the session, the estimate and the truth point follow the same way',
      () async {
        final copy = await tagIn(db, 'proj-a', lineage: 'shared-2');
        final copyId = copy['tag_id']! as String;
        expect(
          (await db.query(
            Tables.triangulationSessions,
            where: 'session_id = ?',
            whereArgs: ['shared-2-proj-a-session'],
          )).single['tag_id'],
          copyId,
        );
        expect(
          (await db.query(
            Tables.estimatedPositions,
            where: 'position_id = ?',
            whereArgs: ['shared-2-proj-a-estimate'],
          )).single['tag_id'],
          copyId,
        );
        final truth = (await db.query(
          Tables.actualTagLocations,
          where: 'location_id = ?',
          whereArgs: ['shared-2-proj-a-truth'],
        )).single;
        expect(truth['tag_id'], copyId);
        final version = (await db.query(
          Tables.tagVersions,
          where: 'tag_version_id = ?',
          whereArgs: [truth['tag_version_id']],
        )).single;
        expect(version['project_id'], 'proj-a');
        expect(version['tag_id'], copyId);
        expect(version['effective_from'], '2026-03-01T00:00:00.000Z');
        // The keeper's stayed put.
        expect(
          (await db.query(
            Tables.actualTagLocations,
            where: 'location_id = ?',
            whereArgs: ['shared-2-proj-c-truth'],
          )).single,
          allOf(
            containsPair('tag_id', 'shared-2'),
            containsPair('tag_version_id', 'shared-2-v2'),
          ),
        );
      },
    );

    test('the copied version chain is the whole chain, row for row', () async {
      final copy = await tagIn(db, 'proj-b', lineage: 'shared-1');
      final chain = await db.query(
        Tables.tagVersions,
        where: 'tag_id = ? AND project_id = ?',
        whereArgs: [copy['tag_id'], 'proj-b'],
        orderBy: 'effective_from',
      );
      expect(chain.map((v) => v['effective_from']), [
        '2026-01-01T00:00:00.000Z',
        '2026-03-01T00:00:00.000Z',
      ]);
      expect(chain.map((v) => v['frequency_mhz']), [151.105, 151.110]);
      expect(
        chain.map((v) => v['tag_version_id']),
        isNot(containsAll(['shared-1-v1', 'shared-1-v2'])),
        reason:
            'fresh ids: the same id in two projects is what the composite '
            'key permits, and it is not what a copy is',
      );
      expect(
        chain.map((v) => v['created_at']),
        ['2026-01-01T00:00:00.000Z', '2026-03-01T00:00:00.000Z'],
        reason:
            'a version\'s bookkeeping is copied verbatim — it records '
            'when the collar\'s reading was written down, and the copy is '
            'the same record',
      );
    });

    test('the "no signal" entries are left dangling by v14 and re-pointed by '
        'v15, and both reports say so', () async {
      // §3.3(3), checked against `assertSealedColumnsFeedNoReachability`
      // rather than the design: v14's fork treats the column as feeding no
      // reachability and does not read it, so its own report still counts
      // these as left alone. Schema v15 (task 11.225) runs in the same
      // `runMigrations` call and is what actually fixes them, deriving the
      // replacement from `lineage_id` rather than from anything v14
      // recorded.
      expect(
        printed,
        contains(
          '  Non_Detections rows in forked projects still naming the '
          'original tag id (left alone by design, Security Model §5.9(b)): '
          '2',
        ),
      );
      expect(
        printed,
        contains('  listened-for ids rewritten to this project\'s own copy: 2'),
      );
      expect(
        printed,
        contains(
          '  listened-for ids left alone (no same-lineage row in this '
          'project): 0',
        ),
      );

      final copyInB = await tagIn(db, 'proj-b', lineage: 'shared-1');
      final copyInA = await tagIn(db, 'proj-a', lineage: 'shared-2');
      final ndB = (await db.query(
        Tables.nonDetections,
        where: 'non_detection_id = ?',
        whereArgs: ['shared-1-proj-b-nd'],
      )).single;
      final ndA = (await db.query(
        Tables.nonDetections,
        where: 'non_detection_id = ?',
        whereArgs: ['shared-2-proj-a-nd'],
      )).single;
      expect(ndB['tag_ids_listened_for'], '["${copyInB['tag_id']}"]');
      expect(ndA['tag_ids_listened_for'], '["${copyInA['tag_id']}"]');
    });

    test('the migration reports what it forked, per table', () async {
      expect(printed, contains('  tags forked: 2'));
      expect(printed, contains('  new tag rows created: 2'));
      expect(printed, contains('  Tag_Versions rows copied: 4'));
      expect(
        printed,
        contains(
          '  records re-pointed to the forked tag — '
          'Triangulation_Sessions: 2, Observations: 6, '
          'Estimated_Positions: 2, Actual_Tag_Locations: 2',
        ),
      );
      expect(
        printed,
        contains(
          '  tag_version_id re-pointed to the copied version — '
          'Observations: 6, Actual_Tag_Locations: 2',
        ),
      );
    });
  });

  group('the ordering §3.3 left open — ties and unknown dates', () {
    TagAdoption adoption(String project, String? at) =>
        TagAdoption(projectId: project, adoptedAt: at, viaLink: true);

    test('an earlier date wins whatever the project ids are', () {
      expect(
        TagAdoption.compare(
          adoption('zzz', '2026-01-01T00:00:00.000Z'),
          adoption('aaa', '2026-02-01T00:00:00.000Z'),
        ),
        isNegative,
      );
    });

    test('an equal date is broken by project id, ascending', () {
      const at = '2026-01-01T00:00:00.000Z';
      expect(
        TagAdoption.compare(adoption('aaa', at), adoption('bbb', at)),
        isNegative,
      );
      expect(
        TagAdoption.compare(adoption('bbb', at), adoption('aaa', at)),
        isPositive,
      );
    });

    test('an unknown date sorts after every known one, then by project id', () {
      expect(
        TagAdoption.compare(
          adoption('aaa', null),
          adoption('zzz', '2026-01-01T00:00:00.000Z'),
        ),
        isPositive,
        reason: 'a date somebody recorded beats no date, whatever the ids',
      );
      expect(
        TagAdoption.compare(adoption('aaa', null), adoption('bbb', null)),
        isNegative,
      );
    });

    test('a tie on the database gives the same keeper in either insertion '
        'order', () async {
      Future<String> keeperWhenLinkedInOrder(List<String> projects) async {
        final db = await openV13();
        addTearDown(db.close);
        await seedUser(db);
        await seedProject(db, 'proj-x');
        await seedProject(db, 'proj-y');
        await seedTag(db, 'tied');
        for (final p in projects) {
          await link(db, p, 'tied', createdAt: t);
        }
        await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);
        return (await db.query(
              Tables.tags,
              where: 'tag_id = ?',
              whereArgs: ['tied'],
            )).single['project_id']!
            as String;
      }

      expect(await keeperWhenLinkedInOrder(['proj-x', 'proj-y']), 'proj-x');
      expect(
        await keeperWhenLinkedInOrder(['proj-y', 'proj-x']),
        'proj-x',
        reason:
            'the tiebreak is the project id, not the row order — the '
            'one property the ordering was chosen for',
      );
    });

    test('an empty adoption date loses the id to a recorded one, and the '
        'copy\'s dates fall back to the original\'s created_at', () async {
      // `created_at` is NOT NULL and the app never writes it empty, so this
      // is a row that violated its own column's intent; the fork still has
      // to give a deterministic answer and a non-null copied_at.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');
      await seedProject(db, 'proj-b');
      await seedTag(db, 'odd');
      await link(db, 'proj-a', 'odd', createdAt: '');
      await link(db, 'proj-b', 'odd', createdAt: '2026-07-01T00:00:00.000Z');

      final printed = <String>[];
      await runZoned(
        () => runMigrations(db, from: 13, to: lastVersionBeforeTheWipe),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );

      final keeper = (await db.query(
        Tables.tags,
        where: 'tag_id = ?',
        whereArgs: ['odd'],
      )).single;
      expect(keeper['project_id'], 'proj-b');
      final copy = await tagIn(db, 'proj-a', lineage: 'odd');
      expect(copy['copied_at'], t, reason: 'the original\'s created_at');
      expect(copy['created_at'], t);
      expect(
        printed.join('\n'),
        contains('copied into proj-a (adopted unknown, by link)'),
        reason:
            'the fallback is visible in the log rather than mistaken '
            'for a recorded date',
      );
    });
  });

  group('a project holding a tag through a record only', () {
    test('is forked too, ordered by its earliest record', () async {
      // The pasted-share screen wrote exactly this shape (design §1.3(b)):
      // proj-b has no link to the tag, only a bearing naming it. §3.3 has no
      // link date to order proj-b by, so its earliest record stands in.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');
      await seedProject(db, 'proj-b');
      await seedTag(db, 'tag-1');
      await link(db, 'proj-a', 'tag-1', createdAt: '2026-06-01T00:00:00.000Z');
      await seedBearing(
        db,
        id: 'obs-b-late',
        projectId: 'proj-b',
        tagId: 'tag-1',
        createdAt: '2026-07-09T00:00:00.000Z',
      );
      await seedBearing(
        db,
        id: 'obs-b-early',
        projectId: 'proj-b',
        tagId: 'tag-1',
        createdAt: '2026-07-02T00:00:00.000Z',
      );

      final census = await TagScopeMigration.takeCensus(db);
      expect(
        census.linkedToTwoOrMoreProjects,
        0,
        reason:
            'the link-only count, which is what §3.1 measures, sees '
            'nothing shared here — that is the point',
      );
      final fork = census.forks.single;
      expect(fork.keeper.projectId, 'proj-a');
      expect(fork.copies.single.projectId, 'proj-b');
      expect(fork.copies.single.viaLink, isFalse);
      expect(fork.copies.single.adoptedAt, '2026-07-02T00:00:00.000Z');
      expect(census.report().join('\n'), contains('by record'));

      final printed = <String>[];
      await runZoned(
        () => runMigrations(db, from: 13, to: lastVersionBeforeTheWipe),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => printed.add(line),
        ),
      );
      await db.execute('PRAGMA foreign_keys = ON');
      expect(await db.rawQuery('PRAGMA foreign_key_check'), isEmpty);

      final copy = await tagIn(db, 'proj-b', lineage: 'tag-1');
      expect(copy['copied_at'], '2026-07-02T00:00:00.000Z');
      expect(
        copy['last_modified_by'],
        'user-1',
        reason: 'no link to take an author from, so the original\'s',
      );
      for (final id in ['obs-b-early', 'obs-b-late']) {
        expect(
          (await db.query(
            Tables.observations,
            where: 'observation_id = ?',
            whereArgs: [id],
          )).single['tag_id'],
          copy['tag_id'],
        );
      }
      expect(
        printed,
        contains(
          '  records re-pointed to the forked tag — '
          'Triangulation_Sessions: 0, Observations: 2, '
          'Estimated_Positions: 0, Actual_Tag_Locations: 0',
        ),
      );
    });
  });

  group('a run with nothing to fork', () {
    test('prints zeroes, not nothing', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'proj-a');
      await seedTag(db, 'tag-1');
      await link(db, 'proj-a', 'tag-1');

      final printed = <String>[];
      await TagScopeMigration.apply(db, 13, log: printed.add);

      expect(printed, contains('  → nothing to fork.'));
      expect(printed, contains('  tags forked: 0'));
      expect(printed, contains('  new tag rows created: 0'));
      expect(printed, contains('  Tag_Versions rows copied: 0'));
      expect(
        printed,
        contains(
          '  records re-pointed to the forked tag — '
          'Triangulation_Sessions: 0, Observations: 0, '
          'Estimated_Positions: 0, Actual_Tag_Locations: 0',
        ),
      );
    });

    test('a fresh create prints nothing at all', () async {
      final db = await openV13();
      addTearDown(db.close);
      final printed = <String>[];
      await TagScopeMigration.apply(db, 0, log: printed.add);
      expect(printed, isEmpty);
    });
  });
}
