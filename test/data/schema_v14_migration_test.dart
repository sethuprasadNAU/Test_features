import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tritrack/data/db/migrations.dart';
import 'package:tritrack/data/db/schema.dart';
import 'package:tritrack/data/db/tag_scope_migration.dart';
import 'package:tritrack_sync/tritrack_sync.dart';

import 'migration_support.dart';

/// **Schema v14 (task 11.219, schema major 3): tags become project-scoped.**
///
/// The design is `CLAUDE_DOCS/TAG_COPY_ON_ADD_DESIGN.md` §3. What this file
/// holds is the part of it that is a decision rather than DDL: the census
/// and where each tag ends up. The fork of a tag two projects hold (§3.3,
/// task 11.224) is `schema_v14_fork_test.dart`.
///
/// **Every database here is built at v13 and migrated forward**, rather than
/// created at v14 and back-filled. A migration test that never runs the
/// migration on real v13 rows is testing the schema, not the change.
void main() {
  const t = '2026-08-02T12:00:00.000Z';

  Future<Database> openV13() async {
    sqfliteFfiInit();
    final db = await databaseFactoryFfi.openDatabase(
      inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 13, singleInstance: false),
    );
    await runMigrations(db, from: 0, to: 13);
    return db;
  }

  Future<void> seedUser(Database db, [String id = 'user-1']) => db.insert(
    Tables.users,
    {
      'user_id': id,
      'first_name': 'Sam',
      'last_name': 'Reyes',
      'email': '$id@example.com',
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    },
  );

  Future<void> seedProject(Database db, String projectId) => db.insert(
    Tables.projects,
    {
      'project_id': projectId,
      'project_name': projectId,
      'owner_user_id': 'user-1',
      'creation_date': t,
      'datum': 'WGS84',
      'coordinate_format': 'dd',
      'triangulation_window_minutes': 15,
      'created_at': t,
      'updated_at': t,
      'revision': 0,
    },
  );

  Future<void> seedTag(Database db, String tagId, {String name = 'Coco'}) =>
      db.insert(Tables.tags, {
        'tag_id': tagId,
        'frequency_mhz': 150.325,
        'tag_name': name,
        'date_put_on': t,
        'status': 'active',
        'color_hex': '#E69F00',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
        'last_modified_by': 'user-1',
      });

  Future<void> link(Database db, String projectId, String tagId) =>
      db.insert(Tables.projectTags, {
        'project_id': projectId,
        'tag_id': tagId,
        'status': 'active',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });

  Future<void> seedVersion(Database db, String id, String tagId) =>
      db.insert(Tables.tagVersions, {
        'tag_version_id': id,
        'tag_id': tagId,
        'effective_from': t,
        'frequency_mhz': 150.325,
        'tag_name': 'Coco',
        'created_at': t,
        'updated_at': t,
        'revision': 0,
      });

  Future<void> seedBearing(
    Database db, {
    required String id,
    required String projectId,
    required String tagId,
  }) => db.insert(Tables.observations, {
    'observation_id': id,
    'project_id': projectId,
    'user_id': 'user-1',
    'tag_id': tagId,
    'timestamp_local': t,
    'timestamp_utc': t,
    'timezone_offset': '+00:00',
    'latitude': 35.1,
    'longitude': -111.6,
    'position_source': 'gps_fix',
    'elevation': 2100.0,
    'altitude_agl': 0.0,
    'observation_type': 'directional',
    'signal_type': 'regular_pulse',
    'signal_strength': 'strong',
    'created_at': t,
    'updated_at': t,
    'revision': 0,
  });

  group('the census — §3.1, printed by the migration itself', () {
    test('counts the four numbers Michael ran, on a database like his',
        () async {
      // Michael ran §3.1's query on his Mac on 2026-09-10 and got `1|5`:
      // five tags, each in exactly one project. This is that shape.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      for (var i = 0; i < 5; i++) {
        await seedTag(db, 'tag-$i', name: 'Collar $i');
        await link(db, 'p1', 'tag-$i');
      }

      final census = await TagScopeMigration.takeCensus(db);
      expect(census.total, 5);
      expect(census.linkedToExactlyOneProject, 5);
      expect(census.linkedToTwoOrMoreProjects, 0);
      expect(census.linkedToNoProject, 0);
    });

    test('an orphan and a shared tag are each counted, separately', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedProject(db, 'p2');
      await seedTag(db, 'tag-one');
      await link(db, 'p1', 'tag-one');
      await seedTag(db, 'tag-shared');
      await link(db, 'p1', 'tag-shared');
      await link(db, 'p2', 'tag-shared');
      await seedTag(db, 'tag-orphan');

      final census = await TagScopeMigration.takeCensus(db);
      expect(census.total, 3);
      expect(census.linkedToExactlyOneProject, 1);
      expect(census.linkedToTwoOrMoreProjects, 1);
      expect(census.linkedToNoProject, 1);
    });

    test('the four numbers reach the log, and an upgrade always says '
        'something', () async {
      // **A migration that moves data and prints nothing cannot be told
      // apart from one that did nothing.** The lines are captured rather
      // than trusted: `report()` returning the right strings is not the
      // same claim as the migration emitting them.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');

      final printed = <String>[];
      await TagScopeMigration.apply(db, 13, log: printed.add);

      expect(printed.first, contains('Schema v14'));
      expect(printed, contains('  tags in total: 1'));
      expect(printed, contains('  linked to exactly one project: 1'));
      expect(printed, contains('  linked to two or more projects: 0'));
      expect(printed, contains('  linked to no project: 0'));
      expect(printed, contains('  → nothing to fork.'));
    });

    test('a fresh create prints nothing, because there is nothing to move',
        () async {
      // The app's own suite builds several hundred empty databases a run;
      // a census of zeroes on every one is noise, not a finding.
      final db = await openV13();
      addTearDown(db.close);
      final printed = <String>[];
      await TagScopeMigration.apply(db, 0, log: printed.add);
      expect(printed, isEmpty);
      // And it still *did* the migration — silence is about the report, not
      // about the work.
      expect(
        (await db.rawQuery('PRAGMA table_info(${Tables.tags})'))
            .map((c) => c['name']),
        contains('project_id'),
      );
    });
  });

  group('a tag in exactly one project — §3.2, the common case', () {
    test('keeps its identifier, gains its project, and nothing else moves',
        () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');
      await seedVersion(db, 'ver-1', 'tag-1');
      await seedBearing(db, id: 'obs-1', projectId: 'p1', tagId: 'tag-1');

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);
      await db.execute('PRAGMA foreign_keys = ON');

      final tag = (await db.query(Tables.tags)).single;
      expect(tag['tag_id'], 'tag-1');
      expect(tag['project_id'], 'p1');
      expect(
        tag['lineage_id'],
        'tag-1',
        reason: 'its own id: already unique, already unguessable, and true — '
            'nobody copied it',
      );
      expect(
        tag['copied_at'],
        isNull,
        reason: 'a tag that was always in one project was not copied, and a '
            'date invented here would be a claim about a past nobody '
            'observed',
      );

      // Every reference still resolves — which `runMigrations` has already
      // checked with `PRAGMA foreign_key_check`, and which is asserted here
      // so a reader can see what that check was protecting.
      expect((await db.query(Tables.observations)).single['tag_id'], 'tag-1');
      final version = (await db.query(Tables.tagVersions)).single;
      expect(version['tag_id'], 'tag-1');
      expect(version['project_id'], 'p1');
    });

    test('every tag also gets a library entry, so the library is complete on '
        'day one', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);

      final entry = (await db.query(kTagLibraryTable)).single;
      expect(entry['tag_id'], 'tag-1');
      expect(entry['lineage_id'], 'tag-1');
      expect(
        entry['tag_name'],
        'Coco',
        reason: 'the library is the person\'s own list of transmitters, and '
            'an empty one on the day this lands would make "copy from your '
            'library" an option nobody could take',
      );
    });

    test('the Project_Tags rows are left exactly where they are — §3.5',
        () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);

      expect(
        await db.query(Tables.projectTags),
        hasLength(1),
        reason: 'they are the only durable record of what this migration '
            'did, and an archive written before v14 still carries them',
      );
    });
  });

  group('a tag no project names — §3.3\'s orphan rule', () {
    test('moves to the library and leaves Tags', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-kept');
      await link(db, 'p1', 'tag-kept');
      await seedTag(db, 'tag-orphan', name: 'Spare');

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);

      expect(
        (await db.query(Tables.tags)).map((r) => r['tag_id']),
        ['tag-kept'],
      );
      expect(
        (await db.query(kTagLibraryTable)).map((r) => r['tag_name']),
        containsAll(['Coco', 'Spare']),
        reason: 'nothing referenced the orphan — that is what made it one — '
            'so it survives where a person can still see and copy it',
      );
    });

    test('its version chain goes with it, and the census says how many',
        () async {
      // **The one thing this migration destroys.** A version is the drift
      // record of a collar somebody was recording against, and the library
      // holds no bearings for it to be the history of. It is counted rather
      // than left to be discovered — a loss nobody printed is a loss nobody
      // knows about.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-orphan');
      await seedVersion(db, 'ver-orphan', 'tag-orphan');

      final census = await TagScopeMigration.takeCensus(db);
      expect(census.versionRowsDropped, 1);
      expect(census.report(), contains('  Tag_Versions rows deleted with '
          'those library-only tags: 1'));

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);
      expect(await db.query(Tables.tagVersions), isEmpty);
    });
  });

  group('a tag two projects hold — §3.3\'s fork', () {
    // The fork itself — who keeps the original id, the copied version
    // chain, the re-pointing, and the counts it prints — is
    // `schema_v14_fork_test.dart`, on a database of the shape Michael's
    // phone reported. Task 11.219 wrote this case as a refusal; it fired on
    // 2026-09-10 and task 11.224 replaced it with the fork. What stays here
    // is the census's wider notion of "in a project", which the fork
    // inherits.

    test('a collar two projects hold **through their bearings** is forked '
        'too, and that is wider than the query Michael ran', () async {
      // §3.1's query asks `Project_Tags` alone. A `Project_Tags` link is the
      // *usual* evidence a tag belongs to a project; a bearing naming it
      // inside a project is evidence just as good, and the two can
      // disagree — the pasted-share screen wrote exactly that shape
      // (design §1.3(b)). A migration that trusted the links alone would
      // scope this tag to `p1` and leave `p2`'s bearing pointing at a tag
      // its project does not hold.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedProject(db, 'p2');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');
      await seedBearing(db, id: 'obs-2', projectId: 'p2', tagId: 'tag-1');

      final census = await TagScopeMigration.takeCensus(db);
      expect(
        census.linkedToTwoOrMoreProjects,
        0,
        reason: 'the link-only count, which is what §3.1 measures, sees '
            'nothing wrong here — that is the point',
      );
      expect(census.sharedTagIds.keys, ['tag-1']);
      expect(census.forks.single.keeper.projectId, 'p1');
      expect(census.forks.single.copies.single.projectId, 'p2');
    });

    test('a tag whose only evidence is a bearing is kept, not dropped',
        () async {
      // The same widening in the other direction, and the one that would
      // have cost data: scoping by links alone would treat this as an
      // orphan, delete it from `Tags`, and take the bearing's foreign key
      // with it.
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await seedBearing(db, id: 'obs-1', projectId: 'p1', tagId: 'tag-1');

      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);
      await db.execute('PRAGMA foreign_keys = ON');

      final tag = (await db.query(Tables.tags)).single;
      expect(tag['tag_id'], 'tag-1');
      expect(tag['project_id'], 'p1');
      expect((await db.query(Tables.observations)).single['tag_id'], 'tag-1');
    });
  });

  group('the shape the schema ends up in', () {
    test('a tag is keyed by its id and its project, and every reference into '
        'it is composite', () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');
      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);

      final tags = (await db.rawQuery(
        "SELECT sql FROM sqlite_master WHERE name = '${Tables.tags}'",
      )).single['sql']! as String;
      expect(tags, contains('PRIMARY KEY (tag_id, project_id)'));

      for (final table in [
        Tables.observations,
        Tables.triangulationSessions,
        Tables.estimatedPositions,
        Tables.actualTagLocations,
        Tables.tagVersions,
      ]) {
        final sql = (await db.rawQuery(
          "SELECT sql FROM sqlite_master WHERE name = ?",
          [table],
        )).single['sql']! as String;
        expect(
          sql,
          contains('FOREIGN KEY (tag_id, project_id)'),
          reason: '$table references a tag, and a tag is keyed by its id and '
              'its project — a single-column reference would name no unique '
              'key and SQLite reports it as a foreign key mismatch at the '
              'first write',
        );
      }
    });

    test('the same tag id may exist in two projects — what the bump buys',
        () async {
      final db = await openV13();
      addTearDown(db.close);
      await seedUser(db);
      await seedProject(db, 'p1');
      await seedProject(db, 'p2');
      await seedTag(db, 'tag-1');
      await link(db, 'p1', 'tag-1');
      await runMigrations(db, from: 13, to: lastVersionBeforeTheWipe);
      await db.execute('PRAGMA foreign_keys = ON');

      final original = (await db.query(Tables.tags)).single;
      // A copy keeps the lineage and takes a fresh id, which is the design.
      // Asserting the *key* rather than the design here: the schema must
      // also permit an archive that carries one project's id into another,
      // exactly as schema v6 did for observations.
      await db.insert(Tables.tags, {
        ...original,
        'project_id': 'p2',
        'copied_at': t,
        // Task 11.240: an individual is project-scoped; the composite key
        // refuses a copy naming the other project's. See the v6 test's
        // helper for the same line.
        'individual_id': null,
      });
      expect(await db.query(Tables.tags), hasLength(2));
    });

    test('the library never leaves the device: it is in no shared '
        'declaration', () async {
      expect(tableSpecs.map((s) => s.name), isNot(contains(kTagLibraryTable)));
      expect(syncTables.map((t) => t.name), isNot(contains(kTagLibraryTable)));
      expect(Tables.all, isNot(contains(kTagLibraryTable)));
      expect(
        Tables.all,
        isNot(contains(Tables.projectTags)),
        reason: 'Project_Tags left the wire in task 11.219, while staying in '
            'the local schema as the record of what this migration did',
      );
    });
  });
}
